import AtumChat
import Foundation
import ImageIO
import MatrixRustSDK

/// One cache for the open chat. Requests and cached results are gated by
/// current session, membership and encryption, including after suspension.
@MainActor
final class RoomLinkPreviews {
    private struct Key: Hashable {
        let url: URL
        let utcDayStart: UInt64
    }

    private struct Read {
        let id: UUID
        let task: Task<LinkPreview?, Error>
    }

    private let client: Client
    private let room: Room
    private let isCurrent: () -> Bool
    private var reads = [Key: Read]()
    private var order = [Key]()
    private var closed = false

    init(client: Client, room: Room, isCurrent: @escaping () -> Bool) {
        self.client = client
        self.room = room
        self.isCurrent = isCurrent
    }

    func card(for item: ChatItem, now: Date = .now) async -> LinkPreview? {
        guard !closed, let url = item.linkPreviewURL, item.eventID != nil, !Task.isCancelled,
              isCurrent(), room.membership() == .joined, room.encryptionState() != .encrypted,
              (try? await room.latestEncryptionState()) == .notEncrypted, canRead
        else { return nil }
        let day = max(0, now.timeIntervalSince1970 / 86_400).rounded(.down)
        let key = Key(url: url, utcDayStart: UInt64(day) * 86_400_000)
        let read: Read
        if let existing = reads[key] {
            read = existing
        } else {
            if order.count == 32 { reads.removeValue(forKey: order.removeFirst())?.task.cancel() }
            read = Read(id: UUID(), task: Task { [weak self] in
                guard let self, self.canRead else { return nil }
                return try await self.fetch(key)
            })
            reads[key] = read
            order.append(key)
        }
        do {
            let result = try await read.task.value
            return canRead ? result : nil
        } catch {
            if reads[key]?.id == read.id {
                reads.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
            return nil
        }
    }

    func close() {
        closed = true
        for read in reads.values { read.task.cancel() }
        reads.removeAll()
        order.removeAll()
    }

    private var canRead: Bool {
        !closed && !Task.isCancelled && isCurrent() && room.membership() == .joined
            && room.encryptionState() == .notEncrypted
    }

    private func fetch(_ key: Key) async throws -> LinkPreview? {
        guard let json = try await client.getUrlPreview(url: key.url.absoluteString, ts: key.utcDayStart),
              let metadata = LinkPreview.Metadata(json: json), canRead else { return nil }
        var image: Data?
        if let uri = metadata.imageURI, let source = try? MediaSource.fromUrl(url: uri),
           let bytes = try? await client.getMediaThumbnail(mediaSource: source, width: 480, height: 270),
           Self.isImage(bytes) {
            image = bytes
        }
        return canRead ? metadata.card(url: key.url, image: image) : nil
    }

    private static func isImage(_ data: Data) -> Bool {
        guard data.count <= LinkPreview.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png", "org.webmproject.webp", "com.compuserve.gif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return (1...4096).contains(width) && (1...4096).contains(height)
    }
}

extension LiveAppModel {
    func openRoomLinkPreviews(roomID: String) -> RoomLinkPreviews? {
        guard let session = liveMatrix, let room = try? session.room(id: roomID) else { return nil }
        return RoomLinkPreviews(client: session.runtime.client, room: room) { [weak self, weak session] in
            guard let session else { return false }
            return self?.liveMatrix === session && (try? session.runtime.requireCurrent()) != nil
        }
    }
}
