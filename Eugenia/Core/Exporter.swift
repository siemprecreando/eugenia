import CommonCrypto
import CryptoKit
import Foundation
import UIKit

/// Exportación de una nota (plan, Fase 3 y 5.8). Cuatro formatos.
///
/// El JSON tiene un ESQUEMA ESTABLE Y VERSIONADO (`schema: "eugenia.note/1"`): es la
/// carga útil que el usuario manda a su CRM con Atajos. Cambiarlo rompe los atajos de
/// otros; si hace falta, se sube la versión y se mantiene la anterior. Documentado en
/// el README.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, markdown, json, text
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .pdf: return "pdf"; case .markdown: return "md"; case .json: return "json"; case .text: return "txt" }
    }
    var title: String {
        switch self { case .pdf: return "PDF"; case .markdown: return "Markdown"; case .json: return "JSON"; case .text: return "Texto" }
    }
}

enum NoteExporter {

    // MARK: JSON (esquema estable)

    struct JSONNote: Codable {
        struct Item: Codable {
            var text: String
            var assignee: String
            var status: String
            var due: String
            var done: Bool
            var atSeconds: Int
            var history: [String]
            var needsConfirmation: Bool
        }
        struct Segment: Codable {
            var start: Double
            var end: Double
            var speaker: String?
            var text: String
        }
        struct Point: Codable { var text: String; var atSeconds: Int }
        var schema = "eugenia.note/1"
        var id: String
        var title: String
        var date: Date
        var durationSeconds: Double
        var language: String
        var folder: String
        var template: String
        var speakers: [String]
        var summary: String
        var keyPoints: [Point]
        var decisions: [String]
        var actionItems: [Item]
        var transcript: [Segment]
    }

    static func jsonModel(_ n: Note) -> JSONNote {
        JSONNote(id: n.id.uuidString, title: n.title, date: n.createdAt, durationSeconds: n.duration,
                 language: n.language, folder: n.folder, template: n.template,
                 speakers: n.speakerLabels.compactMap { n.displayName(forSpeaker: $0) },
                 summary: n.summaryOverview,
                 keyPoints: n.keyPoints.map { .init(text: $0.text, atSeconds: $0.atSeconds) },
                 decisions: n.decisions,
                 actionItems: n.actionItems.map {
                     .init(text: $0.text, assignee: $0.assignee, status: $0.status, due: $0.dueText, done: $0.done,
                           atSeconds: $0.atSeconds, history: $0.history, needsConfirmation: $0.needsConfirmation)
                 },
                 transcript: n.segments.filter { !$0.isMarker }.map {
                     .init(start: $0.start, end: $0.end, speaker: n.displayName(forSpeaker: $0.speaker), text: $0.text)
                 })
    }

