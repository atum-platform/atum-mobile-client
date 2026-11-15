import Foundation
import UniformTypeIdentifiers
import AtumNativeAPI

/// All providers are consumed sequentially. Copy inside the callback: its URL expires on return.
@MainActor
final class ShareItemLoader {
    let queue: ShareQueue
    init(queue: ShareQueue) { self.queue = queue }

    static func providers(from items: [NSExtensionItem]) -> [NSItemProvider] {
        items.flatMap { item in
            let attachments = item.attachments ?? []
            if !attachments.isEmpty { return attachments }
            guard let text = item.attributedContentText?.string, !text.isEmpty else { return [] }
            return [NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)]
        }
    }

    static func representation(for provider: NSItemProvider) -> (ShareItem.Kind, String)? {
        // A file URL is an attachment, not a textual URL. Preserve a specific image/movie UTI.
        for (kind, parent) in [(ShareItem.Kind.image, UTType.image), (.video, .movie)] {
            if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: parent) == true }) {
                return (kind, type)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return (.file, UTType.fileURL.identifier) }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return (.url, UTType.url.identifier) }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { return (.text, UTType.plainText.identifier) }
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) { return (.file, type) }
        return nil
    }
    func load(_ providers: [NSItemProvider], jobID: UUID,
              progress: (Double) -> Void) async throws -> [ShareItem] {
        guard !providers.isEmpty, providers.count <= ShareQueue.maximumItems else { throw ShareQueueFailure.invalid }
        var items = [ShareItem]()
        for provider in providers {
            try Task.checkCancellation()
            items.append(try await load(provider, jobID: jobID))
            progress(Double(items.count) / Double(providers.count))
        }
        return items
    }
    func load(_ provider: NSItemProvider, jobID: UUID) async throws -> ShareItem {
        guard let (kind, type) = Self.representation(for: provider) else { throw ShareQueueFailure.invalid }
        let queue = queue
        let name = provider.suggestedName
        if kind == .url || kind == .text || type == UTType.fileURL.identifier {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { loaded, error in
                    do {
                        if let error { throw error }
                        // Object-registered URLs (NSItemProvider(object:)) and some file
                        // providers answer a URL load with the URL's provider data, not a URL.
                        var value = loaded
                        if let data = loaded as? Data, kind == .url || type == UTType.fileURL.identifier,
                           let url = try? NSURL.object(withItemProviderData: data, typeIdentifier: type) as URL {
                            value = url as NSURL
                        }
                        if let url = value as? URL, url.isFileURL {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            let actualType = UTType(filenameExtension: url.pathExtension)
                            continuation.resume(returning: try queue.copyFile(url, jobID: jobID, kind: actualType?.conforms(to: .image) == true ? .image : (actualType?.conforms(to: .movie) == true ? .video : .file),
                                                                              type: actualType?.identifier, name: name ?? url.lastPathComponent))
                            return
                        }
                        guard type != UTType.fileURL.identifier else { throw ShareQueueFailure.invalid }
                        let text: String
                        if let url = value as? URL { text = url.absoluteString }
                        else if let string = value as? String { text = string }
                        else if let data = value as? Data, data.count <= ShareQueue.maximumTextBytes,
                                let string = String(data: data, encoding: .utf8) { text = string }
                        else { throw ShareQueueFailure.invalid }
                        guard !text.isEmpty, text.utf8.count <= ShareQueue.maximumTextBytes else { throw ShareQueueFailure.tooLarge }
                        continuation.resume(returning: ShareItem(kind: kind, text: text))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareQueueFailure.invalid }
                    var filename = name ?? url.lastPathComponent
                    if (filename as NSString).pathExtension.isEmpty,
                       let ext = UTType(type)?.preferredFilenameExtension { filename += "." + ext }
                    continuation.resume(returning: try queue.copyFile(url, jobID: jobID, kind: kind, type: type, name: filename))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
