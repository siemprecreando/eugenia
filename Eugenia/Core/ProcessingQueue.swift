import AVFoundation
import BackgroundTasks
import Foundation
import UIKit

/// Cola única de enriquecimiento. Plan, sección 5.7.
///
/// Todo lo que viene DESPUÉS de grabar pasa por aquí, de uno en uno: transcribir
/// audio importado, separar hablantes, resumir, indexar para la búsqueda y avisar.
///
/// Reglas:
///  - La grabación manda. Al empezar a grabar la cola se SUSPENDE: el trabajo en curso
///    se cancela y, como el resumen persiste cada fragmento (5.4.7), al reanudar solo
///    se rehace el fragmento que estaba a medias.
///  - El estado vive en las notas (`queued`, `processing`, `interrupted`, `imported`),
///    no en memoria: si iOS mata la app entre dos reuniones, al volver se sigue.
///  - La nota que el usuario tiene abierta se adelanta (`prioritize`).
///  - Térmica `.serious` o peor: pausa. Batería < 20 % sin cargador: se aplaza a una
///    tarea de fondo con corriente.
@MainActor
final class ProcessingQueue: ObservableObject {
    static let shared = ProcessingQueue()
    static let bgTaskID = "com.eugenia.app.processing"

    @Published private(set) var activeNoteID: UUID?
    @Published private(set) var phase: String = ""
    @Published private(set) var suspended = false

    private var worker: Task<Void, Never>?
    private var priorityID: UUID?
    private var wake: CheckedContinuation<Void, Never>?

    private static let pendingStates: Set<String> = [NoteState.queued, NoteState.processing,
                                                     NoteState.interrupted, NoteState.imported]

