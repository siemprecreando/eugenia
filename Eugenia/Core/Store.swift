import Foundation

/// Persistencia mínima en disco. Plan, sección 7 (modelo de datos) reducido a lo que
/// necesita la Fase 1: un índice JSON más los ficheros de audio.
///
/// Deliberadamente NO se usa SwiftData todavía. Para la primera versión instalable
/// interesa que compile a la primera y que el formato sea legible desde Linux por
/// AFC, no tener migraciones. GRDB/SwiftData entran cuando haga falta FTS5 (Fase 2).
struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var language: String
    var audioFileName: String?
    var transcript: String
    var summaryOverview: String
    var decisions: [String]
    var actionItems: [StoredActionItem]
    var state: String   // recording | transcribed | summarized | failed
    var failure: String?
}

struct StoredActionItem: Codable, Equatable {
    var text: String
    var assignee: String
    var status: String
    var atSeconds: Int
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var notes: [Note] = []

    private let fm = FileManager.default

    /// SEGURIDAD — el reparto de carpetas no es organización, es aislamiento.
    ///
    /// `UIFileSharingEnabled` (solo en Debug, para el banco de pruebas del plan 6.5)
    /// expone **todo** `Documents/` por AFC y en la app Archivos. Si el audio de las
    /// reuniones viviera ahí, una build Debug en un teléfono emparejado con cualquier
    /// ordenador entregaría las reuniones enteras.
    ///
    /// Por eso: en `Documents/` SOLO los diagnósticos, que es lo que de verdad hay que
    /// sacar del teléfono. El audio, la transcripción y el índice viven en Application
    /// Support, que AFC no vende ni con file sharing activado.
    var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var privateRoot: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    var audioDirectory: URL { privateRoot.appendingPathComponent("audio", isDirectory: true) }
    var diagnosticsDirectory: URL { documents.appendingPathComponent("diagnostics", isDirectory: true) }
    private var indexURL: URL { privateRoot.appendingPathComponent("notes.json") }

    private init() {
        try? fm.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)

        // PROTECCIÓN DE DATOS, con el matiz que importa: `.complete` deja el fichero
        // ILEGIBLE con el teléfono bloqueado, y esta app graba con la pantalla
        // bloqueada. Con `.complete` la grabación en segundo plano fallaría al
        // escribir — perder una reunión que el usuario creía grabada es el único
        // fallo del que este producto no se recupera (plan 5.1).
        //
        // `.completeUnlessOpen` es exactamente el caso: el fichero sigue escribible
        // mientras está abierto, y queda cifrado en cuanto se cierra y el teléfono
        // se bloquea.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                              ofItemAtPath: audioDirectory.path)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { notes = []; return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([Note].self, from: data).sorted { $0.createdAt > $1.createdAt }
        } catch {
            Log.failure(Log.storage, "index.decode", error)
            notes = []
        }
    }

    func save(_ note: Note) {
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.insert(note, at: 0)
        }
        persist()
    }

    func delete(_ note: Note) {
        if let name = note.audioFileName {
            try? fm.removeItem(at: audioDirectory.appendingPathComponent(name))
        }
        notes.removeAll { $0.id == note.id }
        persist()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(notes)
            // Mismo razonamiento que en el init: `.completeFileProtection` haría
            // fallar este guardado cuando se para una grabación con el teléfono
            // bloqueado, y perderíamos la nota. `.completeUnlessOpen` cifra igual en
            // reposo sin romper el caso de uso real.
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            Log.event(Log.storage, "index.save", "notes=\(notes.count)")
        } catch {
            Log.failure(Log.storage, "index.save", error)
        }
    }

    func freeDiskMB() -> Int {
        let values = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return -1 }
        return Int(bytes / 1_048_576)
    }
}
