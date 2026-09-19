import AVFoundation
import FluidAudio
import Foundation

/// Separación de hablantes. Plan, sección 5.3.
///
/// FluidAudio (Apache 2.0) con el pipeline offline de pyannote (segmentación +
/// WeSpeaker + VBx) en el Neural Engine. Corre en la cola de enriquecimiento, después
/// de grabar, nunca a la vez que una grabación (plan 5.7).
///
/// RED: NINGUNA. Los modelos (~21 MB) van dentro de la app, bajados en CI de un commit
/// fijo de Hugging Face y comprobados fichero a fichero por SHA-256
/// (scripts/fetch-diarizer-models.sh). La librería se pone en modo sin red: si faltara
/// un modelo, falla en vez de ir a descargarlo de una rama que puede cambiar
/// (revisión de seguridad 2026-09-18). La librería no tiene telemetría (revisado en el
/// código de la v0.15.7: solo `ModelRegistry`/`AssetDownloader` usan la red).

struct SpeakerTurn: Codable, Equatable, Sendable {
    var label: String       // "S1", "S2"… por orden de primera aparición
    var start: Double
    var end: Double
}

enum DiarizerError: Error, CustomStringConvertible {
    case modelsMissing
    var description: String { String(localized: "Faltan los modelos de separación de hablantes en la app.") }
}

enum Diarizer {
    /// Una sola instancia: preparar los modelos cuesta segundos y memoria.
    @MainActor private static var manager: OfflineDiarizerManager?

    struct Output: Sendable {
        var turns: [SpeakerTurn]
        /// Huella media por etiqueta (embedding L2 de 256 floats). Solo se guarda si el
        /// usuario activó el reconocimiento de voces (dato biométrico, opt-in).
        var embeddings: [String: [Float]]
    }

    @MainActor
    static func diarize(urls: [URL]) async throws -> Output {
        guard !urls.isEmpty else { return Output(turns: [], embeddings: [:]) }
        let m = manager ?? OfflineDiarizerManager(config: .default)
        if manager == nil {
            ModelHub.offlineMode = true
            guard let bundled = Bundle.main.url(forResource: "DiarizerModels", withExtension: nil) else {
                throw DiarizerError.modelsMissing
            }
            try await m.prepareModels(directory: bundled)
            manager = m
        }
        // Los trozos se procesan como UNA grabación: diarizar cada trozo por separado
        // daría etiquetas que no coinciden entre trozos ("S1" del trozo 2 ≠ "S1" del 1).
        let joined = try await Task.detached(priority: .utility) { try Self.concatenate16k(urls) }.value
        defer { try? FileManager.default.removeItem(at: joined) }
        try Task.checkCancellation()

        let result = try await m.process(joined)
        var order: [String] = []
        for s in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
        where !order.contains(s.speakerId) { order.append(s.speakerId) }
        let label: (String) -> String = { id in "S\((order.firstIndex(of: id) ?? 0) + 1)" }

        let turns = result.segments
            .map { SpeakerTurn(label: label($0.speakerId), start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        var emb: [String: [Float]] = [:]
        if let db = result.speakerDatabase {
            for (id, vector) in db { emb[label(id)] = vector }
        } else {
            // Media de las huellas por segmento.
            var sums: [String: [Float]] = [:]
            var counts: [String: Int] = [:]
            for s in result.segments where !s.embedding.isEmpty {
                let l = label(s.speakerId)
                if sums[l] == nil { sums[l] = [Float](repeating: 0, count: s.embedding.count) }
                for i in s.embedding.indices where i < sums[l]!.count { sums[l]![i] += s.embedding[i] }
                counts[l, default: 0] += 1
            }
            for (l, v) in sums { emb[l] = v.map { $0 / Float(counts[l] ?? 1) } }
        }
        Log.event(Log.queue, "diarize.done", "turns=\(turns.count) speakers=\(order.count)")
        return Output(turns: turns, embeddings: emb)
    }

    /// Une los trozos en un WAV temporal de 16 kHz mono en 16 bits (~115 MB/hora), que
    /// FluidAudio lee por streaming desde disco. Materializarlo en memoria como [Float]
    /// serían ~230 MB por hora de reunión: justo el pico de memoria del riesgo R11.
    nonisolated static func concatenate16k(_ urls: [URL]) throws -> URL {
        let out = TempFiles.root.appendingPathComponent("diar-\(UUID().uuidString).wav")
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw AudioSourceError.converterFailed }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        // Es la reunión entera sin cifrar por la app: se crea vacío con protección
        // ANTES de escribir audio (los atributos de protección se heredan del
        // fichero, no del directorio temporal).
        FileManager.default.createFile(atPath: out.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        let writer = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        // Por si AVAudioFile recreó el fichero en vez de reutilizarlo.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                               ofItemAtPath: out.path)
        let converter = BufferConverter()
        for url in urls {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let fmt = file.processingFormat
            while true {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_384) else { break }
                do { try file.read(into: buf, frameCount: 16_384) } catch { break }
                if buf.frameLength == 0 { break }
                let converted = try converter.convert(buf, to: target)
                try writer.write(from: converted)
            }
        }
        return out
    }
}

/// Alineación turnos ↔ frases (plan 5.3). Pura y con pruebas.
enum SpeakerAligner {
    /// A cada frase se le asigna el hablante con MÁS solape temporal. Sin solape, el
    /// turno más cercano a menos de 1 s; si no, se queda sin hablante (mejor "sin
    /// asignar" que atribuir una frase a quien no la dijo).
    static func assign(segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        return segments.map { seg in
            guard !seg.isMarker else { return seg }
            var s = seg
            let a = seg.start, b = max(seg.end, seg.start + 0.01)
            var best: (label: String, overlap: Double)?
            var overlaps: [String: Double] = [:]
            for t in turns where t.end > a && t.start < b {
                overlaps[t.label, default: 0] += min(b, t.end) - max(a, t.start)
            }
            for (label, o) in overlaps where o > (best?.overlap ?? 0) { best = (label, o) }
            if let best {
                s.speaker = best.label
            } else {
                let mid = (a + b) / 2
                let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
                if let n = nearest, distance(mid, n) < 1.0 { s.speaker = n.label }
            }
            return s
        }
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }
}

/// Huellas de voz persistentes entre reuniones (plan 5.3). OPT-IN: es un dato
/// biométrico (RGPD art. 9). Se guardan solo en este iPhone, fuera de la copia de
/// seguridad, y se borran todas de un toque en Ajustes.
@MainActor
final class VoiceprintStore: ObservableObject {
    static let shared = VoiceprintStore()

