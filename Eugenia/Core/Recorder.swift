import AVFoundation
import Foundation

/// Orquesta captura, escritura a disco y transcripción en vivo.
/// Plan, secciones 5.1 y 5.2.
///
/// PRINCIPIO INNEGOCIABLE: el audio es sagrado. Se escribe a disco de forma
/// incremental desde el primer buffer. Si el ASR falla, se reintenta; si la app
/// muere, la grabación se recupera. Nunca al revés.
@MainActor
final class Recorder: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case processing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveText: String = ""
    @Published private(set) var volatileText: String = ""
    @Published private(set) var elapsed: TimeInterval = 0

    private var source: AudioSource?
    private var audioFile: AVAudioFile?
    private var transcriber: Transcriber?
    private var consumeTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentNote: Note?
    private var finals: [String] = []

    let language: String = Locale.current.language.languageCode?.identifier == "en" ? "en" : "es"
    private var locale: Locale { Locale(identifier: language == "en" ? "en-US" : "es-ES") }

    // MARK: - Ciclo de grabación

    func start() async {
        guard state == .idle else { return }
        finals = []
        liveText = ""
        volatileText = ""
        elapsed = 0

        let id = UUID()
        let fileName = "\(id.uuidString).m4a"
        var note = Note(id: id,
                        title: Self.defaultTitle(),
                        createdAt: Date(),
                        duration: 0,
                        language: language,
                        audioFileName: fileName,
                        transcript: "",
                        summaryOverview: "",
                        decisions: [],
                        actionItems: [],
                        state: "recording",
                        failure: nil)
        Store.shared.save(note)
        currentNote = note

        do {
            try await Transcriber.prepareModel(for: locale)

            let mic = MicrophoneAudioSource()
            let sourceFormat = mic.format

            // AAC ~64 kbps ≈ 28 MB/hora (plan 5.1 y sección 8).
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            let url = Store.shared.audioDirectory.appendingPathComponent(fileName)
            audioFile = try AVAudioFile(forWriting: url, settings: settings)

            let t = Transcriber()
            transcriber = t
            let segments = try await t.start(locale: locale)

            consumeTask = Task { [weak self] in
                for await segment in segments {
                    await self?.handle(segment)
                }
            }

            try mic.start(onBuffer: { [weak self] buffer in
                guard let self else { return }
                Task { await self.ingest(buffer) }
            }, onFinish: {})
            source = mic

            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let s = self.startedAt else { return }
                Task { @MainActor in self.elapsed = Date().timeIntervalSince(s) }
            }
            state = .recording
            Log.event(Log.capture, "record.start", nil, "note=\(id.uuidString)")
        } catch {
            Log.failure(Log.capture, "record.start", error)
            note.state = "failed"
            note.failure = String(describing: error)
            Store.shared.save(note)
            state = .failed(String(describing: error))
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) async {
        // 1) A disco SIEMPRE primero. Si esto falla, la grabación se para.
        do {
            try audioFile?.write(from: buffer)
        } catch {
            Log.failure(Log.capture, "audio.write", error)
        }
        // 2) Al ASR después. Si esto falla, la grabación continúa.
        await transcriber?.feed(buffer)
    }

    private func handle(_ segment: Transcriber.Segment) {
        if segment.isFinal {
            finals.append(segment.text)
            liveText = finals.joined(separator: " ")
            volatileText = ""
        } else {
            volatileText = segment.text
        }
    }

    func stop() async {
        guard state == .recording else { return }
        timer?.invalidate(); timer = nil
        source?.stop(); source = nil
        await transcriber?.finish()
        consumeTask?.cancel()
        audioFile = nil

        guard var note = currentNote else { state = .idle; return }
        note.duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        note.transcript = finals.joined(separator: " ")
        note.state = "transcribed"
        Store.shared.save(note)
        Log.event(Log.capture, "record.stop", nil, "note=\(note.id.uuidString) secs=\(Int(note.duration)) chars=\(note.transcript.count)")

        state = .processing("Resumiendo…")
        await summarize(note)
    }

    private func summarize(_ note: Note) async {
        var note = note
        guard Summarizer.isAvailable else {
            note.state = "failed"
            note.failure = "LLM no disponible: \(Summarizer.availabilityDescription())"
            Store.shared.save(note)
            state = .failed(note.failure ?? "")
            return
        }
        do {
            let summary = try await Summarizer.summarize(transcript: note.transcript, language: note.language)
            note.summaryOverview = summary.overview
            note.decisions = summary.decisions
            note.actionItems = summary.actionItems.map {
                StoredActionItem(text: $0.text, assignee: $0.assignee, status: $0.status, atSeconds: $0.atSeconds)
            }
            note.state = "summarized"
            Store.shared.save(note)
            state = .idle
        } catch {
            Log.failure(Log.summarize, "summarize", error)
            note.state = "failed"
            note.failure = String(describing: error)
            Store.shared.save(note)
            state = .failed(String(describing: error))
        }
    }

    private static func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Reunión · \(f.string(from: Date()))"
    }
}
