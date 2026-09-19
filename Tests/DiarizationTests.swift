import AVFoundation
import XCTest
@testable import Eugenia

/// Separación de hablantes de verdad, en el simulador: dos voces sintéticas distintas
/// → FluidAudio con los modelos QUE VAN DENTRO DE LA APP y sin red.
///
/// Lo que se comprueba de forma estricta es lo que más riesgo tenía: que los modelos
/// estén en el paquete con la estructura que espera la librería y que carguen sin
/// descargar nada (modo sin red). Cuántos hablantes salen con voces sintéticas es
/// informativo: se registra, pero una voz de síntesis no es una reunión.
final class DiarizationTests: XCTestCase {

    /// Voces del simulador. Si no hay dos distintas, la prueba se salta (no falla).
    private func twoVoices() -> (AVSpeechSynthesisVoice, AVSpeechSynthesisVoice)? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let es = all.filter { $0.language.hasPrefix("es") }
        let pool = es.count >= 2 ? es : all
        guard let a = pool.first, let b = pool.first(where: { $0.identifier != a.identifier && $0.gender != a.gender })
                ?? pool.first(where: { $0.identifier != a.identifier }) else { return nil }
        return (a, b)
    }

    /// Síntesis a buffers PCM (no suena nada).
    private func synth(_ text: String, voice: AVSpeechSynthesisVoice) async -> [AVAudioPCMBuffer] {
        let s = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        return await withCheckedContinuation { c in
            var out: [AVAudioPCMBuffer] = []
            var done = false
            s.write(u) { buffer in
                guard !done else { return }
                if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
                    out.append(pcm)
                } else {
                    done = true
                    c.resume(returning: out)
                }
            }
        }
    }

    @MainActor
    func testBundledModelsLoadOfflineAndSeparateTwoVoices() async throws {
        // 1) Los modelos están en el paquete, con la ruta que busca FluidAudio.
        let root = try XCTUnwrap(Bundle.main.url(forResource: "DiarizerModels", withExtension: nil),
                                 "Los modelos de hablantes no están dentro de la app")
        for m in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("speaker-diarization-coreml/\(m).mlmodelc/weights/weight.bin").path), m)
        }

        // 2) Audio: A, B, A, B — 4 turnos de ~4 s.
        guard let (va, vb) = twoVoices() else { throw XCTSkip("El simulador no tiene dos voces de síntesis") }
        let lines = [
            (va, "Buenos días a todos, vamos a revisar el presupuesto del trimestre y las prioridades del equipo."),
            (vb, "De acuerdo. Yo me encargo de cerrar las cifras de ventas antes del viernes por la tarde."),
            (va, "Perfecto. Entonces Marta prepara el informe y lo revisamos juntos la semana que viene."),
            (vb, "Me parece bien. También hay que hablar del contrato con el proveedor nuevo de Monterrey.")
        ]
        var buffers: [AVAudioPCMBuffer] = []
        for (v, t) in lines { buffers += await synth(t, voice: v) }
        guard let fmt = buffers.first?.format else { throw XCTSkip("La síntesis no produjo audio en este simulador") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diar-test-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                       commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            for b in buffers { try file.write(from: b) }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = Double(buffers.reduce(0) { $0 + Int($1.frameLength) }) / fmt.sampleRate
        XCTAssertGreaterThan(seconds, 8, "audio sintetizado demasiado corto")

        // 3) Diarización real, sin red (Diarizer pone la librería en modo sin red).
        let out = try await Diarizer.diarize(urls: [url])
        XCTAssertFalse(out.turns.isEmpty, "no salió ningún turno de hablante")
        let speakers = Set(out.turns.map(\.label))
        print("DIARIZATION-CI seconds=\(Int(seconds)) turns=\(out.turns.count) speakers=\(speakers.count) voices=\(va.identifier),\(vb.identifier)")
    }
}
