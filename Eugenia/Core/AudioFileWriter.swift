import AVFoundation
import Foundation

/// Escritura del audio a disco, fuera del hilo principal, EN TROZOS.
///
/// POR QUÉ TROZOS (revisión 2026-09-18, hallazgo crítico): un .m4a solo escribe su
/// índice al cerrarse. Si la app moría grabando —jetsam en el minuto 50, un crash, el
/// usuario la cerraba con la pantalla bloqueada— el fichero quedaba ilegible y se
/// perdía la reunión ENTERA. Ahora se cierra un trozo cada `partSeconds` y se abre el
/// siguiente: un cierre inesperado pierde como mucho el trozo en curso. El reproductor
/// los encadena (`AudioParts.composition`).
///
/// POR QUÉ ES UN ACTOR: los buffers llegan cada ~85 ms desde el hilo de audio. Si la
/// escritura pasa por el `@MainActor` compite con la interfaz.
///
/// Además convierte al formato del fichero antes de escribir: `AVAudioFile.write`
/// exige el `processingFormat`, y el del micrófono cambia al conectar unos AirPods.
actor AudioFileWriter {
    private let directory: URL
    private let baseName: String
    private let settings: [String: Any]
    private let partSeconds: Double
    private let onPartCreated: @Sendable (String) -> Void

    private var file: AVAudioFile?
    private let converter = BufferConverter()
    private var partIndex = 0
    private var framesInPart: AVAudioFramePosition = 0
    /// Frames escritos en total. Es el reloj del AUDIO: la duración real de la
    /// grabación sale de aquí, no del reloj de pared (que cuenta los huecos).
    private(set) var framesWritten: AVAudioFramePosition = 0
    private var failed = false

    let sampleRate: Double

    init(directory: URL, baseName: String, settings: [String: Any], partSeconds: Double = 180,
         onPartCreated: @escaping @Sendable (String) -> Void) throws {
        self.directory = directory
        self.baseName = baseName
        self.settings = settings
        self.partSeconds = partSeconds
        self.onPartCreated = onPartCreated
        self.sampleRate = settings[AVSampleRateKey] as? Double ?? 48_000
        // El primer trozo se abre ya: si el micrófono o el disco fallan, mejor
        // saberlo antes de decir "grabando".
        let first = try Self.openPart(directory: directory, baseName: baseName, index: 0, settings: settings)
        file = first.file
        onPartCreated(first.name)
    }

    private static func openPart(directory: URL, baseName: String, index: Int,
                                 settings: [String: Any]) throws -> (file: AVAudioFile, name: String) {
        let name = String(format: "%@-%03d.m4a", baseName, index)
        let f = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: settings)
        return (f, name)
    }

    var seconds: Double { Double(framesWritten) / sampleRate }

    /// Devuelve `false` si la escritura falló: el `Recorder` para la grabación y lo
    /// dice, en vez de seguir enseñando GRABANDO sin guardar nada.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !failed, let current = file else { return false }
        do {
            let target = current.processingFormat
            let toWrite = buffer.format == target ? buffer : try converter.convert(buffer, to: target)
            try current.write(from: toWrite)
            let n = AVAudioFramePosition(toWrite.frameLength)
            framesWritten += n
            framesInPart += n
            if Double(framesInPart) / target.sampleRate >= partSeconds {
                try rotate()
            }
            return true
        } catch {
            failed = true
            Log.failure(Log.capture, "audio.write", error)
            return false
        }
    }

    /// Cierra el trozo actual y abre el siguiente. Se usa también al volver de una
    /// interrupción: así el hueco queda entre dos trozos y no dentro de uno.
    func rotate() throws {
        file = nil                       // liberar = cerrar y escribir el índice del .m4a
        partIndex += 1
        framesInPart = 0
        let next = try Self.openPart(directory: directory, baseName: baseName, index: partIndex, settings: settings)
        file = next.file
        onPartCreated(next.name)
        Log.event(Log.capture, "audio.part", "i=\(partIndex)")
    }

    /// Cierra el último trozo. Después de esto no se escribe más.
    func close() {
        file = nil
    }
}

/// Utilidades sobre los trozos de audio de una nota.
enum AudioParts {
    static func isReadable(_ url: URL) -> Bool {
        guard let f = try? AVAudioFile(forReading: url) else { return false }
        return f.length > 0
    }

    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    static func totalDuration(_ urls: [URL]) -> Double {
        urls.reduce(0) { $0 + duration($1) }
    }

    /// Encadena los trozos en una sola línea de tiempo para el reproductor.
    static func composition(_ urls: [URL]) async -> AVAsset? {
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let dur = try? await asset.load(.duration), dur > .zero else { continue }
            do {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)
                cursor = cursor + dur
            } catch {
                Log.failure(Log.capture, "audio.compose", error)
            }
        }
        return cursor > .zero ? comp : nil
    }
}

/// Profundidad de la cola de audio pendiente, compartida entre el hilo del micrófono
/// y el consumidor. Un contador y un candado: no hace falta más.
final class Backlog: @unchecked Sendable {
    private let lock = NSLock()
    private var depth = 0

    func increment() {
        lock.lock(); depth += 1; lock.unlock()
    }

    /// Devuelve la profundidad ANTES de descontar: es la que dice cuánto se acumuló.
    @discardableResult
    func decrement() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = depth
        depth = max(0, depth - 1)
        return current
    }
}
