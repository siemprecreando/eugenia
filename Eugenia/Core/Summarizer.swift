import CryptoKit
import Foundation
import FoundationModels

/// Resumen con el LLM on-device. Plan, sección 5.4.
///
/// La ventana es de 4.096 tokens y en el iPhone 17e (8 GB) **es permanente**: los
/// modelos de ventana grande de iOS 27 piden 12 GB o salen del teléfono por PCC
/// (plan 6.1). Así que el map-reduce con acarreo de estado no es un puente, es la
/// arquitectura.
///
/// Tres etapas:
///  1. MAP con libro de estado: cada fragmento devuelve MENCIONES de compromisos con
///     un `refId` estable, el instante y la evidencia. Persistido por hash (5.4.7).
///  2. RESOLUCIÓN TEMPORAL en Swift puro (5.4.4): agrupar por `refId`, ordenar por
///     instante, la última decisión gana, el historial se conserva y las
///     contradicciones reales se marcan para preguntar, nunca se inventan.
///  3. REDUCE con el contrato de 5.4.5 y la plantilla elegida.

// MARK: - Tipos generados

@Generable
struct TimedPoint: Equatable {
    @Guide(description: "Una idea en una frase, en el idioma de la reunión")
    var text: String
    @Guide(description: "Segundo de la grabación del que sale, tomado de las marcas [mm:ss] del texto")
    var atSeconds: Int
}

@Generable
struct CommitmentMention: Equatable {
    @Guide(description: "Identificador estable del compromiso. Si continúa uno del ESTADO ABIERTO, reutiliza su refId; si es nuevo, inventa uno corto (c1, c2…)")
    var refId: String
    @Guide(description: "La tarea, en una frase, en el idioma de la reunión")
    var text: String
    @Guide(description: "Responsable SOLO si se dice explícitamente. Si no, cadena vacía. No inventar.")
    var assignee: String
    @Guide(.anyOf(["propuesto", "confirmado", "reasignado", "aplazado", "cancelado", "cerrado"]))
    var status: String
    @Guide(description: "Vencimiento EXACTAMENTE como se dijo ('el viernes', 'next week'). Vacío si no se dijo. Nunca conviertas a fecha.")
    var dueText: String
    @Guide(description: "Segundo de la grabación de esta mención, de las marcas [mm:ss]")
    var atSeconds: Int
}

@Generable
struct ChunkDigest {
    @Guide(description: "Qué pasa en este fragmento, 2-3 frases. No repetir lo que ya está en el estado abierto.")
    var notes: String
    @Guide(description: "Ideas importantes del fragmento con su instante")
    var points: [TimedPoint]
    @Guide(description: "Menciones de compromisos en este fragmento: nuevos, o cambios de los del estado abierto")
    var mentions: [CommitmentMention]
}

@Generable
struct MeetingSummary {
    @Guide(description: "Resumen de la reunión en 3-5 frases")
    var overview: String
    @Guide(description: "Puntos clave, cada uno con el segundo del que procede")
    var keyPoints: [TimedPoint]
    @Guide(description: "Decisiones tomadas, en pasado. Incluye lo aplazado, descartado o cerrado. Vacío si no hubo.")
    var decisions: [String]
}

@Generable
struct AnswerWithCitations {
    @Guide(description: "Respuesta breve y directa, solo con información de los fragmentos")
    var answer: String
    @Guide(description: "Segundos de los fragmentos que respaldan la respuesta")
    var citations: [Int]
}

@Generable
struct TranslatedSummary {
    var overview: String
    var decisions: [String]
}

/// Copias planas de lo que devuelve el modelo. Los tipos `@Generable` no se
/// construyen a mano (el macro puede no dejar inicializador memberwise): la
/// resolución, los checkpoints y las pruebas trabajan sobre estas.
struct Mention: Codable, Equatable {
    var refId: String
    var text: String
    var assignee: String
    var status: String
    var dueText: String
    var atSeconds: Int

