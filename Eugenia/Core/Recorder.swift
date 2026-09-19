import AVFoundation
import Foundation
import UIKit

/// Orquesta captura, escritura a disco y transcripción en vivo.
/// Plan, secciones 5.1 y 5.2.
///
/// PRINCIPIO INNEGOCIABLE: el audio es sagrado. Se escribe a disco de forma
/// incremental desde el primer buffer, en trozos que sobreviven a un cierre
/// inesperado, y la transcripción se va guardando por el camino. Si la app muere,
/// `Store.recoverInterruptedRecordings` recupera lo que había al volver a abrirla.
///
/// Lo que NO hace el grabador desde la v0.2: resumir. Al parar, la nota entra en la
/// `ProcessingQueue` y el grabador vuelve a `.idle` en el acto. Antes el resumen
/// colgaba del estado del grabador, y un resumen fallido (o largo) impedía grabar la
/// siguiente reunión (revisión 2026-09-18).
@MainActor
final class Recorder: ObservableObject {

    static let shared = Recorder()

    enum State: Equatable {
        case idle
        case starting
        case recording
        /// Una llamada o Siri tienen el micrófono. La grabación sigue abierta y se
        /// reanuda sola al terminar.
        case interrupted
        case stopping
        case failed(String)

        var isActive: Bool { self == .recording || self == .interrupted }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveText: String = ""
    @Published private(set) var volatileText: String = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// La última nota que se terminó de grabar: la pantalla de grabación ofrece abrirla.
    @Published private(set) var lastFinishedNoteID: UUID?
    @Published private(set) var currentNoteID: UUID?

    private var source: MicrophoneAudioSource?
    private var writer: AudioFileWriter?
    private var transcriber: Transcriber?
    private var consumeTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var timer: Timer?
    private var finals: [TranscriptSegment] = []
    private var lastIncrementalSave = Date.distantPast
    private var interruptedAt: Double?
    private var levelMeter = LevelMeter()

    private(set) var language: String = "es"
    private var locale: Locale { Locale(identifier: language == "en" ? "en-US" : "es-ES") }

    /// Se decide con `Locale.preferredLanguages` —lo que el usuario tiene en Ajustes—
    /// y NO con `Locale.current`, que viene filtrado por las localizaciones del bundle
    /// y devolvía `en` en un teléfono en español. Elegir mal aquí no degrada nada: la
    /// transcripción sale ilegible porque el modelo es de otro idioma.
    nonisolated static func languageCode(preferred: [String]) -> String {
        for etiqueta in preferred {
            guard let codigo = Locale(identifier: etiqueta).language.languageCode?.identifier else { continue }
            if codigo == "es" { return "es" }
            if codigo == "en" { return "en" }
        }
        return "es"
    }

    /// Idioma de la próxima grabación: el que eligió el usuario o el del teléfono.
    nonisolated static func resolveLanguage(setting: String, preferred: [String]) -> String {
        setting == "es" || setting == "en" ? setting : languageCode(preferred: preferred)
    }

    /// Lo que ve el usuario cuando algo falla. El `NSError` crudo va al log, no a la
    /// pantalla; el detalle técnico se conserva entre paréntesis porque en el teléfono
    /// no hay depurador y a veces es lo único que hay.
    nonisolated static func userMessage(for error: Error) -> String {
        if let audio = error as? AudioSourceError {
            return "No se pudo abrir el micrófono. (\(audio.description))"
        }
        if let rec = error as? RecorderError { return rec.description }
        if let sum = error as? SummarizerError { return sum.description }
        let ns = error as NSError
        let detalle = "\(ns.domain) \(ns.code)"
        switch ns.domain {
        case "SFSpeechErrorDomain":
            return "No se pudo preparar el modelo de voz. Puede seguir descargándose; "
                 + "vuelve a intentarlo en un momento. (\(detalle))"
        case NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio":
            return "El audio no está disponible ahora mismo. Cierra otras apps que estén "
                 + "usando el micrófono e inténtalo otra vez. (\(detalle))"
        default:
            return "Algo falló. (\(detalle))"
        }
    }

    enum RecorderError: Error, CustomStringConvertible {
        case micPermissionDenied
        case diskWriteFailed
        case lowDisk(Int)

