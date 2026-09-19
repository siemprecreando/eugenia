import Foundation
import FoundationModels

/// Poner nombre a los hablantes a partir de lo que se DICE en la reunión.
///
/// Dos capas, de más a menos fiable:
///  1. Presentaciones explícitas ("soy Marta", "me llamo…", "I'm…"): reglas, sin
///     modelo, siempre disponibles. Quien lo dice es quien se llama así.
///  2. Si hay Apple Intelligence: el modelo mira el principio de la reunión y solo
///     asigna un nombre cuando el texto lo deja claro (se presenta, o le llaman por su
///     nombre y contesta justo después). Si duda, nada.
///
/// Nunca pisa un nombre que haya puesto el usuario ni el de una huella de voz: solo
/// rellena "Hablante N" que siguen sin nombre. El usuario lo corrige tocando el nombre
/// en la transcripción.
enum SpeakerNaming {

    // MARK: 1) Presentaciones

    /// Palabras que van en mayúscula tras "soy"/"I'm" sin ser un nombre.
    private static let notNames: Set<String> = [
        "yo", "el", "la", "los", "las", "un", "una", "de", "del", "muy", "bueno", "buena", "aquí", "así",
        "nuevo", "nueva", "responsable", "director", "directora", "jefe", "jefa", "gerente", "parte",
        "i", "a", "an", "the", "not", "so", "just", "here", "fine", "good", "sorry", "happy", "glad", "sure",
        "going", "from", "with", "in", "on", "at", "okay", "ok", "hola", "hello", "hi", "sí", "no"
    ]

    /// "soy Marta", "me llamo Juan Pablo", "mi nombre es…", "les habla…", "I'm…",
    /// "I am…", "my name is…". ("this is X" y "habla X" a secas daban falsos positivos.) El nombre, en mayúscula (el ASR capitaliza
    /// nombres propios); una o dos palabras.
    private static let introPattern: NSRegularExpression = {
        let lead = #"(?:\bsoy|\bme llamo|\bmi nombre es|\bles habla|\bte habla|\bI'm|\bI am|\bmy name is)"#
        let name = #"([A-ZÁÉÍÓÚÑÜ][a-záéíóúñü]+(?:\s+[A-ZÁÉÍÓÚÑÜ][a-záéíóúñü]+)?)"#
        return try! NSRegularExpression(pattern: lead + #"\s+"# + name, options: [.caseInsensitive])
    }()

    /// Etiqueta → nombre, solo con presentaciones inequívocas: si una etiqueta dice dos
    /// nombres distintos o dos etiquetas dicen el mismo, esa pista se descarta.
    static func selfIntroductions(_ segments: [TranscriptSegment]) -> [String: String] {
        var votes: [String: [String: Int]] = [:]
        for s in segments where !s.isMarker {
            guard let label = s.speaker else { continue }
            let text = s.text
            let range = NSRange(text.startIndex..., in: text)
            for m in introPattern.matches(in: text, range: range) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                // La regla ignora mayúsculas para el verbo; el NOMBRE sí tiene que ir
                // en mayúscula (si no, "soy consciente" daría "consciente").
                var words = text[r].split(separator: " ").map(String.init)
                guard let first = words.first, first.first?.isUppercase == true else { continue }
                if words.count == 2, words[1].first?.isUppercase != true || notNames.contains(words[1].lowercased()) {
                    words = [first]
                }
                guard !notNames.contains(first.lowercased()) else { continue }
                votes[label, default: [:]][words.joined(separator: " "), default: 0] += 1
            }
        }
        var out: [String: String] = [:]
        for (label, names) in votes where names.count == 1 { out[label] = names.keys.first }
        // El mismo nombre en dos hablantes: no sabemos cuál es. Fuera los dos.
        let counts = Dictionary(grouping: out.values, by: { $0.lowercased() }).mapValues(\.count)
        return out.filter { counts[$0.value.lowercased()] == 1 }
    }

    // MARK: 2) Con el modelo

    @Generable
    struct Guess: Equatable {
        @Guide(description: "Etiqueta exacta del hablante tal como aparece en el texto, p. ej. \"Hablante 2\"")
        var speaker: String
        @Guide(description: "Nombre de pila (y apellido si se dice). Vacío si no es seguro.")
        var name: String
    }

    @Generable
    struct Guesses {
        @Guide(description: "Solo hablantes cuyo nombre queda CLARO en el texto. Lista vacía si ninguno.")
        var speakers: [Guess]
    }

    /// Nombres que el modelo deduce del principio de la reunión. Solo etiquetas que
    /// siguen sin nombre; lo que no reconozca como etiqueta real se ignora.
    static func modelGuesses(note: Note) async -> [String: String] {
        guard Summarizer.isAvailable else { return [:] }
        let unnamed = note.speakerLabels.filter { (note.speakerNames[$0] ?? "").isEmpty }
        guard !unnamed.isEmpty else { return [:] }
        // "Hablante 2" → "S2": la vuelta de lo que ve el modelo a la etiqueta interna.
        var byDisplay: [String: String] = [:]
        for l in unnamed { if let d = note.displayName(forSpeaker: l) { byDisplay[d.lowercased()] = l } }

        let lines = Summarizer.timedLines(segments: note.segments, plain: note.transcript,
                                          speakerName: { note.displayName(forSpeaker: $0) })
        let text = String(lines.joined(separator: "\n").prefix(Summarizer.chunkChars))
        let session = LanguageModelSession {
            """
            Identificas a los hablantes de una transcripción por su NOMBRE, solo cuando el
            texto lo deja claro: alguien se presenta ("soy Marta"), o le llaman por su
            nombre ("Marta, ¿qué opinas?") y ese mismo hablante contesta justo después.
            Si hay la menor duda, no lo incluyas. Nunca inventes nombres.
            """
        }
        do {
            let r = try await session.respond(to: Prompt("TRANSCRIPCIÓN:\n\(text)"), generating: Guesses.self).content
            var out: [String: String] = [:]
            for g in r.speakers {
                let name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 40, name.first?.isUppercase == true,
                      let label = byDisplay[g.speaker.trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
                // Tiene que aparecer en el texto: nada de nombres inventados.
                guard text.localizedCaseInsensitiveContains(name.split(separator: " ").first.map(String.init) ?? name) else { continue }
                out[label] = name
            }
            let counts = Dictionary(grouping: out.values, by: { $0.lowercased() }).mapValues(\.count)
            return out.filter { counts[$0.value.lowercased()] == 1 }
        } catch {
            Log.failure(Log.summarize, "speaker.names", error)
            return [:]
        }
    }

    /// Las dos capas juntas: primero las presentaciones; el modelo solo completa huecos.
    /// Nunca repite un nombre que ya tenga otro hablante.
    static func suggest(for note: Note) async -> [String: String] {
        var names: [String: String] = [:]
        let taken = Set(note.speakerNames.values.map { $0.lowercased() })
        for (l, n) in selfIntroductions(note.segments)
        where (note.speakerNames[l] ?? "").isEmpty && !taken.contains(n.lowercased()) {
            names[l] = n
        }
        var withIntros = note
        for (l, n) in names { withIntros.speakerNames[l] = n }
        let used = Set(withIntros.speakerNames.values.map { $0.lowercased() })
        for (l, n) in await modelGuesses(note: withIntros) where names[l] == nil && !used.contains(n.lowercased()) {
            names[l] = n
        }
        return names
    }
}
