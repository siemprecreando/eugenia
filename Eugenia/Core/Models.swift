import Foundation

/// Modelo de datos. Plan, sección 7, reducido a un índice JSON.
///
/// COMPATIBILIDAD HACIA ATRÁS — regla de este fichero: TODO campo nuevo se decodifica
/// con `decodeIfPresent` y un valor por defecto. Un campo nuevo no opcional hacía que
/// el índice entero dejara de decodificar, `Store.load` lo daba por vacío y el
/// siguiente guardado borraba todas las reuniones. Ver `NoteCompatTests`.

/// Estados de una nota. Se guardan como texto para que el índice sea legible desde
/// Linux y para no romper índices antiguos si se añade uno.
enum NoteState {
    static let recording   = "recording"    // grabando ahora mismo
    static let interrupted = "interrupted"  // la app murió grabando; se recuperó lo que había
    static let queued      = "queued"       // transcripción guardada, esperando enriquecimiento
    static let processing  = "processing"   // diarizando / resumiendo / indexando
    static let summarized  = "summarized"   // lista
    static let failed      = "failed"       // el enriquecimiento falló; la transcripción está
    static let imported    = "imported"     // entró por importación, pendiente de transcribir
    /// Heredado de la v0.1: "transcribed" significaba lo mismo que `queued`.
    static let legacyTranscribed = "transcribed"
}

struct TranscriptSegment: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    /// Segundos desde el inicio de la grabación, en tiempo del AUDIO (no del reloj).
    var start: Double
    var end: Double
    /// Etiqueta del hablante ("S1", "S2"…) tras la diarización. nil = sin asignar.
    var speaker: String?
    /// Marca del sistema, no habla: "interrupción de 00:42", "reanudado"…
    var isMarker: Bool = false

    init(text: String, start: Double, end: Double, speaker: String? = nil, isMarker: Bool = false) {
        self.text = text; self.start = start; self.end = end
        self.speaker = speaker; self.isMarker = isMarker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        isMarker = try c.decodeIfPresent(Bool.self, forKey: .isMarker) ?? false
    }
}

struct StoredActionItem: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var assignee: String
    /// propuesto | confirmado | reasignado | aplazado | cancelado | cerrado
    var status: String
    /// Segundo del audio en el que se decidió (último eslabón de la cadena).
    var atSeconds: Int
    var done: Bool = false
    /// Vencimiento tal como se dijo ("el viernes", "la semana que viene"). Nunca se
    /// convierte a fecha concreta por nuestra cuenta (plan 5.4.5).
    var dueText: String = ""
    /// Cadena temporal legible: "Asignado a Marta en 03:10", "Reasignado a Javier en 41:55".
    var history: [String] = []
    /// Contradicción real detectada (plan 5.4.4): sale a la UI como pregunta.
    var needsConfirmation: Bool = false

    init(text: String, assignee: String, status: String, atSeconds: Int,
         done: Bool = false, dueText: String = "", history: [String] = [],
         needsConfirmation: Bool = false) {
        self.text = text; self.assignee = assignee; self.status = status
        self.atSeconds = atSeconds; self.done = done; self.dueText = dueText
        self.history = history; self.needsConfirmation = needsConfirmation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "propuesto"
        atSeconds = try c.decodeIfPresent(Int.self, forKey: .atSeconds) ?? 0
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        dueText = try c.decodeIfPresent(String.self, forKey: .dueText) ?? ""
        history = try c.decodeIfPresent([String].self, forKey: .history) ?? []
        needsConfirmation = try c.decodeIfPresent(Bool.self, forKey: .needsConfirmation) ?? false
    }

    /// Los estados finales no pueden aparecer como "próximos pasos" (plan 5.4.5).
    var isOpen: Bool { !["cancelado", "aplazado", "cerrado"].contains(status) && !done }
}

/// Una frase del resumen con el rango de audio del que sale (plan 5.4.7: trazabilidad).
struct SummaryPoint: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var atSeconds: Int

    init(text: String, atSeconds: Int) { self.text = text; self.atSeconds = atSeconds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        atSeconds = try c.decodeIfPresent(Int.self, forKey: .atSeconds) ?? 0
    }
}

/// Resultado del map de un fragmento, persistido con el hash del fragmento (plan
/// 5.4.7): reanudar un resumen interrumpido no rehace lo ya hecho.
struct MapCheckpoint: Codable, Equatable {
    var chunkHash: String
    var notes: String
    var openItemsJSON: String
}

struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var language: String
    /// v0.1: un único fichero. Desde v0.2 el audio va en trozos (`audioParts`) para que
    /// un cierre inesperado pierda como mucho el trozo en curso, no la reunión.
    var audioFileName: String?
    var audioParts: [String] = []
    /// present | deleted (retención, plan 8.2) | none (nota importada de texto/PDF)
    var audioState: String = "present"
    var transcript: String
    var segments: [TranscriptSegment] = []
    var summaryOverview: String
    var keyPoints: [SummaryPoint] = []
    var decisions: [String]
    var actionItems: [StoredActionItem]
    var state: String
    /// Texto legible del fallo. NUNCA el `String(describing:)` de un error: los de
    /// FoundationModels pueden llevar dentro el fragmento de transcripción.
    var failure: String?
    var folder: String = ""
    /// executive | actionItems | detailed | oneOnOne | sales (plan, Fase 3)
    var template: String = "executive"
    /// Etiqueta de diarización → nombre que puso el usuario ("S1" → "Marta").
    var speakerNames: [String: String] = [:]
    var followUpEmail: String = ""
    /// Idioma → contenido traducido (transcripción y resumen), plan Fase 3.
    var translations: [String: Translation] = [:]
    var mapCheckpoints: [MapCheckpoint] = []
    var isFavorite: Bool = false
    /// "document" para notas de PDF/texto importado; "audio" para grabaciones.
    var source: String = "audio"
    var attendees: [String] = []
    var calendarEventID: String?
    /// Re-transcripción pedida en otro idioma. La transcripción y el resumen actuales
    /// NO se borran hasta que la nueva sale bien (revisión 2026-09-18).
    var pendingLanguage: String?
    /// Motivo de fallo máquina-legible: "modelUnavailable" se reintenta solo al activar
    /// Apple Intelligence; el resto, solo a mano.
    var failureCode: String?

    struct Translation: Codable, Equatable {
        var transcript: String
        var overview: String
        var decisions: [String]
    }

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), duration: TimeInterval = 0,
         language: String, audioFileName: String? = nil, transcript: String = "",
         summaryOverview: String = "", decisions: [String] = [],
         actionItems: [StoredActionItem] = [], state: String, failure: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.duration = duration
        self.language = language; self.audioFileName = audioFileName; self.transcript = transcript
        self.summaryOverview = summaryOverview; self.decisions = decisions
        self.actionItems = actionItems; self.state = state; self.failure = failure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Reunión"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "es"
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        audioParts = try c.decodeIfPresent([String].self, forKey: .audioParts) ?? []
        audioState = try c.decodeIfPresent(String.self, forKey: .audioState) ?? "present"
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        summaryOverview = try c.decodeIfPresent(String.self, forKey: .summaryOverview) ?? ""
        keyPoints = try c.decodeIfPresent([SummaryPoint].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([StoredActionItem].self, forKey: .actionItems) ?? []
        var s = try c.decodeIfPresent(String.self, forKey: .state) ?? NoteState.queued
        if s == NoteState.legacyTranscribed { s = NoteState.queued }
        state = s
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? "executive"
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        followUpEmail = try c.decodeIfPresent(String.self, forKey: .followUpEmail) ?? ""
        translations = try c.decodeIfPresent([String: Translation].self, forKey: .translations) ?? [:]
        mapCheckpoints = try c.decodeIfPresent([MapCheckpoint].self, forKey: .mapCheckpoints) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "audio"
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        pendingLanguage = try c.decodeIfPresent(String.self, forKey: .pendingLanguage)
        failureCode = try c.decodeIfPresent(String.self, forKey: .failureCode)
    }

    /// Todos los ficheros de audio de la nota, en orden, incluido el formato v0.1.
    var allAudioFiles: [String] {
        if !audioParts.isEmpty { return audioParts }
        return audioFileName.map { [$0] } ?? []
    }

    /// Nombre visible de un hablante: el que puso el usuario o "Hablante N".
    func displayName(forSpeaker label: String?) -> String? {
        guard let label else { return nil }
        if let name = speakerNames[label], !name.isEmpty { return name }
        let n = label.drop(while: { !$0.isNumber })
        return n.isEmpty ? label : "Hablante \(n)"
    }

    /// Transcripción plana reconstruida desde los segmentos, con hablante si lo hay.
    func renderedTranscript(withTimestamps: Bool = false, withSpeakers: Bool = true) -> String {
        guard !segments.isEmpty else { return transcript }
        var lines: [String] = []
        var lastSpeaker: String??  = .none
        for s in segments {
            if s.isMarker { lines.append("[\(s.text)]"); lastSpeaker = .none; continue }
            var prefix = ""
            if withTimestamps { prefix += "[\(TimeFormat.mmss(s.start))] " }
            if withSpeakers, let name = displayName(forSpeaker: s.speaker), lastSpeaker != .some(s.speaker) {
                prefix += "\(name): "
            }
            lastSpeaker = .some(s.speaker)
            lines.append(prefix + s.text)
        }
        return lines.joined(separator: withSpeakers || withTimestamps ? "\n" : " ")
    }

    var speakerLabels: [String] {
        var seen: [String] = []
        for s in segments { if let sp = s.speaker, !seen.contains(sp) { seen.append(sp) } }
        return seen
    }
}

enum TimeFormat {
    static func mmss(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
