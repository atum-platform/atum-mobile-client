import Foundation

/// Nonsecret sandbox provenance. Never created by reading surviving Keychain.
/// The explicit sign-in/recovery coordinator owns initial creation.
public struct OIDCInstallation: Sendable, Equatable {
    public let id, generation: UUID
    init(id: UUID, generation: UUID) { self.id = id; self.generation = generation }
}

@MainActor public final class OIDCInstallationMarker {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("installation-v1.json") }
    public convenience init() {
        self.init(directory: URL.applicationSupportDirectory.appendingPathComponent("AtumIdentity", isDirectory: true))
    }
    init(directory: URL) { self.directory = directory }
    #if DEBUG
    /// Fixed diagnostic namespace only; never addresses the product marker.
    public convenience init(probeID: UUID) {
        self.init(directory: URL.documentsDirectory.appendingPathComponent("P2AccountResume", isDirectory: true)
            .appendingPathComponent(probeID.uuidString, isDirectory: true))
    }
    #endif

    public func load() throws -> OIDCInstallation? {
        do {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
                throw OIDCGrantFailure.storageUnavailable
            }
            #if os(iOS)
            guard attributes[.protectionKey] as? String == FileProtectionType.complete.rawValue else {
                throw OIDCGrantFailure.storageUnavailable
            }
            #endif
            let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: file))
            guard value.version == 1 else { throw OIDCGrantFailure.storageUnavailable }
            return OIDCInstallation(id: value.id, generation: value.generation)
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    /// Explicit creation never replaces a surviving marker or touches Keychain.
    /// The caller must first resolve any surviving Matrix identity/recovery data.
    public func createForExplicitSignIn(generation: UUID) throws -> OIDCInstallation {
        do {
            guard try load() == nil else { throw OIDCGrantFailure.storageUnavailable }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var location = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            let installation = OIDCInstallation(id: UUID(), generation: generation)
            let data = try JSONEncoder().encode(Value(version: 1, id: installation.id, generation: generation))
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard try load() == installation else { throw OIDCGrantFailure.storageUnavailable }
            return installation
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    /// W4 E3 (coordinator decision 11): moves the marker aside for an explicit
    /// sign-in again, never deleting it: `archived/installation-<id>.json` in
    /// the same folder (excluded from backup, the file keeps its protection).
    /// Reads nothing, so a malformed marker moves too. True when one moved;
    /// false when there was none. Never replaces an archived file.
    public func archiveForSignInAgain(id: UUID) throws -> Bool {
        do {
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            let folder = directory.appendingPathComponent("archived", isDirectory: true)
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let target = folder.appendingPathComponent("installation-\(id.uuidString).json")
            guard !FileManager.default.fileExists(atPath: target.path) else { throw OIDCGrantFailure.storageUnavailable }
            try FileManager.default.moveItem(at: file, to: target)
            guard !FileManager.default.fileExists(atPath: file.path),
                  FileManager.default.fileExists(atPath: target.path) else { throw OIDCGrantFailure.storageUnavailable }
            return true
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    /// Exact marker removal. Recovery/Matrix cleanup remains the caller's
    /// separate explicit custody decision; this method cannot remove secrets.
    public func remove(_ installation: OIDCInstallation) throws {
        do {
            guard try load() == installation else { throw OIDCGrantFailure.storageUnavailable }
            try FileManager.default.removeItem(at: file)
            guard try load() == nil else { throw OIDCGrantFailure.storageUnavailable }
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    func quarantineForSignOut(_ installation: OIDCInstallation, transactionID: UUID) throws {
        do {
            let target = signOutFile(transactionID)
            if !FileManager.default.fileExists(atPath: file.path),
               FileManager.default.fileExists(atPath: target.path) { return }
            guard try load() == installation,
                  !FileManager.default.fileExists(atPath: target.path) else {
                throw OIDCGrantFailure.storageUnavailable
            }
            let folder = target.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.moveItem(at: file, to: target)
            guard !FileManager.default.fileExists(atPath: file.path),
                  FileManager.default.fileExists(atPath: target.path) else {
                throw OIDCGrantFailure.storageUnavailable
            }
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    func restoreAfterFailedSignOut(_ installation: OIDCInstallation, transactionID: UUID) throws {
        do {
            let source = signOutFile(transactionID)
            if FileManager.default.fileExists(atPath: file.path),
               !FileManager.default.fileExists(atPath: source.path),
               try load() == installation { return }
            guard !FileManager.default.fileExists(atPath: file.path),
                  FileManager.default.fileExists(atPath: source.path) else {
                throw OIDCGrantFailure.storageUnavailable
            }
            try FileManager.default.moveItem(at: source, to: file)
            guard try load() == installation else { throw OIDCGrantFailure.storageUnavailable }
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    func purgeSignOutQuarantine(transactionID: UUID) throws {
        do {
            let target = signOutFile(transactionID)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.removeItem(at: target)
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw OIDCGrantFailure.storageUnavailable
            }
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    func hasActiveInstallationFile() -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private func signOutFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("signed-out", isDirectory: true)
            .appendingPathComponent("installation-\(id.uuidString).json")
    }
    private struct Value: Codable { let version: Int; let id, generation: UUID }
}
