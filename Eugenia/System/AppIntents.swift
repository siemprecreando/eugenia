import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Automatización externa con Atajos (plan 5.8). El dominio se expone como entidades
/// que Atajos puede filtrar y encadenar; los nueve intents de la tabla de 5.8.
///
/// Todo corre en el teléfono. Lo que salga hacia un CRM lo decide el atajo del
/// usuario, con sus credenciales; nosotros no vemos ni guardamos ese destino.

// MARK: - Entidades

struct NotaEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reunión"
    static let defaultQuery = NotaQuery()

    var id: UUID
    @Property(title: "Título") var titulo: String
    @Property(title: "Fecha") var fecha: Date
    @Property(title: "Duración (s)") var duracion: Double
    @Property(title: "Idioma") var idioma: String
    @Property(title: "Carpeta") var carpeta: String
    @Property(title: "Resumen") var resumen: String
    @Property(title: "Hablantes") var hablantes: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(titulo)", subtitle: "\(fecha.formatted(date: .abbreviated, time: .shortened))")
    }

    init(_ n: Note) {
        id = n.id
        titulo = n.title
        fecha = n.createdAt
        duracion = n.duration
        idioma = n.language
        carpeta = n.folder
        resumen = n.summaryOverview
        hablantes = n.speakerLabels.compactMap { n.displayName(forSpeaker: $0) }
    }
}

struct NotaQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [NotaEntity] {
        identifiers.compactMap { Store.shared.note($0) }.map(NotaEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NotaEntity] {
        Store.shared.notes.prefix(15).map(NotaEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NotaEntity] {
        let ids = SearchIndex.shared.search(string, in: Store.shared.notes, limit: 30, semantic: false).map(\.noteID)
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.compactMap { Store.shared.note($0) }.map(NotaEntity.init)
    }
}

struct ActionItemEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tarea"
    static let defaultQuery = ActionItemQuery()

    var id: UUID
    @Property(title: "Texto") var texto: String
    @Property(title: "Responsable") var responsable: String
    @Property(title: "Vencimiento") var vencimiento: String
    @Property(title: "Estado") var estado: String
    @Property(title: "Hecha") var hecho: Bool
    @Property(title: "Reunión") var notaOrigen: String
    @Property(title: "Instante (s)") var instanteDecision: Int
    var noteID: UUID

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(texto)", subtitle: "\(responsable.isEmpty ? estado : "\(responsable) · \(estado)")")
    }

    init(_ i: StoredActionItem, note: Note) {
        id = i.id
        texto = i.text
        responsable = i.assignee
        vencimiento = i.dueText
        estado = i.status
        hecho = i.done
        notaOrigen = note.title
        instanteDecision = i.atSeconds
        noteID = note.id
    }
}

struct ActionItemQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ActionItemEntity] {
        Store.shared.notes.flatMap { n in
            n.actionItems.filter { identifiers.contains($0.id) }.map { ActionItemEntity($0, note: n) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [ActionItemEntity] {
        Store.shared.notes.prefix(10).flatMap { n in n.actionItems.filter(\.isOpen).map { ActionItemEntity($0, note: n) } }
    }
}

enum ExportFormatEntity: String, AppEnum {
    case pdf, markdown, json, text
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Formato"
    static let caseDisplayRepresentations: [ExportFormatEntity: DisplayRepresentation] = [
        .pdf: "PDF", .markdown: "Markdown", .json: "JSON", .text: "Texto"
    ]
    var format: ExportFormat { ExportFormat(rawValue: rawValue) ?? .json }
}

enum TemplateEntity: String, AppEnum {
    case executive, actionItems, detailed, oneOnOne, sales
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Plantilla"
    static let caseDisplayRepresentations: [TemplateEntity: DisplayRepresentation] = [
        .executive: "Resumen ejecutivo", .actionItems: "Tareas y responsables", .detailed: "Acta detallada",
        .oneOnOne: "Reunión 1:1", .sales: "Llamada comercial"
    ]
}

// MARK: - Intents (plan 5.8, tabla)

/// DetenerGrabación que DEVUELVE la nota (el de la Live Activity no devuelve nada).
struct StopAndGetNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Detener grabación y obtener la reunión"
    static let description = IntentDescription("Detiene la grabación en curso y devuelve la reunión guardada.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NotaEntity?> {
        await Recorder.shared.stop()
        let note = Recorder.shared.lastFinishedNoteID.flatMap { Store.shared.note($0) }
        return .result(value: note.map(NotaEntity.init))
    }
}

struct GetLatestNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener última reunión"
    static let description = IntentDescription("Devuelve la reunión más reciente, opcionalmente de una carpeta.")

    @Parameter(title: "Carpeta") var carpeta: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NotaEntity?> {
        let notes = Store.shared.notes.filter { carpeta == nil || carpeta!.isEmpty || $0.folder == carpeta }
        return .result(value: notes.first.map(NotaEntity.init))
    }
}

struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Buscar reuniones"
    static let description = IntentDescription("Busca reuniones por texto, fechas y hablante.")

    @Parameter(title: "Texto") var texto: String?
    @Parameter(title: "Desde") var desde: Date?
    @Parameter(title: "Hasta") var hasta: Date?
    @Parameter(title: "Hablante") var hablante: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NotaEntity]> {
        var notes = Store.shared.notes
        if let d = desde { notes = notes.filter { $0.createdAt >= d } }
        if let h = hasta { notes = notes.filter { $0.createdAt <= h } }
        if let who = hablante, !who.isEmpty {
            notes = notes.filter { n in
                n.speakerLabels.compactMap { n.displayName(forSpeaker: $0) }
                    .contains { $0.localizedCaseInsensitiveContains(who) }
                || n.attendees.contains { $0.localizedCaseInsensitiveContains(who) }
            }
        }
        if let t = texto, !t.isEmpty {
            let ids = SearchIndex.shared.search(t, in: notes, limit: 50).map(\.noteID)
            var seen = Set<UUID>()
            notes = ids.filter { seen.insert($0).inserted }.compactMap { Store.shared.note($0) }
        }
        return .result(value: notes.map(NotaEntity.init))
    }
}

struct GetSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener resumen"
    static let description = IntentDescription("Devuelve el resumen de una reunión. Con otra plantilla, lo regenera en el iPhone.")

    @Parameter(title: "Reunión") var nota: NotaEntity
    @Parameter(title: "Plantilla") var plantilla: TemplateEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard var n = Store.shared.note(nota.id) else { return .result(value: "") }
        if let p = plantilla, p.rawValue != n.template {
            let result = try await Summarizer.summarize(
                segments: n.segments, plainTranscript: n.transcript, language: n.language,
                template: SummaryTemplate(rawValue: p.rawValue) ?? .executive, tone: AppSettings.shared.summaryTone,
                meetingDate: n.createdAt, speakerName: { n.displayName(forSpeaker: $0) },
                checkpoints: n.mapCheckpoints, onCheckpoint: { _ in })
            n.summaryOverview = result.overview
            n.decisions = result.decisions
        }
        var text = n.summaryOverview
        if !n.decisions.isEmpty { text += "\n\n" + n.decisions.map { "• \($0)" }.joined(separator: "\n") }
        return .result(value: text)
    }
}

struct GetActionItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener tareas"
    static let description = IntentDescription("Devuelve las tareas de una reunión, filtradas por estado o responsable.")

    @Parameter(title: "Reunión") var nota: NotaEntity
    @Parameter(title: "Estado") var estado: String?
    @Parameter(title: "Responsable") var responsable: String?
    @Parameter(title: "Solo pendientes", default: true) var soloPendientes: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ActionItemEntity]> {
        guard let n = Store.shared.note(nota.id) else { return .result(value: []) }
        let items = n.actionItems.filter { i in
            (!soloPendientes || i.isOpen)
                && (estado == nil || estado!.isEmpty || i.status == estado)
                && (responsable == nil || responsable!.isEmpty || i.assignee.localizedCaseInsensitiveContains(responsable!))
        }
        return .result(value: items.map { ActionItemEntity($0, note: n) })
    }
}

struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Obtener transcripción"
    static let description = IntentDescription("Devuelve la transcripción de una reunión.")

    @Parameter(title: "Reunión") var nota: NotaEntity
    @Parameter(title: "Con marcas de tiempo", default: false) var conTiempos: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let n = Store.shared.note(nota.id) else { return .result(value: "") }
        return .result(value: n.renderedTranscript(withTimestamps: conTiempos, withSpeakers: true))
    }
}

struct ExportNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Exportar reunión"
    static let description = IntentDescription(
        "Exporta una reunión en PDF, Markdown, JSON (esquema eugenia.note/1) o texto. Es la pieza para enviar a un CRM.")

    @Parameter(title: "Reunión") var nota: NotaEntity
    @Parameter(title: "Formato", default: .json) var formato: ExportFormatEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let n = Store.shared.note(nota.id) else { throw IntentError.notFound }
        let url = try NoteExporter.file(n, format: formato.format)
        let type: UTType = switch formato {
        case .pdf: .pdf
        case .json: .json
        case .markdown: UTType("net.daringfireball.markdown") ?? .plainText
        case .text: .plainText
        }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: type))
    }
}

struct MarkActionItemDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Marcar tarea como hecha"
    static let description = IntentDescription("Marca una tarea de una reunión como hecha.")

    @Parameter(title: "Tarea") var tarea: ActionItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ActionItemEntity> {
        var updated: ActionItemEntity = tarea
        Store.shared.update(tarea.noteID) { n in
            if let i = n.actionItems.firstIndex(where: { $0.id == tarea.id }) {
                n.actionItems[i].done = true
                updated = ActionItemEntity(n.actionItems[i], note: n)
            }
        }
        return .result(value: updated)
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notFound
    var localizedStringResource: LocalizedStringResource { "No se encontró la reunión." }
}

// MARK: - Frases de Siri sin configuración (plan 5.8)

struct EugeniaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Graba la reunión con \(.applicationName)",
                              "Empieza a grabar en \(.applicationName)",
                              "Record a meeting with \(.applicationName)"],
                    shortTitle: "Grabar reunión", systemImageName: "mic.circle.fill")
        AppShortcut(intent: StopAndGetNoteIntent(),
                    phrases: ["Detén la grabación de \(.applicationName)",
                              "Stop recording in \(.applicationName)"],
                    shortTitle: "Detener grabación", systemImageName: "stop.circle")
        AppShortcut(intent: GetLatestNoteIntent(),
                    phrases: ["Última reunión de \(.applicationName)",
                              "Envía la última reunión de \(.applicationName)"],
                    shortTitle: "Última reunión", systemImageName: "doc.text")
    }
}