    /// Arranque de la app: recuperar grabaciones cortadas y reanudar lo pendiente.
    func bootstrap() {
        Store.shared.recoverInterruptedRecordings(except: Recorder.shared.currentNoteID)
        // Live Activity que dejó un proceso anterior muerto a mitad de grabación.
        if !Recorder.shared.state.isActive && Recorder.shared.state != .starting {
            LiveActivityController.shared.endOrphans()
        }
        // Lo que se quedó "processing" al morir la app vuelve a la cola.
        for n in Store.shared.notes where n.state == NoteState.processing {
            Store.shared.update(n.id) { $0.state = NoteState.queued }
        }
        RetentionPolicy.sweep()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in ProcessingQueue.shared.kick() }
        }
        kick()
    }

    // MARK: - Señales

    func suspendForRecording() {
        suspended = true
        worker?.cancel()
        Log.event(Log.queue, "queue.suspend")
    }

    func resume() {
        suspended = false
        kick()
    }

    func recordingFinished(noteID: UUID) {
        suspended = false
        prioritize(noteID)
    }

    func enqueue(_ id: UUID) {
        Store.shared.update(id) { if !Self.pendingStates.contains($0.state) { $0.state = NoteState.queued } }
        kick()
    }

    /// La nota que el usuario está mirando pasa delante (plan 5.7).
    func prioritize(_ id: UUID) {
        priorityID = id
        kick()
    }

    func kick() {
        if let w = wake { wake = nil; w.resume() }
        guard worker == nil else { return }
        worker = Task { await self.loop() }
    }

    private var pending: [Note] {
        Store.shared.notes
            .filter { Self.pendingStates.contains($0.state) }
            .sorted { $0.createdAt < $1.createdAt }        // FIFO por antigüedad
    }

    private var blockedReason: String? {
        if suspended || Recorder.shared.state.isActive || Recorder.shared.state == .starting { return "grabando" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "el iPhone está caliente"
        default: break
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let charging = [.charging, .full].contains(UIDevice.current.batteryState)
        if level >= 0, level < 0.2, !charging { return "batería baja" }
        return nil
    }

    private func loop() async {
        defer {
            worker = nil; activeNoteID = nil; phase = ""
            // Un trabajo cancelado que termina de deshacerse DESPUÉS de que la grabación
            // acabara: su `kick()` llegó cuando este worker aún existía y se perdió.
            if !suspended, !Recorder.shared.state.isActive, !pending.isEmpty,
               UIApplication.shared.applicationState != .background {
                Task { @MainActor in ProcessingQueue.shared.kick() }
            }
        }
        while !Task.isCancelled {
            let queue = pending
            guard !queue.isEmpty else { return }
            if let reason = blockedReason {
                phase = "En pausa: \(reason)"
                if reason == "batería baja" { scheduleBackgroundProcessing() }
                if reason == "grabando" { return }          // resume() nos vuelve a llamar
                await sleepUntilKicked(seconds: 60)
                continue
            }
            let next = queue.first { $0.id == priorityID } ?? queue[0]
            if next.id == priorityID { priorityID = nil }
            await process(next.id)
            if Task.isCancelled { return }
        }
    }

    private func sleepUntilKicked(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if let w = self.wake { self.wake = nil; w.resume() }
            }
        }
    }

    // MARK: - Un trabajo

    private func process(_ id: UUID) async {
        guard let initial = Store.shared.note(id) else { return }
        activeNoteID = id
        Store.shared.update(id) { $0.state = NoteState.processing; $0.failure = nil }

        // Unos segundos de gracia en segundo plano: iOS da ~30 s tras bloquear. Si se
        // acaban, el trabajo se cancela y los fragmentos ya hechos quedan guardados.
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "eugenia.enrich") { [weak self] in
            self?.worker?.cancel()
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid                       // que el defer no lo cierre dos veces
        }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        do {
            // 1) Audio importado sin transcribir
            if (initial.segments.isEmpty && initial.transcript.isEmpty || initial.pendingLanguage != nil)
                && !initial.allAudioFiles.isEmpty {
                phase = "Transcribiendo"
                try await transcribeFromAudio(id)
            }
            // El usuario pidió otra cosa entretanto (reintentar, otra plantilla, otro
            // idioma) o la borró: este trabajo ya no vale; la cola lo retoma.
            guard stillMine(id) else { return }
            // 2) Hablantes
            if AppSettings.shared.diarizationEnabled, let n = Store.shared.note(id),
               !n.allAudioFiles.isEmpty, n.audioState == "present", n.speakerLabels.isEmpty, !n.segments.isEmpty {
                phase = "Separando hablantes"
                try Task.checkCancellation()
                await diarize(id)
            }
            try Task.checkCancellation()
            guard stillMine(id) else { return }
            // 2b) Audio fuera, si el usuario no quiere guardarlo: a partir de aquí ya no
            // hace falta (el resumen trabaja sobre la transcripción).
            if AppSettings.shared.audioRetentionDays == RetentionPolicy.afterProcessing,
               let n = Store.shared.note(id), RetentionPolicy.audioNoLongerNeeded(n) {
                RetentionPolicy.dropAudio(n)
            }
            // 3) Resumen
            guard let n = Store.shared.note(id) else { return }
            let hasText = !n.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText {
                phase = "Resumiendo"
                try await summarize(id)
            } else {
                Store.shared.update(id) {
                    guard $0.state == NoteState.processing else { return }
                    $0.state = NoteState.failed
                    $0.failure = SummarizerError.emptyTranscript.description
                    $0.failureCode = "emptyTranscript"
                }
            }
            // 4) Índice de búsqueda
            SearchIndex.shared.invalidate(id)
            // 5) Aviso
            if let done = Store.shared.note(id), done.state == NoteState.summarized {
                Notifier.summaryReady(done)
            }
            Log.event(Log.queue, "job.done", "note=\(id.uuidString)")
        } catch is CancellationError {
            // Suspendido (grabación) o sin tiempo de fondo: vuelve a la cola tal cual.
            Store.shared.update(id) { if $0.state == NoteState.processing { $0.state = NoteState.queued } }
            Log.event(Log.queue, "job.suspended", "note=\(id.uuidString)")
        } catch {
            Log.failure(Log.queue, "job", error)
            Store.shared.update(id) {
                guard $0.state == NoteState.processing else { return }
                $0.state = NoteState.failed
                // Texto legible y SIN contenido: nunca el `String(describing:)` del error
                // (los de FoundationModels pueden arrastrar el fragmento de transcripción).
                $0.failure = Recorder.userMessage(for: error)
                if let e = error as? SummarizerError, case .modelUnavailable = e {
                    $0.failureCode = "modelUnavailable"
                } else {
                    $0.failureCode = "other"
                }
                // Una re-transcripción que falla deja la nota como estaba, sin repetirse.
                $0.pendingLanguage = nil
            }
        }
        activeNoteID = nil
        phase = ""
    }

    private func stillMine(_ id: UUID) -> Bool {
        Store.shared.note(id)?.state == NoteState.processing
    }

    /// Reintentar a mano una nota fallida (o forzar otra plantilla).
    func retry(_ id: UUID, resetSummary: Bool = false) {
        Store.shared.update(id) {
            $0.state = NoteState.queued
            $0.failure = nil
            $0.failureCode = nil
            if resetSummary { $0.mapCheckpoints = [] }
        }
        prioritize(id)
    }

    private func summarize(_ id: UUID) async throws {
        guard let n = Store.shared.note(id) else { return }
        let template = SummaryTemplate(rawValue: n.template) ?? .executive
        let result = try await Summarizer.summarize(
            segments: n.segments, plainTranscript: n.transcript, language: n.language,
            template: template, tone: AppSettings.shared.summaryTone, meetingDate: n.createdAt,
            speakerName: { n.displayName(forSpeaker: $0) },
            checkpoints: n.mapCheckpoints,
            onCheckpoint: { cp in
                Store.shared.update(id) { $0.mapCheckpoints.append(cp) }
            })
        Store.shared.update(id) {
            guard $0.state == NoteState.processing else { return }
            // Las tareas que el usuario ya marcó como hechas siguen hechas.
            let doneTexts = Set($0.actionItems.filter(\.done).map(\.text))
            $0.summaryOverview = result.overview
            $0.keyPoints = result.keyPoints
            $0.decisions = result.decisions
            $0.actionItems = result.actionItems.map { var i = $0; i.done = doneTexts.contains(i.text); return i }
            $0.state = NoteState.summarized
            $0.failure = nil
            $0.failureCode = nil
        }
    }

    // MARK: - Transcribir un fichero (importación y re-transcripción)

    /// Transcribe los ficheros de audio de la nota con el MISMO pipeline que el
    /// micrófono (FileAudioSource → Transcriber). Guarda segmentos con tiempos.
    private func transcribeFromAudio(_ id: UUID) async throws {
        guard let n = Store.shared.note(id) else { return }
        let language = n.pendingLanguage ?? n.language
        let locale = Locale(identifier: language == "en" ? "en-US" : "es-ES")
        try await Transcriber.prepareModel(for: locale)
        var all: [TranscriptSegment] = []
        var offset = 0.0
        for name in n.allAudioFiles {
            try Task.checkCancellation()
            let url = Store.shared.audioURL(name)
            let segs = try await FileTranscription.transcribe(url: url, locale: locale)
            all += segs.map { TranscriptSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            offset += AudioParts.duration(url)
        }
        Store.shared.update(id) {
            guard $0.state == NoteState.processing else { return }
            if $0.pendingLanguage != nil {
                // Solo AHORA, con la transcripción nueva en la mano, se tira lo viejo.
                $0.language = language
                $0.pendingLanguage = nil
                $0.speakerNames = [:]
                $0.summaryOverview = ""
                $0.keyPoints = []
                $0.decisions = []
                $0.actionItems = []
                $0.translations = [:]
                $0.followUpEmail = ""
            }
            $0.segments = all
            $0.transcript = all.map(\.text).joined(separator: " ")
            if $0.duration == 0 { $0.duration = offset }
            $0.mapCheckpoints = []
        }
    }

    /// ¿Están todos los ficheros de audio de la nota en disco? (Una nota restaurada
    /// de una copia sin audio dice "present" pero no tiene nada que transcribir.)
    func hasAllAudio(_ n: Note) -> Bool {
        n.audioState == "present" && !n.allAudioFiles.isEmpty
            && n.allAudioFiles.allSatisfy { FileManager.default.fileExists(atPath: Store.shared.audioURL($0).path) }
    }

    /// Cambiar el idioma de una reunión ya grabada: se vuelve a transcribir desde el
    /// audio (plan 5.2: anulación manual del idioma).
    /// Antes borraba transcripción y resumen de entrada: si la nueva transcripción
    /// fallaba (modelo del otro idioma sin red, audio que no está), la nota se quedaba
    /// vacía para siempre. Ahora lo viejo se conserva hasta que lo nuevo sale bien.
    @discardableResult
    func retranscribe(_ id: UUID, language: String) -> Bool {
        guard let n = Store.shared.note(id), hasAllAudio(n) else { return false }
        Store.shared.update(id) {
            $0.pendingLanguage = language
            $0.state = NoteState.queued
            $0.failure = nil
            $0.failureCode = nil
        }
        prioritize(id)
        return true
    }

    private func diarize(_ id: UUID) async {
        guard let n = Store.shared.note(id) else { return }
        let urls = n.allAudioFiles.map(Store.shared.audioURL)
        do {
            let out = try await Diarizer.diarize(urls: urls)
            guard !out.turns.isEmpty else { return }
            let labelled = SpeakerAligner.assign(segments: n.segments, turns: out.turns)
            var names: [String: String] = n.speakerNames
            for (label, name) in VoiceprintStore.shared.match(embeddings: out.embeddings) where names[label] == nil {
                names[label] = name
            }
            // Borrada o re-pedida mientras se separaban hablantes: no se toca nada, y
            // mucho menos se guardan huellas de voz de una reunión borrada.
            guard stillMine(id) else { return }
            Store.shared.update(id) {
                guard $0.state == NoteState.processing else { return }
                $0.segments = labelled
                $0.speakerNames = names
            }
            DiarizationCache.shared.store(noteID: id, embeddings: out.embeddings)
        } catch {
            // Sin hablantes la reunión sigue siendo útil: se resume igual.
            Log.failure(Log.queue, "diarize", error)
        }
    }

    // MARK: - Fondo

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                ProcessingQueue.shared.kick()
                task.expirationHandler = { Task { @MainActor in ProcessingQueue.shared.worker?.cancel() } }
                // Se da por terminado cuando la cola se vacía o a los 10 minutos.
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if ProcessingQueue.shared.worker == nil { break }
                }
                task.setTaskCompleted(success: true)
            }
        }
    }

    func scheduleBackgroundProcessing() {
        let req = BGProcessingTaskRequest(identifier: Self.bgTaskID)
        req.requiresExternalPower = true
        req.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(req)
    }
}

