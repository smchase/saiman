import Foundation
import AppKit

// MARK: - Constants

enum AttachmentConstants {
    static let maxAttachmentsPerMessage = 6
    static let maxImageDimension: CGFloat = 1568  // Claude's recommended max
    static let thumbnailSize: CGFloat = 80
    static let supportedImageTypes = ["public.jpeg", "public.png", "public.gif", "com.compuserve.gif", "public.heic", "public.webp"]
    static let supportedExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
}

// MARK: - Attachment Model

struct Attachment: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let mimeType: String
    let relativePath: String  // Relative path from ~/.saiman/attachments/
    let width: Int
    let height: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        relativePath: String,
        width: Int,
        height: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.createdAt = createdAt
    }

    /// Full path to the attachment file
    var fullPath: URL {
        AttachmentManager.attachmentsDirectory.appendingPathComponent(relativePath)
    }

    /// Check if the file exists on disk
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fullPath.path)
    }

    /// Load the image data from disk
    func loadImageData() -> Data? {
        guard fileExists else { return nil }
        return try? Data(contentsOf: fullPath)
    }

    /// Load as NSImage
    func loadImage() -> NSImage? {
        guard let data = loadImageData() else { return nil }
        return NSImage(data: data)
    }

    /// Load thumbnail image
    func loadThumbnail() -> NSImage? {
        guard let image = loadImage() else {
            return nil
        }

        let thumbnailSize = AttachmentConstants.thumbnailSize
        let aspectRatio = image.size.width / image.size.height

        let targetSize: NSSize
        if aspectRatio > 1 {
            targetSize = NSSize(width: thumbnailSize, height: thumbnailSize / aspectRatio)
        } else {
            targetSize = NSSize(width: thumbnailSize * aspectRatio, height: thumbnailSize)
        }

        let thumbnail = NSImage(size: targetSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        thumbnail.unlockFocus()

        return thumbnail
    }

    /// Get MIME type from file extension
    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        default:
            return "image/jpeg"
        }
    }

    /// Check if a file extension is supported
    static func isSupported(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return AttachmentConstants.supportedExtensions.contains(ext)
    }
}

// MARK: - Pending Attachment (before saving to disk)

/// Represents an attachment that hasn't been saved yet (during message composition)
struct PendingAttachment: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let imageData: Data
    let image: NSImage
    let mimeType: String

    init?(id: UUID = UUID(), filename: String, data: Data) {
        guard let image = NSImage(data: data) else { return nil }

        self.id = id
        self.filename = filename
        self.imageData = data
        self.image = image
        self.mimeType = Attachment.mimeType(for: filename)
    }

    init?(id: UUID = UUID(), image: NSImage, filename: String = "clipboard.png") {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        self.id = id
        self.filename = filename
        self.imageData = pngData
        self.image = image
        self.mimeType = "image/png"
    }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
    }
}
