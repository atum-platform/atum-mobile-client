import AtumChat
import Foundation
import ImageIO
import Observation

/// Session-owned registry. Teardown closes every reader before releasing the
/// SDK room/client; no content or decrypted thumbnails survive account change.
@MainActor
final class SharedCollectionsRegistry {
    var generation: UInt64 = 0
    var scopes: [UUID: LiveSharedCollections] = [:]
    func closeAll() {
        generation &+= 1
        let values = Array(scopes.values)
        scopes = [:]
        for scope in values { scope.close() }
    }
}

extension LiveMatrixSession {
    /// All room kinds use this same entry point; no roster or UI dependency.
    func openSharedCollections(roomID: String, context: RoomContext,
                               knownNames: [String: String] = [:],
                               catalogBotUserIDs: Set<String> = [],
                               languageCode: String = "en") async throws -> LiveSharedCollections {
        let generation = sharedCollectionsRegistry.generation
        let room = try room(id: roomID)
        let encrypted = await SDKTimelineSource.encryption(of: room)
        let mapperRoom = ItemMapperRoom(roomID: roomID, context: context, isEncrypted: encrypted,
                                        knownNames: knownNames, catalogBotUserIDs: catalogBotUserIDs,
                                        languageCode: languageCode)
        var sources: [SharedCollectionSection: SDKSharedCollectionsSource] = [:]
        do {
            for section in SharedCollectionSection.allCases {
                sources[section] = try await SDKSharedCollectionsSource.make(room: room, mapperRoom: mapperRoom, section: section)
            }
            _ = try self.room(id: roomID) // custody check after suspension
            guard sharedCollectionsRegistry.generation == generation else { throw SharedCollectionFailure.unavailable }
            let scope = LiveSharedCollections(session: self, roomID: roomID, sources: sources)
            sharedCollectionsRegistry.scopes[scope.id] = scope
            scope.observeConnection()
            scope.observeContents()
            return scope
        } catch {
            for source in sources.values { source.close() }
            throw error as? SharedCollectionFailure ?? SharedCollectionFailure.unavailable
        }
    }
}

/// Data/actions only. The panel owns a scope until dismissal, then calls close.
/// Reads run only when its models receive loadPreview/seeAll/loadMore/retry.
@MainActor
final class LiveSharedCollections {
    enum OpenResult {
        case link(LinkPolicy.Decision)
        case image(MediaViewerRequest)
        case file(LiveMediaFile)
    }
    let id = UUID()
    let roomID: String
    let sections: [SharedCollectionSection: SharedCollectionsModel]
    private weak var session: LiveMatrixSession?
    private var closed = false
    private var epoch: UInt64 = 0
    private var thumbnails: [String: Data] = [:]
    private var thumbnailOrder: [String] = []
    private var thumbnailItems: [String: SharedCollectionItem] = [:]
    private var thumbnailBytes = 0
    private var thumbnailTasks: [String: Task<Data?, Never>] = [:]
    private var fileInFlight = false

