import AppKit
import PDFKit
import UniformTypeIdentifiers

enum AttachmentError: LocalizedError {
    case directory(String)
    case tooLarge(String)
    case unsupported(String)
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .directory(let name):
            return "«\(name)» es una carpeta. Adjunta los archivos individualmente."
        case .tooLarge(let name):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(DraftAttachment.maxFileSize), countStyle: .file)
            return "«\(name)» supera el límite de \(limit)."
        case .unsupported(let name):
            return "No se puede leer «\(name)». Se admiten imágenes, PDF, documentos (Word, RTF, ODT) y archivos de texto o código."
        case .noText(let name):
            return "«\(name)» no contiene texto que se pueda leer."
        }
    }
}

/// A file added in the composer that hasn't been sent yet. Nothing is written
/// to disk until the message is sent, so discarded drafts leave no files behind.
struct DraftAttachment: Identifiable {
    enum Kind { case image, document }

    let id = UUID()
    let name: String
    let kind: Kind
    let data: Data
    /// Thumbnail shown in the composer (images only).
    let preview: NSImage?

    static let maxFileSize = 25 * 1024 * 1024
    static let maxCount = 10

    @MainActor
    static func load(from url: URL) throws -> DraftAttachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true { throw AttachmentError.directory(name) }
        if let size = values?.fileSize, size > maxFileSize { throw AttachmentError.tooLarge(name) }

        let data = try Data(contentsOf: url)
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            return try image(data, name: name)
        }
        guard let text = FileStore.extractText(from: data, type: type) else {
            throw AttachmentError.unsupported(name)
        }
        guard !text.trimmed.isEmpty else { throw AttachmentError.noText(name) }
        return DraftAttachment(name: name, kind: .document, data: data, preview: nil)
    }

    @MainActor
    static func image(_ data: Data, name: String) throws -> DraftAttachment {
        guard data.count <= maxFileSize else { throw AttachmentError.tooLarge(name) }
        guard let normalized = ImageStore.normalizedData(data),
              let preview = ImageStore.thumbnail(of: normalized, maxPixelSize: 240)
        else { throw AttachmentError.unsupported(name) }
        return DraftAttachment(name: name, kind: .image, data: normalized, preview: preview)
    }
}

extension NSPasteboard {
    /// The first image type on the pasteboard, in the order the source app offered them
    /// (PNG for screenshots, TIFF from most apps, JPEG or HEIC from some).
    private var imageType: PasteboardType? {
        types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    var hasImage: Bool { imageType != nil }

    var imageData: Data? { imageType.flatMap { data(forType: $0) } }
}

/// Documents attached by the user, stored in `Persistence.filesDirectory`.
@MainActor
enum FileStore {
    /// Longest text sent to the model per file (roughly 40k tokens).
    static let maxCharacters = 150_000

    private static var textCache: [UUID: String] = [:]

    static func fileURL(for file: StoredFile) -> URL {
        Persistence.filesDirectory.appending(path: file.filename)
    }

    static func save(_ data: Data, name: String) throws -> StoredFile {
        Persistence.ensureDirectories()
        let id = UUID()
        let ext = (name as NSString).pathExtension
        let file = StoredFile(
            id: id, filename: ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)",
            name: name, byteCount: data.count)
        try data.write(to: fileURL(for: file), options: .atomic)
        return file
    }

    static func delete(_ files: [StoredFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: fileURL(for: file))
            textCache[file.id] = nil
        }
    }

    /// The file's text as sent to the model, or nil if it can no longer be read.
    static func text(for file: StoredFile) -> String? {
        if let cached = textCache[file.id] { return cached }
        let url = fileURL(for: file)
        guard let data = try? Data(contentsOf: url),
              var text = extractText(from: data, type: UTType(filenameExtension: url.pathExtension))
        else { return nil }
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "\n[… truncated: the file is too long …]"
        }
        textCache[file.id] = text
        return text
    }

    static func extractText(from data: Data, type: UTType?) -> String? {
        if type?.conforms(to: .pdf) == true || data.starts(with: Data("%PDF".utf8)) {
            guard let document = PDFDocument(data: data) else { return nil }
            return document.string ?? ""
        }
        if let type, let documentType = richDocumentType(for: type) {
            return (try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil))?.string
        }
        return plainText(from: data)
    }

    private static func richDocumentType(for type: UTType) -> NSAttributedString.DocumentType? {
        let mapping: [(UTType?, NSAttributedString.DocumentType)] = [
            (UTType("org.openxmlformats.wordprocessingml.document"), .officeOpenXML),
            (UTType("com.microsoft.word.doc"), .docFormat),
            (UTType("org.oasis-open.opendocument.text"), .openDocument),
            (.rtf, .rtf),
            (.webArchive, .webArchive),
        ]
        return mapping.first { $0.0.map(type.conforms(to:)) ?? false }?.1
    }

    private static func plainText(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // NUL bytes mean binary content (archives, executables, unknown formats).
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }
}
