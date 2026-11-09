import Foundation
import Security

public enum MatrixCustodyFailure: Error, Equatable {
    case storageUnavailable, recoveryRequired, invalidIdentity, interruptedPreparation, refreshRequired, expired
}

/// Minted only by the bounded authenticated HTTP adapter. It retains the exact
/// verified grant response, so callers cannot substitute a different token pair.
public struct MatrixAuthenticatedDevice: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let homeserver = "https://chat.atumplatform.com/"
    static let whoamiURL = URL(string: homeserver + "_matrix/client/v3/account/whoami")!
    let grant: OIDCVerifiedGrant
    public let userID, deviceID: String
    static func delivered(_ data: Data, grant: OIDCVerifiedGrant, requested: String) throws -> Self {
        do {
            let payload = try NativeAPI.decode(Whoami.self, from: data)
            guard payload.device == requested, grant.requestedDeviceID == requested else { throw OIDCFailure.deviceMismatch }
            return Self(grant: grant, userID: payload.user, deviceID: payload.device)
        } catch let error as OIDCFailure { throw error }
        catch { throw MatrixCustodyFailure.invalidIdentity }
    }
    private struct Whoami: Decodable {
        let user, device: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            user = try c.string("user_id", minimum: 4, maximum: 1024)
            device = try c.string("device_id", minimum: 1, maximum: 255)
            guard user.hasPrefix("@"), user.dropFirst().contains(":"),
                  !user.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  device.range(of: "\\A[A-Za-z0-9._-]{1,255}\\z", options: .regularExpression) != nil,
                  (try c.optional("is_guest", as: Bool.self)) != true else { throw OIDCFailure.deviceMismatch }
        }
    }
    public var description: String { "MatrixAuthenticatedDevice(<account and grant redacted>)" }
    public var debugDescription: String { description }
}

/// Storage data is not a new authenticated identity. SDK adapters consume it
/// only through the prepared/ready tickets and recheck the local device keys.
public struct MatrixStoredSession: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID, deviceID, homeserver, clientID: String
    public let accessToken, refreshToken: String
    public let expiresAt: Date
    public var description: String { "MatrixStoredSession(<secrets and identity redacted>)" }
    public var debugDescription: String { description }
}

/// Main-process writer. The shared group holds only Matrix credentials/store
/// passphrase; no domain, recovery or deletion material enters this envelope.
/// Refresh journaling preserves the same identity, store and device keys.
@MainActor public final class MatrixSessionKeychain {
    public static let accessGroup = MatrixCustodyRecord.accessGroup
    private let generation: UUID
    private let clients: MASPublicClients
    private let metadata: MASMetadata
    private let operations: any OIDCKeychainOperations
    public convenience init(generation: UUID, clients: MASPublicClients, metadata: MASMetadata) {
        self.init(generation: generation, clients: clients, metadata: metadata, operations: SystemOIDCKeychain())
    }
    init(generation: UUID, clients: MASPublicClients, metadata: MASMetadata, operations: any OIDCKeychainOperations) {
        self.generation = generation; self.clients = clients; self.metadata = metadata; self.operations = operations
    }