    static func json(_ n: Note) -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(jsonModel(n))) ?? Data("{}".utf8)
    }

    // MARK: Markdown y texto

    static func markdown(_ n: Note) -> String {
        var md = "# \(n.title)\n\n"
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short
        md += "*\(f.string(from: n.createdAt)) · \(TimeFormat.mmss(n.duration))*\n\n"
        if !n.summaryOverview.isEmpty { md += "## Resumen\n\n\(n.summaryOverview)\n\n" }
        if !n.keyPoints.isEmpty {
            md += "## Puntos clave\n\n" + n.keyPoints.map { "- \($0.text) *(\(TimeFormat.mmss(Double($0.atSeconds))))*" }
                .joined(separator: "\n") + "\n\n"
        }
        if !n.decisions.isEmpty { md += "## Decisiones\n\n" + n.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        let open = n.actionItems.filter(\.isOpen)
        if !open.isEmpty {
            md += "## Próximos pasos\n\n" + open.map { i in
                "- [\(i.done ? "x" : " ")] \(i.text)" + (i.assignee.isEmpty ? "" : " — **\(i.assignee)**")
                    + (i.dueText.isEmpty ? "" : " (\(i.dueText))") + (i.needsConfirmation ? " ⚠️ por confirmar" : "")
            }.joined(separator: "\n") + "\n\n"
        }
        md += "## Transcripción\n\n" + n.renderedTranscript(withTimestamps: true, withSpeakers: true) + "\n"
        return md
    }

    static func text(_ n: Note) -> String {
        markdown(n)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "*", with: "")
    }

    // MARK: PDF

    static func pdf(_ n: Note) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)       // A4 en puntos
        let margin: CGFloat = 48
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let body = NSMutableAttributedString()
        func add(_ s: String, _ font: UIFont, _ color: UIColor = .black, spacing: CGFloat = 8) {
            let p = NSMutableParagraphStyle(); p.paragraphSpacing = spacing
            body.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        add(n.title, .boldSystemFont(ofSize: 22))
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short
        add("\(f.string(from: n.createdAt)) · \(TimeFormat.mmss(n.duration))", .systemFont(ofSize: 11), .darkGray, spacing: 16)
        if !n.summaryOverview.isEmpty { add("Resumen", .boldSystemFont(ofSize: 15)); add(n.summaryOverview, .systemFont(ofSize: 11), spacing: 14) }
        if !n.keyPoints.isEmpty {
            add("Puntos clave", .boldSystemFont(ofSize: 15))
            n.keyPoints.forEach { add("• \($0.text) (\(TimeFormat.mmss(Double($0.atSeconds))))", .systemFont(ofSize: 11), spacing: 4) }
        }
        if !n.decisions.isEmpty { add("Decisiones", .boldSystemFont(ofSize: 15)); n.decisions.forEach { add("• \($0)", .systemFont(ofSize: 11), spacing: 4) } }
        if !n.actionItems.isEmpty {
            add("Tareas", .boldSystemFont(ofSize: 15))
            n.actionItems.forEach { i in
                add("\(i.done ? "☑" : "☐") \(i.text)\(i.assignee.isEmpty ? "" : " — \(i.assignee)") [\(i.status)]",
                    .systemFont(ofSize: 11), spacing: 4)
            }
        }
        add("Transcripción", .boldSystemFont(ofSize: 15))
        add(n.renderedTranscript(withTimestamps: true, withSpeakers: true), .systemFont(ofSize: 10), .darkGray)

        return renderer.pdfData { ctx in
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var range = CFRange(location: 0, length: 0)
            let textRect = page.insetBy(dx: margin, dy: margin)
            repeat {
                ctx.beginPage()
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: textRect.minX, y: page.height - textRect.maxY,
                                               width: textRect.width, height: textRect.height), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()
                range = CFRange(location: visible.location + visible.length, length: 0)
                if visible.length == 0 { break }       // nada cabe: evitar bucle infinito
            } while range.location < body.length
        }
    }

    /// Fichero temporal listo para compartir. Se borra al terminar de compartir o, si
    /// no, lo limpia el sistema (carpeta tmp).
    static func file(_ n: Note, format: ExportFormat) throws -> URL {
        let safe = n.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.prefix(60)).\(format.fileExtension)")
        let data: Data
        switch format {
        case .pdf: data = pdf(n)
        case .markdown: data = Data(markdown(n).utf8)
        case .json: data = json(n)
        case .text: data = Data(text(n).utf8)
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

// MARK: - Copia cifrada del archivo completo (plan, Fase 4; sustituye a CloudKit)

/// Formato `.eugenia` v1:
///   "EUGX1" | sal (16) | registros…
///   registro = longitud del nombre (UInt16 BE) | nombre UTF-8 | longitud del bloque
///              sellado (UInt64 BE) | AES-GCM combinado (nonce | cifrado | etiqueta)
/// Clave: PBKDF2-HMAC-SHA256, 210.000 iteraciones, 32 bytes (recomendación OWASP 2023).
/// Cada fichero va en su propio registro: el audio se procesa trozo a trozo sin cargar
/// el archivo entero en memoria. El nombre del registro va dentro del bloque autenticado
/// (datos asociados), así que no se puede renombrar un registro sin que falle.
enum EncryptedArchive {
    static let magic = Data("EUGX1".utf8)
    static let iterations: UInt32 = 210_000

    enum ArchiveError: Error, CustomStringConvertible {
        case badFormat, wrongPassword, weakPassword
        var description: String {
            switch self {
            case .badFormat: return "El fichero no es una copia de Eugenia o está dañado."
            case .wrongPassword: return "La contraseña no es correcta."
            case .weakPassword: return "Usa una contraseña de al menos 8 caracteres."
            }
        }
    }

    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }

    /// Escribe la copia. `files` = (nombre en el archivo, URL local).
    static func write(to url: URL, password: String, index: Data, files: [(String, URL)]) throws {
        guard password.count >= 8 else { throw ArchiveError.weakPassword }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = deriveKey(password: password, salt: salt)
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.write(contentsOf: magic + salt)
        func record(_ name: String, _ data: Data) throws {
            let nameData = Data(name.utf8)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: nameData)
            guard let combined = sealed.combined else { throw ArchiveError.badFormat }
            var header = Data()
            header.append(contentsOf: withUnsafeBytes(of: UInt16(nameData.count).bigEndian) { Array($0) })
            header.append(nameData)
            header.append(contentsOf: withUnsafeBytes(of: UInt64(combined.count).bigEndian) { Array($0) })
            try h.write(contentsOf: header + combined)
        }
        try record("notes.json", index)
        for (name, file) in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            try record("audio/" + name, data)
        }
    }

    /// Lee una copia y devuelve el índice y los ficheros descifrados, uno a uno.
    static func read(from url: URL, password: String, onFile: (String, Data) throws -> Void) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard let head = try h.read(upToCount: 21), head.count == 21, head.prefix(5) == magic else { throw ArchiveError.badFormat }
        let key = deriveKey(password: password, salt: head.suffix(16))
        var index: Data?
        while let lenData = try h.read(upToCount: 2), lenData.count == 2 {
            let nameLen = Int(UInt16(bigEndian: lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }))
            guard nameLen > 0, nameLen < 1_024,
                  let nameData = try h.read(upToCount: nameLen), nameData.count == nameLen,
                  let sizeData = try h.read(upToCount: 8), sizeData.count == 8 else { throw ArchiveError.badFormat }
            let size = Int(UInt64(bigEndian: sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
            guard size > 28, size < 2_000_000_000, let blob = try h.read(upToCount: size), blob.count == size else {
                throw ArchiveError.badFormat
            }
            let plain: Data
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key, authenticating: nameData)
            } catch {
                throw index == nil ? ArchiveError.wrongPassword : ArchiveError.badFormat
            }
            let name = String(decoding: nameData, as: UTF8.self)
            if name == "notes.json" { index = plain } else { try onFile(name, plain) }
        }
        guard let index else { throw ArchiveError.badFormat }
        return index
    }
}
