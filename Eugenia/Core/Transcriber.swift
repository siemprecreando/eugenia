import AVFoundation
import Foundation
import Speech

/// ASR on-device con `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26+).
/// Plan, secciones 5.2 y 3.1. Solo español e inglés, por decisión de alcance.
///
/// Compila en CI (Xcode 26) y corre en el iPhone 17e desde 2026-09-18.
actor Transcriber {

    enum TranscriberError: Error {
        case localeNotSupported(String)
        case noAudioFormat
        case notRunning
    }

    struct Segment: Sendable {
        let text: String
        let isFinal: Bool
        /// Segundos en el tiempo del AUDIO (el del fichero), ya corregidos por los
        /// buffers que el freno se saltó.
        let start: Double
        let end: Double
    }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()

    /// Segundos de audio entregados al analizador y hasta dónde ha devuelto resultados.
    /// La diferencia es el RETRASO real del ASR, que es lo que hay que vigilar para no
    /// acumular audio convertido sin límite (riesgo R11). La versión anterior medía la
    /// cola equivocada: la de entrada, que nunca crecía.
    private var fedSeconds: Double = 0
    private var resultEnd: Double = 0
    var lagSeconds: Double { max(0, fedSeconds - resultEnd) }

    /// Buffers que el freno saltó: (tiempo del analizador en que se saltó, segundos
    /// saltados). El analizador no los ve, así que su reloj se queda atrás del reloj
    /// del fichero; esto lo corrige para que cada frase apunte al segundo exacto.
    private var skips: [(at: Double, seconds: Double)] = []

    private func audioTime(_ analyzerTime: Double) -> Double {
        analyzerTime + skips.filter { $0.at <= analyzerTime }.reduce(0) { $0 + $1.seconds }
    }

    /// El `Recorder` avisa de que se saltó este buffer por presión.
    func skipped(_ buffer: AVAudioPCMBuffer) {
        skips.append((fedSeconds, Double(buffer.frameLength) / buffer.format.sampleRate))
    }

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
            Log.event(Log.asr, "assets.download.start", "locale=\(supported.identifier)")
            try await request.downloadAndInstall()
            Log.event(Log.asr, "assets.download.done", "locale=\(supported.identifier)")
        } else {
            Log.event(Log.asr, "assets.present", "locale=\(supported.identifier)")
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
                    let start = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                    let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
                    self.noteResult(end: end)
                    outContinuation.yield(Segment(text: text, isFinal: result.isFinal,
                                                  start: self.audioTime(start), end: self.audioTime(end)))
                }
                outContinuation.finish()
            } catch {
                Log.failure(Log.asr, "results.stream", error, caseId: caseId)
                outContinuation.finish()
            }
        }

        try await a.start(inputSequence: inputSequence)
        Log.event(Log.asr, "analyzer.start", "locale=\(supported.identifier) sr=\(fmt.sampleRate)", caseId: caseId)
        return out
    }

    private func noteResult(end: Double) { resultEnd = max(resultEnd, end) }

    /// Alimenta el analizador. Los buffers vienen del `AudioSource`, sea micro o fichero.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let analyzerFormat else { return }
        do {
            let converted = try converter.convert(buffer, to: analyzerFormat)
            fedSeconds += Double(converted.frameLength) / analyzerFormat.sampleRate
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
            Log.failure(Log.asr, "buffer.convert", error)
        }
    }

    func finish() async {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // ESPERAR, no cancelar: al finalizar, el analizador consolida la última frase
        // volátil y la entrega como final. Cancelar aquí la tiraba (revisión 2026-09-18).
        if analyzer == nil { resultsTask?.cancel() }   // nunca arrancó: nada que drenar
        _ = await resultsTask?.value
        inputBuilder = nil
        analyzer = nil
        transcriber = nil
        Log.event(Log.asr, "analyzer.finish")
    }
}