/// Transcripción de un fichero con el pipeline de producción.
enum FileTranscription {
    static func transcribe(url: URL, locale: Locale, caseId: String? = nil) async throws -> [TranscriptSegment] {
        // El fichero se abre ANTES de arrancar el analizador: si no se puede leer, no
        // queda un SpeechAnalyzer vivo para siempre.
        let source = try FileAudioSource(url: url, realtimeFactor: 0)
        let transcriber = Transcriber()
        let segments = try await transcriber.start(locale: locale, caseId: caseId)

        // El consumidor arranca ANTES de alimentar.
        let collector = Task<[TranscriptSegment], Never> {
            var finals: [TranscriptSegment] = []
            for await s in segments where s.isFinal {
                let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { finals.append(TranscriptSegment(text: t, start: s.start, end: s.end)) }
            }
            return finals
        }

        // Orden garantizado: un AsyncStream y un único consumidor.
        let (buffers, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let pump = Task.detached(priority: .userInitiated) {
            for await buffer in buffers { await transcriber.feed(buffer) }
        }

        let done = AsyncStream<Void>.makeStream()
        do {
            try source.start(onBuffer: { continuation.yield($0) }, onFinish: { done.continuation.finish() })
        } catch {
            continuation.finish(); await pump.value; await transcriber.finish()
            throw error
        }
        // Al empezar una grabación la cola cancela: se deja de leer el fichero en vez
        // de transcribirlo entero a la vez que el micrófono (plan 5.7).
        await withTaskCancellationHandler {
            for await _ in done.stream {}
        } onCancel: {
            source.stop()
        }
        continuation.finish()
        await pump.value
        await transcriber.finish()
        let result = await collector.value
        try Task.checkCancellation()
        return result
    }
}
