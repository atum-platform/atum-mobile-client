import CryptoKit
import Foundation
import AtumChat

/// The App Group files behind communication notifications:
/// - `rooms.json`, the app's `NotificationRoomDirectory`;
/// - `faces/<sha256>.png`, chat-header faces the app drew for assistant and
///   app rooms;
/// - `avatars/<sha256>`, avatar thumbnails the extension fetched through the
///   SDK's authenticated media path, capped by count and bytes with
///   least-recently-used eviction.
/// Every file uses after-first-unlock protection, like the Matrix store, so the
/// extension can read it on a locked phone. File names are hashes: no Matrix
/// ID, room ID or media URI appears in a path.
public struct NotificationSharedStore: Sendable {
    public static let maximumAvatarFiles = 160
    public static let maximumAvatarBytes = 4 * 1_024 * 1_024
    public static let maximumImageBytes = 512 * 1_024
    static let maximumDirectoryBytes = 512 * 1_024

    private let root: URL

    public init() throws {
        #if os(iOS)
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.atum.mobile.shared") else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        root = group.appendingPathComponent("AtumNotifications", isDirectory: true)
        #else
        throw MatrixCustodyFailure.storageUnavailable
        #endif
    }

    public init(root: URL) { self.root = root }

    private var directoryFile: URL { root.appendingPathComponent("rooms.json") }
    private var facesFolder: URL { root.appendingPathComponent("faces", isDirectory: true) }
    private var avatarsFolder: URL { root.appendingPathComponent("avatars", isDirectory: true) }

    // MARK: Directory (app writes, extension reads)

    public func readDirectory() -> NotificationRoomDirectory? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: directoryFile.path)[.size] as? NSNumber,
              size.intValue <= Self.maximumDirectoryBytes,
              let data = try? Data(contentsOf: directoryFile) else { return nil }
        return try? JSONDecoder().decode(NotificationRoomDirectory.self, from: data)
    }

    /// Writes only when the content changed, so a re-render costs one read.
    public func writeDirectory(_ directory: NotificationRoomDirectory) throws {
        var bounded = directory
        if bounded.rooms.count > NotificationRoomDirectory.maximumRooms {
            let kept = bounded.rooms.keys.sorted().prefix(NotificationRoomDirectory.maximumRooms)
            bounded.rooms = bounded.rooms.filter { kept.contains($0.key) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bounded)
        guard data.count <= Self.maximumDirectoryBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        if (try? Data(contentsOf: directoryFile)) == data { return }
        try prepare(root)
        try data.write(to: directoryFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: App-drawn faces

    /// The file name for one face: the hash of what was drawn, so a changed
    /// face is a new file and an unchanged one is not redrawn.
    public static func faceFileName(identity: String) -> String {
        hex(SHA256.hash(data: Data(identity.utf8))) + ".png"
    }

    public func hasFace(_ name: String) -> Bool {
        guard let name = CommunicationNotificationPolicy.validFaceFile(name) else { return false }
        return FileManager.default.fileExists(atPath: facesFolder.appendingPathComponent(name).path)
    }

    public func writeFace(_ png: Data, name: String) throws {
        guard let name = CommunicationNotificationPolicy.validFaceFile(name),
              png.count <= Self.maximumImageBytes else { throw CocoaError(.fileWriteInvalidFileName) }
        try prepare(root); try prepare(facesFolder)
        try png.write(to: facesFolder.appendingPathComponent(name),
                      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func readFace(_ name: String) -> Data? {
        guard let name = CommunicationNotificationPolicy.validFaceFile(name) else { return nil }
        return boundedRead(facesFolder.appendingPathComponent(name))
    }

    /// Removes every face the current directory no longer names.
    public func pruneFaces(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: facesFolder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Avatar thumbnails (extension cache)

    /// A Matrix content URI names immutable media, so a cached thumbnail never
    /// goes stale; a new avatar is a new URI and a new entry.
    public static func avatarKey(uri: String, pixelSide: Int) -> String {
        hex(SHA256.hash(data: Data("\(pixelSide)\u{0}\(uri)".utf8)))
    }

    public func cachedAvatar(uri: String, pixelSide: Int) -> Data? {
        let file = avatarsFolder.appendingPathComponent(Self.avatarKey(uri: uri, pixelSide: pixelSide))
        guard let data = boundedRead(file) else { return nil }
        // Touch for least-recently-used eviction.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func storeAvatar(_ data: Data, uri: String, pixelSide: Int) {
        guard !data.isEmpty, data.count <= Self.maximumImageBytes else { return }
        do {
            try prepare(root); try prepare(avatarsFolder)
            try data.write(to: avatarsFolder.appendingPathComponent(Self.avatarKey(uri: uri, pixelSide: pixelSide)),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            evictAvatars()
        } catch {}
    }

    /// Oldest first until both the count and the byte caps hold.
    func evictAvatars() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: avatarsFolder, includingPropertiesForKeys: keys)
        else { return }
        var entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        while !entries.isEmpty, entries.count > Self.maximumAvatarFiles || total > Self.maximumAvatarBytes {
            let oldest = entries.removeFirst()
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.2
        }
    }

    // MARK: Sign-out

    /// One account's faces, avatars and room names: sign-out removes them all.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Private

    private func boundedRead(_ file: URL) -> Data? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= Self.maximumImageBytes else { return nil }
        return try? Data(contentsOf: file)
    }

    private func prepare(_ folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            .posixPermissions: 0o700,
        ])
        var value = folder
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try? value.setResourceValues(resources)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
