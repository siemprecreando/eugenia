import AVFoundation
import Foundation
import Speech

/// ASR on-device con `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+).
/// Plan, secciones 5.2 y 3.1. Solo español e inglés, por decisión de alcance.
///
/// NOTA DE VERIFICACIÓN: escrito contra la API pública documentada de iOS 26, pero
/// NUNCA COMPILADO (no hay Mac en el equipo; ver plan 6.3). Los nombres de
/// `AssetInventory` son el punto más probable de ajuste en el primer build verde.
actor Transcriber {

    enum TranscriberError: Error {
        case localeNotSupported(String)
        case noAudioFormat
        case notRunning
    }

    struct Segment: Sendable {
        let text: String
        let isFinal: Bool
    }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    /// Asegura que el modelo del idioma está instalado. Hay que llamarlo ANTES de la
    /// primera grabación, no en mitad de una reunión (plan 5.2).
    static func prepareModel(for locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeNotSupported(locale.identifier)
        }
        try await AssetInventory.reserve(locale: supported)
        let probe = SpeechTranscriber(locale: supported,
                                      transcriptionOptions: [],
                                      reportingOptions: [],
                                      attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            Log.event(Log.asr, "assets.download.start", nil, "locale=\(supported.identifier)")
            try await request.downloadAndInstall()
            Log.event(Log.asr, "assets.download.done", nil, "locale=\(supported.identifier)")
        } else {
            Log.event(Log.asr, "assets.present", nil, "locale=\(supported.identifier)")
        }
    }

    /// Arranca la sesión y devuelve el flujo de segmentos. Los volátiles llegan con
    /// `isFinal == false` y la UI los muestra en gris hasta que se consolidan.
    func start(locale: Locale, caseId: String? = nil) async throws -> AsyncStream<Segment> {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeNotSupported(locale.identifier)
        }

        let t = SpeechTranscriber(locale: supported,
                                  transcriptionOptions: [],
                                  reportingOptions: [.volatileResults],
                                  attributeOptions: [])
        let a = SpeechAnalyzer(modules: [t])

        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw TranscriberError.noAudioFormat
        }

        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = t
        self.analyzer = a
        self.inputBuilder = builder
        self.analyzerFormat = fmt

        let (out, outContinuation) = AsyncStream<Segment>.makeStream()

        resultsTask = Task {
            do {
                for try await result in t.results {
                    let text = String(result.text.characters)
                    outContinuation.yield(Segment(text: text, isFinal: result.isFinal))
                }
                outContinuation.finish()
            } catch {
                Log.failure(Log.asr, "results.stream", error, caseId: caseId)
                outContinuation.finish()
            }
        }

        try await a.start(inputSequence: inputSequence)
        Log.event(Log.asr, "analyzer.start", caseId, "locale=\(supported.identifier) sr=\(fmt.sampleRate)")
        return out
    }

    /// Alimenta el analizador. Los buffers vienen del `AudioSource`, sea micro o fichero.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let analyzerFormat else { return }
        do {
            let converted = try converter.convert(buffer, to: analyzerFormat)
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
            Log.failure(Log.asr, "buffer.convert", error)
        }
    }

    func finish() async {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        inputBuilder = nil
        analyzer = nil
        transcriber = nil
        Log.event(Log.asr, "analyzer.finish")
    }
}
