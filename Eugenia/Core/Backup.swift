import Foundation

/// Copia cifrada del archivo completo y su restauración. Plan, Fase 4.
/// Sustituye a la sincronización por iCloud, que exige cuenta de pago (plan 6.4) y
/// además contradice la promesa del producto. El usuario elige dónde guardarla.
@MainActor
enum Backup {
    /// Crea `Eugenia-AAAAMMDD.eugenia` en tmp y devuelve su URL para compartir/guardar.
    static func export(password: String, includeAudio: Bool) throws -> URL {
        let store = Store.shared
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let index = try enc.encode(store.notes)
        let files: [(String, URL)] = includeAudio
            ? store.notes.flatMap { n in n.allAudioFiles.map { ($0, store.audioURL($0)) } }
            : []
        let name = "Eugenia-\(ReportStamp.string(from: Date()).prefix(8)).eugenia"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try EncryptedArchive.write(to: url, password: password, index: index, files: files)
        Log.event(Log.storage, "backup.export", "notes=\(store.notes.count) audio=\(files.count)")
        return url
    }

    /// Restaura: añade las notas que no existen (por id); las que ya existen no se
    /// tocan. Devuelve cuántas se añadieron.
    @discardableResult
    static func restore(from url: URL, password: String) throws -> Int {
        let store = Store.shared
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var written: [String] = []
        let index = try EncryptedArchive.read(from: url, password: password) { name, data in
            // Solo "audio/<nombre plano>": un nombre con rutas no sale de la carpeta.
            guard name.hasPrefix("audio/") else { return }
            let file = URL(fileURLWithPath: String(name.dropFirst(6))).lastPathComponent
            let target = store.audioURL(file)
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
                written.append(file)
            }
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let incoming = try dec.decode([Note].self, from: index)
        var added = 0
        for n in incoming where store.note(n.id) == nil {
            var copy = n
            if copy.state == NoteState.recording || copy.state == NoteState.processing { copy.state = NoteState.queued }
            store.save(copy)
            added += 1
        }
        Log.event(Log.storage, "backup.restore", "added=\(added) audio=\(written.count)")
        ProcessingQueue.shared.kick()
        return added
    }
}
