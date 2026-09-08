import AVFoundation
import Foundation

/// Origen de audio del pipeline. Plan, sección 6.5.
///
/// Esto NO es una abstracción de conveniencia: es el requisito que hace que la app
/// sea probable en remoto. Las pruebas corren sobre fichero (`FileAudioSource`), que
/// es repetible y se puede disparar desde Linux; el micrófono se prueba a mano.
/// Meterlo después sería un refactor del camino crítico.
protocol AudioSource: AnyObject {
    var format: AVAudioFormat { get }
    /// Entrega buffers hasta que se llame a `stop()` o se agote la fuente.
    /// `onFinish` se llama solo en fuentes finitas (fichero).
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFinish: @escaping () -> Void) throws
    func stop()
}

enum AudioSourceError: Error {
    case sessionUnavailable
    case fileUnreadable(URL)
    case converterFailed
}

// MARK: - Micrófono

final class MicrophoneAudioSource: AudioSource {
    private let engine = AVAudioEngine()
    private var running = false

    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFinish: @escaping () -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        // .record + .default a propósito: NO .voiceChat. El procesamiento de voz de
        // Apple está optimizado para el interlocutor cercano y degrada la voz lejana,
        // que es justo el caso de uso de este producto (plan 5.1).
        try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        Log.event(Log.capture, "mic.start", nil, "sr=\(fmt.sampleRate) ch=\(fmt.channelCount)")
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.event(Log.capture, "mic.stop")
    }
}

// MARK: - Fichero (pruebas)

/// Reproduce un fichero de audio como si fuera el micrófono. No toca AVAudioSession,
/// así que corre sin permisos y sin hardware: es lo que permite que el banco de
/// pruebas se dispare desde Linux.
final class FileAudioSource: AudioSource {
    private let file: AVAudioFile
    private let chunkFrames: AVAudioFrameCount
    private var cancelled = false
    /// A 0 va lo más rápido que pueda; a 1.0 simula tiempo real.
    private let realtimeFactor: Double

    let format: AVAudioFormat

    init(url: URL, realtimeFactor: Double = 0, chunkFrames: AVAudioFrameCount = 4096) throws {
        guard let f = try? AVAudioFile(forReading: url) else { throw AudioSourceError.fileUnreadable(url) }
        self.file = f
        self.format = f.processingFormat
        self.chunkFrames = chunkFrames
        self.realtimeFactor = realtimeFactor
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onFinish: @escaping () -> Void) throws {
        cancelled = false
        let fmt = format
        let frames = chunkFrames
        let factor = realtimeFactor
        Task.detached { [weak self] in
            guard let self else { return }
            while !self.cancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { break }
                do {
                    try self.file.read(into: buffer, frameCount: frames)
                } catch {
                    Log.failure(Log.capture, "file.read", error)
                    break
                }
                if buffer.frameLength == 0 { break }
                onBuffer(buffer)
                if factor > 0 {
                    let seconds = Double(buffer.frameLength) / fmt.sampleRate * factor
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
            onFinish()
        }
    }

    func stop() { cancelled = true }
}

// MARK: - Conversión de formato

/// Adapta los buffers del origen al formato que pide SpeechAnalyzer.
final class BufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = buffer.format
        if source == target { return buffer }

        if converter == nil || converter?.outputFormat != target || converter?.inputFormat != source {
            converter = AVAudioConverter(from: source, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { throw AudioSourceError.converterFailed }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioSourceError.converterFailed
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }
}
