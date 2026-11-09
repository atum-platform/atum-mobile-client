import AtumChat
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum AttachmentPreparationFailure: Error, Equatable, Sendable {
    case tooLargePhoto
    case tooLargeFile
    case unreadable
}

/// One tile in the composer while its local bytes are being prepared.
struct StagedChatAttachment: Identifiable, Equatable, Sendable {
    enum Hint: Equatable, Sendable { case photo, file }
    enum State: Equatable, Sendable {
        case preparing
        case ready(OutgoingChatAttachment)
    }

    let id: String
    let hint: Hint
    let displayName: String
    var state: State

    var outgoing: OutgoingChatAttachment? {
        guard case let .ready(value) = state else { return nil }
        return value
    }
}

/// Turns picker/importer results into bounded, metadata-free files before
/// anything can enter the send queue. The actor owns the app's disposable
/// staging directory; prepared files survive chat navigation but not launch.
actor AttachmentPreparer {
    static let shared = AttachmentPreparer()
    static let maximumItems = 10
    static let fallbackUploadLimit: UInt64 = 20 * 1_024 * 1_024
    nonisolated static var viewerShareFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("atum-media-viewer", isDirectory: true)
    }

    private let fileManager = FileManager.default
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-chat-attachments", isDirectory: true)
    }

    func cleanForLaunch() {
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: Self.viewerShareFolder)
    }

    func preparePhoto(data: Data, suggestedFilename: String?, type: UTType?,
                      uploadLimit: UInt64) throws -> OutgoingChatAttachment {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentPreparationFailure.unreadable
        }
        try ensureFolder()

        let id = UUID().uuidString.lowercased()
        let sourceType = type ?? CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let isGIF = sourceType?.conforms(to: .gif) == true
        let hasAlpha = Self.hasAlpha(sourceImage)
        let outputSource = isGIF ? sourceImage : try Self.uprightImage(sourceImage, source: source)
        let filename: String
        let mimetype: String
        let output: Data
        let dimensions: (width: UInt64, height: UInt64)

        if isGIF {
            // Re-encoding animated frames can temporarily consume far more memory
            // than the encoded input. Reject an already-oversize upload first.
            guard UInt64(data.count) <= uploadLimit else {
                throw AttachmentPreparationFailure.tooLargePhoto
            }
            filename = Self.safeFilename(suggestedFilename, fallback: id + ".gif", extension: "gif")
            mimetype = "image/gif"
            output = try Self.sanitizedGIF(source)
            dimensions = (UInt64(sourceImage.width), UInt64(sourceImage.height))
        } else {
            // CGImage has raw sensor dimensions; the display orientation lives in
            // ImageIO metadata. Bake it into pixels before deriving every output.
            let resized = try Self.scaledImage(outputSource, maximumLongSide: 2_560)
            dimensions = (UInt64(resized.width), UInt64(resized.height))
            if hasAlpha {
                filename = Self.safeFilename(suggestedFilename, fallback: id + ".png", extension: "png")
                mimetype = "image/png"
                guard let encoded = UIImage(cgImage: resized).pngData() else {
                    throw AttachmentPreparationFailure.unreadable
                }
                output = encoded
            } else {
                filename = Self.safeFilename(suggestedFilename, fallback: id + ".jpg", extension: "jpg")
                mimetype = "image/jpeg"
                guard let encoded = UIImage(cgImage: resized).jpegData(compressionQuality: 0.8) else {
                    throw AttachmentPreparationFailure.unreadable
                }
                output = encoded
            }
        }

        guard UInt64(output.count) <= uploadLimit else {
            throw AttachmentPreparationFailure.tooLargePhoto
        }
        let fileURL = folder.appendingPathComponent(id + "." + (filename as NSString).pathExtension)
        try output.write(to: fileURL, options: .atomic)

        let thumbnail = try Self.scaledImage(outputSource, maximumLongSide: 800)
        guard let thumbnailData = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8) else {
            throw AttachmentPreparationFailure.unreadable
        }
        let thumbnailURL = folder.appendingPathComponent(id + "-thumbnail.jpg")
        try thumbnailData.write(to: thumbnailURL, options: .atomic)

        return OutgoingChatAttachment(
            id: id,
            kind: .image(width: dimensions.width, height: dimensions.height, isAnimated: isGIF),
            filePath: fileURL.path,
            thumbnailPath: thumbnailURL.path,
            filename: filename,
            mimetype: mimetype,
            byteSize: UInt64(output.count)
        )
    }

    func prepareFile(url: URL, uploadLimit: UInt64) throws -> OutgoingChatAttachment {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw AttachmentPreparationFailure.unreadable
        }
        guard UInt64(size) <= uploadLimit else { throw AttachmentPreparationFailure.tooLargeFile }
        try ensureFolder()

        let id = UUID().uuidString.lowercased()
        let name = Self.safeFilename(values.name ?? url.lastPathComponent,
                                     fallback: id, extension: url.pathExtension)
        let destination = folder.appendingPathComponent(id + "-" + name)
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            throw AttachmentPreparationFailure.unreadable
        }
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize > 0 else {
            try? fileManager.removeItem(at: destination)
            throw AttachmentPreparationFailure.unreadable
        }
        guard UInt64(copiedSize) <= uploadLimit else {
            try? fileManager.removeItem(at: destination)
            throw AttachmentPreparationFailure.tooLargeFile
        }
        let contentType = UTType(filenameExtension: destination.pathExtension)
        let mimetype = contentType?.preferredMIMEType ?? "application/octet-stream"
        return OutgoingChatAttachment(id: id, kind: .file, filePath: destination.path,
                                      filename: name, mimetype: mimetype,
                                      byteSize: UInt64(copiedSize))
    }

    func remove(_ attachment: OutgoingChatAttachment) {
        try? fileManager.removeItem(atPath: attachment.filePath)
        if let thumbnailPath = attachment.thumbnailPath {
            try? fileManager.removeItem(atPath: thumbnailPath)
        }
    }

    private func ensureFolder() throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func scaledImage(_ image: CGImage, maximumLongSide: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maximumLongSide else { return image }
        let scale = CGFloat(maximumLongSide) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AttachmentPreparationFailure.unreadable
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw AttachmentPreparationFailure.unreadable }
        return output
    }

    /// Applies the source EXIF orientation to image pixels. The re-encoded
    /// attachment intentionally has no orientation metadata, so it must be
    /// physically upright before it is scaled or encoded.
    private static func uprightImage(_ image: CGImage, source: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let number = properties?[kCGImagePropertyOrientation] as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value),
              orientation != .up else {
            return image
        }

        let outputSize: CGSize
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            outputSize = CGSize(width: image.height, height: image.width)
        default:
            outputSize = CGSize(width: image.width, height: image.height)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        let uiOrientation: UIImage.Orientation
        switch orientation {
        case .up: uiOrientation = .up
        case .upMirrored: uiOrientation = .upMirrored
        case .down: uiOrientation = .down
        case .downMirrored: uiOrientation = .downMirrored
        case .left: uiOrientation = .left
        case .leftMirrored: uiOrientation = .leftMirrored
        case .right: uiOrientation = .right
        case .rightMirrored: uiOrientation = .rightMirrored
        @unknown default: throw AttachmentPreparationFailure.unreadable
        }
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            UIImage(cgImage: image, scale: 1, orientation: uiOrientation).draw(
                in: CGRect(origin: .zero, size: outputSize)
            )
        }
        guard let output = rendered.cgImage else { throw AttachmentPreparationFailure.unreadable }
        return output
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
    }

    /// Re-encode frames and timing only. EXIF, GPS, XMP and every other
    /// source metadata dictionary are deliberately omitted.
    private static func sanitizedGIF(_ source: CGImageSource) throws -> Data {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw AttachmentPreparationFailure.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, count, nil
        ) else { throw AttachmentPreparationFailure.unreadable }
        let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let sourceGIF = sourceProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loop = sourceGIF?[kCGImagePropertyGIFLoopCount] ?? 0
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop],
        ] as CFDictionary)
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw AttachmentPreparationFailure.unreadable
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime]
                ?? gif?[kCGImagePropertyGIFDelayTime] ?? 0.1
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentPreparationFailure.unreadable
        }
        return output as Data
    }

    private static func safeFilename(_ proposed: String?, fallback: String, extension ext: String) -> String {
        let last = (proposed ?? "").split(separator: "/").last.map(String.init) ?? ""
        let clean = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return fallback }
        let base = (clean as NSString).deletingPathExtension
        guard !base.isEmpty else { return fallback }
        return ext.isEmpty ? base : base + "." + ext
    }
}
