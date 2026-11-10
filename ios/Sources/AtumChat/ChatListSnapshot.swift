import CryptoKit
import Foundation

/// The last complete chat list the phone painted, kept on disk so a cold
/// launch shows the person's real rows before the Matrix room list, `/agents`
/// and `/apps` answer. It is presentation only: every field is what the row
/// already displayed, never authority for a room action.
///
/// Rows are stored in Home's order. A snapshot is account-scoped and is
/// ignored when another account signs in.
public struct ChatListSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public enum Kind: String, Codable, Equatable, Sendable {
        case atum
        case assistant
        case app
        case person
        case group
        case invitation
    }

    public enum Verification: String, Codable, Equatable, Sendable {
        case official
        case verified
    }

    public struct AvatarCandidate: Codable, Equatable, Hashable, Sendable {
        public var url: String
        public var sha256: String?

        public init(url: String, sha256: String?) {
            self.url = url
            self.sha256 = sha256
        }
    }

    /// A named assistant's shape mark, by its `/agents` raw values. An
    /// unknown value from a newer platform simply draws the initial.
    public struct Mark: Codable, Equatable, Hashable, Sendable {
        public var shape: String
        public var color: String

        public init(shape: String, color: String) {
            self.shape = shape
            self.color = color
        }
    }

    public struct Room: Codable, Equatable, Sendable {
        public var id: String
        public var roomID: String
        public var kind: Kind
        public var name: String
        public var verification: Verification?
        public var avatarURL: String?
        public var matrixAvatarURL: String?
        public var avatarSHA256: String?
        public var avatarCandidates: [AvatarCandidate]
        /// Absent in snapshots written before the mark was kept.
        public var mark: Mark?
        public var preview: RowPreview.Display
        public var latestEventAt: Date?
        public var latestWasDeliveryNotice: Bool
        public var unreadCount: Int
        public var notificationCount: Int
        public var highlightCount: Int
        public var isMarkedUnread: Bool
        public var isPinned: Bool
        public var isMuted: Bool
        public var canOpen: Bool
        public var isWaitingForRoom: Bool
        public var isComingSoon: Bool
        public var awaitsStart: Bool
        public var isFounder: Bool
        /// Display identity from /agents, for matching a positive platform binding
        /// while that catalog is unavailable. Never authority for opening a room.
        public var assistantPrincipal: String?
        public var assistantMatrixUserID: String?

        public init(id: String, roomID: String, kind: Kind, name: String,
                    verification: Verification? = nil,
                    avatarURL: String? = nil, matrixAvatarURL: String? = nil,
                    avatarSHA256: String? = nil,
                    avatarCandidates: [AvatarCandidate] = [],
                    mark: Mark? = nil,
                    preview: RowPreview.Display = .init(prefix: .none, value: .empty, sendState: .sent),
                    latestEventAt: Date? = nil,
                    latestWasDeliveryNotice: Bool = false,
                    unreadCount: Int = 0, notificationCount: Int = 0,
                    highlightCount: Int = 0, isMarkedUnread: Bool = false,
                    isPinned: Bool = false, isMuted: Bool = false,
                    canOpen: Bool = true, isWaitingForRoom: Bool = false,
                    isComingSoon: Bool = false, awaitsStart: Bool = false,
                    isFounder: Bool = false, assistantPrincipal: String? = nil,
                    assistantMatrixUserID: String? = nil) {
            self.id = id
            self.roomID = roomID
            self.kind = kind
            self.name = name
            self.verification = verification
            self.avatarURL = avatarURL
            self.matrixAvatarURL = matrixAvatarURL
            self.avatarSHA256 = avatarSHA256
            self.avatarCandidates = avatarCandidates
            self.mark = mark
            self.preview = preview
            self.latestEventAt = latestEventAt
            self.latestWasDeliveryNotice = latestWasDeliveryNotice
            self.unreadCount = max(0, unreadCount)
            self.notificationCount = max(0, notificationCount)
            self.highlightCount = max(0, highlightCount)
            self.isMarkedUnread = isMarkedUnread
            self.isPinned = isPinned
            self.isMuted = isMuted
            self.canOpen = canOpen
            self.isWaitingForRoom = isWaitingForRoom
            self.isComingSoon = isComingSoon
            self.awaitsStart = awaitsStart
            self.isFounder = isFounder
            self.assistantPrincipal = assistantPrincipal
            self.assistantMatrixUserID = assistantMatrixUserID
        }

        /// True when the row already has a photo/logo to draw. A row with one
        /// is never left on letters just because the bytes are still arriving.
        public var hasAvatarSource: Bool {
            isFounder || avatarURL != nil || matrixAvatarURL != nil
                || !avatarCandidates.isEmpty
        }

        public var hasSemanticPreview: Bool {
            if case .empty = preview.value { return false }
            return true
        }
    }

    public let schemaVersion: Int
    public var accountID: String
    public var savedAt: Date
    public var rooms: [Room]

    public init(accountID: String, savedAt: Date = Date(), rooms: [Room]) {
        schemaVersion = Self.schemaVersion
        self.accountID = accountID
        self.savedAt = savedAt
        self.rooms = rooms
    }
}

