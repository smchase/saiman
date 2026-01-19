import Foundation
import AppKit

/// Manages attachment storage, resizing, and retrieval
final class AttachmentManager: @unchecked Sendable {
    static let shared = AttachmentManager()

    /// Base directory for all attachments
    static var attachmentsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".saiman/attachments")
    }

    private let fileManager = FileManager.default

    private init() {
        // Ensure base attachments directory exists
        try? fileManager.createDirectory(at: Self.attachmentsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Save Attachment

    /// Save a pending attachment to disk, returns the saved Attachment
    func save(pending: PendingAttachment, conversationId: UUID) -> Attachment? {
        // Create conversation directory
        let conversationDir = Self.attachmentsDirectory.appendingPathComponent(conversationId.uuidString)
        try? fileManager.createDirectory(at: conversationDir, withIntermediateDirectories: true)

        // Resize image if needed
        let resizedData = resizeImageIfNeeded(pending.imageData, mimeType: pending.mimeType)
        let imageSize = getImageSize(from: resizedData) ?? (width: 100, height: 100)

        // Generate filename with attachment ID
        let ext = fileExtension(for: pending.mimeType)
        let filename = "\(pending.id.uuidString).\(ext)"
        let relativePath = "\(conversationId.uuidString)/\(filename)"
        let fullPath = Self.attachmentsDirectory.appendingPathComponent(relativePath)

        // Write to disk
        do {
            try resizedData.write(to: fullPath)
            Logger.shared.debug("Saved attachment: \(relativePath)")

            return Attachment(
                id: pending.id,
                filename: pending.filename,
                mimeType: pending.mimeType,
                relativePath: relativePath,
                width: imageSize.width,
                height: imageSize.height
            )
        } catch {
            Logger.shared.error("Failed to save attachment: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Delete Attachment

    /// Delete an attachment from disk
    func delete(attachment: Attachment) {
        let path = attachment.fullPath
        try? fileManager.removeItem(at: path)
        Logger.shared.debug("Deleted attachment: \(attachment.relativePath)")
    }

    /// Delete all attachments for a conversation
    func deleteAll(for conversationId: UUID) {
        let conversationDir = Self.attachmentsDirectory.appendingPathComponent(conversationId.uuidString)
        try? fileManager.removeItem(at: conversationDir)
        Logger.shared.debug("Deleted all attachments for conversation: \(conversationId)")
    }

    // MARK: - Image Processing

    /// Resize image if it exceeds the maximum dimension
    private func resizeImageIfNeeded(_ data: Data, mimeType: String) -> Data {
        guard let image = NSImage(data: data) else { return data }

        let maxDim = AttachmentConstants.maxImageDimension
        let size = image.size

        // Check if resizing is needed
        if size.width <= maxDim && size.height <= maxDim {
            return data
        }

        // Calculate new size maintaining aspect ratio
        let aspectRatio = size.width / size.height
        let newSize: NSSize
        if size.width > size.height {
            newSize = NSSize(width: maxDim, height: maxDim / aspectRatio)
        } else {
            newSize = NSSize(width: maxDim * aspectRatio, height: maxDim)
        }

        // Create resized image
        guard let resizedImage = resize(image: image, to: newSize) else { return data }

        // Convert back to data
        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return data }

        let outputData: Data?
        switch mimeType {
        case "image/png":
            outputData = bitmap.representation(using: .png, properties: [:])
        case "image/gif":
            outputData = bitmap.representation(using: .gif, properties: [:])
        default:
            outputData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }

        Logger.shared.debug("Resized image from \(Int(size.width))x\(Int(size.height)) to \(Int(newSize.width))x\(Int(newSize.height))")

        return outputData ?? data
    }

    private func resize(image: NSImage, to newSize: NSSize) -> NSImage? {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    private func getImageSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = NSImage(data: data) else { return nil }
        return (width: Int(image.size.width), height: Int(image.size.height))
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        default:
            return "jpg"
        }
    }

    // MARK: - Load from Pasteboard/Drag

    /// Load image from pasteboard (for paste operations)
    func loadFromPasteboard(_ pasteboard: NSPasteboard) -> [PendingAttachment] {
        var attachments: [PendingAttachment] = []

        // Try to get file URLs first
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if let attachment = loadFromURL(url) {
                    attachments.append(attachment)
                }
            }
        }

        // If no files, try to get image data directly (for screenshots, copy from web, etc.)
        if attachments.isEmpty, let image = NSImage(pasteboard: pasteboard) {
            if let attachment = PendingAttachment(image: image) {
                attachments.append(attachment)
            }
        }

        return attachments
    }

    /// Load image from file URL
    func loadFromURL(_ url: URL) -> PendingAttachment? {
        let filename = url.lastPathComponent

        guard Attachment.isSupported(filename: filename) else {
            Logger.shared.debug("Unsupported file type: \(filename)")
            return nil
        }

        guard let data = try? Data(contentsOf: url) else {
            Logger.shared.error("Failed to read file: \(url.path)")
            return nil
        }

        return PendingAttachment(filename: filename, data: data)
    }

    // MARK: - Open in Default App

    /// Open attachment in default application
    func openInDefaultApp(_ attachment: Attachment) {
        guard attachment.fileExists else {
            Logger.shared.error("Cannot open attachment - file not found: \(attachment.relativePath)")
            return
        }
        NSWorkspace.shared.open(attachment.fullPath)
    }
}
