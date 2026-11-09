import Foundation
import Security

/// Device-only custody for the third, Drive-specific OAuth grant. The record
/// is bound to the current installation and the already verified account
/// subject; it cannot address Matrix or domain credentials.
@MainActor public final class OIDCDriveKeychain: OIDCGrantStore {
    public static let accessGroup = OIDCDomainKeychain.accessGroup
    static let service = "com.atum.mobile.oidc.drive.v1"

    private let generation: UUID
    private let account: OIDCRestoredAccount
    private let metadata: MASMetadata
    private let operations: any OIDCKeychainOperations

    public convenience init(generation: UUID, account: OIDCRestoredAccount,
                            metadata: MASMetadata) {
        self.init(generation: generation, account: account, metadata: metadata,
                  operations: SystemOIDCKeychain())
    }

    init(generation: UUID, account: OIDCRestoredAccount, metadata: MASMetadata,
         operations: any OIDCKeychainOperations) {
        self.generation = generation
        self.account = account
        self.metadata = metadata
        self.operations = operations
    }

    public func load() throws -> OIDCStoredGrant? {
        var query = match
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        let (status, result) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              attributes[kSecAttrService as String] as? String == Self.service,
              attributes[kSecAttrAccount as String] as? String == generation.uuidString,
              attributes[kSecAttrAccessGroup as String] as? String == Self.accessGroup,
              attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false,
              let data = attributes[kSecValueData as String] as? Data,
              data.count <= 65_536 else {
            throw OIDCGrantFailure.storageUnavailable
        }
        do {
            let record = try JSONDecoder().decode(OIDCStoredGrant.self, from: data)
            try validate(record)
            return record
        } catch {
            throw OIDCGrantFailure.storageUnavailable
        }
    }

    public func save(_ record: OIDCStoredGrant) throws {
        try validate(record)
        let existing = try load()
        guard existing.map({ $0.subject == record.subject }) ?? true else {
            throw OIDCGrantFailure.storageUnavailable
        }
        let data: Data
        do { data = try JSONEncoder().encode(record) }
        catch { throw OIDCGrantFailure.storageUnavailable }
        guard data.count <= 65_536 else { throw OIDCGrantFailure.storageUnavailable }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status: OSStatus
        if existing == nil {
            status = operations.add(match.merging(attributes) { _, value in value })
        } else {
            status = operations.update(match, attributes: attributes)
        }
        guard status == errSecSuccess, try load() == record else {
            throw OIDCGrantFailure.storageUnavailable
        }
    }

    func requireEmptyForSignIn() throws {
        guard try load() == nil else { throw OIDCGrantFailure.reauthenticationRequired }
    }

    public func resume(installation marker: OIDCInstallationMarker) throws -> OIDCDriveResume {
        guard let installation = try marker.load(),
              installation.generation == generation,
              let record = try load(), record.phase == .ready else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        let store = ResumeStore(keychain: self, marker: marker, installation: installation)
        return OIDCDriveResume(store: store, metadata: metadata, record: record,
                               account: account)
    }

    /// Makes the exact grant unreachable before its optional remote
    /// revocation. The returned record is secret-bearing and must remain only
    /// in the caller's in-memory cleanup task.
    public func withdraw() throws -> OIDCStoredGrant? {
        let record = try load()
        let status = operations.delete(match)
        guard status == errSecSuccess || status == errSecItemNotFound,
              try load() == nil else {
            throw OIDCGrantFailure.storageUnavailable
        }
        return record
    }

    /// Forced session replacement may lose the bound domain ticket before it
    /// can reconstruct this typed store. Delete only the exact Drive service
    /// and installation generation; Matrix/domain grants remain untouched.
    public static func forceWithdraw(generation: UUID) throws {
        try forceWithdraw(generation: generation, operations: SystemOIDCKeychain())
    }

    static func forceWithdraw(generation: UUID,
                              operations: any OIDCKeychainOperations) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: generation.uuidString,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = operations.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OIDCGrantFailure.storageUnavailable
        }
    }

    private var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: generation.uuidString,
         kSecAttrAccessGroup as String: Self.accessGroup,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private func validate(_ record: OIDCStoredGrant) throws {
        let safe: (String, Int) -> Bool = { value, maximum in
            (1...maximum).contains(value.utf8.count)
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard record.generation == generation,
              record.issuer == metadata.issuer,
              record.clientID == MASPublicClients.drive,
              record.subject == account.subject,
              safe(record.subject, 1_024),
              safe(record.accessToken, 8_192),
              safe(record.refreshToken, 8_192),
              !record.accessToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !record.refreshToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              record.expiresAt.timeIntervalSince1970.isFinite,
              record.expiresAt.timeIntervalSince1970 >= 0,
              record.expiresAt.timeIntervalSince1970 < Double(NativeAPI.maximumInteger),
              (record.phase == .ready) == (record.attempt == nil) else {
            throw OIDCGrantFailure.storageUnavailable
        }
    }

    @MainActor private final class ResumeStore: OIDCGrantStore {
        let keychain: OIDCDriveKeychain
        let marker: OIDCInstallationMarker
        let installation: OIDCInstallation

        init(keychain: OIDCDriveKeychain, marker: OIDCInstallationMarker,
             installation: OIDCInstallation) {
            self.keychain = keychain
            self.marker = marker
            self.installation = installation
        }

        func load() throws -> OIDCStoredGrant? {
            guard try marker.load() == installation else {
                throw OIDCGrantFailure.reauthenticationRequired
            }
            return try keychain.load()
        }

        func save(_ record: OIDCStoredGrant) throws {
            _ = try load()
            try keychain.save(record)
        }
    }
}

@MainActor public struct OIDCDriveResume: CustomStringConvertible, CustomDebugStringConvertible {
    let store: any OIDCGrantStore
    let metadata: MASMetadata
    let record: OIDCStoredGrant
    public let account: OIDCRestoredAccount

    fileprivate init(store: any OIDCGrantStore, metadata: MASMetadata,
                     record: OIDCStoredGrant, account: OIDCRestoredAccount) {
        self.store = store
        self.metadata = metadata
        self.record = record
        self.account = account
    }

    public nonisolated var description: String { "OIDCDriveResume(<secrets redacted>)" }
    public nonisolated var debugDescription: String { description }
}
