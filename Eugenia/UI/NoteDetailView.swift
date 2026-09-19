import UniformTypeIdentifiers
import AVFoundation
import SwiftUI

/// Detalle de una reunión (plan, Fase 1-3): reproductor + transcripción sincronizada +
/// resumen con saltos al audio + tareas + preguntas, edición, plantillas, exportación,
/// email de seguimiento y traducción.
struct NoteDetailView: View {
    let noteID: UUID
    var startAt: Double?

    @EnvironmentObject private var store: Store
    @ObservedObject private var queue = ProcessingQueue.shared
    @StateObject private var player = PlayerController()
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case summary, transcript, tasks, ask
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .summary: return "Resumen"
            case .transcript: return "Transcripción"
            case .tasks: return "Tareas"
            case .ask: return "Preguntar"
            }
        }
    }

    @State private var tab: Tab = .summary
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var editingSummary = false
    @State private var summaryDraft = ""
    @State private var showingSpeakers = false
    @State private var shareURL: URL?
    @State private var working: String?
    @State private var errorText: String?
    @State private var showTranslation = false
    @State private var confirmDelete = false

    private var note: Note? { store.note(noteID) }

    var body: some View {
        Group {
            if let note {
                content(note)
            } else {
                ContentUnavailableView("La reunión ya no existe", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let note else { return }
            if [NoteState.queued, NoteState.imported, NoteState.interrupted].contains(note.state) {
                queue.prioritize(noteID)
            }
            await player.load(note)
            if let startAt { player.seek(startAt); tab = .transcript }
        }
        .onDisappear { player.pause() }
        .sheet(isPresented: $showingSpeakers) { if let note { SpeakerNamesView(note: note) } }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Algo falló", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("¿Borrar la reunión?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar audio, transcripción y resumen", role: .destructive) {
                if let note { store.delete(note) }
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func content(_ note: Note) -> some View {
        VStack(spacing: 0) {
            List {
                header(note)
                Picker("Sección", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("detail-tabs")

                switch tab {
                case .summary: summarySection(note)
                case .transcript: transcriptSection(note)
                case .tasks: tasksSection(note)
                case .ask: Section { AskAIView(scope: note.id, embedded: true) }
                }
            }
            .listStyle(.insetGrouped)
            if player.isReady { PlayerBar(player: player) }
        }
        .navigationTitle(note.title)
        .toolbar { toolbar(note) }
        .overlay {
            if let working {
                ProgressView(working).padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: Cabecera

    @ViewBuilder
    private func header(_ note: Note) -> some View {
        Section {
            if editingTitle {
                HStack {
                    TextField("Título", text: $titleDraft)
                    Button("Guardar") {
                        let t = titleDraft.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { store.update(note.id) { $0.title = t } }
                        editingTitle = false
                    }
                }
            } else {
                Button {
                    titleDraft = note.title; editingTitle = true
                } label: {
                    HStack {
                        Text(note.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint("Editar título")
            }
            HStack(spacing: 6) {
                Text(note.createdAt, style: .date)
                Text(note.createdAt, style: .time)
                if note.duration > 0 { Text("· \(TimeFormat.mmss(note.duration))") }
                Text("· \(note.language.uppercased())")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !note.attendees.isEmpty {
                Text("Asistentes: \(note.attendees.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            }
            stateBanner(note)
        }
    }

    @ViewBuilder
    private func stateBanner(_ note: Note) -> some View {
        if queue.activeNoteID == note.id, !queue.phase.isEmpty {
            HStack { ProgressView(); Text(queue.phase) }.font(.callout)
        } else if note.state == NoteState.failed {
            VStack(alignment: .leading, spacing: 8) {
                Label(note.failure ?? String(localized: "No se pudo completar el resumen."), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                Text("La transcripción está guardada.").font(.caption).foregroundStyle(.secondary)
                Button("Reintentar") { queue.retry(note.id) }.buttonStyle(.bordered)
            }
            .accessibilityIdentifier("failure-banner")
        } else if [NoteState.queued, NoteState.imported, NoteState.interrupted].contains(note.state) {
            Label(note.state == NoteState.interrupted
                  ? String(localized: "La app se cerró mientras grababa: se recuperó lo grabado. En cola para resumir.")
                  : String(localized: "En cola: se procesará en cuanto sea posible."),
                  systemImage: "clock").font(.callout).foregroundStyle(.orange)
        }
    }

    // MARK: Resumen

    @ViewBuilder
    private func summarySection(_ note: Note) -> some View {
        let tr = note.translations[note.language == "es" ? "en" : "es"]
        if tr != nil {
            Toggle(note.language == "es" ? "Ver en inglés" : "Ver en español", isOn: $showTranslation)
        }
        Section("Resumen") {
            if editingSummary {
                TextEditor(text: $summaryDraft).frame(minHeight: 140)
                Button("Guardar") {
                    store.update(note.id) { $0.summaryOverview = summaryDraft }
                    editingSummary = false
                }
            } else if note.summaryOverview.isEmpty {
                Text("Todavía no hay resumen.").foregroundStyle(.secondary)
            } else {
                Text(showTranslation ? (tr?.overview ?? note.summaryOverview) : note.summaryOverview)
                    .textSelection(.enabled)
                Button("Editar resumen") { summaryDraft = note.summaryOverview; editingSummary = true }
                    .font(.caption)
            }
        }
        if !note.keyPoints.isEmpty {
            Section("Puntos clave") {
                ForEach(note.keyPoints) { p in
                    TimedRow(text: p.text, seconds: Double(p.atSeconds), canSeek: player.isReady) { player.seek($0); player.play() }
                }
            }
        }
        let questions = note.actionItems.filter(\.needsConfirmation)
        if !questions.isEmpty {
            Section("Por confirmar") {
                ForEach(questions) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(i.text, systemImage: "questionmark.circle").foregroundStyle(.orange)
                        ForEach(i.history, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        let decisions = showTranslation ? (tr?.decisions ?? note.decisions) : note.decisions
        if !decisions.isEmpty {
            Section("Decisiones") {
                ForEach(Array(decisions.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Section("Plantilla") {
            Picker("Plantilla", selection: Binding(get: { note.template }, set: { t in
                store.update(note.id) { $0.template = t }
            })) {
                ForEach(SummaryTemplate.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Button("Volver a resumir con esta plantilla") { queue.retry(note.id) }
                .disabled(note.transcript.isEmpty)
        }
        Section("Seguimiento") {
            if note.followUpEmail.isEmpty {
                Button("Redactar email de seguimiento") { run("Redactando…") {
                    let mail = try await Summarizer.followUpEmail(note: note)
                    store.update(note.id) { $0.followUpEmail = mail }
                } }
                .disabled(note.summaryOverview.isEmpty)
            } else {
                Text(note.followUpEmail).textSelection(.enabled).font(.callout)
                HStack {
                    Button("Copiar") {
                        // Solo en este iPhone (sin Portapapeles Universal) y caduca a los 2 min.
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: note.followUpEmail]],
                                                      options: [.localOnly: true,
                                                                .expirationDate: Date().addingTimeInterval(120)])
                    }
                    Spacer()
                    Button("Rehacer") { store.update(note.id) { $0.followUpEmail = "" } }
                }
                .buttonStyle(.borderless)
            }
            let target = note.language == "es" ? "en" : "es"
            Button(tr == nil ? (target == "en" ? "Traducir al inglés" : "Traducir al español")
                             : "Rehacer la traducción") {
                run("Traduciendo…") {
                    let t = try await Summarizer.translate(note: note, to: target)
                    store.update(note.id) { $0.translations[target] = t }
                    showTranslation = true
                }
            }
            .disabled(note.transcript.isEmpty)
        }
    }

    // MARK: Transcripción

    @ViewBuilder
    private func transcriptSection(_ note: Note) -> some View {
        Section {
            if !note.speakerLabels.isEmpty {
                Button { showingSpeakers = true } label: { Label("Nombres de los hablantes", systemImage: "person.2") }
            }
            Menu {
                Button("Español") { queue.retranscribe(note.id, language: "es") }
                Button("Inglés") { queue.retranscribe(note.id, language: "en") }
            } label: {
                Label("¿Idioma equivocado? Volver a transcribir", systemImage: "globe")
            }
            .disabled(!queue.hasAllAudio(note) || note.pendingLanguage != nil)
        }
        Section("Transcripción") {
            if showTranslation, let tr = note.translations[note.language == "es" ? "en" : "es"] {
                Text(tr.transcript).textSelection(.enabled)
            } else if note.segments.isEmpty {
                Text(note.transcript.isEmpty ? String(localized: "(vacía)") : note.transcript)
                    .textSelection(.enabled)
            } else {
                // LazyVStack dentro de la celda: una reunión de 2 h no se pinta entera.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(note.segments) { seg in
                        SegmentRow(segment: seg, name: note.displayName(forSpeaker: seg.speaker),
                                   color: SpeakerColor.color(for: seg.speaker),
                                   active: player.currentTime >= seg.start && player.currentTime < max(seg.end, seg.start + 1))
                            .onTapGesture { if player.isReady && !seg.isMarker { player.seek(seg.start); player.play() } }
                    }
                }
            }
        }
    }

    // MARK: Tareas

    @ViewBuilder
    private func tasksSection(_ note: Note) -> some View {
        let open = note.actionItems.filter { $0.isOpen }
        let closed = note.actionItems.filter { !$0.isOpen }
        if note.actionItems.isEmpty {
            Text("Sin tareas.").foregroundStyle(.secondary)
        }
        if !open.isEmpty {
            Section("Próximos pasos") { ForEach(open) { taskRow(note, $0) } }
        }
        if !closed.isEmpty {
            Section("Hechas, aplazadas o canceladas") { ForEach(closed) { taskRow(note, $0) } }
        }
    }

    private func taskRow(_ note: Note, _ item: StoredActionItem) -> some View {
        HStack(alignment: .top) {
            Button {
                store.update(note.id) { n in
                    if let i = n.actionItems.firstIndex(where: { $0.id == item.id }) { n.actionItems[i].done.toggle() }
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Marcar como pendiente" : "Marcar como hecha")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).strikethrough(item.done)
                HStack(spacing: 6) {
                    Text(item.status)
                    if !item.assignee.isEmpty { Text("· \(item.assignee)") }
                    if !item.dueText.isEmpty { Text("· \(item.dueText)") }
                    if item.needsConfirmation { Text("· por confirmar").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(item.history, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if player.isReady {
                Button(TimeFormat.mmss(Double(item.atSeconds))) { player.seek(Double(item.atSeconds)); player.play() }
                    .font(.caption.monospacedDigit()).buttonStyle(.borderless)
            }
        }
    }

    // MARK: Barra

    @ToolbarContentBuilder
    private func toolbar(_ note: Note) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Exportar") {
                    ForEach(ExportFormat.allCases) { f in
                        Button(f.title) {
                            do { shareURL = try NoteExporter.file(note, format: f) }
                            catch { errorText = Recorder.userMessage(for: error) }
                        }
                    }
                }
                if AppSettings.shared.dataOutConsent && !AppSettings.shared.crmShortcutName.isEmpty {
                    Button { ShortcutRunner.sendToCRM(noteID: note.id) } label: {
                        Label("Enviar al CRM (atajo)", systemImage: "paperplane")
                    }
                }
                Button {
                    store.update(note.id) { $0.isFavorite.toggle() }
                } label: {
                    Label(note.isFavorite ? "Quitar de favoritas" : "Favorita (no se borra el audio)", systemImage: "star")
                }
                if note.state != NoteState.recording {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Borrar", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Más acciones")
            .accessibilityIdentifier("detail-menu")
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        Task {
            working = label
            defer { working = nil }
            do { try await work() } catch { errorText = Recorder.userMessage(for: error) }
        }
    }
}

// MARK: - Piezas

private struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Al cerrar la hoja, fuera las copias temporales en claro (tmp/export).
        let exportDir = TempFiles.exportDirectory.standardizedFileURL.path
        let urls = items.compactMap { $0 as? URL }
        vc.completionWithItemsHandler = { _, _, _, _ in
            for u in urls where u.standardizedFileURL.path.hasPrefix(exportDir) {
                try? FileManager.default.removeItem(at: u)
            }
        }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct TimedRow: View {
    let text: String
    let seconds: Double
    let canSeek: Bool
    let seek: (Double) -> Void
    var body: some View {
        HStack(alignment: .top) {
            Text(text)
            Spacer()
            if canSeek {
                Button(TimeFormat.mmss(seconds)) { seek(seconds) }
                    .font(.caption.monospacedDigit()).buttonStyle(.borderless)
                    .accessibilityLabel("Escuchar desde \(TimeFormat.mmss(seconds))")
            } else {
                Text(TimeFormat.mmss(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .brown, .indigo]
    static func color(for label: String?) -> Color {
        guard let label, let n = Int(label.drop(while: { !$0.isNumber })) else { return .secondary }
        return palette[(n - 1) % palette.count]
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let name: String?
    let color: Color
    let active: Bool
    var body: some View {
        if segment.isMarker {
            Label(segment.text, systemImage: "pause.circle").font(.caption).foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let name { Text(name).font(.caption.weight(.semibold)).foregroundStyle(color) }
                    Text(TimeFormat.mmss(segment.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .padding(active ? 4 : 0)
                    .background(active ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Renombrar hablantes (plan 5.3). Con el reconocimiento de voces activo, además
/// aprende la voz para las próximas reuniones.
struct SpeakerNamesView: View {
    let note: Note
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(note.speakerLabels, id: \.self) { label in
                        HStack {
                            Circle().fill(SpeakerColor.color(for: label)).frame(width: 12, height: 12)
                            TextField(note.displayName(forSpeaker: label) ?? label, text: Binding(
                                get: { names[label] ?? "" }, set: { names[label] = $0 }))
                        }
                    }
                } footer: {
                    Text(AppSettings.shared.voiceprintsEnabled
                         ? "Eugenia recordará estas voces para reconocerlas en próximas reuniones. Se guardan solo en este iPhone."
                         : "Puedes activar el reconocimiento de voces en Ajustes para que Eugenia las reconozca en próximas reuniones.")
                }
            }
            .navigationTitle("Hablantes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let clean = names.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
                        store.update(note.id) { n in for (k, v) in clean { n.speakerNames[k] = v } }
                        let emb = DiarizationCache.shared.embeddings(noteID: note.id)
                        for (label, name) in clean { if let e = emb[label] { VoiceprintStore.shared.enroll(name: name, embedding: e) } }
                        SearchIndex.shared.invalidate(note.id)
                        dismiss()
                    }
                }
            }
            .onAppear { names = note.speakerNames }
        }
    }
}

// MARK: - Reproductor

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }

    private var player: AVPlayer?
    private var observer: Any?

    func load(_ note: Note) async {
        guard player == nil, note.audioState == "present" else { return }
        let urls = note.allAudioFiles.map(Store.shared.audioURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty, let asset = await AudioParts.composition(urls) else { return }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? note.duration
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                self?.currentTime = t.seconds
                self?.isPlaying = (self?.player?.rate ?? 0) > 0
            }
        }
        isReady = true
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() { player?.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }

    func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func skip(_ delta: Double) { seek(currentTime + delta) }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: PlayerController
    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }),
                   in: 0...max(player.duration, 1))
                .accessibilityLabel("Posición del audio")
            HStack {
                Text(TimeFormat.mmss(player.currentTime)).font(.caption.monospacedDigit())
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .accessibilityLabel("Atrás 15 segundos")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.largeTitle)
                }
                .accessibilityLabel(player.isPlaying ? "Pausa" : "Reproducir")
                .accessibilityIdentifier("play-button")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .accessibilityLabel("Adelante 15 segundos")
                Spacer()
                Menu("\(player.rate, specifier: "%.1f")×") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Button("\(r, specifier: "%.2g")×") { player.rate = Float(r) } }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}
