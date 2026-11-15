import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// No credentials in the handoff. A new login/store generation cannot inherit old shares.
public struct ShareAccount: Codable, Equatable, Sendable {
    public let userID: String
    public let generation: UUID
    public init(userID: String, generation: UUID) { self.userID = userID; self.generation = generation }
}

public struct ShareChat: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isGroup: Bool
    public let recipients: [String]
    public let avatarURI: String?
    public init(id: String, name: String, isGroup: Bool, recipients: [String], avatarURI: String? = nil) {
        self.id = id; self.name = name; self.isGroup = isGroup
        self.recipients = recipients; self.avatarURI = avatarURI
    }
}

public struct ShareDirectory: Codable, Equatable, Sendable {
    public let account: ShareAccount
    /// Already sorted by recency and filtered by the app's visibility/archival policies.
    public let chats: [ShareChat]
    public init(account: ShareAccount, chats: [ShareChat]) { self.account = account; self.chats = chats }
}

public struct ShareItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, video, file, url, text }
    public let kind: Kind
    /// A UUID file name inside this job, never a provider path or user-supplied path.
    public let file: String?
    public let filename: String?
    public let typeIdentifier: String?
    public let text: String?
    public init(kind: Kind, file: String? = nil, filename: String? = nil,
                typeIdentifier: String? = nil, text: String? = nil) {
        self.kind = kind; self.file = file; self.filename = filename
        self.typeIdentifier = typeIdentifier; self.text = text
    }
}

public struct ShareJob: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, handingOff, accepted }
    public struct Delivery: Codable, Equatable, Sendable {
        public let roomID: String
        public let itemIndex: Int
        public var state: State = .pending
    }
    public let id: UUID
    public let account: ShareAccount
    public let createdAt: Date
    public let items: [ShareItem]
    public let caption: String
    public var deliveries: [Delivery]
    public init(id: UUID, account: ShareAccount, items: [ShareItem], caption: String, rooms: [String]) {
        self.id = id; self.account = account; self.items = items; self.caption = caption; createdAt = Date()
        deliveries = rooms.flatMap { room in items.indices.map { Delivery(roomID: room, itemIndex: $0) } }
    }
}

public enum ShareQueueFailure: Error { case unavailable, invalid, tooLarge, full, accountChanged }

/// Atomic manifests, disk-to-disk provider copies, and one short cross-process metadata lock.
/// The extension never starts a Matrix client or touches the crypto store/refresh token.
public struct ShareQueue: Sendable {
    public static let maximumItems = 10
    public static let maximumItemBytes = 20 * 1_024 * 1_024
    public static let maximumTextBytes = 64 * 1_024
    public static let maximumDiskBytes = 400 * 1_024 * 1_024
    public let root: URL
    private var fm: FileManager { FileManager.default }
    public init(root: URL) { self.root = root }
    public init() throws {
        #if os(iOS)
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.atum.mobile.shared")
        else { throw ShareQueueFailure.unavailable }
        root = group.appendingPathComponent("AtumShare", isDirectory: true)
        #else
        throw ShareQueueFailure.unavailable
        #endif
    }
    public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private var directoryURL: URL { root.appendingPathComponent("directory.json") }