    fileprivate init(session: LiveMatrixSession, roomID: String,
                     sources: [SharedCollectionSection: SDKSharedCollectionsSource]) {
        self.session = session
        self.roomID = roomID
        sections = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, SharedCollectionsModel(section: $0.key, source: $0.value)) })
    }

    fileprivate func observeConnection() {
        guard !closed else { return }
        let offline = withObservationTracking {
            session?.lifecycle?.showsConnectionGlyph ?? true
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeConnection() }
        }
        for model in sections.values { model.setOffline(offline) }
    }

    fileprivate func observeContents() {
        guard !closed else { return }
        withObservationTracking {
            for model in sections.values { _ = model.revision }
            for (key, item) in thumbnailItems where !contains(item) {
                thumbnailTasks[key]?.cancel()
                thumbnailItems[key] = nil
                thumbnailOrder.removeAll { $0 == key }
                if let data = thumbnails.removeValue(forKey: key) { thumbnailBytes -= data.count }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeContents() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        epoch &+= 1
        for model in sections.values { model.close() }
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks = [:]
        thumbnails = [:]
        thumbnailOrder = []
        thumbnailItems = [:]
        thumbnailBytes = 0
        session?.sharedCollectionsRegistry.scopes[id] = nil
        session = nil
    }

    /// At most four SDK thumbnail operations in flight. The UI may retry nil
    /// when slots are busy. Keys include the source so edits cannot reuse old
    /// bytes. No disk cache of decrypted media is introduced here.
    func thumbnail(for item: SharedCollectionItem, pixelSide: Int = 320) async -> Data? {
        guard let session, !closed, contains(item), let request = item.thumbnail else { return nil }
        let side = max(1, min(pixelSide, 1024))
        let source: String
        switch request { case let .scaled(value), let .content(value): source = value }
        let key = Data((item.id + "|" + String(side) + "|" + source).utf8).base64EncodedString()
        if let value = thumbnails[key] { return value }
        if let task = thumbnailTasks[key] {
            let data = await task.value
            return !closed && contains(item) ? data : nil
        }
        guard thumbnailTasks.count < 4 else { return nil }
        let requestEpoch = epoch
        let task = Task { @MainActor [weak session] () -> Data? in
            guard let session, !Task.isCancelled else { return nil }
            let data: Data?
            switch request {
            case .scaled: data = await session.mediaThumbnail(sourceHandle: source, pixelWidth: side, pixelHeight: side)
            case .content: data = await session.mediaContent(sourceHandle: source)
            }
            guard !Task.isCancelled, let data, data.count <= SharedCollectionsPolicy.thumbnailMaximumBytes,
                  Self.validImage(data) else { return nil }
            return data
        }
        thumbnailItems[key] = item
        thumbnailTasks[key] = task
        let data = await task.value
        guard !closed, epoch == requestEpoch else { return nil }
        thumbnailTasks[key] = nil
        guard contains(item), let data else { thumbnailItems[key] = nil; return nil }
        thumbnails[key] = data
        thumbnailOrder.append(key)
        thumbnailBytes += data.count
        while thumbnailOrder.count > 96 || thumbnailBytes > 32 * 1024 * 1024 {
            let old = thumbnailOrder.removeFirst()
            thumbnailItems[old] = nil
            if let value = thumbnails.removeValue(forKey: old) { thumbnailBytes -= value.count }
        }
        return data
    }

    /// Open photos through MediaViewerRequest; videos/audio/files through the
    /// SDK-owned file handle for QuickLook/Share; web links through LinkPolicy.
    func open(_ item: SharedCollectionItem, senderLabel: String = "") async throws -> OpenResult {
        guard !closed, contains(item) else { throw SharedCollectionFailure.unavailable }
        if item.kind == .link { return .link(item.linkDecision) }
        if item.kind == .image, let media = item.media,
           MediaKind.usesImagePresentation(mimetype: media.mimetype, filename: media.filename) {
            let file = try await save(item)
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            guard Self.validImage(data, desktopThumbnailTypesOnly: false) else { throw SharedCollectionFailure.invalidMedia }
            return .image(MediaViewerRequest(rowID: item.id, media: media, sender: senderLabel,
                                              timestamp: item.timestamp, caption: "", localFileURL: nil,
                                              initialImageData: data))
        }
        return .file(try await save(item))
    }

    /// Bounded access for the existing MediaViewer, including its later Share
    /// fetch. A request cannot substitute another item's opaque media source.
    func mediaAccess(for item: SharedCollectionItem) -> ChatMediaAccess {
        ChatMediaAccess(
            thumbnail: { [weak self] media, width, height in
                guard media == item.media else { return nil }
                return await self?.thumbnail(for: item, pixelSide: max(width, height))
            },
            content: { [weak self] media in
                guard media == item.media, let file = try? await self?.save(item) else { return nil }
                return try? Data(contentsOf: file.url, options: .mappedIfSafe)
            },
            file: { [weak self] media in
                guard media == item.media else { return nil }
                return try? await self?.save(item)
            }
        )
    }

    /// Save/export entry point. Retain the returned handle while QuickLook or
    /// Share uses its URL. Missing/oversized sizes are refused before fetching;
    /// actual disk size is checked too. SDK remains responsible for decryption.
    func save(_ item: SharedCollectionItem) async throws -> LiveMediaFile {
        guard let session, !closed, contains(item), let media = item.media else { throw SharedCollectionFailure.unavailable }
        guard let size = media.byteSize else { throw SharedCollectionFailure.sizeUnavailable }
        guard size <= SharedCollectionsPolicy.fileMaximumBytes else { throw SharedCollectionFailure.tooLarge }
        guard !fileInFlight else { throw SharedCollectionFailure.unavailable }
        fileInFlight = true
        defer { fileInFlight = false }
        let requestEpoch = epoch
        guard let file = await session.mediaFile(sourceHandle: media.sourceHandle,
                                                 filename: media.filename, mimetype: media.mimetype ?? "application/octet-stream"),
              !closed, requestEpoch == epoch, contains(item), !Task.isCancelled else { throw SharedCollectionFailure.unavailable }
        let values = try file.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0,
              UInt64(bytes) <= SharedCollectionsPolicy.fileMaximumBytes else { throw SharedCollectionFailure.tooLarge }
        return file
    }

    private func contains(_ item: SharedCollectionItem) -> Bool {
        sections.values.contains { $0.contains(item) }
    }
    private static func validImage(_ data: Data, desktopThumbnailTypesOnly: Bool = true) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              !desktopThumbnailTypesOnly || ["public.jpeg", "public.png", "org.webmproject.webp", "com.compuserve.gif"].contains(type),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 16384 && height <= 16384 && width <= 40_000_000 / height
    }
}