public extension ChatListSnapshot {
    /// Cached identity and previews hold the list steady while the live
    /// sources are still partial. Live counts, flags and time keep moving.
    ///
    /// Once the live list is authoritative its order and rows win outright;
    /// that is the one moment the cached projection is dropped.
    static func merged(cached: [Room], live: [Room],
                       liveIsAuthoritative: Bool) -> [Room] {
        guard !liveIsAuthoritative else { return authoritative(cached: cached, live: live) }
        guard !cached.isEmpty else { return live }

        var liveByID = [String: Room]()
        for room in live where liveByID[room.id] == nil { liveByID[room.id] = room }

        var merged = cached.map { cachedRow -> Room in
            guard let liveRow = liveByID[cachedRow.id] else { return cachedRow }
            var row = cachedRow
            // A live photo/logo replaces the cached one as soon as it exists;
            // a missing one must not erase what the person already saw.
            if let value = liveRow.avatarURL { row.avatarURL = value }
            if let value = liveRow.matrixAvatarURL { row.matrixAvatarURL = value }
            if let value = liveRow.avatarSHA256 { row.avatarSHA256 = value }
            if !liveRow.avatarCandidates.isEmpty { row.avatarCandidates = liveRow.avatarCandidates }
            if let value = liveRow.mark { row.mark = value }
            if let value = liveRow.verification { row.verification = value }
            row.latestWasDeliveryNotice = liveRow.latestWasDeliveryNotice
            if liveRow.hasSemanticPreview { row.preview = liveRow.preview }
            if let value = liveRow.latestEventAt,
               row.latestEventAt == nil || value > row.latestEventAt! {
                row.latestEventAt = value
            }
            row.unreadCount = liveRow.unreadCount
            row.notificationCount = liveRow.notificationCount
            row.highlightCount = liveRow.highlightCount
            row.isMarkedUnread = liveRow.isMarkedUnread
            row.isPinned = liveRow.isPinned
            row.isMuted = liveRow.isMuted
            row.canOpen = liveRow.canOpen
            row.isWaitingForRoom = liveRow.isWaitingForRoom
            row.isComingSoon = liveRow.isComingSoon
            row.awaitsStart = liveRow.awaitsStart
            row.isFounder = row.isFounder || liveRow.isFounder
            return row
        }

        let cachedIDs = Set(cached.map(\.id))
        merged.append(contentsOf: live.filter { !cachedIDs.contains($0.id) })
        return merged
    }

    /// The live list is complete, but a delivery-outcome notice at its head
    /// was suppressed. Keep the last real message from the cache for exactly
    /// those rows; genuinely empty rooms stay empty.
    static func authoritative(cached: [Room], live: [Room]) -> [Room] {
        guard !cached.isEmpty else { return live }
        var cachedByID = [String: Room]()
        for room in cached where cachedByID[room.id] == nil { cachedByID[room.id] = room }
        return live.map { row in
            guard row.latestWasDeliveryNotice, !row.hasSemanticPreview,
                  let cached = cachedByID[row.id], cached.hasSemanticPreview else {
                return row
            }
            var kept = row
            kept.preview = cached.preview
            return kept
        }
    }
}

