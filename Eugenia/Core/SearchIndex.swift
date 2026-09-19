import Foundation
import NaturalLanguage

/// Búsqueda global híbrida. Plan, secciones 5.5 y 5.6.
///
/// Léxica (coincidencia de términos, BM25 simplificado) + semántica (embeddings de
/// frase de NaturalLanguage, on-device) fusionadas por *reciprocal rank fusion*. Solo
/// léxica falla con "¿qué decidimos del presupuesto?"; solo semántica falla con
/// "¿qué dijo Marta de Acme?".
///
/// En memoria y no en SQLite/FTS5 a propósito: un usuario, cientos de notas como
/// mucho; recorrerlas en memoria cuesta milisegundos y ahorra una base de datos
/// entera. Los vectores se calculan perezosamente y se cachean por nota.

struct SearchHit: Identifiable, Equatable {
    var id: String { "\(noteID)-\(Int(atSeconds))-\(text.hashValue)" }
    var noteID: UUID
    var noteTitle: String
    var text: String
    var atSeconds: Double
    var score: Double
}

@MainActor
final class SearchIndex {
    static let shared = SearchIndex()

    struct Passage {
        var noteID: UUID
        var noteTitle: String
        var text: String
        var atSeconds: Double
        var language: String
        var tokens: [String]
    }

    private var passages: [UUID: [Passage]] = [:]
    private var vectors: [UUID: [[Double]]] = [:]
    private var stamps: [UUID: Int] = [:]

    func invalidate(_ id: UUID) {
        passages[id] = nil
        vectors[id] = nil
        stamps[id] = nil
    }

