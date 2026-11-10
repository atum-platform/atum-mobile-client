#if DEBUG
import AtumChat
import Foundation
import UIKit

/// Debug only: `-AtumScriptedShared <ready|empty|partial|failed|offline>`
/// gives a scripted person or group chat's info sheet a Shared section on
/// `ScriptedSharedCollectionSource` (synthetic rows, no SDK). The real
/// models, display rules and views run unchanged.
@MainActor
final class ScriptedSharedCollectionsScope: SharedCollectionsScope {
    let sections: [SharedCollectionSection: SharedCollectionsModel]
    private(set) var isClosed = false

    init(mode: ScriptedSharedCollections.Mode) {
        sections = Dictionary(uniqueKeysWithValues: SharedCollectionSection.allCases.map { section in
            (section, SharedCollectionsModel(section: section,
                                             source: ScriptedSharedCollectionSource(section: section, mode: mode)))
        })
        if mode == .offline { for model in sections.values { model.setOffline(true) } }
    }

    static func opener(arguments: [String] = ProcessInfo.processInfo.arguments) -> SharedCollectionsOpener? {
        guard let mode = ScriptedSharedCollections.mode(arguments: arguments) else { return nil }
        return { ScriptedSharedCollectionsScope(mode: mode) }
    }

    func thumbnail(for item: SharedCollectionItem, pixelSide: Int) async -> Data? {
        guard !isClosed, contains(item), item.thumbnail != nil else { return nil }
        return Self.picture(item, side: max(64, min(pixelSide, 1_024)))
    }

    func open(_ item: SharedCollectionItem, senderLabel: String) async throws -> LiveSharedCollections.OpenResult {
        guard !isClosed, contains(item) else { throw SharedCollectionFailure.unavailable }
        if item.kind == .link { return .link(item.linkDecision) }
        if item.kind == .image, let media = item.media {
            return .image(MediaViewerRequest(rowID: item.id, media: media, sender: senderLabel,
                                             timestamp: item.timestamp, caption: "", localFileURL: nil,
                                             initialImageData: Self.picture(item, side: 1_200)))
        }
        return .file(try await save(item))
    }

    func save(_ item: SharedCollectionItem) async throws -> LiveMediaFile {
        guard !isClosed, contains(item), let media = item.media else { throw SharedCollectionFailure.unavailable }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-scripted-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(media.filename ?? "file")
        if !FileManager.default.fileExists(atPath: url.path) {
            switch item.kind {
            case .image:
                try (Self.picture(item, side: 1_200) ?? Data()).write(to: url, options: .atomic)
            case .file where media.mimetype == "application/pdf":
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
                try renderer.writePDF(to: url) { context in
                    context.beginPage()
                    UIColor(white: 0.9, alpha: 1).setFill()
                    context.cgContext.fill(CGRect(x: 48, y: 64, width: 516, height: 40))
                }
            default:
                // Video, audio and office files: a placeholder of the right name.
                try Data(count: 256).write(to: url, options: .atomic)
            }
        }
        return LiveMediaFile(scriptedURL: url)
    }

    func mediaAccess(for item: SharedCollectionItem) -> ChatMediaAccess {
        ChatMediaAccess(
            thumbnail: { [weak self] media, width, height in
                guard media == item.media else { return nil }
                return await self?.thumbnail(for: item, pixelSide: max(width, height))
            },
            content: { [weak self] media in
                guard media == item.media, let file = try? await self?.save(item) else { return nil }
                return try? Data(contentsOf: file.url)
            },
            file: { [weak self] media in
                guard media == item.media else { return nil }
                return try? await self?.save(item)
            }
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for model in sections.values { model.close() }
    }

    private func contains(_ item: SharedCollectionItem) -> Bool {
        sections.values.contains { $0.contains(item) }
    }

    /// A deterministic gradient per row, so screenshots are stable.
    private static func picture(_ item: SharedCollectionItem, side: Int) -> Data? {
        let number = Int(item.eventID.split(separator: "-").last ?? "0") ?? 0
        let hues: [(CGFloat, CGFloat, CGFloat)] = [(0.85, 0.38, 0.18), (0.32, 0.60, 0.54), (0.36, 0.42, 0.74),
                                                   (0.78, 0.62, 0.24), (0.55, 0.36, 0.62)]
        let first = hues[number % hues.count]
        let second = hues[(number + 2) % hues.count]
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let colors = [UIColor(red: first.0, green: first.1, blue: first.2, alpha: 1).cgColor,
                          UIColor(red: second.0, green: second.1, blue: second.2, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}
#endif
