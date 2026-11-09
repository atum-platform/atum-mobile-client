import Foundation

/// The encrypted SDK owns database contents and locking. This type only gates
/// directory creation/presence before the SDK can silently create missing files.
public struct MatrixStorePaths: Sendable {
    public let data, cache: URL
}

public struct MatrixStoreDirectory: Sendable {
    private let root: URL
    public init() throws {
        #if os(iOS)
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.atum.mobile.shared") else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        root = group.appendingPathComponent("AtumMatrix", isDirectory: true)
        #else
        throw MatrixCustodyFailure.storageUnavailable
        #endif
    }
    init(root: URL) { self.root = root }

    /// First creation is explicit and exclusive. An interrupted directory is
    /// preserved, including empty/partial files; it cannot be silently retried.
    public func createPrepared(generation: UUID) throws -> MatrixStorePaths {
        do {
            let folder = location(generation)
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw MatrixCustodyFailure.interruptedPreparation }
            if !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: attributes)
                var value = root; var resources = URLResourceValues(); resources.isExcludedFromBackup = true
                try value.setResourceValues(resources)
            }
            try check(root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: attributes)
            let paths = MatrixStorePaths(data: folder.appendingPathComponent("data", isDirectory: true),
                                         cache: folder.appendingPathComponent("cache", isDirectory: true))
            try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: false, attributes: attributes)
            try FileManager.default.createDirectory(at: paths.cache, withIntermediateDirectories: false, attributes: attributes)
            return paths
        } catch let failure as MatrixCustodyFailure { throw failure }
        catch { throw MatrixCustodyFailure.storageUnavailable }
    }
    /// No mkdir/open/repair. Both authoritative state and crypto files must be
    /// present before opening a ready store. No SQL reads or second store lock.
    public func requireExisting(generation: UUID) throws -> MatrixStorePaths {
        do {
            try check(root); try check(location(generation))
            let paths = MatrixStorePaths(data: location(generation).appendingPathComponent("data", isDirectory: true),
                                         cache: location(generation).appendingPathComponent("cache", isDirectory: true))
            try check(paths.data); try check(paths.cache)
            for name in ["matrix-sdk-state.sqlite3", "matrix-sdk-crypto.sqlite3"] {
                let a = try FileManager.default.attributesOfItem(atPath: paths.data.appendingPathComponent(name).path)
                guard a[.type] as? FileAttributeType == .typeRegular,
                      (a[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw MatrixCustodyFailure.recoveryRequired }
                #if os(iOS)
                guard a[.protectionKey] as? String == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
                    throw MatrixCustodyFailure.recoveryRequired
                }
                #endif
            }
            return paths
        } catch { throw MatrixCustodyFailure.recoveryRequired }
    }

    func quarantineForSignOut(generation: UUID, transactionID: UUID) throws {
        do {
            let active = location(generation)
            let target = signOutLocation(transactionID)
            if !FileManager.default.fileExists(atPath: active.path),
               FileManager.default.fileExists(atPath: target.path) { return }
            _ = try requireExisting(generation: generation)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw MatrixCustodyFailure.storageUnavailable
            }
            let folder = target.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: attributes)
            }
            try FileManager.default.moveItem(at: active, to: target)
            guard !FileManager.default.fileExists(atPath: active.path),
                  FileManager.default.fileExists(atPath: target.path) else {
                throw MatrixCustodyFailure.storageUnavailable
            }
        } catch let failure as MatrixCustodyFailure { throw failure }
        catch { throw MatrixCustodyFailure.storageUnavailable }
    }

    func restoreAfterFailedSignOut(generation: UUID, transactionID: UUID) throws {
        do {
            let active = location(generation)
            let source = signOutLocation(transactionID)
            if FileManager.default.fileExists(atPath: active.path),
               !FileManager.default.fileExists(atPath: source.path) {
                _ = try requireExisting(generation: generation)
                return
            }
            guard !FileManager.default.fileExists(atPath: active.path),
                  FileManager.default.fileExists(atPath: source.path) else {
                throw MatrixCustodyFailure.storageUnavailable
            }
            try FileManager.default.moveItem(at: source, to: active)
            _ = try requireExisting(generation: generation)
        } catch let failure as MatrixCustodyFailure { throw failure }
        catch { throw MatrixCustodyFailure.storageUnavailable }
    }

    func purgeSignOutQuarantine(transactionID: UUID) throws {
        do {
            let target = signOutLocation(transactionID)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.removeItem(at: target)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw MatrixCustodyFailure.storageUnavailable
            }
        } catch { throw MatrixCustodyFailure.storageUnavailable }
    }

    func hasActiveStore(generation: UUID) -> Bool {
        FileManager.default.fileExists(atPath: location(generation).path)
    }

    private func location(_ generation: UUID) -> URL { root.appendingPathComponent(generation.uuidString, isDirectory: true) }
    private func signOutLocation(_ id: UUID) -> URL {
        root.appendingPathComponent("signed-out", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private var attributes: [FileAttributeKey: Any] {
        var values: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        values[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return values
    }
    private func check(_ directory: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              (a[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw MatrixCustodyFailure.recoveryRequired
        }
        #if os(iOS)
        guard a[.protectionKey] as? String == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else {
            throw MatrixCustodyFailure.recoveryRequired
        }
        #endif
    }
}
