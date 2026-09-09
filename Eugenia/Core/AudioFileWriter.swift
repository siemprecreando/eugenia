import AVFoundation
import Foundation

/// Escritura del audio a disco, fuera del hilo principal.
///
/// POR QUÉ ES UN ACTOR Y NO UN MÉTODO DE `Recorder`: los buffers llegan cada ~85 ms
/// desde el hilo de audio. Si la escritura pasa por el `@MainActor` compite con la
/// interfaz, y en una reunión de dos horas eso es exactamente el sitio donde aparecen
/// los tirones y las pérdidas. Aquí el `Recorder` sigue siendo MainActor para la UI,
/// pero el camino del audio no lo toca.
///
/// Además convierte al formato del fichero antes de escribir: `AVAudioFile.write`
/// exige que el buffer venga en `processingFormat`, y el formato del micrófono no
/// tiene por qué coincidir (hay dispositivos que entregan 2 canales).
actor AudioFileWriter {
    private let file: AVAudioFile
    private let converter = BufferConverter()
    private(set) var framesWritten: AVAudioFramePosition = 0
    private var failed = false

    init(url: URL, settings: [String: Any]) throws {
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    var processingFormat: AVAudioFormat { file.processingFormat }

    /// Devuelve `false` si la escritura falló: el `Recorder` decide si para.
    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !failed else { return false }
        do {
            let target = file.processingFormat
            let toWrite = buffer.format == target ? buffer : try converter.convert(buffer, to: target)
            try file.write(from: toWrite)
            framesWritten += AVAudioFramePosition(toWrite.frameLength)
            return true
        } catch {
            failed = true
            Log.failure(Log.capture, "audio.write", error)
            return false
        }
    }
}

/// Profundidad de la cola de audio pendiente, compartida entre el hilo del micrófono
/// y el consumidor. Un contador y un candado: no hace falta más, y evita traerse un
/// paquete de atómicos para esto.
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
