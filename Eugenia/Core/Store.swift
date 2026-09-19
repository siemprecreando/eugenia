import Foundation
import UIKit

/// Persistencia en disco. Plan, sección 7 reducido a un índice JSON más ficheros.
///
/// Deliberadamente NO SQLite/SwiftData: un solo usuario, cientos de notas como mucho,
/// y un índice legible desde Linux por AFC vale más que las migraciones. La búsqueda
/// (plan 5.6) se hace en memoria sobre este mismo índice: ver `SearchIndex`.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var notes: [Note] = []

    private let fm = FileManager.default
    /// Si el índice no se pudo leer, NO se vuelve a escribir: escribir encima de un
    /// índice que no entendemos es borrar todas las reuniones (revisión 2026-09-18).
    private(set) var indexIsReadOnly = false
    /// El índice existe pero no se pudo leer (teléfono bloqueado): se relee al desbloquear.
    private var waitingForUnlock = false
    /// Notas borradas en esta sesión. Un resumen que termina DESPUÉS del borrado no
    /// puede resucitarlas al guardar.
    private var deletedIDs: Set<UUID> = []

    /// SEGURIDAD — el reparto de carpetas no es organización, es aislamiento.
    ///
    /// `UIFileSharingEnabled` (solo en Debug, para el banco de pruebas del plan 6.5)
    /// expone **todo** `Documents/` por AFC y en la app Archivos. Si el audio de las
    /// reuniones viviera ahí, una build Debug en un teléfono emparejado con cualquier
    /// ordenador entregaría las reuniones enteras.
    ///
    /// Por eso: en `Documents/` SOLO los diagnósticos, que es lo que de verdad hay que
    /// sacar del teléfono. El audio, la transcripción y el índice viven en Application
    /// Support.
    ///
    /// MATIZ MEDIDO EL 2026-09-18: eso protege del file sharing (VendDocuments), pero
    /// una app firmada con certificado de DESARROLLO —como la que instala SideStore con
    /// Apple ID gratuito— también admite VendContainer: cualquier ordenador emparejado
    /// y con el teléfono desbloqueado puede leer el contenedor entero, Application
    /// Support incluido. No hay forma de evitarlo desde la app con firma gratuita. La
    /// defensa real es no emparejar el iPhone con ordenadores ajenos.
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
        excludeFromBackup(audioDirectory)
        excludeFromBackup(privateRoot)
        load()
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let s = Store.shared
                if s.waitingForUnlock {
                    s.load()
                    // Lo que el arranque con el teléfono bloqueado no pudo decidir.
                    if !s.indexIsReadOnly {
                        AppSettings.shared.settleRetentionDefault(
                            hasSavedAudio: s.notes.contains { $0.audioState == "present" && !$0.allAudioFiles.isEmpty })
                        RetentionPolicy.sweep()
                    }
                }
            }
        }
    }

    func load() {
        // "No existe" y "no se puede leer" NO son lo mismo. Si iOS arranca la app en
        // segundo plano con el teléfono bloqueado (tarea de fondo, Siri), el índice
        // existe pero está cifrado: tratarlo como vacío hacía que el siguiente guardado
        // pisara todas las reuniones con una sola (revisión de seguridad 2026-09-18).
        guard fm.fileExists(atPath: indexURL.path) else { notes = []; indexIsReadOnly = false; return }
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            Log.failure(Log.storage, "index.read", error)
            indexIsReadOnly = true
            waitingForUnlock = true
            return
        }
        waitingForUnlock = false
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([Note].self, from: data).sorted { $0.createdAt > $1.createdAt }
            indexIsReadOnly = false
        } catch {
            Log.failure(Log.storage, "index.decode", error)
            // Copia intacta del índice ilegible y bloqueo de escritura. Sin esto, el
            // siguiente `save()` sobrescribía notes.json con UNA nota y el resto de
            // reuniones desaparecía sin rastro.
            let backup = privateRoot.appendingPathComponent("notes.corrupt-\(ReportStamp.string(from: Date())).json")
            try? fm.copyItem(at: indexURL, to: backup)
            indexIsReadOnly = true
            notes = []
        }
    }

    func save(_ note: Note) {
        guard !deletedIDs.contains(note.id) else { return }
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.insert(note, at: 0)
            notes.sort { $0.createdAt > $1.createdAt }
        }
        persist()
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    /// Restaurar de una copia una nota borrada en esta misma sesión: sin esto `save`
    /// la ignoraba en silencio (protección contra resúmenes que llegan tarde).
    func allowRestore(_ id: UUID) { deletedIDs.remove(id) }

    /// Modificación puntual sin pisar lo que otro trabajo haya guardado entretanto:
    /// se relee la nota actual del índice y se aplica el cambio sobre ella.
    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var n = note(id) else { return }
        change(&n)
        save(n)
    }

    func delete(_ note: Note) {
        // La reunión que se está grabando no se borra: dejaba la grabadora, la Live
        // Activity y la cola a medias (revisión 2026-09-18). Primero hay que pararla.
        guard note.id != Recorder.shared.currentNoteID else {
            Log.event(Log.storage, "delete.blocked.recording")
            return
        }
        deletedIDs.insert(note.id)
        deleteAudio(of: note)
        DiarizationCache.shared.remove(noteID: note.id)
        notes.removeAll { $0.id == note.id }
        persist()
    }

    // MARK: - Hablantes

    /// Pone (o quita, con nombre vacío) el nombre de un hablante en TODA la reunión.
    func renameSpeaker(noteID: UUID, label: String, to newName: String) {
        renameSpeakers(noteID: noteID, [label: newName])
    }

    /// Varios a la vez, en UNA pasada. El resumen se escribió con los nombres de antes
    /// ("Hablante 2" o el anterior): se sustituyen también en resumen, tareas, correo
    /// y traducciones. Primero a marcadores únicos y luego a los nombres nuevos: así
    /// intercambiar Marta↔Luis no acaba con todo diciendo "Luis" (revisión 2026-09-18).
    func renameSpeakers(noteID: UUID, _ changes: [String: String]) {
        update(noteID) { n in
            var swaps: [(old: String, token: String, new: String)] = []
            for (label, newName) in changes {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                let old = n.displayName(forSpeaker: label) ?? label
                if name.isEmpty { n.speakerNames[label] = nil } else { n.speakerNames[label] = name }
                let new = n.displayName(forSpeaker: label) ?? label
                if old != new { swaps.append((old, "\u{E000}\(swaps.count)\u{E001}", new)) }
            }
            guard !swaps.isEmpty else { return }
            // Nombres largos primero: "Hablante 12" antes que "Hablante 1".
            swaps.sort { $0.old.count > $1.old.count }
            let swap: (String) -> String = { text in
                var t = text
                for s in swaps { t = Self.replaceWord(s.old, with: s.token, in: t) }
                for s in swaps { t = t.replacingOccurrences(of: s.token, with: s.new) }
                return t
            }
            n.summaryOverview = swap(n.summaryOverview)
            n.keyPoints = n.keyPoints.map { var p = $0; p.text = swap(p.text); return p }
            n.decisions = n.decisions.map(swap)
            n.actionItems = n.actionItems.map { var i = $0; i.text = swap(i.text); i.assignee = swap(i.assignee); return i }
            n.followUpEmail = swap(n.followUpEmail)
            n.translations = n.translations.mapValues { tr in
                var t = tr
                t.overview = swap(t.overview)
                t.decisions = t.decisions.map(swap)
                return t
            }
        }
        SearchIndex.shared.invalidate(noteID)
    }

    /// Solo palabras enteras: renombrar "Ana" no toca "Mariana".
    nonisolated static func replaceWord(_ old: String, with new: String, in text: String) -> String {
        guard !old.isEmpty, text.localizedCaseInsensitiveContains(old) else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        // Sin distinguir mayúsculas: el modelo a veces escribe "hablante 2".
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }

    /// Una frase mal atribuida: pasa a otro hablante existente, o a uno NUEVO si
    /// `label` es nil (con `newName` como nombre). Devuelve la etiqueta final.
    @discardableResult
    func reassignSegment(noteID: UUID, segmentID: UUID, to label: String?, newName: String = "") -> String? {
        var result: String?
        let knownVoiceLabels = Set(DiarizationCache.shared.embeddings(noteID: noteID).keys)
        update(noteID) { n in
            guard let i = n.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            var target = label
            if target == nil {
                // El número nuevo no puede ser de NADIE: ni de las frases, ni de un
                // nombre guardado, ni de una huella de la separación (un hablante sin
                // frases también la tiene). Si no, la persona nueva heredaba nombre y voz.
                let known = Set(n.speakerLabels).union(n.speakerNames.keys).union(knownVoiceLabels)
                let used = known.compactMap { Int($0.drop(while: { !$0.isNumber })) }
                target = "S\((used.max() ?? 0) + 1)"
                let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                n.speakerNames[target!] = clean.isEmpty ? nil : clean
            }
            n.segments[i].speaker = target
            n.transcript = n.renderedTranscript(withSpeakers: false)
            result = target
        }
        SearchIndex.shared.invalidate(noteID)
        return result
    }

    func deleteAudio(of note: Note) {
        for name in note.allAudioFiles {
            try? fm.removeItem(at: audioURL(name))
        }
    }

    func audioURL(_ name: String) -> URL {
        // El nombre viene del índice; aun así, solo el último componente: nada de
        // rutas que salgan de audio/.
        audioDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }

    var folders: [String] {
        Array(Set(notes.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    /// Tamaño en disco del audio de una nota, en bytes.
    func audioBytes(of note: Note) -> Int64 {
        note.allAudioFiles.reduce(0) { acc, name in
            let size = (try? fm.attributesOfItem(atPath: audioURL(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return acc + size
        }
    }

    // MARK: - Recuperación tras cierre inesperado

    /// Al arrancar: una nota en `recording` significa que la app murió grabando (jetsam,
    /// crash, el usuario la cerró). El audio va en trozos, así que los trozos cerrados
    /// son legibles; el último puede no serlo. La transcripción se fue guardando por el
    /// camino. Se marca `interrupted` y entra en la cola: el usuario no pierde la reunión.
    func recoverInterruptedRecordings(except activeID: UUID?) {
        for n in notes where n.state == NoteState.recording && n.id != activeID {
            var fixed = n
            fixed.state = NoteState.interrupted
            // Trozos vacíos o ilegibles fuera: no sirven y romperían el reproductor.
            fixed.audioParts = n.audioParts.filter { AudioParts.isReadable(audioURL($0)) }
            if fixed.duration == 0 { fixed.duration = AudioParts.totalDuration(fixed.audioParts.map(audioURL)) }
            if fixed.segments.last(where: { !$0.isMarker }) != nil {
                fixed.segments.append(TranscriptSegment(text: "La grabación se interrumpió aquí",
                                                        start: fixed.duration, end: fixed.duration,
                                                        isMarker: true))
            }
            fixed.transcript = fixed.renderedTranscript(withSpeakers: false)
            save(fixed)
            Log.event(Log.storage, "recover.recording", "note=\(n.id.uuidString) parts=\(fixed.audioParts.count)")
        }
    }

    private func persist() {
        guard !indexIsReadOnly else {
            Log.event(Log.storage, "index.save.blocked", "notes=\(notes.count)")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(notes)
            // Mismo razonamiento que en el init: `.completeFileProtection` haría
            // fallar este guardado cuando se para una grabación con el teléfono
            // bloqueado, y perderíamos la nota. `.completeUnlessOpen` cifra igual en
            // reposo sin romper el caso de uso real.
            //
            // El ÍNDICE va con `.completeUntilFirstUserAuthentication`: tiene que poder
            // leerse cuando iOS arranca la app en segundo plano con el teléfono
            // bloqueado (tarea de fondo, Siri). El audio sigue en `.completeUnlessOpen`.
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // La escritura atómica crea un fichero NUEVO: la exclusión de copia de
            // seguridad hay que volver a ponerla cada vez.
            excludeFromBackup(indexURL)
            Log.event(Log.storage, "index.save", "notes=\(notes.count)")
        } catch {
            Log.failure(Log.storage, "index.save", error)
        }
    }

    /// PRIVACIDAD — sin esto, iCloud Backup subía audio y transcripciones a Apple
    /// (cifrado de extremo a extremo solo con Protección Avanzada de Datos). La promesa
    /// es "tus reuniones no salen de tu iPhone": tampoco por la copia de seguridad.
    /// Contrapartida asumida: si se pierde el teléfono, se pierden las reuniones; para
    /// eso está la exportación cifrada (plan, Fase 4).
    func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
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
        var demo = Note.demoSet
        demo[0].segments = [
            TranscriptSegment(text: "Antes de nada, el presupuesto del trimestre. Marta, ¿lo llevas tú?", start: 12, end: 16, speaker: "S1"),
            TranscriptSegment(text: "Lo puedo llevar, pero necesito los números de soporte.", start: 17, end: 21, speaker: "S2"),
            TranscriptSegment(text: "Vale, pues lo cierras tú y lo vemos el viernes.", start: 22, end: 25, speaker: "S1"),
            TranscriptSegment(text: "Llamada entrante", start: 1_200, end: 1_200, isMarker: true),
            TranscriptSegment(text: "Sinceramente, con la migración encima no voy a llegar. ¿Lo coges tú?", start: 2_510, end: 2_515, speaker: "S2"),
            TranscriptSegment(text: "Está bien, me lo quedo yo.", start: 2_516, end: 2_518, speaker: "S1"),
            TranscriptSegment(text: "Pensándolo mejor, hasta que no cerremos la migración esto no se toca.", start: 3_490, end: 3_500, speaker: "S1")
        ]
        demo[0].speakerNames = ["S1": "Javier", "S2": "Marta"]
        demo[0].keyPoints = [SummaryPoint(text: "El presupuesto pasa de Marta a Javier", atSeconds: 2_515),
                             SummaryPoint(text: "La migración es la prioridad única", atSeconds: 3_490)]
        demo[0].actionItems[0].history = ["Asignado a Marta en 00:12", "Reasignado de Marta a Javier en 41:55", "Aparcado en 58:10"]
        demo[0].folder = "Producto"
        demo[0].attendees = ["Javier", "Marta"]
        demo[1].folder = "Equipo"
        notes = demo
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
                state: NoteState.queued,
                failure: nil
            )
        ]
    }
}
#endif
