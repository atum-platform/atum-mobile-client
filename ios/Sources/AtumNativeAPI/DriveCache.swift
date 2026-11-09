import CryptoKit
import Foundation

/// Account-scoped, rebuildable Drive bytes and last-good directory pages.
/// The actor serializes manifest replacement, ETag promotion and eviction.
public actor DriveCache {
    public struct Configuration: Equatable, Sendable {
        public var evictableBudgetBytes: Int64
        public var minimumFreeBytes: Int64
        public var maxEntryCount: Int
        public var maxPageCount: Int
        public var maxCachedItems: Int
        public var maxManifestBytes: Int

        public init(evictableBudgetBytes: Int64 = 250 * 1_024 * 1_024,
                    minimumFreeBytes: Int64 = 64 * 1_024 * 1_024,
                    maxEntryCount: Int = 20_000,
                    maxPageCount: Int = 256,
                    maxCachedItems: Int = 20_000,
                    maxManifestBytes: Int = 8 * 1_024 * 1_024) {
            self.evictableBudgetBytes = evictableBudgetBytes
            self.minimumFreeBytes = minimumFreeBytes
            self.maxEntryCount = maxEntryCount
            self.maxPageCount = maxPageCount
            self.maxCachedItems = maxCachedItems
            self.maxManifestBytes = maxManifestBytes
        }
    }

    private struct Entry: Codable, Equatable, Sendable {
        let itemID: String
        let etag: String
        let relativePath: String
        let size: Int64
        var lastAccessedAt: Date
        var kept: Bool
    }

    private struct CachedPage: Codable, Equatable, Sendable {
        let page: DrivePage
        var lastAccessedAt: Date
    }

    private struct Manifest: Codable, Equatable, Sendable {
        var version = 2
        var entries = [String: Entry]()
        var pages = [String: CachedPage]()
    }

    private struct LegacyManifest: Codable {
        let version: Int
        let entries: [String: Entry]
        let pages: [String: DrivePage]
    }

    private let root: URL
    private let files: URL
    private let incoming: URL
    private let manifestURL: URL
    private let configuration: Configuration
    private let availableCapacity: @Sendable () throws -> Int64
    private var manifest: Manifest
    private var withdrawn = false

    public static func live(scope: DriveCacheScope,
                            configuration: Configuration = .init()) throws -> DriveCache {
        let root = URL.applicationSupportDirectory
            .appendingPathComponent("AtumDrive", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(scope.key, isDirectory: true)
        return try DriveCache(root: root, configuration: configuration)
    }

    public init(root: URL, configuration: Configuration = .init()) throws {
        try self.init(root: root, configuration: configuration) {
            let values = try root.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return capacity
            }
            return Int64(values.volumeAvailableCapacity ?? 0)
        }
    }

    init(root: URL, configuration: Configuration,
         availableCapacity: @escaping @Sendable () throws -> Int64) throws {
        guard configuration.evictableBudgetBytes > 0,
              configuration.minimumFreeBytes >= 0,
              configuration.maxEntryCount > 0,
              configuration.maxPageCount > 0,
              configuration.maxCachedItems > 0,
              configuration.maxManifestBytes > 0 else {
            throw DriveFailure.storageUnavailable
        }
        self.root = root.standardizedFileURL
        files = self.root.appendingPathComponent("files", isDirectory: true)
        incoming = self.root.appendingPathComponent("incoming", isDirectory: true)
        manifestURL = self.root.appendingPathComponent("manifest.json")
        self.configuration = configuration
        self.availableCapacity = availableCapacity

        try Self.prepareDirectory(self.root)
        try Self.prepareDirectory(files)
        try Self.prepareDirectory(incoming)
        var needsPersist = false
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
                guard data.count <= configuration.maxManifestBytes else {
                    throw DriveFailure.storageUnavailable
                }
                if let current = try? JSONDecoder().decode(Manifest.self, from: data),
                   current.version == 2 {
                    manifest = current
                } else {
                    let legacy = try JSONDecoder().decode(LegacyManifest.self, from: data)
                    guard legacy.version == 1 else { throw DriveFailure.storageUnavailable }
                    manifest = Manifest(
                        entries: legacy.entries,
                        pages: legacy.pages.mapValues {
                            CachedPage(page: $0, lastAccessedAt: .distantPast)
                        }
                    )
                    needsPersist = true
                }
                try Self.validate(manifest)
            } catch {
                // Metadata and unkept bytes are rebuildable. A malformed or
                // oversized manifest resets to an empty safe cache rather than
                // bricking Drive on every launch.
                try? FileManager.default.removeItem(at: manifestURL)
                manifest = Manifest()
                needsPersist = true
            }
        } else {
            manifest = Manifest()
            needsPersist = true
        }
        if try Self.startupSweep(root: self.root, files: files, incoming: incoming,
                                 manifest: &manifest) {
            needsPersist = true
        }
        let startupRemoved = try Self.enforceLimits(
            manifest: &manifest,
            configuration: configuration,
            protectingPage: nil,
            protectingEntry: nil
        )
        if !startupRemoved.isEmpty { needsPersist = true }
        if needsPersist {
            try Self.write(manifest, to: manifestURL, maximumBytes: configuration.maxManifestBytes)
        }
        for entry in startupRemoved {
            try? FileManager.default.removeItem(at: files.appendingPathComponent(entry.relativePath))
        }
    }

    public func page(parentID: String, now: Date = Date()) throws -> DrivePage? {
        try requireActive()
        _ = try checkedString(parentID, minimum: 1, maximum: 1_024)
        guard var record = manifest.pages[parentID] else { return nil }
        record.lastAccessedAt = now
        manifest.pages[parentID] = record
        try? persist(protectingPage: parentID)
        return record.page
    }

    /// Only a complete validated page reaches this operation. The atomic
    /// manifest write leaves the preceding last-good page in place on failure.
    public func store(page: DrivePage, now: Date = Date()) throws {
        try requireActive()
        let previous = manifest
        manifest.pages[page.parentID] = CachedPage(page: page, lastAccessedAt: now)
        do { try persist(protectingPage: page.parentID) }
        catch {
            manifest = previous
            throw error
        }
    }

    public func cachedURL(for item: DriveItem, now: Date = Date()) throws -> URL? {
        try requireActive()
        let key = Self.entryKey(itemID: item.id, etag: item.etag)
        guard var entry = manifest.entries[key], entry.itemID == item.id,
              entry.etag == item.etag, entry.size == item.size else { return nil }
        let url = try fileURL(entry)
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == entry.size else {
            let previous = manifest
            manifest.entries[key] = nil
            do { try persist() }
            catch { manifest = previous }
            return nil
        }
        entry.lastAccessedAt = now
        let previous = manifest
        manifest.entries[key] = entry
        do { try persist(protectingEntry: key) }
        catch { manifest = previous; throw error }
        return url
    }

    public func isKept(_ item: DriveItem) throws -> Bool {
        try requireActive()
        return manifest.entries.values.contains { $0.itemID == item.id && $0.kept }
    }

    /// The newest explicitly retained older ETag. It is a fallback for an
    /// offline open only; an online caller still downloads the current ETag.
    public func retainedURL(for item: DriveItem, now: Date = Date()) throws -> URL? {
        try requireActive()
        let currentKey = Self.entryKey(itemID: item.id, etag: item.etag)
        guard let candidate = manifest.entries
            .filter({ $0.key != currentKey && $0.value.itemID == item.id && $0.value.kept })
            .max(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
            return nil
        }
        var entry = candidate.value
        let url = try fileURL(entry)
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == entry.size else { return nil }
        entry.lastAccessedAt = now
        let previous = manifest
        manifest.entries[candidate.key] = entry
        do { try persist(protectingEntry: candidate.key) }
        catch { manifest = previous; throw error }
        return url
    }

    public func prepareDownload(expectedBytes: Int64) throws -> URL {
        try requireActive()
        guard (0...NativeAPI.maximumInteger).contains(expectedBytes) else {
            throw DriveFailure.storageUnavailable
        }
        let capacity: Int64
        do { capacity = try availableCapacity() }
        catch { throw DriveFailure.storageUnavailable }
        guard capacity >= expectedBytes + configuration.minimumFreeBytes else {
            throw DriveFailure.lowDisk
        }
        let url = incoming.appendingPathComponent(UUID().uuidString + ".download")
        guard url.deletingLastPathComponent().standardizedFileURL == incoming else {
            throw DriveFailure.storageUnavailable
        }
        return url
    }

    /// Promotes a verified staging file within the same account directory,
    /// persists its manifest record, then removes superseded versions and
    /// trims only non-kept LRU entries.
    public func commit(_ staging: URL, item: DriveItem, keepOffline: Bool,
                       now: Date = Date()) throws -> URL {
        try requireActive()
        guard staging.deletingLastPathComponent().standardizedFileURL == incoming,
              FileManager.default.fileExists(atPath: staging.path) else {
            throw DriveFailure.storageUnavailable
        }
        let size = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == item.size else {
            try? FileManager.default.removeItem(at: staging)
            throw DriveFailure.invalidResponse
        }

        let key = Self.entryKey(itemID: item.id, etag: item.etag)
        let suffix = Self.safeExtension(item.name)
        let relative = key + suffix
        let destination = files.appendingPathComponent(relative)
        let priorForItem = manifest.entries.filter { $0.value.itemID == item.id }
        let remainsKept = keepOffline || priorForItem.contains(where: { $0.value.kept })

        do {
            try Self.protect(staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            try Self.protect(destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw DriveFailure.storageUnavailable
        }

        let previous = manifest
        manifest.entries[key] = Entry(
            itemID: item.id,
            etag: item.etag,
            relativePath: relative,
            size: item.size,
            lastAccessedAt: now,
            kept: remainsKept
        )
        var removed = [Entry]()
        for (oldKey, entry) in priorForItem where oldKey != key {
            manifest.entries[oldKey] = nil
            removed.append(entry)
        }
        removed += evictionEntries(protecting: key)
        do {
            try persist(protectingEntry: key)
        } catch {
            manifest = previous
            if previous.entries[key] == nil {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        for entry in removed { try? FileManager.default.removeItem(at: fileURL(entry)) }
        return destination
    }

    public func setKept(_ kept: Bool, for item: DriveItem) throws {
        try requireActive()
        let key = Self.entryKey(itemID: item.id, etag: item.etag)
        let previous = manifest
        if kept {
            guard var entry = manifest.entries[key] else { throw DriveFailure.notFound }
            entry.kept = true
            manifest.entries[key] = entry
        } else {
            let matches = manifest.entries.filter { $0.value.itemID == item.id }
            for (entryKey, var entry) in matches {
                entry.kept = false
                manifest.entries[entryKey] = entry
            }
        }
        var removed = [Entry]()
        do {
            if !kept { removed = evictionEntries(protecting: nil) }
            try persist(protectingEntry: kept ? key : nil)
        } catch {
            manifest = previous
            throw error
        }
        for entry in removed { try? FileManager.default.removeItem(at: fileURL(entry)) }
    }

    public func releasePreview() throws {
        try trim()
    }

    public func trim() throws {
        try requireActive()
        let previous = manifest
        let removed = evictionEntries(protecting: nil)
        do { try persist() }
        catch { manifest = previous; throw error }
        for entry in removed { try? FileManager.default.removeItem(at: fileURL(entry)) }
    }

    /// Marks this object unusable and removes its account namespace. Session
    /// teardown additionally calls `wipeAll`, which removes the whole v1 root.
    public func withdraw() throws {
        guard !withdrawn else { return }
        withdrawn = true
        manifest = Manifest()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// Sign-out is a privacy boundary, not a cache transaction. It removes all
    /// account namespaces and old tombstones best-effort and never blocks the
    /// session from ending.
    public static func wipeAll() {
        let root = URL.applicationSupportDirectory
            .appendingPathComponent("AtumDrive", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    private func evictionEntries(protecting protectedKey: String?) -> [Entry] {
        var total = manifest.entries.values.filter { !$0.kept }.reduce(Int64(0)) {
            $0 + $1.size
        }
        guard total > configuration.evictableBudgetBytes else { return [] }
        let candidates = manifest.entries
            .filter { !$0.value.kept && $0.key != protectedKey }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        var removed = [Entry]()
        for (key, entry) in candidates where total > configuration.evictableBudgetBytes {
            manifest.entries[key] = nil
            total -= entry.size
            removed.append(entry)
        }
        return removed
    }

    private func fileURL(_ entry: Entry) throws -> URL {
        guard !entry.relativePath.contains("/"), !entry.relativePath.contains("\\"),
              !entry.relativePath.hasPrefix(".") else {
            throw DriveFailure.storageUnavailable
        }
        let url = files.appendingPathComponent(entry.relativePath)
        guard url.deletingLastPathComponent().standardizedFileURL == files else {
            throw DriveFailure.storageUnavailable
        }
        return url
    }

    private func persist(protectingPage: String? = nil,
                         protectingEntry: String? = nil) throws {
        let previous = manifest
        let removed: [Entry]
        do {
            removed = try Self.enforceLimits(
                manifest: &manifest,
                configuration: configuration,
                protectingPage: protectingPage,
                protectingEntry: protectingEntry
            )
            try Self.write(manifest, to: manifestURL,
                           maximumBytes: configuration.maxManifestBytes)
        } catch let failure as DriveFailure {
            manifest = previous
            throw failure
        } catch {
            manifest = previous
            throw DriveFailure.storageUnavailable
        }
        for entry in removed { try? FileManager.default.removeItem(at: fileURL(entry)) }
    }

    private func requireActive() throws {
        if withdrawn { throw DriveFailure.storageUnavailable }
    }

    private static func entryKey(itemID: String, etag: String) -> String {
        let value = Data((itemID + "\u{0}" + etag).utf8)
        return SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard (1...16).contains(ext.count),
              ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return ""
        }
        return "." + ext
    }

    private static func validate(_ manifest: Manifest) throws {
        guard manifest.version == 2 else { throw DriveFailure.storageUnavailable }
        for (key, entry) in manifest.entries {
            guard key == entryKey(itemID: entry.itemID, etag: entry.etag),
                  entry.relativePath.hasPrefix(key),
                  !entry.relativePath.contains("/"), !entry.relativePath.contains("\\"),
                  (0...NativeAPI.maximumInteger).contains(entry.size) else {
                throw DriveFailure.storageUnavailable
            }
        }
        guard manifest.pages.allSatisfy({ $0.key == $0.value.page.parentID }) else {
            throw DriveFailure.storageUnavailable
        }
    }

    private static func write(_ manifest: Manifest, to url: URL,
                              maximumBytes: Int) throws {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= maximumBytes else { throw DriveFailure.storageUnavailable }
        try data.write(to: url, options: [.atomic])
        try protect(url)
    }

    private static func enforceLimits(manifest: inout Manifest,
                                      configuration: Configuration,
                                      protectingPage: String?,
                                      protectingEntry: String?) throws -> [Entry] {
        while manifest.pages.count > configuration.maxPageCount
                || manifest.pages.values.reduce(0, { $0 + $1.page.items.count })
                    > configuration.maxCachedItems {
            guard let victim = manifest.pages
                .filter({ $0.key != protectingPage })
                .min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                throw DriveFailure.storageUnavailable
            }
            manifest.pages[victim.key] = nil
        }

        var removed = [Entry]()
        func removeOldestEvictable() -> Bool {
            guard let victim = manifest.entries
                .filter({ !$0.value.kept && $0.key != protectingEntry })
                .min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) else {
                return false
            }
            manifest.entries[victim.key] = nil
            removed.append(victim.value)
            return true
        }
        while manifest.entries.count > configuration.maxEntryCount {
            guard removeOldestEvictable() else { throw DriveFailure.storageUnavailable }
        }

        while try JSONEncoder().encode(manifest).count > configuration.maxManifestBytes {
            if let victim = manifest.pages
                .filter({ $0.key != protectingPage })
                .min(by: { $0.value.lastAccessedAt < $1.value.lastAccessedAt }) {
                manifest.pages[victim.key] = nil
            } else if !removeOldestEvictable() {
                throw DriveFailure.storageUnavailable
            }
        }
        return removed
    }

    private static func startupSweep(root: URL, files: URL, incoming: URL,
                                     manifest: inout Manifest) throws -> Bool {
        var changed = false
        let manager = FileManager.default
        let accountRoot = root.deletingLastPathComponent()
        if accountRoot.lastPathComponent == "v1",
           let children = try? manager.contentsOfDirectory(
                at: accountRoot,
                includingPropertiesForKeys: nil
           ) {
            for child in children where child.lastPathComponent.hasPrefix(".withdrawn-") {
                    try? manager.removeItem(at: child)
            }
        }
        if let staging = try? manager.contentsOfDirectory(at: incoming,
                                                          includingPropertiesForKeys: nil) {
            for item in staging { try? manager.removeItem(at: item) }
        }

        let referenced = Set(manifest.entries.values.map(\.relativePath))
        if let stored = try? manager.contentsOfDirectory(at: files,
                                                         includingPropertiesForKeys: nil) {
            for item in stored where !referenced.contains(item.lastPathComponent) {
                try? manager.removeItem(at: item)
            }
        }
        for (key, entry) in manifest.entries {
            let url = files.appendingPathComponent(entry.relativePath)
            let actual = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if actual.map(Int64.init) != entry.size {
                manifest.entries[key] = nil
                changed = true
            }
        }
        return changed
    }

    private static func prepareDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try protect(url)
        } catch {
            throw DriveFailure.storageUnavailable
        }
    }

    private static func protect(_ input: URL) throws {
        var url = input
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}