        var description: String {
            switch self {
            case .micPermissionDenied:
                return "Eugenia no tiene permiso para usar el micrófono. Actívalo en Ajustes › Eugenia › Micrófono."
            case .diskWriteFailed:
                return "No se pudo seguir guardando el audio (¿almacenamiento lleno?). Lo grabado hasta aquí está guardado."
            case .lowDisk(let mb):
                return "Queda muy poco espacio (\(mb) MB). Libera espacio antes de grabar: una hora de reunión ocupa unos 30 MB."
            }
        }
    }

    // MARK: - Ciclo de grabación

    /// Deja el grabador listo para otra reunión si la anterior terminó con error.
    /// La nota ya está guardada en el Store; aquí solo se limpia la pantalla.
    func resetIfFinished() {
        guard case .failed = state else { return }
        state = .idle
        clearLive()
    }

    private func clearLive() {
        finals = []
        liveText = ""
        volatileText = ""
        elapsed = 0
        level = 0
    }

    /// Arranca una grabación. Síncrono en la entrada: el estado pasa a `.starting` en
    /// el acto, así un segundo toque (o volver a abrir la pantalla mientras se
    /// descarga el modelo de voz) no arranca dos grabaciones a la vez.
    func start(title: String? = nil, folder: String = "", attendees: [String] = [],
               calendarEventID: String? = nil) {
        guard state == .idle else { return }
        state = .starting
        clearLive()
        lastFinishedNoteID = nil
        startTask = Task { await self.performStart(title: title, folder: folder,
                                                   attendees: attendees, calendarEventID: calendarEventID) }
    }

    /// Cancelar mientras arranca: se deshace todo y no queda nada grabando a escondidas.
    func cancelStart() {
        guard state == .starting else { return }
        startTask?.cancel()
    }

