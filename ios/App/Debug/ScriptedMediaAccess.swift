#if DEBUG
import AtumChat
import SwiftUI
import UIKit

@MainActor
enum ScriptedMediaAccess {
    private static var failedThumbnails = Set<String>()
    private static var failedFiles = Set<String>()
    static let access = ChatMediaAccess(
        thumbnail: { media, width, height in
            imageData(handle: media.thumbnailSourceHandle ?? media.sourceHandle,
                      width: width, height: height)
        },
        content: { media in
            imageData(handle: media.sourceHandle, width: 1_600, height: 1_200)
        },
        file: { media in
            await file(media: media)
        },
        uploadLimit: { MediaAttachmentPolicy.fallbackUploadLimit }
    )

    static func stagedAttachments() -> [OutgoingChatAttachment] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atum-scripted-staged",
                                                                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var output = [OutgoingChatAttachment]()
        for index in 1...3 {
            let id = "scripted-photo-\(index)"
            let url = folder.appendingPathComponent(id + ".png")
            let data = imageData(handle: "scripted:" + id, width: 640, height: 480) ?? Data()
            try? data.write(to: url, options: .atomic)
            output.append(OutgoingChatAttachment(id: id,
                                                 kind: .image(width: 640, height: 480, isAnimated: false),
                                                 filePath: url.path, filename: "photo-\(index).png",
                                                 mimetype: "image/png", byteSize: UInt64(data.count)))
        }
        let pdfID = "scripted-file-1"
        let pdfURL = folder.appendingPathComponent("bao-cao.pdf")
        if !FileManager.default.fileExists(atPath: pdfURL.path) {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            try? renderer.writePDF(to: pdfURL) { context in
                context.beginPage()
                NSAttributedString(string: "Atum scripted PDF",
                                   attributes: [.font: UIFont.systemFont(ofSize: 28)])
                    .draw(at: CGPoint(x: 48, y: 64))
            }
        }
        let size = (try? pdfURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 1
        output.append(OutgoingChatAttachment(id: pdfID, kind: .file,
                                             filePath: pdfURL.path, filename: "bao-cao.pdf",
                                             mimetype: "application/pdf", byteSize: UInt64(size)))
        return output
    }

    private static func imageData(handle: String, width: Int, height: Int) -> Data? {
        guard handle.hasPrefix("scripted:") else { return nil }
        if handle.contains("fail-once"), handle.contains("thumbnail"),
           failedThumbnails.insert(handle).inserted {
            return nil
        }
        let size = CGSize(width: max(80, min(width, 1_600)),
                          height: max(80, min(height, 1_200)))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let colors = [UIColor(red: 0.85, green: 0.38, blue: 0.18, alpha: 1).cgColor,
                          UIColor(red: 0.32, green: 0.60, blue: 0.54, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray,
                                      locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient,
                                                 start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height),
                                                 options: [])
            let number = String(abs(handle.hashValue) % 10)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(size.width, size.height) * 0.48,
                                         weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            ]
            let text = NSAttributedString(string: number, attributes: attributes)
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                  y: (size.height - bounds.height) / 2))
        }
    }

    private static func file(media: ChatMedia) async -> LiveMediaFile? {
        if ProcessInfo.processInfo.arguments.contains(AtumLaunchArguments.scriptedSlowFileDownloadFlag),
           media.sourceHandle.contains(".file.0") {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if media.sourceHandle.contains(".file.8"),
           failedFiles.insert(media.sourceHandle).inserted {
            return nil
        }
        let name = media.filename ?? "preview.dat"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-scripted-" + String(abs(media.sourceHandle.hashValue)) + "-" + name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                if media.mimetype == "application/pdf" {
                    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
                    try renderer.writePDF(to: url) { context in
                        context.beginPage()
                        NSAttributedString(
                            string: "Atum scripted preview",
                            attributes: [.font: UIFont.systemFont(ofSize: 28)]
                        ).draw(at: CGPoint(x: 48, y: 64))
                    }
                } else if media.mimetype?.hasPrefix("image/") == true,
                          let data = imageData(handle: media.sourceHandle, width: 800, height: 600) {
                    try data.write(to: url, options: .atomic)
                } else {
                    try Data("Atum scripted preview\n".utf8).write(to: url, options: .atomic)
                }
            } catch {
                return nil
            }
        }
        return LiveMediaFile(scriptedURL: url)
    }
}
#endif
