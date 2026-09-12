import AppKit
import ImageIO

@MainActor
enum ImageStore {
    private static let cache = NSCache<NSString, NSImage>()
    private static var contextCache: [UUID: String] = [:]

    static func fileURL(for image: StoredImage) -> URL {
        Persistence.imagesDirectory.appending(path: image.filename)
    }

    static func save(_ data: Data, prompt: String?, title: String? = nil) throws -> StoredImage {
        Persistence.ensureDirectories()
        let id = UUID()
        let image = StoredImage(
            id: id, filename: "\(id.uuidString).\(fileExtension(for: data))", prompt: prompt, title: title)
        try data.write(to: fileURL(for: image), options: .atomic)
        return image
    }

    /// Copies the image's file under a new id, keeping its prompt and title.
    static func duplicate(_ image: StoredImage) throws -> StoredImage {
        let id = UUID()
        let ext = (image.filename as NSString).pathExtension
        let copy = StoredImage(
            id: id, filename: ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)",
            prompt: image.prompt, title: image.title)
        try FileManager.default.copyItem(at: fileURL(for: image), to: fileURL(for: copy))
        return copy
    }

    static func nsImage(for image: StoredImage) -> NSImage? {
        let key = image.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let loaded = NSImage(contentsOf: fileURL(for: image)) else { return nil }
        cache.setObject(loaded, forKey: key)
        return loaded
    }

    static func delete(_ images: [StoredImage]) {
        for image in images {
            try? FileManager.default.removeItem(at: fileURL(for: image))
            cache.removeObject(forKey: image.id.uuidString as NSString)
            contextCache[image.id] = nil
        }
    }

    static func mimeType(for image: StoredImage) -> String {
        switch (image.filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// A downscaled JPEG `data:` URL used to send the image back to the model as context.
    static func contextDataURL(for image: StoredImage, maxPixelSize: Int = 1024) -> String? {
        if let cached = contextCache[image.id] { return cached }
        guard let source = CGImageSourceCreateWithURL(fileURL(for: image) as CFURL, nil),
              let thumbnail = downscaled(source, maxPixelSize: maxPixelSize)
        else { return nil }

        // Flatten onto white so transparent PNGs don't turn black as JPEG.
        let rect = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        guard let context = CGContext(
            data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(thumbnail, in: rect)
        guard let flattened = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: flattened).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return nil }

        let url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        contextCache[image.id] = url
        return url
    }

    /// Returns user-provided image data in a format the image APIs accept: PNG, JPEG and WebP
    /// are kept as is; anything else ImageIO can read (HEIC, TIFF, GIF…) is re-encoded.
    static func normalizedData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        if knownExtension(for: data) != nil { return data }
        guard let image = downscaled(source, maxPixelSize: 4096) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        return isOpaque
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            : rep.representation(using: .png, properties: [:])
    }

    static func thumbnail(of data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downscaled(source, maxPixelSize: maxPixelSize)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// Decodes the first frame, applying its EXIF orientation and capping its longest side.
    private static func downscaled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func fileExtension(for data: Data) -> String {
        knownExtension(for: data) ?? "png"
    }

    private static func knownExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return nil
    }
}
