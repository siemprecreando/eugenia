import AVFoundation
import Foundation
import NaturalLanguage
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Importación (plan, Fase 3): audio y vídeo de Archivos, Fotos o "Abrir en…", y
/// documentos PDF/texto. Todo se procesa en el teléfono: el audio entra en la cola y
/// se transcribe con el mismo pipeline que el micrófono; el PDF se lee con PDFKit y,
/// si una página es una imagen escaneada, con el OCR de Vision.
enum Importer {
    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff, .pdf, .plainText, .text,
                                           UTType("net.daringfireball.markdown") ?? .plainText]

    enum ImportError: Error, CustomStringConvertible {
        case unsupported(String)
        case noAudioTrack
        case emptyDocument
        case exportFailed

        var description: String {
            switch self {
            case .unsupported(let ext):
                return "Eugenia no sabe abrir ficheros .\(ext). Admite audio (m4a, mp3, wav, aiff…), vídeo (mov, mp4), PDF y texto."
            case .noAudioTrack:
                return "Este fichero no tiene pista de audio."
            case .emptyDocument:
                return "No se encontró texto en el documento (ni con reconocimiento de texto)."
            case .exportFailed:
                return "No se pudo extraer el audio del fichero."
            }
        }
    }

    /// Importa un fichero y crea la nota. Devuelve su id.
    @MainActor
    static func importFile(_ url: URL, folder: String = "") async throws -> UUID {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let title = url.deletingPathExtension().lastPathComponent

        if type.conforms(to: .pdf) {
            let text = try await Task.detached(priority: .userInitiated) { try readPDF(url) }.value
            return saveDocument(title: title, text: text, folder: folder)
        }
        if type.conforms(to: .plainText) || type.conforms(to: .text) || url.pathExtension.lowercased() == "md" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.emptyDocument }
            return saveDocument(title: title, text: text, folder: folder)
        }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) || type.conforms(to: .movie) {
            return try await importMedia(url, title: title, folder: folder)
        }
        throw ImportError.unsupported(url.pathExtension.isEmpty ? "?" : url.pathExtension)
    }

    @MainActor
    private static func importMedia(_ url: URL, title: String, folder: String) async throws -> UUID {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw ImportError.noAudioTrack
        }
        let id = UUID()
        let name = "\(id.uuidString)-000.m4a"
        let target = Store.shared.audioURL(name)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.exportFailed
        }
        do {
            try await session.export(to: target, as: .m4a)
        } catch {
            Log.failure(Log.storage, "import.export", error)
            throw ImportError.exportFailed
        }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let language = Recorder.resolveLanguage(setting: AppSettings.shared.recordingLanguage,
                                                preferred: Locale.preferredLanguages)
        var note = Note(id: id, title: title, duration: duration.isFinite ? duration : 0,
                        language: language, state: NoteState.imported)
        note.audioParts = [name]
        note.folder = folder
        note.template = AppSettings.shared.defaultTemplate
        Store.shared.save(note)
        Log.event(Log.storage, "import.media", "note=\(id.uuidString) secs=\(Int(note.duration))")
        ProcessingQueue.shared.prioritize(id)
        return id
    }

    @MainActor
    private static func saveDocument(title: String, text: String, folder: String) -> UUID {
        var note = Note(title: title, language: detectLanguage(text), transcript: text, state: NoteState.queued)
        note.source = "document"
        note.audioState = "none"
        note.folder = folder
        note.template = AppSettings.shared.defaultTemplate
        Store.shared.save(note)
        Log.event(Log.storage, "import.document", "note=\(note.id.uuidString) chars=\(text.count)")
        ProcessingQueue.shared.prioritize(note.id)
        return note.id
    }

    static func detectLanguage(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.spanish, .english]
        r.processString(String(text.prefix(4_000)))
        return r.dominantLanguage == .english ? "en" : "es"
    }

    /// Texto de cada página; si una página no tiene texto seleccionable, OCR.
    nonisolated static func readPDF(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unsupported("pdf") }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count > 20 {
                pages.append(text)
            } else if let ocr = ocr(page), !ocr.isEmpty {
                pages.append(ocr)
            }
        }
        let all = pages.joined(separator: "\n\n")
        guard !all.isEmpty else { throw ImportError.emptyDocument }
        return all
    }

    nonisolated private static func ocr(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cg = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
