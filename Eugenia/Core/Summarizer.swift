import Foundation
import FoundationModels

/// Resumen con el LLM on-device. Plan, sección 5.4.
///
/// La ventana es de 4.096 tokens y en el iPhone 17e (8 GB) **es permanente**: los
/// modelos de ventana grande de iOS 27 piden 12 GB (plan 6.1). Así que el map-reduce
/// con acarreo de estado no es un puente, es la arquitectura.

@Generable
struct ActionItemDraft: Equatable {
    @Guide(description: "La tarea, en una frase, en el mismo idioma que la transcripción")
    var text: String

    @Guide(description: "Nombre del responsable SOLO si se dice explícitamente. Si no, cadena vacía. No inventar.")
    var assignee: String

    @Guide(description: "Estado del compromiso")
    @Guide(.anyOf(["propuesto", "confirmado", "reasignado", "aparcado", "cancelado"]))
    var status: String

    @Guide(description: "Segundo aproximado de la grabación en el que se decidió")
    var atSeconds: Int
}

@Generable
struct ChunkDigest {
    @Guide(description: "Qué pasa en este fragmento, 2-3 frases. No repetir lo que ya está en el estado abierto.")
    var notes: String

    @Guide(description: "Compromisos vivos tras este fragmento, incluyendo los que venían del estado abierto y han cambiado")
    var openItems: [ActionItemDraft]
}

@Generable
struct MeetingSummary {
    @Guide(description: "Resumen ejecutivo de la reunión en 3-5 frases")
    var overview: String

    @Guide(description: "Decisiones tomadas, una por línea. Vacío si no hubo ninguna.")
    var decisions: [String]

    @Guide(description: "Tareas finales tras resolver reasignaciones y cancelaciones. Una por compromiso, no una por mención.")
    var actionItems: [ActionItemDraft]
}

enum SummarizerError: Error {
    case modelUnavailable(String)
}

struct Summarizer {

    /// Comprueba disponibilidad. Es lo único que sobrevive de la mitigación del
    /// riesgo R1 (plan 11): el iPhone 17e soporta Apple Intelligence, pero el usuario
    /// puede tenerlo desactivado en Ajustes o el modelo todavía descargándose.
    static func availabilityDescription() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable(\(String(describing: reason)))"
        @unknown default:
            return "unknown"
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Trocea por caracteres, que es una aproximación grosera pero estable a los
    /// tokens. El número real de tokens se mide con `tokenCount(for:)` en el spike 5.
    private static let chunkChars = 3_000

    static func summarize(transcript: String, language: String) async throws -> MeetingSummary {
        guard isAvailable else { throw SummarizerError.modelUnavailable(availabilityDescription()) }

        let chunks = split(transcript)
        Log.event(Log.summarize, "mapreduce.start", nil, "chunks=\(chunks.count) chars=\(transcript.count)")

        // MAP con acarreo de estado: cada fragmento recibe el libro de compromisos
        // abiertos y puede modificarlos o cerrarlos, en vez de duplicarlos (plan 5.4.2).
        var openItems: [ActionItemDraft] = []
        var notes: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession {
                """
                Eres un analista de reuniones. Trabajas en \(language).
                Recibes un FRAGMENTO de la transcripción y el ESTADO ABIERTO con los
                compromisos que siguen vivos.

                Reglas, en orden de importancia:
                1. No inventes. Si un dato no está dicho, déjalo vacío.
                2. Si un compromiso del estado abierto cambia de responsable, de fecha
                   o se cancela en este fragmento, DEVUÉLVELO MODIFICADO. No crees uno
                   nuevo: son estados sucesivos del mismo compromiso.
                3. Devuelve el estado abierto completo tras este fragmento, no solo lo
                   que ha cambiado.
                """
            }

            let state = openItems.isEmpty
                ? "(vacío)"
                : openItems.map { "- [\($0.status)] \($0.text) · \($0.assignee.isEmpty ? "sin responsable" : $0.assignee)" }
                           .joined(separator: "\n")

            let prompt = """
            ESTADO ABIERTO:
            \(state)

            FRAGMENTO \(index + 1) de \(chunks.count):
            \(chunk)
            """

            do {
                let response = try await session.respond(to: Prompt(prompt), generating: ChunkDigest.self)
                openItems = response.content.openItems
                notes.append(response.content.notes)
                Log.event(Log.summarize, "map.chunk", nil, "i=\(index) open=\(openItems.count)")
            } catch {
                // Un fragmento que falla no tira el resumen entero: se anota y se sigue.
                Log.failure(Log.summarize, "map.chunk", error)
                notes.append("")
            }
        }

        // REDUCE
        let session = LanguageModelSession {
            """
            Eres un analista de reuniones. Trabajas en \(language).
            Recibes las notas por fragmento y la lista final de compromisos ya resuelta.
            Produce el resumen de la reunión.

            Reglas:
            1. No inventes nada que no esté en las notas.
            2. Un compromiso por tarea, no una por mención.
            3. Si algo quedó contradictorio, dilo en el resumen en vez de elegir por tu cuenta.
            """
        }

        let items = openItems.map { "- [\($0.status)] \($0.text) · \($0.assignee) · t=\($0.atSeconds)s" }
                             .joined(separator: "\n")
        let prompt = """
        NOTAS POR FRAGMENTO:
        \(notes.filter { !$0.isEmpty }.joined(separator: "\n\n"))

        COMPROMISOS RESUELTOS:
        \(items.isEmpty ? "(ninguno)" : items)
        """

        let response = try await session.respond(to: Prompt(prompt), generating: MeetingSummary.self)
        Log.event(Log.summarize, "mapreduce.done", nil, "items=\(response.content.actionItems.count)")
        return response.content
    }

    private static func split(_ text: String) -> [String] {
        guard text.count > chunkChars else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var current = ""
        // Trocea por frases para no partir una idea por la mitad.
        for sentence in text.split(separator: ".", omittingEmptySubsequences: false) {
            let piece = sentence + "."
            if current.count + piece.count > chunkChars, !current.isEmpty {
                out.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
