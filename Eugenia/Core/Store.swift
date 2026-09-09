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

#if DEBUG
extension Store {
    /// Datos de muestra para las capturas y las pruebas de interfaz (`--ui-demo`).
    ///
    /// Rellena la lista EN MEMORIA y no llama a `persist()`: nada de esto toca el
    /// disco ni sobrevive al cierre de la app. Si algún día esto escribiera, una
    /// build de depuración contaminaría el índice real del teléfono.
    func seedDemo() {
        notes = Note.demoSet
        Log.event(Log.storage, "demo.seed", "notes=\(notes.count)")
    }
}

extension Note {
    /// La reunión larga es la del spike 4b del plan: el presupuesto se asigna a
    /// Marta, se reasigna a Javier y acaba aparcado. Sirve para ver de un vistazo
    /// si la pantalla de detalle sabe enseñar un acuerdo que cambió de dueño.
    static var demoSet: [Note] {
        let now = Date()
        return [
            Note(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                title: "Comité de producto",
                createdAt: now.addingTimeInterval(-3_600),
                duration: 2_940,
                language: "es",
                audioFileName: nil,
                transcript: """
                Javier: Antes de nada, el presupuesto del trimestre. Marta, ¿lo llevas tú?
                Marta: Lo puedo llevar, pero necesito los números de soporte.
                Javier: Vale, pues lo cierras tú y lo vemos el viernes.
                […]
                Marta: Sinceramente, con la migración encima no voy a llegar. ¿Lo coges tú?
                Javier: Está bien, me lo quedo yo.
                […]
                Javier: Pensándolo mejor, hasta que no cerremos la migración esto no se
                toca. Lo dejamos aparcado y lo retomamos en dos semanas.
                """,
                summaryOverview: """
                Revisión del trimestre. El presupuesto cambió de responsable durante la \
                reunión y terminó aparcado hasta cerrar la migración. Se confirmaron dos \
                compromisos con fecha.
                """,
                decisions: [
                    "El presupuesto queda aparcado hasta que termine la migración (dos semanas).",
                    "La migración pasa a ser la prioridad única del equipo."
                ],
                actionItems: [
                    StoredActionItem(text: "Cerrar el presupuesto del trimestre",
                                     assignee: "Javier", status: "aparcado", atSeconds: 58),
                    StoredActionItem(text: "Pasar los números de soporte",
                                     assignee: "Marta", status: "pendiente", atSeconds: 12),
                    StoredActionItem(text: "Plan de migración con fechas",
                                     assignee: "Javier", status: "pendiente", atSeconds: 41)
                ],
                state: "summarized",
                failure: nil
            ),
            Note(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                title: "1:1 con Marta",
                createdAt: now.addingTimeInterval(-90_000),
                duration: 1_500,
                language: "es",
                audioFileName: nil,
                transcript: "…",
                summaryOverview: "Seguimiento quincenal. Carga de trabajo alta por la migración.",
                decisions: [],
                actionItems: [
                    StoredActionItem(text: "Repartir las guardias de la semana que viene",
                                     assignee: "Marta", status: "pendiente", atSeconds: 320)
                ],
                state: "summarized",
                failure: nil
            ),
            Note(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                title: "Llamada con proveedor",
                createdAt: now.addingTimeInterval(-260_000),
                duration: 720,
                language: "es",
                audioFileName: nil,
                transcript: "",
                summaryOverview: "",
                decisions: [],
                actionItems: [],
                state: "transcribed",
                failure: nil
            )
        ]
    }
}
#endif
