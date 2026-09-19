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

    /// Fichero temporal listo para compartir, en `tmp/export`. Se borra al cerrar la
    /// hoja de compartir (`ShareSheet`) y, si la app muere antes, al arrancar
    /// (`TempFiles.cleanAtLaunch`).
    static func file(_ n: Note, format: ExportFormat) throws -> URL {
        var safe = n.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        if safe.hasPrefix(".") || safe.isEmpty { safe = "Reunion" + safe }
        let url = TempFiles.exportDirectory.appendingPathComponent("\(safe.prefix(60)).\(format.fileExtension)")
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

/// Formato `.eugenia` v2 (revisión de seguridad 2026-09-18; el v1 se sigue leyendo):
///   cabecera = "EUGX2" | KDF (1 byte, 1 = PBKDF2-HMAC-SHA256) | iteraciones (UInt32 BE) | sal (16)
///   registro = longitud del nombre (UInt16 BE) | nombre UTF-8 | longitud del bloque
///              sellado (UInt64 BE) | AES-GCM combinado (nonce | cifrado | etiqueta)
///   último registro = "#end", cuyo contenido es el número de registros anteriores.
/// Datos autenticados de cada registro: cabecera | número de registro | nombre. Así no
/// se puede quitar, reordenar, cambiar de copia ni cortar el final sin que falle; en
/// v1 solo se autenticaba el nombre.
/// Clave: PBKDF2-HMAC-SHA256 con 600.000 iteraciones (OWASP 2023 para SHA-256; las
/// 210.000 que decía v1 son la cifra de SHA-512). Las iteraciones van en la cabecera:
/// se podrán subir sin romper copias viejas. Contraseña normalizada (NFC): la misma
/// escrita con otro teclado da la misma clave.
/// Cada fichero de audio va en su propio registro; son trozos de 180 s, así que se
/// cargan de uno en uno sin picos de memoria.
enum EncryptedArchive {
    static let magicV1 = Data("EUGX1".utf8)
    static let magic = Data("EUGX2".utf8)
    static let iterationsV1: UInt32 = 210_000
    static let iterations: UInt32 = 600_000
    static let minPasswordLength = 12
    private static let endName = "#end"

    enum ArchiveError: Error, CustomStringConvertible {
        case badFormat, wrongPassword, weakPassword, truncated, randomFailed
        var description: String {
            switch self {
            case .badFormat: return String(localized: "El fichero no es una copia de Eugenia o está dañado.")
            case .wrongPassword: return String(localized: "La contraseña no es correcta.")
            case .weakPassword: return String(localized: "Usa una contraseña de al menos 12 caracteres.")
            case .truncated: return String(localized: "La copia está incompleta: le faltan datos al final.")
            case .randomFailed: return String(localized: "No se pudo generar la clave. Inténtalo de nuevo.")
            }
        }
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        _ = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }

    private static func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private static func readBE<T: FixedWidthInteger>(_ d: Data, as: T.Type) -> T {
        T(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }
    private static func aad(_ header: Data, _ n: UInt32, _ name: Data) -> Data { header + be(n) + name }

    /// Escribe la copia. `files` = (nombre en el archivo, URL local). Devuelve los
    /// nombres de audio que NO se pudieron leer (para avisar: la copia quedaría
    /// incompleta sin que nadie lo sepa).
    @discardableResult
    static func write(to url: URL, password: String, index: Data, files: [(String, URL)]) throws -> [String] {
        guard password.precomposedStringWithCanonicalMapping.count >= minPasswordLength else { throw ArchiveError.weakPassword }
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw ArchiveError.randomFailed }
        let header = magic + Data([1]) + be(iterations) + salt
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.protectionKey: FileProtectionType.complete])
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.write(contentsOf: header)
        var count: UInt32 = 0
        func record(_ name: String, _ data: Data) throws {
            let nameData = Data(name.utf8)
            let sealed = try AES.GCM.seal(data, using: key, authenticating: aad(header, count, nameData))
            guard let combined = sealed.combined else { throw ArchiveError.badFormat }
            try h.write(contentsOf: be(UInt16(nameData.count)) + nameData + be(UInt64(combined.count)) + combined)
            count += 1
        }
        try record("notes.json", index)
        var skipped: [String] = []
        for (name, file) in files {
            guard let data = try? Data(contentsOf: file) else { skipped.append(name); continue }
            try record("audio/" + name, data)
        }
        try record(endName, be(count))
        return skipped
    }

    /// Lee una copia (v2 o v1) y devuelve el índice; los ficheros van a `onFile`.
    static func read(from url: URL, password: String, onFile: (String, Data) throws -> Void) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard let m = try h.read(upToCount: 5), m.count == 5 else { throw ArchiveError.badFormat }
        let v2 = m == magic
        guard v2 || m == magicV1 else { throw ArchiveError.badFormat }
        let header: Data
        let key: SymmetricKey
        if v2 {
            guard let rest = try h.read(upToCount: 21), rest.count == 21, rest[rest.startIndex] == 1 else {
                throw ArchiveError.badFormat
            }
            let iters = readBE(rest.subdata(in: rest.startIndex + 1 ..< rest.startIndex + 5), as: UInt32.self)
            // Un fichero ajeno no puede pedir una derivación absurda (bloquear la app).
            guard (100_000...10_000_000).contains(iters) else { throw ArchiveError.badFormat }
            header = m + rest
            key = deriveKey(password: password, salt: rest.suffix(16), iterations: iters)
        } else {
            guard let salt = try h.read(upToCount: 16), salt.count == 16 else { throw ArchiveError.badFormat }
            header = m + salt
            key = deriveKey(password: password, salt: salt, iterations: iterationsV1)
        }
        var index: Data?
        var count: UInt32 = 0
        var ended = false
        while let lenData = try h.read(upToCount: 2), lenData.count == 2 {
            guard !ended else { throw ArchiveError.badFormat }   // nada después del final
            let nameLen = Int(readBE(lenData, as: UInt16.self))
            guard nameLen > 0, nameLen < 1_024,
                  let nameData = try h.read(upToCount: nameLen), nameData.count == nameLen,
                  let sizeData = try h.read(upToCount: 8), sizeData.count == 8 else { throw ArchiveError.truncated }
            let size = readBE(sizeData, as: UInt64.self)
            guard size > 28, size < 200_000_000 else { throw ArchiveError.badFormat }
            guard let blob = try h.read(upToCount: Int(size)), blob.count == Int(size) else { throw ArchiveError.truncated }
            let plain: Data
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key,
                                         authenticating: v2 ? aad(header, count, nameData) : nameData)
            } catch {
                throw count == 0 ? ArchiveError.wrongPassword : ArchiveError.badFormat
            }
            let name = String(decoding: nameData, as: UTF8.self)
            if v2 && name == endName {
                guard plain.count == 4, readBE(plain, as: UInt32.self) == count else { throw ArchiveError.badFormat }
                ended = true
            } else if name == "notes.json" {
                guard index == nil else { throw ArchiveError.badFormat }
                index = plain
            } else {
                try onFile(name, plain)
            }
            count += 1
        }
        if v2 && !ended { throw ArchiveError.truncated }
        guard let index else { throw ArchiveError.badFormat }
        return index
    }
}
