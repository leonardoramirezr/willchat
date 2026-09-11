import AppKit
import ImageIO

@MainActor
enum ImageStore {
    private static let cache = NSCache<NSString, NSImage>()
    private static var contextCache: [UUID: String] = [:]

    static func fileURL(for image: StoredImage) -> URL {
        Persistence.imagesDirectory.appending(path: image.filename)
    }

    static func save(_ data: Data, prompt: String?) throws -> StoredImage {
        Persistence.ensureDirectories()
        let id = UUID()
        let image = StoredImage(id: id, filename: "\(id.uuidString).\(fileExtension(for: data))", prompt: prompt)
        try data.write(to: fileURL(for: image), options: .atomic)
        return image
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
        guard let source = CGImageSourceCreateWithURL(fileURL(for: image) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

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

    private static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        return "png"
    }
}
