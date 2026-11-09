import Foundation
import Security

/// Concrete main-private storage, not identity verification. Only the main app
/// has this access group. No recovery/Matrix record is addressed by this type.
@MainActor public final class OIDCDomainKeychain: OIDCGrantStore {
    public static let accessGroup = "7D5FC62RXD.com.atum.mobile"
    static let service = "com.atum.mobile.oidc.domain.v1"
    private let generation: UUID
    private let issuer, clientID, matrixClientID: String
    private let operations: any OIDCKeychainOperations

    public convenience init(generation: UUID, clients: MASPublicClients, metadata: MASMetadata) {
        self.init(generation: generation, clients: clients, metadata: metadata, operations: SystemOIDCKeychain())
    }
    init(generation: UUID, clients: MASPublicClients, metadata: MASMetadata, operations: any OIDCKeychainOperations) {
        self.generation = generation; issuer = metadata.issuer; clientID = clients.domain
        matrixClientID = clients.matrix; self.metadata = metadata; self.operations = operations
    }
    private let metadata: MASMetadata

    /// Fresh-install preflight. A domain grant from any prior installation is
    /// an explicit recovery/sign-out decision; a new browser flow must not be
    /// the first operation that discovers or overwrites it.
    public func requireAbsentForExplicitSignIn() throws {
        var query = match
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        let (status, _) = operations.copy(query)
        guard status == errSecItemNotFound else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
    }

    func requireEmptyForSignIn(installation: OIDCInstallation, clients: MASPublicClients, metadata: MASMetadata) throws {
        guard generation == installation.generation, issuer == metadata.issuer,
              clientID == clients.domain, matrixClientID == clients.matrix,
              try loadEnvelope() == nil else { throw OIDCGrantFailure.reauthenticationRequired }
    }

