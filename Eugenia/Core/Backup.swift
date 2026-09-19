import Foundation

/// Copia cifrada del archivo completo y su restauración. Plan, Fase 4.
/// Sustituye a la sincronización por iCloud, que exige cuenta de pago (plan 6.4) y
/// además contradice la promesa del producto. El usuario elige dónde guardarla.
@MainActor
enum Backup {
    struct ExportResult { var url: URL; var skippedAudio: Int }

    /// Crea `Eugenia-AAAAMMDD.eugenia` en tmp y devuelve su URL para compartir/guardar.
    /// El cifrado va fuera del hilo principal: con audio son cientos de MB.
    static func export(password: String, includeAudio: Bool) async throws -> ExportResult {
        let store = Store.shared
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let index = try enc.encode(store.notes)
        let files: [(String, URL)] = includeAudio
            ? store.notes.flatMap { n in n.allAudioFiles.map { ($0, store.audioURL($0)) } }
            : []
        let name = "Eugenia-\(ReportStamp.string(from: Date()).prefix(8)).eugenia"
        let url = TempFiles.exportDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let skipped = try await Task.detached(priority: .userInitiated) {
            try EncryptedArchive.write(to: url, password: password, index: index, files: files)
        }.value
        Log.event(Log.storage, "backup.export", "notes=\(store.notes.count) audio=\(files.count) skipped=\(skipped.count)")
        return ExportResult(url: url, skippedAudio: skipped.count)
    }

    /// Nombres de audio válidos para una nota: `<id>-NNN.m4a` (v0.2) o `<id>.<ext>`
    /// (v0.1). Una copia ajena no puede colar en su índice el audio de OTRA nota, que
    /// luego se borraría al borrar la nota importada (revisión de seguridad 2026-09-18).
    nonisolated static func isOwnAudio(_ name: String, of id: UUID) -> Bool {
        let pattern = "^" + id.uuidString + "(-[0-9]{3})?\\.(m4a|caf|wav)$"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Restaura: añade las notas que no existen (por id); las que ya existen no se
    /// tocan. Devuelve cuántas se añadieron.
    ///
    /// Orden a propósito: el audio se descifra a una carpeta de paso, luego se lee y
    /// valida el índice, y solo entonces se mueve a su sitio el audio que pertenece a
    /// una nota nueva. Un índice malo no deja ficheros huérfanos.
    @discardableResult
    static func restore(from url: URL, password: String) async throws -> Int {
        let store = Store.shared
        let staging = TempFiles.root.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        defer { try? FileManager.default.removeItem(at: staging) }

        let (index, staged) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, [String]) in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var staged: [String] = []
            let index = try EncryptedArchive.read(from: url, password: password) { name, data in
                guard name.hasPrefix("audio/") else { return }
                let file = URL(fileURLWithPath: String(name.dropFirst(6))).lastPathComponent
                guard !file.isEmpty, !file.hasPrefix(".") else { return }
                try data.write(to: staging.appendingPathComponent(file),
                               options: [.atomic, .completeFileProtectionUnlessOpen])
                staged.append(file)
            }
            return (index, staged)
        }.value

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let incoming = try dec.decode([Note].self, from: index)
        let stagedSet = Set(staged)
        var added = 0, moved = 0
        for n in incoming where store.note(n.id) == nil {
            var copy = n
            // Solo el audio que es de ESTA nota; lo demás se ignora.
            copy.audioParts = n.audioParts.filter { Self.isOwnAudio($0, of: n.id) }
            if let legacy = n.audioFileName, !Self.isOwnAudio(legacy, of: n.id) { copy.audioFileName = nil }
            for file in copy.allAudioFiles where stagedSet.contains(file) {
                let target = store.audioURL(file)
                if !FileManager.default.fileExists(atPath: target.path),
                   (try? FileManager.default.moveItem(at: staging.appendingPathComponent(file), to: target)) != nil {
                    moved += 1
                }
            }
            if copy.state == NoteState.recording || copy.state == NoteState.processing { copy.state = NoteState.queued }
            // Copia sin audio: la nota no puede decir que lo tiene (se ofrecería volver
            // a transcribir y fallaría).
            if copy.audioState == "present", !copy.allAudioFiles.isEmpty,
               !copy.allAudioFiles.allSatisfy({ FileManager.default.fileExists(atPath: store.audioURL($0).path) }) {
                copy.audioState = copy.allAudioFiles.contains(where: {
                    FileManager.default.fileExists(atPath: store.audioURL($0).path) }) ? "present" : "deleted"
            }
            store.allowRestore(copy.id)
            store.save(copy)
            added += 1
        }
        Log.event(Log.storage, "backup.restore", "added=\(added) audio=\(moved)")
        ProcessingQueue.shared.kick()
        return added
    }
}

/// Ficheros temporales con contenido de reuniones (exportaciones, copias, el WAV de la
/// separación de hablantes). Van a subcarpetas propias de tmp y se limpian al arrancar:
/// iOS limpia tmp "cuando quiere", que puede ser nunca (revisión de seguridad 2026-09-18).
enum TempFiles {
    static var root: URL { FileManager.default.temporaryDirectory }
    static var exportDirectory: URL {
        let d = root.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return d
    }

    /// Al arrancar. Nada de lo que hay aquí sirve tras reiniciar la app.
    static func cleanAtLaunch() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for item in items {
            let n = item.lastPathComponent
            if n == "export" || n.hasPrefix("restore-") || n.hasPrefix("diar-") || n.hasPrefix("import-") {
                if (try? fm.removeItem(at: item)) != nil { removed += 1 }
            }
        }
        if removed > 0 { Log.event(Log.storage, "tmp.clean", "removed=\(removed)") }
    }
}