/// One account-scoped JSON file in the caches directory. A corrupt, foreign
/// or stale file is simply absent; it never blocks Home.
public struct ChatListSnapshotStore: Sendable {
    public static let defaultMaximumAge: TimeInterval = 30 * 24 * 60 * 60

    public let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("atum-chat-list", isDirectory: true)
            .appendingPathComponent("snapshot.v1.json", isDirectory: false)
    }

    public func load(accountID: String, now: Date = Date(),
                     maximumAge: TimeInterval = defaultMaximumAge) -> ChatListSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard !accountID.isEmpty,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let snapshot = try? decoder.decode(ChatListSnapshot.self, from: data),
              snapshot.schemaVersion == ChatListSnapshot.schemaVersion,
              snapshot.accountID == accountID,
              snapshot.rooms.count <= 500,
              !snapshot.rooms.contains(where: { $0.id.isEmpty || $0.roomID.isEmpty })
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let age = now.timeIntervalSince(snapshot.savedAt)
        guard age >= -60, age <= maximumAge else { return nil }
        return snapshot
    }

    public func save(accountID: String, rooms: [ChatListSnapshot.Room],
                     savedAt: Date = Date()) throws {
        guard !accountID.isEmpty, rooms.count <= 500 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let snapshot = ChatListSnapshot(accountID: accountID, savedAt: savedAt, rooms: rooms)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// A bounded file cache for avatar bytes, keyed by the source identity the
/// caller controls (an `mxc` URI at a pixel size, or a public URL plus its
/// digest). Memory layers stay in the callers; this is the part that survives
/// a cold launch, so a photo does not turn back into a letter tile.
public actor AvatarDiskCache {
    public struct Limits: Sendable {
        public var maximumBytes: Int
        public var maximumEntryBytes: Int
        public var maximumEntries: Int

        public init(maximumBytes: Int = 24 * 1_024 * 1_024,
                    maximumEntryBytes: Int = 4 * 1_024 * 1_024,
                    maximumEntries: Int = 256) {
            self.maximumBytes = max(1, maximumBytes)
            self.maximumEntryBytes = max(1, maximumEntryBytes)
            self.maximumEntries = max(1, maximumEntries)
        }
    }

    public let directory: URL
    private let limits: Limits
    private let fileManager: FileManager

    public init(directory: URL? = nil, limits: Limits = Limits(),
                fileManager: FileManager = .default) {
        let base = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("atum-avatar-bytes", isDirectory: true)
        self.limits = limits
        self.fileManager = fileManager
    }

    public func data(for key: String) -> Data? {
        guard !key.isEmpty else { return nil }
        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= limits.maximumEntryBytes else { return nil }
        // Touch for a coarse least-recently-used order.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    @discardableResult
    public func store(_ data: Data, for key: String) -> Bool {
        guard !key.isEmpty, !data.isEmpty, data.count <= limits.maximumEntryBytes else {
            return false
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: key), options: .atomic)
            try pruneIfNeeded()
            return true
        } catch {
            return false
        }
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    /// Total bytes currently on disk, for diagnostics and tests.
    public func storedBytes() -> Int {
        entries().reduce(0) { $0 + $1.bytes }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key), isDirectory: false)
    }

    static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".bin"
    }

    private struct Entry {
        let url: URL
        let bytes: Int
        let modified: Date
    }

    private func entries() -> [Entry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "bin",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }
            return Entry(url: url, bytes: size,
                         modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private func pruneIfNeeded() throws {
        var entries = entries()
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard entries.count > limits.maximumEntries || total > limits.maximumBytes else { return }
        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard entries.count > limits.maximumEntries || total > limits.maximumBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.bytes
            entries.removeFirst()
        }
    }
}