    private func performStart(title: String?, folder: String, attendees: [String], calendarEventID: String?) async {
        let settings = AppSettings.shared
        language = Recorder.resolveLanguage(setting: settings.recordingLanguage,
                                            preferred: Locale.preferredLanguages)

        let free = Store.shared.freeDiskMB()
        if free >= 0 && free < 200 {
            state = .failed(RecorderError.lowDisk(free).description)
            return
        }

        let id = UUID()
        var note = Note(id: id, title: title?.isEmpty == false ? title! : Self.defaultTitle(),
                        language: language, state: NoteState.recording)
        note.folder = folder
        note.attendees = attendees
        note.calendarEventID = calendarEventID
        note.template = settings.defaultTemplate

        do {
            // Cola de enriquecimiento en pausa ANTES de cargar nada: la grabación es
            // prioridad 1 y no compite con un resumen por memoria (plan 5.7).
            ProcessingQueue.shared.suspendForRecording()

            try await Transcriber.prepareModel(for: locale)
            try Task.checkCancellation()
            // Permiso DESPUÉS del modelo: el onboarding ya lo pidió; aquí solo se
            // comprueba. Y sin permiso no se crea ninguna nota vacía.
            guard await MicrophoneAudioSource.requestPermission() else { throw RecorderError.micPermissionDenied }

            let mic = MicrophoneAudioSource(profile: MicProfile(rawValue: settings.micProfile) ?? .room)
            // Asignado YA: `prepare()` activa la sesión de audio, y si algo falla después
            // `teardown()` tiene que poder soltarla (antes se quedaba activa y las otras
            // apps no recuperaban el sonido).
            source = mic
            // prepare() ANTES de leer el formato: ver el comentario en AudioSource.
            try mic.prepare()
            let sourceFormat = mic.format

            // AAC ~64 kbps ≈ 28 MB/hora (plan 5.1 y sección 8).
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            Store.shared.save(note)
            currentNoteID = id
            let fileWriter = try AudioFileWriter(
                directory: Store.shared.audioDirectory, baseName: id.uuidString,
                settings: fileSettings,
                onPartCreated: { name in
                    Task { @MainActor in Store.shared.update(id) { $0.audioParts.append(name) } }
                })
            writer = fileWriter

            let t = Transcriber()
            transcriber = t
            let segments = try await t.start(locale: locale)
            try Task.checkCancellation()

            consumeTask = Task { [weak self] in
                for await segment in segments {
                    self?.handle(segment)
                }
            }

            // ORDEN DE LOS BUFFERS: un AsyncStream conserva el orden de `yield` y un
            // único consumidor lo drena en secuencia. `.unbounded` a propósito: una
            // cola acotada descarta buffers, y aquí descartar es perder audio.
            let (buffers, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
            bufferContinuation = continuation

            // Freno: el disco nunca pierde nada; el ASR es ciudadano de segunda y SÍ se
            // salta audio cuando va más de 30 s por detrás (riesgo R11). El retraso se
            // mide DENTRO del transcriptor, que es donde se acumula de verdad.
            let backlog = Backlog()
            let maxLagSeconds = 30.0
            let meter = levelMeter

            pumpTask = Task.detached(priority: .userInitiated) { [fileWriter] in
                var skipping = false
                for await buffer in buffers {
                    _ = backlog.decrement()
                    meter.measure(buffer)

                    let ok = await fileWriter.write(buffer)      // 1) disco SIEMPRE
                    if !ok {
                        await MainActor.run { Recorder.shared.failDuringRecording(RecorderError.diskWriteFailed) }
                        break
                    }

                    let lag = await t.lagSeconds                 // 2) ASR, si da tiempo
                    if lag > maxLagSeconds || (skipping && lag > maxLagSeconds / 2) {
                        if !skipping { Log.event(Log.asr, "asr.skip.start", "lag=\(Int(lag))") }
                        skipping = true
                        await t.skipped(buffer)
                        continue
                    }
                    if skipping { Log.event(Log.asr, "asr.skip.end", "lag=\(Int(lag))"); skipping = false }
                    await t.feed(buffer)
                }
            }

            mic.onEvent = { [weak self] event in self?.handle(event) }
            try mic.start(onBuffer: { buffer in
                backlog.increment()
                continuation.yield(buffer)
            }, onFinish: {})

            if Task.isCancelled { throw CancellationError() }

            let startedTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // `.common`: el modo por defecto se congela mientras el usuario hace scroll.
            RunLoop.main.add(startedTimer, forMode: .common)
            timer = startedTimer
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
            state = .recording
            LiveActivityController.shared.start(noteID: id, title: note.title)
            Log.event(Log.capture, "record.start", "note=\(id.uuidString) lang=\(language)")
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            if cancelled {
                Log.event(Log.capture, "record.start.cancelled")
            } else {
                Log.failure(Log.capture, "record.start", error)
            }
            await teardown()
            // Antes de borrar: `Store.delete` se niega a borrar la nota en grabación.
            currentNoteID = nil
            if Store.shared.note(id) != nil {
                // Si no llegó a grabar nada, la nota sobra.
                if let n = Store.shared.note(id), n.allAudioFiles.allSatisfy({ !AudioParts.isReadable(Store.shared.audioURL($0)) }) {
                    Store.shared.delete(n)
                }
            }
            currentNoteID = nil
            ProcessingQueue.shared.resume()
            state = cancelled ? .idle : .failed(Self.userMessage(for: error))
        }
    }

    private func tick() {
        Task {
            if let w = writer { elapsed = await w.seconds }
        }
        level = levelMeter.current
        LiveActivityController.shared.update(elapsed: elapsed, level: level,
                                             interrupted: state == .interrupted)
    }

    private func handle(_ segment: Transcriber.Segment) {
        if segment.isFinal {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                finals.append(TranscriptSegment(text: text, start: segment.start, end: segment.end))
                liveText = finals.suffix(40).map(\.text).joined(separator: " ")
            }
            volatileText = ""
            saveIncrementally()
        } else {
            volatileText = segment.text
        }
    }

    /// La transcripción se guarda por el camino (cada ~10 s como mucho): si la app
    /// muere, lo transcrito hasta ahí no se pierde con ella.
    private func saveIncrementally(force: Bool = false) {
        guard let id = currentNoteID, force || Date().timeIntervalSince(lastIncrementalSave) > 10 else { return }
        lastIncrementalSave = Date()
        let segs = finals
        let secs = elapsed
        Store.shared.update(id) {
            $0.segments = segs
            $0.transcript = segs.map(\.text).joined(separator: " ")
            $0.duration = secs
        }
    }