    init(refId: String, text: String, assignee: String, status: String, dueText: String = "", atSeconds: Int) {
        self.refId = refId; self.text = text; self.assignee = assignee
        self.status = status; self.dueText = dueText; self.atSeconds = atSeconds
    }

    init(_ m: CommitmentMention) {
        self.init(refId: m.refId, text: m.text, assignee: m.assignee, status: m.status,
                  dueText: m.dueText, atSeconds: m.atSeconds)
    }
}

struct Point: Codable, Equatable {
    var text: String
    var atSeconds: Int
}

/// El resultado ya resuelto, listo para guardar en la nota.
struct SummaryResult {
    var overview: String
    var keyPoints: [SummaryPoint]
    var decisions: [String]
    var actionItems: [StoredActionItem]
}

enum SummarizerError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case allChunksFailed(Int)
    case emptyTranscript

    var description: String {
        switch self {
        case .modelUnavailable(let reason):
            return "La transcripción está guardada, pero el resumen necesita Apple Intelligence. "
                 + "Actívalo en Ajustes › Apple Intelligence y Siri y deja que termine de descargar. (\(reason))"
        case .allChunksFailed(let n):
            return "El modelo no pudo procesar ninguno de los \(n) fragmentos. La transcripción está guardada; "
                 + "vuelve a intentarlo más tarde."
        case .emptyTranscript:
            return "No hay transcripción que resumir: la grabación no contiene voz reconocible."
        }
    }
}

enum SummaryTemplate: String, CaseIterable, Identifiable {
    case executive, actionItems, detailed, oneOnOne, sales
    var id: String { rawValue }

    var title: String {
        switch self {
        case .executive: return "Resumen ejecutivo"
        case .actionItems: return "Tareas y responsables"
        case .detailed: return "Acta detallada"
        case .oneOnOne: return "Reunión 1:1"
        case .sales: return "Llamada comercial"
        }
    }

    var instructions: String {
        switch self {
        case .executive:
            return "Resumen ejecutivo: lo esencial para alguien que no estuvo, en 3-5 frases, y 3-6 puntos clave."
        case .actionItems:
            return "Céntrate en qué se acordó hacer y quién. El resumen es breve (2-3 frases); los puntos clave son los acuerdos."
        case .detailed:
            return "Acta detallada: resumen de 5 frases y un punto clave por cada tema tratado, en orden, sin omitir temas."
        case .oneOnOne:
            return "Reunión 1:1: estado de la persona, bloqueos, feedback dado y recibido, y acuerdos de seguimiento."
        case .sales:
            return "Llamada comercial: necesidades del cliente, objeciones, presupuesto y plazos mencionados, y siguientes pasos."
        }
    }
}

// MARK: - Resumidor

struct Summarizer {

    static func availabilityDescription() -> String { availabilitySnapshot().descripcion }