    /// Unidades de ~200 palabras respetando los segmentos (y por tanto los turnos).
    nonisolated static func makePassages(for note: Note) -> [Passage] {
        var out: [Passage] = []
        var buffer: [String] = []
        var words = 0
        var start: Double = 0
        let speech = note.segments.filter { !$0.isMarker }
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: " ")
            out.append(Passage(noteID: note.id, noteTitle: note.title, text: text, atSeconds: start,
                               language: note.language, tokens: tokenize(text)))
            buffer = []; words = 0
        }
        if speech.isEmpty {
            // Notas sin segmentos (v0.1, importadas de texto): por palabras.
            let all = note.transcript.split(separator: " ")
            stride(from: 0, to: all.count, by: 200).forEach { i in
                let text = all[i..<min(all.count, i + 200)].joined(separator: " ")
                out.append(Passage(noteID: note.id, noteTitle: note.title, text: text, atSeconds: 0,
                                   language: note.language, tokens: tokenize(text)))
            }
        } else {
            for s in speech {
                if buffer.isEmpty { start = s.start }
                let who = note.displayName(forSpeaker: s.speaker).map { "\($0): " } ?? ""
                buffer.append(who + s.text)
                words += s.text.split(separator: " ").count
                if words >= 200 { flush() }
            }
            flush()
        }
        // El resumen y el título también se buscan (instante 0).
        let meta = ([note.title, note.summaryOverview] + note.decisions + note.actionItems.map(\.text))
            .filter { !$0.isEmpty }.joined(separator: ". ")
        if !meta.isEmpty {
            out.append(Passage(noteID: note.id, noteTitle: note.title, text: meta, atSeconds: 0,
                               language: note.language, tokens: tokenize(meta)))
        }
        return out
    }

    nonisolated static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    private func ensure(_ note: Note) {
        // Huella del contenido que se indexa. Antes era una suma de longitudes: renombrar
        // la reunión o a un hablante no la cambiaba y la búsqueda enseñaba lo viejo.
        var h = Hasher()
        h.combine(note.title)
        h.combine(note.transcript)
        h.combine(note.summaryOverview)
        h.combine(note.speakerNames)
        h.combine(note.segments.count)
        h.combine(note.actionItems.map(\.text))
        let stamp = h.finalize()
        if stamps[note.id] == stamp, passages[note.id] != nil { return }
        passages[note.id] = Self.makePassages(for: note)
        vectors[note.id] = nil
        stamps[note.id] = stamp
    }

    private func vectorsFor(_ note: Note) -> [[Double]] {
        if let v = vectors[note.id] { return v }
        let model = NLEmbedding.sentenceEmbedding(for: note.language == "en" ? .english : .spanish)
        let v = (passages[note.id] ?? []).map { model?.vector(for: String($0.text.prefix(1_000))) ?? [] }
        vectors[note.id] = v
        return v
    }

    /// Búsqueda sobre todas las notas (o una). Devuelve los mejores fragmentos.
    func search(_ query: String, in notes: [Note], limit: Int = 20, semantic: Bool = true) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        notes.forEach(ensure)
        let all: [(Passage, Int, Int)] = notes.flatMap { n in
            (passages[n.id] ?? []).enumerated().map { ($0.element, $0.offset, 0) }
        }
        guard !all.isEmpty else { return [] }

        // 1) Léxico: BM25 simplificado.
        let qTokens = Set(Self.tokenize(q))
        let n = Double(all.count)
        var df: [String: Double] = [:]
        for (p, _, _) in all { for t in Set(p.tokens) where qTokens.contains(t) { df[t, default: 0] += 1 } }
        let avgLen = all.reduce(0.0) { $0 + Double($1.0.tokens.count) } / n
        func bm25(_ p: Passage) -> Double {
            var score = 0.0
            let len = Double(p.tokens.count)
            var tf: [String: Double] = [:]
            for t in p.tokens where qTokens.contains(t) { tf[t, default: 0] += 1 }
            for (t, f) in tf {
                let idf = log(1 + (n - (df[t] ?? 0) + 0.5) / ((df[t] ?? 0) + 0.5))
                score += idf * (f * 2.2) / (f + 1.2 * (0.25 + 0.75 * len / max(avgLen, 1)))
            }
            // Frase exacta: empujón fuerte (nombres propios, cifras).
            if p.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { score += 3 }
            return score
        }
        let lexical = all.map { ($0, bm25($0.0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }

        // 2) Semántico: coseno contra el embedding de la consulta.
        var semanticRank: [(Int, Double)] = []
        if semantic {
            var queryVectors: [String: [Double]] = [:]
            for lang in Set(notes.map(\.language)) {
                queryVectors[lang] = NLEmbedding.sentenceEmbedding(for: lang == "en" ? .english : .spanish)?.vector(for: q) ?? []
            }
            let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var flat: [Double] = []
            for item in all {
                guard let note = byID[item.0.noteID] else { flat.append(0); continue }
                let vs = vectorsFor(note)
                let pv = item.1 < vs.count ? vs[item.1] : []
                flat.append(Self.cosine(queryVectors[note.language] ?? [], pv))
            }
            semanticRank = flat.enumerated().map { ($0.offset, $0.element) }
                .filter { $0.1 > 0.35 }.sorted { $0.1 > $1.1 }
        }

        // 3) Reciprocal rank fusion (k = 60).
        var fused: [Int: Double] = [:]
        let index: [String: Int] = Dictionary(all.enumerated().map { ("\($0.element.0.noteID)-\($0.element.1)", $0.offset) },
                                              uniquingKeysWith: { a, _ in a })
        for (rank, item) in lexical.enumerated() {
            if let i = index["\(item.0.0.noteID)-\(item.0.1)"] { fused[i, default: 0] += 1 / Double(60 + rank + 1) }
        }
        for (rank, item) in semanticRank.enumerated() { fused[item.0, default: 0] += 1 / Double(60 + rank + 1) }

        return fused.sorted { $0.value > $1.value }.prefix(limit).map { i, score in
            let p = all[i].0
            return SearchHit(noteID: p.noteID, noteTitle: p.noteTitle, text: p.text, atSeconds: p.atSeconds, score: score)
        }
    }

    nonisolated static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Preguntas "globales" (de qué trató, resúmeme…) se contestan con el resumen, no
    /// con recuperación (plan 5.5, punto 4).
    nonisolated static func isGlobalQuestion(_ q: String) -> Bool {
        let s = q.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let markers = ["de que trato", "de que se hablo", "resume", "resumen", "en general", "que se decidio en la reunion",
                       "what was the meeting about", "summarize", "summary", "overall"]
        return markers.contains { s.contains($0) }
    }
}