    public func readDirectory() throws -> ShareDirectory? {
        try locked {
            guard fm.fileExists(atPath: directoryURL.path) else { return nil }
            return try decode(ShareDirectory.self, at: directoryURL)
        }
    }
    public func publish(_ directory: ShareDirectory) throws {
        try locked { try write(directory, to: directoryURL) }
    }
    public func begin() throws -> UUID {
        try locked {
            let folders = try jobFolders()
            // Orphaned provider copies (cancelled/killed before commit) expire after a day.
            for url in folders where !fm.fileExists(atPath: url.appendingPathComponent("job.json").path) {
                if let date = try url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   date < Date().addingTimeInterval(-86_400) { try? fm.removeItem(at: url) }
            }
            guard try jobFolders().count < 20, diskBytes() < Self.maximumDiskBytes else { throw ShareQueueFailure.full }
            let id = UUID()
            try prepare(folder(id))
            return id
        }
    }
    /// Must run while NSItemProvider's temporary URL is alive. No full-size image/video decode.
    public func copyFile(_ url: URL, jobID: UUID, kind: ShareItem.Kind, type: String?, name: String?) throws -> ShareItem {
        try locked {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes > 0
            else { throw ShareQueueFailure.invalid }
            guard bytes <= Self.maximumItemBytes, diskBytes() + bytes <= Self.maximumDiskBytes else { throw ShareQueueFailure.tooLarge }
            let file = UUID().uuidString
            let target = folder(jobID).appendingPathComponent(file)
            try fm.copyItem(at: url, to: target)
            try protect(target)
            guard try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes else {
                try? fm.removeItem(at: target); throw ShareQueueFailure.invalid
            }
            let filename = String((name ?? url.lastPathComponent).replacingOccurrences(of: "/", with: "_").prefix(240))
            return ShareItem(kind: kind, file: file, filename: filename, typeIdentifier: type)
        }
    }
    public func commit(_ job: ShareJob, currentAccount: () throws -> ShareAccount) throws {
        try locked {
            guard try currentAccount() == job.account,
                  let directory = try decodeOptionalDirectory(), directory.account == job.account,
                  job.deliveries.allSatisfy({ d in directory.chats.contains { $0.id == d.roomID } })
            else { throw ShareQueueFailure.accountChanged }
            try validate(job, requireFiles: true)
            guard !fm.fileExists(atPath: folder(job.id).appendingPathComponent("job.json").path) else { throw ShareQueueFailure.invalid }
            try write(job, to: folder(job.id).appendingPathComponent("job.json"))
        }
    }
    public func jobs(account: ShareAccount) throws -> [ShareJob] {
        try locked {
            try jobFolders().compactMap { url in
                let file = url.appendingPathComponent("job.json")
                guard fm.fileExists(atPath: file.path) else { return nil }
                let job = try decode(ShareJob.self, at: file)
                guard job.account == account else { return nil }
                try validate(job)
                return job
            }.sorted { $0.createdAt < $1.createdAt }
        }
    }
    public func save(_ job: ShareJob) throws {
        try locked { try validate(job); try write(job, to: folder(job.id).appendingPathComponent("job.json")) }
    }
    public func remove(_ id: UUID) throws { try locked { try fm.removeItem(at: folder(id)) } }
    public func clear() throws {
        try locked {
            for url in try jobFolders() { try fm.removeItem(at: url) }
            if fm.fileExists(atPath: directoryURL.path) { try fm.removeItem(at: directoryURL) }
        }
    }
    public func fileURL(_ item: ShareItem, jobID: UUID) throws -> URL {
        guard let file = item.file, UUID(uuidString: file) != nil else { throw ShareQueueFailure.invalid }
        return folder(jobID).appendingPathComponent(file)
    }
    private func validate(_ job: ShareJob, requireFiles: Bool = false) throws {
        guard !job.items.isEmpty, job.items.count <= Self.maximumItems,
              job.caption.utf8.count <= Self.maximumTextBytes,
              !job.deliveries.isEmpty, job.deliveries.count <= Self.maximumItems * 20,
              job.deliveries.allSatisfy({ job.items.indices.contains($0.itemIndex) && $0.roomID.hasPrefix("!") })
        else { throw ShareQueueFailure.invalid }
        for item in job.items {
            if item.kind == .url || item.kind == .text {
                guard let text = item.text, !text.isEmpty, text.utf8.count <= Self.maximumTextBytes else { throw ShareQueueFailure.invalid }
            } else {
                let url = try fileURL(item, jobID: job.id)
                guard requireFiles else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= Self.maximumItemBytes else { throw ShareQueueFailure.invalid }
            }
        }
    }
    private func decodeOptionalDirectory() throws -> ShareDirectory? {
        guard fm.fileExists(atPath: directoryURL.path) else { return nil }
        return try decode(ShareDirectory.self, at: directoryURL)
    }
    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_024 * 1_024 else { throw ShareQueueFailure.invalid }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_024 * 1_024 else { throw ShareQueueFailure.tooLarge }
        try data.write(to: url, options: .atomic)
        try protect(url)
    }
    private func prepare(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try protect(url)
        var resource = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
    private func protect(_ url: URL) throws {
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private func jobFolders() throws -> [URL] {
        try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }
    private func diskBytes() -> Int {
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return Self.maximumDiskBytes }
        return files.reduce(0) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return total }
            return total + (values.fileSize ?? 0)
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare(root)
        let fd = open(root.appendingPathComponent("metadata.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ShareQueueFailure.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ShareQueueFailure.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