    private func handle(_ event: MicEvent) {
        switch event {
        case .interrupted:
            guard state == .recording else { return }
            interruptedAt = elapsed
            state = .interrupted
        case .resumed(let reason):
            if state == .interrupted, let at = interruptedAt {
                finals.append(TranscriptSegment(text: "Interrupción (\(reason == "interruption" ? "llamada o aviso del sistema" : reason)) en \(TimeFormat.mmss(at))",
                                                start: at, end: at, isMarker: true))
                interruptedAt = nil
                // El hueco queda ENTRE dos trozos de audio, no dentro de uno.
                if let w = writer { Task { try? await w.rotate() } }
            }
            if state == .interrupted { state = .recording }
        case .resumeFailed(let message):
            failDuringRecording(message: message)
        }
    }

    /// Algo impide seguir grabando. Se guarda lo que haya y se dice claro.
    func failDuringRecording(_ error: Error) {
        failDuringRecording(message: Self.userMessage(for: error))
    }

    private func failDuringRecording(message: String) {
        guard state.isActive, let id = currentNoteID else { return }
        Task {
            await stop()
            // Solo si ESTA grabación es la que acabó: si el usuario ya había parado y
            // empezado otra, el fallo tardío no puede marcar la nueva como fallida.
            if state == .idle, lastFinishedNoteID == id { state = .failed(message) }
        }
    }

    /// Para y guarda. Síncrono en la entrada: `.stopping` se pone en el acto, así un
    /// doble toque en "Parar" ya no ejecuta dos veces la finalización (revisión).
    func stop() async {
        guard state.isActive else { return }
        state = .stopping
        let id = currentNoteID
        await teardown()

        // Todo lo que no depende de la nota se hace SIEMPRE, exista o no (antes, sin
        // nota se saltaba la Live Activity, la cola quedaba suspendida y el escritor
        // seguía vivo).
        let secs = await writer?.seconds ?? elapsed
        writer = nil
        currentNoteID = nil
        LiveActivityController.shared.end()
        // La nota se lee DESPUÉS de la última espera: un trozo de audio añadido
        // entretanto no se pierde al guardar.
        guard let id, var note = Store.shared.note(id) else {
            ProcessingQueue.shared.resume()
            state = .idle
            return
        }
        note.duration = secs
        note.segments = finals
        note.transcript = finals.filter { !$0.isMarker }.map(\.text).joined(separator: " ")
        note.state = NoteState.queued
        Store.shared.save(note)
        Log.event(Log.capture, "record.stop", "note=\(id.uuidString) secs=\(Int(note.duration)) segs=\(finals.count)")

        lastFinishedNoteID = id
        ProcessingQueue.shared.recordingFinished(noteID: id)
        state = .idle
    }

    /// Todo lo que hay que soltar, compartido por `stop()` y por un arranque fallido.
    /// Antes un arranque fallido dejaba la sesión de audio activa (silenciando otras
    /// apps), el analizador vivo y dos tareas sin cerrar.
    private func teardown() async {
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        source?.stop(); source = nil
        // Cerrar el flujo ANTES de finalizar el analizador: así el bombeo drena lo que
        // quede encolado y no se pierde el último trozo de la reunión.
        bufferContinuation?.finish()
        bufferContinuation = nil
        _ = await pumpTask?.value
        pumpTask = nil
        await writer?.close()
        await transcriber?.finish()
        // Esperar al consumidor: las últimas frases finales llegan al finalizar.
        _ = await consumeTask?.value
        consumeTask = nil
        transcriber = nil
    }

    static func defaultTitle(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Reunión · \(f.string(from: date))"
    }
}

/// Nivel de entrada para el medidor de la pantalla y la Live Activity. Se escribe
/// desde el hilo del bombeo y se lee desde el principal.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    var current: Float { lock.lock(); defer { lock.unlock() }; return value }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(1, n / 4)))
        // A escala 0…1 aproximada: -50 dB → 0, 0 dB → 1.
        let db = 20 * log10(max(rms, 0.000_01))
        let norm = max(0, min(1, (db + 50) / 50))
        lock.lock(); value = value * 0.6 + norm * 0.4; lock.unlock()
    }
}