    /// Persist/readback before any SDK store creation. Never overwrites a
    /// surviving record, even one with an interrupted or malformed envelope.
    public func prepare(device: MatrixAuthenticatedDevice, marker: OIDCInstallationMarker, requestStartedAt: Date) throws -> MatrixCustodyTicket {
        let grant = device.grant
        guard let installation = try marker.load() else { throw MatrixCustodyFailure.recoveryRequired }
        guard grant.identity.issuer == metadata.issuer, installation.generation == generation, grant.identity.isAuthorizationCode,
              grant.identity.audience == clients.matrix, grant.requestedDeviceID == device.deviceID else {
            throw MatrixCustodyFailure.invalidIdentity
        }
        let expectedScope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:" + device.deviceID
        if let scope = grant.response.scope {
            let parts = scope.split(separator: " ").map(String.init)
            guard Set(parts) == Set(expectedScope.split(separator: " ").map(String.init)), Set(parts).count == parts.count else {
                throw MatrixCustodyFailure.invalidIdentity
            }
        }
        let expiry = requestStartedAt.addingTimeInterval(Double(grant.response.expiresIn))
        guard requestStartedAt.timeIntervalSince1970.isFinite, requestStartedAt.timeIntervalSince1970 >= 0,
              expiry.timeIntervalSince1970.isFinite, expiry.timeIntervalSince1970 < Double(NativeAPI.maximumInteger),
              try load() == nil else { throw MatrixCustodyFailure.storageUnavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        let session = MatrixStoredSession(userID: device.userID, deviceID: device.deviceID,
            homeserver: MatrixAuthenticatedDevice.homeserver, clientID: clients.matrix,
            accessToken: grant.response.accessToken, refreshToken: grant.response.refreshToken, expiresAt: expiry)
        let envelope = MatrixCustodyRecord.Envelope(version: 1, installationID: installation.id, generation: generation,
            issuer: grant.identity.issuer, subject: grant.identity.subject, session: session,
            passphrase: Data(bytes).base64EncodedString(), phase: .prepared, deviceKeys: nil,
            refreshAttempt: nil)
        try persist(envelope, replacing: false)
        return MatrixCustodyTicket(envelope: envelope)
    }

    /// A prepared envelope does not permit automatic relaunch. The explicit
    /// sign-in/recovery coordinator must reconcile its original SDK identity.
    public func resume(marker: OIDCInstallationMarker) throws -> MatrixCustodyTicket {
        guard let installation = try marker.load(), installation.generation == generation, let envelope = try load(),
              envelope.installationID == installation.id else { throw MatrixCustodyFailure.recoveryRequired }
        guard envelope.phase == .ready else { throw MatrixCustodyFailure.interruptedPreparation }
        guard envelope.refreshAttempt == nil else { throw MatrixCustodyFailure.refreshRequired }
        return MatrixCustodyTicket(envelope: envelope)
    }

    /// Resumes only the original ready Matrix grant. Expiry is intentionally
    /// allowed so controlled refresh can complete before SDK construction.
    public func resumeGrantForRefresh(marker: OIDCInstallationMarker) throws -> OIDCMatrixResume {
        guard let installation = try marker.load(), installation.generation == generation,
              let envelope = try load(), envelope.installationID == installation.id,
              envelope.phase == .ready, envelope.deviceKeys != nil else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        guard envelope.refreshAttempt == nil else { throw OIDCGrantFailure.reauthenticationRequired }
        let store = RefreshStore(keychain: self, marker: marker, installation: installation)
        return OIDCMatrixResume(store: store, metadata: metadata,
                                record: Self.grantRecord(envelope),
                                expectedScope: Self.scope(deviceID: envelope.session.deviceID))
    }

    /// Called only after the SDK has restored the exact session and read actual
    /// local public keys. No keys/tokens enter ordinary files or evidence.
    public func commitPrepared(_ ticket: MatrixCustodyTicket, marker: OIDCInstallationMarker, curve25519: String, ed25519: String) throws -> MatrixCustodyTicket {
        try recheck(ticket, marker: marker)
        guard ticket.envelope.phase == .prepared,
              MatrixCustodyRecord.validKey(curve25519), MatrixCustodyRecord.validKey(ed25519) else { throw MatrixCustodyFailure.recoveryRequired }
        let old = ticket.envelope
        let ready = MatrixCustodyRecord.Envelope(version: old.version, installationID: old.installationID, generation: old.generation,
            issuer: old.issuer, subject: old.subject, session: old.session, passphrase: old.passphrase,
            phase: .ready, deviceKeys: .init(curve: curve25519, ed: ed25519),
            refreshAttempt: nil)
        try persist(ready, replacing: true)
        return MatrixCustodyTicket(envelope: ready)
    }

    /// Every SDK opening must check the current record, not an old cached ticket.
    /// File-presence and actual-key validation are separate SDK adapter steps.
    public func recheck(_ ticket: MatrixCustodyTicket, marker: OIDCInstallationMarker) throws {
        guard let installation = try marker.load(), installation.id == ticket.envelope.installationID, installation.generation == generation,
              try load() == ticket.envelope else { throw MatrixCustodyFailure.recoveryRequired }
    }

    private func load() throws -> MatrixCustodyRecord.Envelope? {
        let envelope = try MatrixCustodyRecord.load(issuer: metadata.issuer, clientID: clients.matrix, copy: operations.copy)
        guard envelope == nil || envelope?.generation == generation else { throw MatrixCustodyFailure.recoveryRequired }
        return envelope
    }
    private static func scope(deviceID: String) -> String {
        "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:" + deviceID
    }
    private static func grantRecord(_ envelope: MatrixCustodyRecord.Envelope) -> OIDCStoredGrant {
        OIDCStoredGrant(generation: envelope.generation, issuer: envelope.issuer,
                        clientID: envelope.session.clientID, subject: envelope.subject,
                        accessToken: envelope.session.accessToken,
                        refreshToken: envelope.session.refreshToken,
                        expiresAt: envelope.session.expiresAt,
                        phase: envelope.refreshAttempt == nil ? .ready : .spending,
                        attempt: envelope.refreshAttempt)
    }
    private func saveRefresh(_ record: OIDCStoredGrant,
                             marker: OIDCInstallationMarker,
                             installation: OIDCInstallation) throws {
        guard try marker.load() == installation,
              let current = try load(), current.installationID == installation.id,
              current.phase == .ready, current.deviceKeys != nil else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        let previous = Self.grantRecord(current)
        guard record.generation == previous.generation,
              record.issuer == previous.issuer,
              record.clientID == previous.clientID,
              record.subject == previous.subject else {
            throw OIDCGrantFailure.storageUnavailable
        }
        switch (previous.phase, record.phase) {
        case (.ready, .spending):
            guard previous.attempt == nil, record.attempt != nil,
                  record.accessToken == previous.accessToken,
                  record.refreshToken == previous.refreshToken,
                  record.expiresAt == previous.expiresAt else {
                throw OIDCGrantFailure.storageUnavailable
            }
        case (.spending, .ready):
            guard previous.attempt != nil, record.attempt == nil,
                  record.refreshToken != previous.refreshToken else {
                throw OIDCGrantFailure.storageUnavailable
            }
        default:
            throw OIDCGrantFailure.storageUnavailable
        }
        let session = MatrixStoredSession(userID: current.session.userID,
            deviceID: current.session.deviceID, homeserver: current.session.homeserver,
            clientID: current.session.clientID, accessToken: record.accessToken,
            refreshToken: record.refreshToken, expiresAt: record.expiresAt)
        let updated = MatrixCustodyRecord.Envelope(version: current.version,
            installationID: current.installationID, generation: current.generation,
            issuer: current.issuer, subject: current.subject, session: session,
            passphrase: current.passphrase, phase: current.phase,
            deviceKeys: current.deviceKeys, refreshAttempt: record.attempt)
        try persist(updated, replacing: true)
    }
    private func persist(_ envelope: MatrixCustodyRecord.Envelope, replacing: Bool) throws {
        try MatrixCustodyRecord.validate(envelope, issuer: metadata.issuer, clientID: clients.matrix)
        guard envelope.generation == generation else { throw MatrixCustodyFailure.recoveryRequired }
        let data: Data
        do { data = try JSONEncoder().encode(envelope) } catch { throw MatrixCustodyFailure.storageUnavailable }
        guard data.count <= 65_536 else { throw MatrixCustodyFailure.storageUnavailable }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = replacing ? operations.update(match, attributes: attributes)
            : operations.add(match.merging(attributes) { _, new in new })
        guard status == errSecSuccess, try load() == envelope else { throw MatrixCustodyFailure.storageUnavailable }
    }
    private var match: [String: Any] {
        MatrixCustodyRecord.match
    }
    @MainActor private final class RefreshStore: OIDCGrantStore {
        let keychain: MatrixSessionKeychain
        let marker: OIDCInstallationMarker
        let installation: OIDCInstallation
        init(keychain: MatrixSessionKeychain, marker: OIDCInstallationMarker,
             installation: OIDCInstallation) {
            self.keychain = keychain; self.marker = marker; self.installation = installation
        }
        func load() throws -> OIDCStoredGrant? {
            guard try marker.load() == installation,
                  let envelope = try keychain.load(),
                  envelope.installationID == installation.id,
                  envelope.phase == .ready, envelope.deviceKeys != nil else {
                throw OIDCGrantFailure.reauthenticationRequired
            }
            return MatrixSessionKeychain.grantRecord(envelope)
        }
        func save(_ record: OIDCStoredGrant) throws {
            try keychain.saveRefresh(record, marker: marker, installation: installation)
        }
    }
}

/// Not Decodable. A ready ticket proves local Keychain provenance only; the
/// actual SDK must compare its device keys before any encrypted operation.
public struct MatrixCustodyTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let envelope: MatrixCustodyRecord.Envelope
    public var session: MatrixStoredSession { envelope.session }
    public var passphrase: String { envelope.passphrase }
    public var generation: UUID { envelope.generation }
    public var isPrepared: Bool { envelope.phase == .prepared }
    init(envelope: MatrixCustodyRecord.Envelope) { self.envelope = envelope }
    /// Public device keys from this exact ready envelope, before SDK activation.
    /// Prepared first-creation tickets cannot authorize existing-only restore.
    public func requiredDeviceKeys() throws -> (curve25519: String, ed25519: String) {
        guard envelope.phase == .ready, let keys = envelope.deviceKeys else { throw MatrixCustodyFailure.interruptedPreparation }
        return (keys.curve, keys.ed)
    }
    public func verifyDeviceKeys(curve25519: String, ed25519: String) throws {
        guard let keys = envelope.deviceKeys, keys.curve == curve25519, keys.ed == ed25519 else {
            throw MatrixCustodyFailure.recoveryRequired
        }
    }
    public var description: String { "MatrixCustodyTicket(<shared Matrix secrets redacted>)" }
    public var debugDescription: String { description }
}

/// Opaque main-process authority for rotating only the existing Matrix grant.
/// It cannot create or switch the local Matrix identity or SDK store.
@MainActor public struct OIDCMatrixResume: CustomStringConvertible, CustomDebugStringConvertible {
    let store: any OIDCGrantStore
    let metadata: MASMetadata
    let record: OIDCStoredGrant
    let expectedScope: String
    fileprivate init(store: any OIDCGrantStore, metadata: MASMetadata,
                     record: OIDCStoredGrant, expectedScope: String) {
        self.store = store; self.metadata = metadata; self.record = record
        self.expectedScope = expectedScope
    }
    public nonisolated var description: String { "OIDCMatrixResume(<secrets redacted>)" }
    public nonisolated var debugDescription: String { description }
}
