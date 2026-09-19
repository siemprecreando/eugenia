import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var queue = ProcessingQueue.shared

    @State private var query = ""
    @State private var folderFilter: String?
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingAsk = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importError: String?
    @State private var importing = false
    @State private var movingNote: Note?

    private var filtered: [Note] {
        store.notes.filter { folderFilter == nil || $0.folder == folderFilter }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if !query.isEmpty {
                    SearchResultsView(query: query, notes: filtered)
                } else if store.notes.isEmpty {
                    ContentUnavailableView {
                        Label("Sin reuniones todavía", systemImage: "waveform")
                    } description: {
                        Text("Pulsa Grabar para la primera, o importa un audio o un PDF. Todo se procesa en este iPhone.")
                    }
                } else {
                    library
                }
            }
            .navigationTitle("Eugenia")
            .searchable(text: $query, prompt: Text("Buscar en todas las reuniones"))
            .navigationDestination(for: NoteRoute.self) { route in
                NoteDetailView(noteID: route.id, startAt: route.at)
            }
            .safeAreaInset(edge: .bottom) { recordBar }
            .toolbar { toolbar }
        }
        .fullScreenCover(isPresented: $router.showRecorder) {
            RecordView(initialTitle: router.pendingTitle, eventID: router.pendingEventID)
        }
        .fullScreenCover(isPresented: Binding(get: { !settings.onboardingDone },
                                              set: { if !$0 { settings.onboardingDone = true } })) {
            OnboardingView()
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingAsk) { AskAIView(scope: nil) }
        .sheet(item: $movingNote) { note in MoveToFolderView(note: note) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Importer.supportedTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { runImport(urls) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                importing = true
                defer { importing = false; photoItem = nil }
                do {
                    guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return }
                    _ = try await Importer.importFile(movie.url, folder: folderFilter ?? "")
                } catch {
                    importError = (error as? CustomStringConvertible)?.description ?? Recorder.userMessage(for: error)
                }
            }
        }
        .onChange(of: router.pendingImportURL) { _, url in
            guard let url else { return }
            router.pendingImportURL = nil
            runImport([url])
        }
        .alert("No se pudo importar", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .overlay { if importing { ProgressView("Importando…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
    }

    private func runImport(_ urls: [URL]) {
        Task {
            importing = true
            defer { importing = false }
            for url in urls {
                do {
                    let id = try await Importer.importFile(url, folder: folderFilter ?? "")
                    if urls.count == 1 { router.open(noteID: id) }
                } catch {
                    importError = (error as? CustomStringConvertible)?.description ?? Recorder.userMessage(for: error)
                }
            }
        }
    }

    // MARK: Biblioteca

    private var library: some View {
        List {
            if !store.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        FolderChip(title: String(localized: "Todas"), selected: folderFilter == nil) { folderFilter = nil }
                        ForEach(store.folders, id: \.self) { f in
                            FolderChip(title: f, selected: folderFilter == f) { folderFilter = f }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }
            if store.indexIsReadOnly {
                Label("El índice de reuniones no se pudo leer. Se guardó una copia intacta y no se escribirá encima.",
                      systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            ForEach(filtered) { note in
                NavigationLink(value: NoteRoute(id: note.id, at: nil)) {
                    NoteRow(note: note, phase: queue.activeNoteID == note.id ? queue.phase : nil,
                            queuePosition: queuePosition(note))
                }
                .accessibilityIdentifier("note-\(note.title)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { store.delete(note) } label: { Label("Borrar", systemImage: "trash") }
                    Button { movingNote = note } label: { Label("Carpeta", systemImage: "folder") }.tint(.indigo)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        store.update(note.id) { $0.isFavorite.toggle() }
                    } label: {
                        Label(note.isFavorite ? "Quitar favorita" : "Favorita", systemImage: note.isFavorite ? "star.slash" : "star")
                    }.tint(.yellow)
                }
            }
        }
    }

    private func queuePosition(_ note: Note) -> Int? {
        guard [NoteState.queued, NoteState.imported, NoteState.interrupted].contains(note.state) else { return nil }
        let pending = store.notes.filter { [NoteState.queued, NoteState.imported, NoteState.interrupted].contains($0.state) }
            .sorted { $0.createdAt < $1.createdAt }
        return pending.firstIndex { $0.id == note.id }.map { $0 + 1 }
    }

    private var recordBar: some View {
        Button {
            router.startRecording()
        } label: {
            Label(recorder.state.isActive ? "Grabando… (volver)" : "Grabar",
                  systemImage: recorder.state.isActive ? "record.circle" : "mic.circle.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.state.isActive ? .red : .accentColor)
        .accessibilityIdentifier("record-button")
        .padding()
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Ajustes")
                .accessibilityIdentifier("settings-button")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingAsk = true } label: { Image(systemName: "sparkles") }
                .accessibilityLabel("Preguntar a tus reuniones")
                .accessibilityIdentifier("ask-button")
            Menu {
                Button { showingImporter = true } label: { Label("Desde Archivos", systemImage: "folder") }
                PhotosPicker(selection: $photoItem, matching: .videos) { Label("Vídeo de Fotos", systemImage: "photo") }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Importar")
            .accessibilityIdentifier("import-menu")
            StatusBadge()
        }
    }
}

/// Vídeo de la fototeca como fichero temporal.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

private struct FolderChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NoteRow: View {
    let note: Note
    var phase: String?
    var queuePosition: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if note.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                if note.source == "document" { Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary) }
                Text(note.title).font(.headline).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(note.createdAt, style: .date)
                if note.duration > 0 { Text("· \(TimeFormat.mmss(note.duration))") }
                Text("· \(note.language.uppercased())")
                if !note.folder.isEmpty { Text("· \(note.folder)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let label = stateLabel {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(note.state == NoteState.failed ? .red : .orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var stateLabel: String? {
        if let phase { return phase }
        switch note.state {
        case NoteState.recording:   return String(localized: "Grabando")
        case NoteState.queued, NoteState.imported:
            if let p = queuePosition { return String(localized: "En cola (\(p))") }
            return String(localized: "En cola")
        case NoteState.interrupted: return String(localized: "Recuperada tras un cierre: en cola")
        case NoteState.processing:  return String(localized: "Procesando")
        case NoteState.failed:      return String(localized: "Sin resumen: toca para ver por qué")
        default: return nil
        }
    }
}

/// Disponibilidad del LLM, visible siempre. El iPhone 17e lo soporta, pero Apple
/// Intelligence puede estar desactivado en Ajustes o el modelo descargándose.
struct StatusBadge: View {
    // La disponibilidad CAMBIA con la app abierta: se relee al volver a primer plano.
    @Environment(\.scenePhase) private var scenePhase
    @State private var estado = Summarizer.availabilitySnapshot()
    @State private var showInfo = false

    var body: some View {
        let ok = estado.disponible
        Button { showInfo = true } label: {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
        .onChange(of: scenePhase) { _, fase in
            if fase == .active { estado = Summarizer.availabilitySnapshot() }
        }
        .accessibilityLabel(ok ? "Modelo de IA disponible" : "Modelo de IA no disponible")
        .accessibilityValue(estado.descripcion)
        .accessibilityIdentifier("ai-badge")
        .alert(ok ? "IA lista" : "IA no disponible", isPresented: $showInfo) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(ok ? "Los resúmenes, las preguntas y las traducciones se hacen en este iPhone con Apple Intelligence."
                    : "Para resumir hace falta Apple Intelligence: Ajustes › Apple Intelligence y Siri. Mientras tanto se graba y transcribe con normalidad. (\(estado.descripcion))")
        }
    }
}

private struct MoveToFolderView: View {
    let note: Note
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var newFolder = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Sin carpeta") { set("") }
                    ForEach(store.folders, id: \.self) { f in
                        Button { set(f) } label: {
                            HStack { Text(f); if note.folder == f { Spacer(); Image(systemName: "checkmark") } }
                        }
                    }
                }
                Section("Nueva carpeta") {
                    TextField("Nombre", text: $newFolder)
                    Button("Crear y mover") { set(newFolder.trimmingCharacters(in: .whitespaces)) }
                        .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Mover a carpeta")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }

    private func set(_ folder: String) {
        store.update(note.id) { $0.folder = folder }
        dismiss()
    }
}

/// Resultados de la búsqueda global: fragmentos con salto al segundo exacto.
private struct SearchResultsView: View {
    let query: String
    let notes: [Note]
    @State private var hits: [SearchHit] = []

    var body: some View {
        List {
            if hits.isEmpty {
                Text("Sin resultados").foregroundStyle(.secondary)
            }
            ForEach(hits) { hit in
                NavigationLink(value: NoteRoute(id: hit.noteID, at: hit.atSeconds)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(hit.noteTitle).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(TimeFormat.mmss(hit.atSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(hit.text).font(.callout).lineLimit(3)
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)      // no buscar en cada tecla
            hits = SearchIndex.shared.search(query, in: notes)
        }
    }
}