    struct Person: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var embedding: [Float]
        var samples: Int
    }

    @Published private(set) var people: [Person] = []
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voiceprints.json")
    }
    /// Por encima de este coseno, es la misma persona.
    static let threshold: Float = 0.72

    /// Si el fichero existe pero no se pudo leer (teléfono bloqueado), `people` vacío
    /// NO significa "no hay huellas": guardar encima las borraría. Se reintenta la
    /// lectura antes de cada uso y no se escribe hasta haberlo leído.
    private var loaded = false

    private init() { ensureLoaded() }

    private func ensureLoaded() {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { loaded = true; return }
        guard let data = try? Data(contentsOf: url) else { return }
        people = (try? JSONDecoder().decode([Person].self, from: data)) ?? []
        loaded = true
    }

    /// Guarda (o refina, promediando) la huella de `name`.
    func enroll(name: String, embedding: [Float]) {
        guard AppSettings.shared.voiceprintsEnabled, !name.isEmpty, !embedding.isEmpty else { return }
        ensureLoaded()
        if let i = people.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           people[i].embedding.count == embedding.count {
            let n = Float(people[i].samples)
            people[i].embedding = zip(people[i].embedding, embedding).map { ($0 * n + $1) / (n + 1) }
            people[i].samples += 1
        } else {
            people.append(Person(name: name, embedding: embedding, samples: 1))
        }
        save()
    }

    /// Etiqueta de esta reunión → nombre conocido.
    func match(embeddings: [String: [Float]]) -> [String: String] {
        guard AppSettings.shared.voiceprintsEnabled else { return [:] }
        ensureLoaded()
        var out: [String: String] = [:]
        var used: Set<UUID> = []
        for (label, e) in embeddings {
            let best = people.filter { !used.contains($0.id) }
                .map { ($0, Self.cosine($0.embedding, e)) }
                .max { $0.1 < $1.1 }
            if let (p, score) = best, score >= Self.threshold {
                out[label] = p.name
                used.insert(p.id)
            }
        }
        return out
    }

    func remove(_ person: Person) { people.removeAll { $0.id == person.id }; save() }

    func removeAll() {
        people = []
        try? FileManager.default.removeItem(at: url)
        DiarizationCache.shared.removeAll()
    }

    private func save() {
        guard loaded else { Log.event(Log.storage, "voiceprints.save.blocked"); return }
        guard let data = try? JSONEncoder().encode(people) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        Store.shared.excludeFromBackup(url)
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

/// Huellas por reunión, para poder aprender la voz cuando el usuario pone nombre a
/// "Hablante 2" días después. Solo existe si el reconocimiento de voces está activo.
@MainActor
final class DiarizationCache {
    static let shared = DiarizationCache()

    private var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice", isDirectory: true)
    }

    func store(noteID: UUID, embeddings: [String: [Float]]) {
        guard AppSettings.shared.voiceprintsEnabled, !embeddings.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Store.shared.excludeFromBackup(dir)
        let url = dir.appendingPathComponent("\(noteID.uuidString).json")
        if let data = try? JSONEncoder().encode(embeddings) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    func embeddings(noteID: UUID) -> [String: [Float]] {
        let url = dir.appendingPathComponent("\(noteID.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    func remove(noteID: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(noteID.uuidString).json"))
    }

    func removeAll() { try? FileManager.default.removeItem(at: dir) }
}