    /// Las dos cosas de UNA sola lectura. Preguntarlo dos veces puede dar dos
    /// respuestas distintas, y entonces la insignia y el texto se contradicen.
    static func availabilitySnapshot() -> (disponible: Bool, descripcion: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "available")
        case .unavailable(let reason):
            return (false, "unavailable(\(String(describing: reason)))")
        @unknown default:
            return (false, "unknown")
        }
    }

    static var isAvailable: Bool { availabilitySnapshot().disponible }

    /// Presupuesto por fragmento en caracteres. Aproximación estable a los tokens:
    /// ~3.000 caracteres ≈ 900-1.100 tokens en español, que deja sitio al libro de
    /// estado, las instrucciones y la salida dentro de 4.096.
    static let chunkChars = 2_800
    /// El libro de estado que viaja en cada map no puede crecer sin límite.
    static let maxOpenItemsInPrompt = 20

    static func languageName(_ code: String) -> String { code == "en" ? "inglés" : "español" }

    /// Resume una nota. `checkpoints` son los map ya hechos (por hash del fragmento):
    /// si una reunión se reanuda, no se rehacen. `onCheckpoint` persiste cada map nuevo.
    static func summarize(segments: [TranscriptSegment], plainTranscript: String, language: String,
                          template: SummaryTemplate, tone: String, meetingDate: Date,
                          speakerName: (String?) -> String?,
                          checkpoints: [MapCheckpoint],
                          onCheckpoint: (MapCheckpoint) -> Void) async throws -> SummaryResult {
        guard isAvailable else { throw SummarizerError.modelUnavailable(availabilityDescription()) }

        let lines = timedLines(segments: segments, plain: plainTranscript, speakerName: speakerName)
        let chunks = split(lines.joined(separator: "\n"))
        guard !chunks.isEmpty else { throw SummarizerError.emptyTranscript }
        Log.event(Log.summarize, "mapreduce.start", "chunks=\(chunks.count)")

        var mentions: [Mention] = []
        var notes: [String] = []
        var points: [Point] = []
        var failures = 0
        let known = Dictionary(checkpoints.map { ($0.chunkHash, $0) }, uniquingKeysWith: { a, _ in a })

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let hash = hashOf(chunk)
            if let cp = known[hash], let decoded = decodeCheckpoint(cp) {
                mentions += decoded.mentions
                notes.append(cp.notes)
                points += decoded.points
                continue
            }

            let open = ActionResolver.resolve(mentions).filter(\.isOpen).suffix(maxOpenItemsInPrompt)
            let state = open.isEmpty ? "(vacío)" : open.map {
                "- refId=\($0.refId) [\($0.status)] \($0.text) · \($0.assignee.isEmpty ? "sin responsable" : $0.assignee)"
            }.joined(separator: "\n")

            let session = LanguageModelSession {
                """
                Eres un analista de reuniones. Escribes en \(languageName(language)).
                Recibes un FRAGMENTO de la transcripción, con marcas [mm:ss], y el ESTADO
                ABIERTO con los compromisos que siguen vivos.

                Reglas, en orden de importancia:
                1. No inventes. Si un dato no está dicho, déjalo vacío.
                2. Si un compromiso del estado abierto cambia de responsable, de fecha, se
                   aplaza o se cancela, emite una mención con SU MISMO refId y el nuevo estado.
                3. Cada mención e idea lleva el segundo de la marca [mm:ss] más cercana.
                4. Un tema que vuelve se continúa con su refId, no se duplica.
                """
            }
            let prompt = """
            ESTADO ABIERTO:
            \(state)

            FRAGMENTO \(index + 1) de \(chunks.count):
            \(chunk)
            """
            do {
                let response = try await session.respond(to: Prompt(prompt), generating: ChunkDigest.self)
                let d = response.content
                // refIds que el modelo NO vio (cerrados o fuera de los 20 del estado)
                // pueden repetirse para una tarea distinta: se renombran por fragmento
                // para que el resolvedor no fusione tareas ajenas.
                let shown = Set(open.map(\.refId))
                let existing = Set(mentions.map(\.refId))
                let newMentions = d.mentions.map(Mention.init).map { m -> Mention in
                    var x = m
                    if existing.contains(x.refId) && !shown.contains(x.refId) { x.refId = "k\(index)-\(x.refId)" }
                    return x
                }
                let newPoints = d.points.map { Point(text: $0.text, atSeconds: $0.atSeconds) }
                mentions += newMentions
                notes.append(d.notes)
                points += newPoints
                onCheckpoint(encodeCheckpoint(hash: hash, notes: d.notes, mentions: newMentions, points: newPoints))
                Log.event(Log.summarize, "map.chunk", "i=\(index) mentions=\(newMentions.count)")
            } catch is CancellationError {
                throw CancellationError()        // grabación nueva: vuelve a la cola, no "falla"
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Un fragmento que falla no tira el resumen entero; todos, sí.
                Log.failure(Log.summarize, "map.chunk", error)
                failures += 1
            }
        }
        if failures == chunks.count { throw SummarizerError.allChunksFailed(chunks.count) }

        let resolved = ActionResolver.resolve(mentions)
        let items = resolved.map {
            "- [\($0.status)] \($0.text) · \($0.assignee.isEmpty ? "sin responsable" : $0.assignee)"
            + ($0.dueText.isEmpty ? "" : " · vence: \($0.dueText)") + " · t=\($0.atSeconds)s"
            + ($0.needsConfirmation ? " · CONTRADICTORIO" : "")
        }.joined(separator: "\n")

        let f = DateFormatter(); f.dateStyle = .full
        f.locale = Locale(identifier: language == "en" ? "en_US" : "es_ES")
        let reduce = LanguageModelSession {
            """
            Eres un analista de reuniones. Escribes en \(languageName(language)), con tono \(toneDescription(tone)).
            Plantilla: \(template.instructions)
            La reunión fue el \(f.string(from: meetingDate)).

            Contrato:
            1. No inventes nada que no esté en las notas.
            2. Nunca fusiones compromisos con distinto responsable o vencimiento.
            3. Lo aplazado, cancelado o cerrado va en decisiones, en pasado, nunca como pendiente.
            4. No conviertas fechas vagas en fechas concretas.
            5. Cada punto clave lleva su segundo.
            6. Si algo está marcado CONTRADICTORIO, dilo como pregunta abierta.
            """
        }
        let pointsText = points.prefix(40).map { "[\(TimeFormat.mmss(Double($0.atSeconds)))] \($0.text)" }
                               .joined(separator: "\n")
        let prompt = """
        NOTAS POR FRAGMENTO:
        \(notes.filter { !$0.isEmpty }.joined(separator: "\n\n"))

        IDEAS CON INSTANTE:
        \(pointsText.isEmpty ? "(ninguna)" : pointsText)

        COMPROMISOS RESUELTOS:
        \(items.isEmpty ? "(ninguno)" : items)
        """
        let response = try await reduce.respond(to: Prompt(String(prompt.prefix(9_000))),
                                                generating: MeetingSummary.self)
        let s = response.content
        Log.event(Log.summarize, "mapreduce.done", "items=\(resolved.count) points=\(s.keyPoints.count)")
        return SummaryResult(overview: s.overview,
                             keyPoints: s.keyPoints.map { SummaryPoint(text: $0.text, atSeconds: max(0, $0.atSeconds)) },
                             decisions: s.decisions,
                             actionItems: resolved.map(\.stored))
    }

    static func toneDescription(_ tone: String) -> String {
        switch tone {
        case "formal": return "formal y profesional"
        case "casual": return "cercano y directo"
        case "concise": return "telegráfico, frases muy cortas"
        default: return "neutro"
        }
    }

    /// Líneas "[mm:ss] Hablante: texto". Sin segmentos (notas v0.1 o importadas de
    /// texto) se usa el texto plano sin marcas.
    static func timedLines(segments: [TranscriptSegment], plain: String,
                           speakerName: (String?) -> String?) -> [String] {
        let speech = segments.filter { !$0.isMarker }
        guard !speech.isEmpty else { return plain.isEmpty ? [] : [plain] }
        return speech.map { s in
            let who = speakerName(s.speaker).map { "\($0): " } ?? ""
            return "[\(TimeFormat.mmss(s.start))] \(who)\(s.text)"
        }
    }

    static func hashOf(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct CheckpointPayload: Codable {
        var mentions: [Mention]
        var points: [Point]
    }

    static func encodeCheckpoint(hash: String, notes: String, mentions: [Mention], points: [Point]) -> MapCheckpoint {
        let json = (try? JSONEncoder().encode(CheckpointPayload(mentions: mentions, points: points)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return MapCheckpoint(chunkHash: hash, notes: notes, openItemsJSON: json)
    }

    static func decodeCheckpoint(_ cp: MapCheckpoint) -> (mentions: [Mention], points: [Point])? {
        guard let p = try? JSONDecoder().decode(CheckpointPayload.self, from: Data(cp.openItemsJSON.utf8)) else { return nil }
        return (p.mentions, p.points)
    }

    /// Internal, no private: el troceado decide cuántas llamadas al LLM se hacen y
    /// dónde se parte una idea. Es lógica pura y tiene pruebas.
    ///
    /// Corta en fin de frase (. ? ! …) o salto de línea, y el separador viaja dentro
    /// de la frase: no se inventa ni se pierde ningún carácter. Una "frase" más larga
    /// que el presupuesto (ASR sin puntuación) se parte en duro por espacios: antes se
    /// quedaba entera y desbordaba la ventana del modelo.
    static func split(_ text: String, limit: Int = chunkChars) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var current = ""
        var sentence = ""

        func push(_ piece: String) {
            if current.count + piece.count > limit, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += piece
        }

        func flush() {
            guard !sentence.isEmpty else { return }
            if sentence.count > limit {
                // Partir en duro, preferiblemente en un espacio.
                var rest = Substring(sentence)
                while rest.count > limit {
                    let cut = rest.index(rest.startIndex, offsetBy: limit)
                    let head = rest[..<cut]
                    let splitAt = head.lastIndex(of: " ").map { rest.index(after: $0) } ?? cut
                    push(String(rest[..<splitAt]))
                    rest = rest[splitAt...]
                }
                if !rest.isEmpty { push(String(rest)) }
            } else {
                push(sentence)
            }
            sentence = ""
        }

        for character in text {
            sentence.append(character)
            if ".?!…\n".contains(character) { flush() }
        }
        flush()

        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Ask AI (plan 5.5)

    /// Responde con los fragmentos recuperados. Las preguntas globales ("¿de qué trató
    /// la reunión?") no pasan por aquí: se contestan con el resumen (ver AskAIView).
    static func answer(question: String, passages: [SearchHit], language: String) async throws -> AnswerWithCitations {
        guard isAvailable else { throw SummarizerError.modelUnavailable(availabilityDescription()) }
        let context = passages.prefix(8).map {
            "[\($0.noteTitle) · \(TimeFormat.mmss($0.atSeconds))] (s=\(Int($0.atSeconds))) \($0.text)"
        }.joined(separator: "\n")
        let session = LanguageModelSession {
            """
            Respondes preguntas sobre reuniones usando SOLO los fragmentos dados.
            Escribes en \(languageName(language)). Si los fragmentos no contienen la
            respuesta, dilo claramente. Cita los segundos (s=…) de los fragmentos usados.
            """
        }
        let prompt = "FRAGMENTOS:\n\(String(context.prefix(7_000)))\n\nPREGUNTA: \(question)"
        return try await session.respond(to: Prompt(prompt), generating: AnswerWithCitations.self).content
    }

    // MARK: - Email de seguimiento y traducción (Fase 3)

    static func followUpEmail(note: Note) async throws -> String {
        guard isAvailable else { throw SummarizerError.modelUnavailable(availabilityDescription()) }
        let tasks = note.actionItems.filter(\.isOpen).map {
            "- \($0.text)\($0.assignee.isEmpty ? "" : " (\($0.assignee))")\($0.dueText.isEmpty ? "" : " — \($0.dueText)")"
        }.joined(separator: "\n")
        let session = LanguageModelSession {
            """
            Redactas emails de seguimiento de reuniones, en \(languageName(note.language)), breves y
            profesionales. Sin inventar nada. Incluye asunto en la primera línea ("Asunto: …").
            """
        }
        let prompt = """
        REUNIÓN: \(note.title)
        RESUMEN: \(note.summaryOverview)
        DECISIONES:
        \(note.decisions.map { "- \($0)" }.joined(separator: "\n"))
        TAREAS:
        \(tasks.isEmpty ? "(ninguna)" : tasks)
        """
        return try await session.respond(to: Prompt(String(prompt.prefix(8_000)))).content
    }

    /// Traducción es ↔ en, on-device con el mismo modelo. La transcripción se traduce
    /// por fragmentos para no desbordar la ventana.
    static func translate(note: Note, to target: String) async throws -> Note.Translation {
        guard isAvailable else { throw SummarizerError.modelUnavailable(availabilityDescription()) }
        let targetName = languageName(target)
        var translatedChunks: [String] = []
        for chunk in split(note.renderedTranscript(withSpeakers: true), limit: 1_800) {
            try Task.checkCancellation()
            let s = LanguageModelSession {
                "Traduces al \(targetName) de forma fiel y natural. Devuelve SOLO la traducción, conservando nombres y marcas."
            }
            translatedChunks.append(try await s.respond(to: Prompt(chunk)).content)
        }
        var overview = ""
        var decisions: [String] = []
        if !note.summaryOverview.isEmpty {
            let s = LanguageModelSession { "Traduces al \(targetName) de forma fiel. No añadas nada." }
            let prompt = "RESUMEN:\n\(note.summaryOverview)\n\nDECISIONES:\n\(note.decisions.joined(separator: "\n"))"
            let r = try await s.respond(to: Prompt(prompt), generating: TranslatedSummary.self).content
            overview = r.overview
            decisions = r.decisions
        }
        return Note.Translation(transcript: translatedChunks.joined(separator: "\n"),
                                overview: overview, decisions: decisions)
    }
}

// MARK: - Resolución temporal (plan 5.4.4) — Swift puro, con pruebas

struct ResolvedItem: Equatable {
    var refId: String
    var text: String
    var assignee: String
    var status: String
    var dueText: String
    var atSeconds: Int
    var history: [String]
    var needsConfirmation: Bool

    var isOpen: Bool { !["cancelado", "aplazado", "cerrado"].contains(status) }

    var stored: StoredActionItem {
        StoredActionItem(text: text, assignee: assignee, status: status, atSeconds: atSeconds,
                         dueText: dueText, history: history, needsConfirmation: needsConfirmation)
    }
}

enum ActionResolver {
    /// Agrupa por `refId`, ordena por instante, la última mención gana y el resto se
    /// conserva como historial. Marca contradicción (nunca la resuelve inventando) si:
    ///  - la última mención es `propuesto` y una anterior era `confirmado`, o
    ///  - dos menciones a menos de 30 s asignan responsables distintos.
    static func resolve(_ mentions: [Mention]) -> [ResolvedItem] {
        var order: [String] = []
        var groups: [String: [Mention]] = [:]
        for m in mentions {
            let key = m.refId.trimmingCharacters(in: .whitespaces).lowercased().isEmpty
                ? "t:" + m.text.lowercased() : m.refId.trimmingCharacters(in: .whitespaces).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.compactMap { key in
            guard let group = groups[key]?.sorted(by: { $0.atSeconds < $1.atSeconds }), let last = group.last else { return nil }
            var history: [String] = []
            var previousAssignee = ""
            for m in group {
                let t = TimeFormat.mmss(Double(m.atSeconds))
                if m.assignee != previousAssignee, !m.assignee.isEmpty {
                    history.append(previousAssignee.isEmpty ? "Asignado a \(m.assignee) en \(t)"
                                                            : "Reasignado de \(previousAssignee) a \(m.assignee) en \(t)")
                    previousAssignee = m.assignee
                } else if m.status != "propuesto" || history.isEmpty {
                    history.append("\(m.status.capitalized) en \(t)")
                }
            }
            var contradiction = false
            if last.status == "propuesto", group.dropLast().contains(where: { $0.status == "confirmado" }) {
                contradiction = true
            }
            for (a, b) in zip(group, group.dropFirst())
            where !a.assignee.isEmpty && !b.assignee.isEmpty && a.assignee != b.assignee
                && abs(b.atSeconds - a.atSeconds) < 30 {
                contradiction = true
            }
            let assignee = last.assignee.isEmpty ? previousAssignee : last.assignee
            let due = last.dueText.isEmpty ? (group.last { !$0.dueText.isEmpty }?.dueText ?? "") : last.dueText
            return ResolvedItem(refId: key, text: last.text, assignee: assignee, status: last.status,
                                dueText: due, atSeconds: max(0, last.atSeconds),
                                history: history.count > 1 ? history : [],
                                needsConfirmation: contradiction)
        }
    }
}