    public func load() throws -> OIDCStoredGrant? {
        let envelope = try loadEnvelope()
        guard envelope?.revoking != true else { throw OIDCGrantFailure.reauthenticationRequired }
        return envelope?.grant
    }
    private func loadEnvelope() throws -> Envelope? {
        var query = match
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        let (status, result) = operations.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              attributes[kSecAttrService as String] as? String == Self.service,
              attributes[kSecAttrAccount as String] as? String == generation.uuidString,
              attributes[kSecAttrAccessGroup as String] as? String == Self.accessGroup,
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false,
              let data = attributes[kSecValueData as String] as? Data, data.count <= 65_536 else {
            throw OIDCGrantFailure.storageUnavailable
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.revoking != true || envelope.binding == nil else { throw OIDCGrantFailure.storageUnavailable }
            try validate(envelope.grant)
            if let binding = envelope.binding {
                guard binding.generation == generation, binding.issuer == issuer,
                      binding.subject == envelope.grant.subject, binding.domainClientID == clientID,
                      binding.matrixClientID == matrixClientID else { throw OIDCGrantFailure.storageUnavailable }
            }
            return envelope
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }

    public func save(_ record: OIDCStoredGrant) throws {
        try validate(record)
        let existing = try loadEnvelope()
        guard existing?.revoking != true else { throw OIDCGrantFailure.reauthenticationRequired }
        // Rotation preserves the verified binding; raw storage cannot create,
        // erase or switch its subject/principal/installation provenance.
        guard existing?.binding.map({ $0.subject == record.subject }) ?? true else { throw OIDCGrantFailure.storageUnavailable }
        try persist(Envelope(version: 1, grant: record, binding: existing?.binding), replacing: existing != nil)
    }

    public func bind(_ verified: OIDCAccountBinding, domainGrant: OIDCVerifiedGrant, installation: OIDCInstallation) throws {
        guard let existing = try loadEnvelope(), existing.revoking != true, existing.grant.phase == .ready,
              installation.generation == generation, verified.issuer == issuer,
              verified.matrixClientID == matrixClientID, verified.domainClientID == clientID,
              domainGrant.identity.issuer == issuer, domainGrant.identity.subject == verified.subject,
              domainGrant.identity.audience == clientID,
              domainGrant.response.accessToken == existing.grant.accessToken,
              domainGrant.response.refreshToken == existing.grant.refreshToken,
              verified.subject == existing.grant.subject else { throw OIDCGrantFailure.invalidIdentity }
        let binding = BoundAccount(installationID: installation.id, generation: generation, issuer: verified.issuer,
            subject: verified.subject, principal: verified.principal, matrixClientID: matrixClientID, domainClientID: clientID)
        guard existing.binding == nil || existing.binding == binding else { throw OIDCGrantFailure.invalidIdentity }
        if existing.binding == binding { return }
        try persist(Envelope(version: 1, grant: existing.grant, binding: binding), replacing: true)
    }

    /// Returns local provenance, never a new VerifiedOIDCIdentity. A fresh
    /// install, unbound fixture record or interrupted spend cannot resume.
    public func resume(installation marker: OIDCInstallationMarker) throws -> OIDCDomainResume {
        guard let installation = try marker.load(), installation.generation == generation,
              let envelope = try loadEnvelope(), envelope.revoking != true else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        guard envelope.grant.phase == .ready else {
            throw OIDCGrantFailure.refreshInterrupted
        }
        guard
              let binding = envelope.binding, binding.installationID == installation.id else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        let store = ResumeStore(keychain: self, marker: marker, installation: installation, binding: binding)
        return OIDCDomainResume(store: store, metadata: metadata, record: envelope.grant,
            account: OIDCRestoredAccount(issuer: binding.issuer, subject: binding.subject, principal: binding.principal))
    }

    private func persist(_ envelope: Envelope, replacing: Bool) throws {
        let data: Data
        do { data = try JSONEncoder().encode(envelope) }
        catch { throw OIDCGrantFailure.storageUnavailable }
        guard data.count <= 65_536 else { throw OIDCGrantFailure.storageUnavailable }
        // First inspect any existing item. A weak/foreign/malformed record is
        // preserved for recovery, never silently upgraded or overwritten.
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status: OSStatus
        if replacing {
            status = operations.update(match, attributes: attributes)
        } else {
            status = operations.add(match.merging(attributes) { _, value in value })
        }
        // Duplicate/add races or unavailable/locked storage are not retried.
        // No delete-before-replace and no new token released on failed readback.
        guard status == errSecSuccess, try loadEnvelope() == envelope else { throw OIDCGrantFailure.storageUnavailable }
    }

    /// Local removal of this exact domain generation only. Callers own remote
    /// revocation and the separate recovery-key sign-out decision.
    public func remove() throws {
        guard try loadEnvelope()?.revoking != true else { throw OIDCGrantFailure.reauthenticationRequired }
        try deleteRecord()
    }

    /// An interrupted initial domain flow remains unbound in this existing
    /// main-private record. Poison it before network cleanup; later instances
    /// cannot expose, rotate or bind it. A failed acknowledgement retains it
    /// for explicit replay after relaunch, using the same installation generation.
    public func revokeUnbound(using transport: MASHTTP) async throws {
        try await revokeUnbound(using: transport, matching: nil)
    }
    /// Failed initial installation may observe another attempt's record after
    /// its earlier empty-store check. Cleanup cannot claim that record merely
    /// because it has the same configured generation/client.
    func revokeUnbound(using transport: MASHTTP, matching grant: OIDCVerifiedGrant?) async throws {
        guard let current = try loadEnvelope() else { return }
        if let grant {
            guard current.grant.issuer == grant.identity.issuer, current.grant.clientID == grant.identity.audience,
                  current.grant.subject == grant.identity.subject,
                  current.grant.accessToken == grant.response.accessToken,
                  current.grant.refreshToken == grant.response.refreshToken else { return }
        }
        guard current.binding == nil else { throw OIDCGrantFailure.invalidIdentity }
        let pending = Envelope(version: 1, grant: current.grant, binding: nil, revoking: true)
        if current != pending { try persist(pending, replacing: true) }
        try await transport.revokeDomain(pending.grant, metadata: metadata)
        guard try loadEnvelope() == pending else { throw OIDCGrantFailure.storageUnavailable }
        try deleteRecord()
    }

    private func deleteRecord() throws {
        let status = operations.delete(match)
        guard status == errSecSuccess || status == errSecItemNotFound,
              try load() == nil else { throw OIDCGrantFailure.storageUnavailable }
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
            (1...maximum).contains(value.utf8.count) && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard record.generation == generation, record.issuer == issuer, record.clientID == clientID,
              safe(record.subject, 1024), safe(record.accessToken, 8192), safe(record.refreshToken, 8192),
              !record.accessToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !record.refreshToken.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              record.expiresAt.timeIntervalSince1970.isFinite, record.expiresAt.timeIntervalSince1970 >= 0,
              record.expiresAt.timeIntervalSince1970 < Double(NativeAPI.maximumInteger),
              (record.phase == .ready) == (record.attempt == nil) else { throw OIDCGrantFailure.storageUnavailable }
    }
    private struct Envelope: Codable, Equatable {
        let version: Int
        let grant: OIDCStoredGrant
        let binding: BoundAccount?
        var revoking: Bool? = nil // Absent in previous v1 records; no migration/write on read.
    }
    private struct BoundAccount: Codable, Equatable {
        let installationID, generation: UUID
        let issuer, subject: String
        let principal: NativeID
        let matrixClientID, domainClientID: String
    }
    @MainActor private final class ResumeStore: OIDCGrantStore {
        let keychain: OIDCDomainKeychain
        let marker: OIDCInstallationMarker
        let installation: OIDCInstallation
        let binding: BoundAccount
        init(keychain: OIDCDomainKeychain, marker: OIDCInstallationMarker, installation: OIDCInstallation, binding: BoundAccount) {
            self.keychain = keychain; self.marker = marker; self.installation = installation; self.binding = binding
        }
        func load() throws -> OIDCStoredGrant? {
            guard try marker.load() == installation, let envelope = try keychain.loadEnvelope(),
                  envelope.revoking != true, envelope.binding == binding else { throw OIDCGrantFailure.reauthenticationRequired }
            return envelope.grant
        }
        func save(_ record: OIDCStoredGrant) throws {
            _ = try load() // Recheck installation/binding for every mutation.
            try keychain.save(record)
        }
    }
}

public struct OIDCRestoredAccount: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let issuer, subject: String
    public let principal: NativeID
    fileprivate init(issuer: String, subject: String, principal: NativeID) { self.issuer = issuer; self.subject = subject; self.principal = principal }
    public var description: String { "OIDCRestoredAccount(<identity redacted>)" }
    public var debugDescription: String { description }
    public func reconcile(_ me: OIDCMe) throws {
        guard me.issuer == issuer, me.subject == subject, me.principal == principal else { throw OIDCFailure.subjectMismatch }
    }
    public func reconcile(matrix: MatrixCustodyTicket) throws {
        guard matrix.envelope.issuer == issuer,
              matrix.envelope.subject == subject else { throw OIDCFailure.subjectMismatch }
    }
}

/// Opaque ticket minted only by the concrete private Keychain after checking
/// verified binding and current sandbox marker. It is not Decodable.
@MainActor public struct OIDCDomainResume: CustomStringConvertible, CustomDebugStringConvertible {
    let store: any OIDCGrantStore
    let metadata: MASMetadata
    let record: OIDCStoredGrant
    public let account: OIDCRestoredAccount
    fileprivate init(store: any OIDCGrantStore, metadata: MASMetadata, record: OIDCStoredGrant, account: OIDCRestoredAccount) {
        self.store = store; self.metadata = metadata; self.record = record; self.account = account
    }
    public nonisolated var description: String { "OIDCDomainResume(<secrets redacted>)" }
    public nonisolated var debugDescription: String { description }
}

// Narrow seam for exercising Security query attributes and failure ordering.
// Production always selects Apple's APIs; no alternate storage implementation.
@MainActor protocol OIDCKeychainOperations {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
@MainActor final class SystemOIDCKeychain: OIDCKeychainOperations {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
