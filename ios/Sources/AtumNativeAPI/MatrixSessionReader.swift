import Foundation
import Security

/// Copy-only and synchronous: usable from SDK callbacks and a fresh notification
/// process. No write/delete/refresh operation or private credential group exists
/// on this interface. Never chooses an identity from a push payload or a scan.
public struct MatrixSessionReader: Sendable {
    private let issuer, clientID: String
    private let operations: any MatrixKeychainReading
    public init(clients: MASPublicClients, metadata: MASMetadata) {
        self.init(clients: clients, metadata: metadata, operations: SystemMatrixKeychainReader())
    }
    init(clients: MASPublicClients, metadata: MASMetadata, operations: any MatrixKeychainReading) {
        issuer = metadata.issuer; clientID = clients.matrix; self.operations = operations
    }
    /// Preflight for an explicit first sign-in. Absence is the only accepted
    /// state; a ready, prepared, malformed, legacy or coexisting record is a
    /// recovery decision and is never overwritten by a new browser grant.
    public func requireAbsent() throws {
        guard try MatrixCustodyRecord.load(issuer: issuer, clientID: clientID,
                                           copy: operations.copy) == nil else {
            throw MatrixCustodyFailure.recoveryRequired
        }
    }
    public func loadCurrent(now: Date = Date()) throws -> MatrixCustodyTicket {
        guard let envelope = try MatrixCustodyRecord.load(issuer: issuer, clientID: clientID, copy: operations.copy) else {
            throw MatrixCustodyFailure.recoveryRequired
        }
        guard envelope.phase == .ready else { throw MatrixCustodyFailure.interruptedPreparation }
        guard envelope.refreshAttempt == nil else { throw MatrixCustodyFailure.refreshRequired }
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        guard now < envelope.session.expiresAt else { throw MatrixCustodyFailure.expired }
        return MatrixCustodyTicket(envelope: envelope)
    }
    public func recheck(_ ticket: MatrixCustodyTicket, now: Date = Date()) throws {
        guard try loadCurrent(now: now).envelope == ticket.envelope else { throw MatrixCustodyFailure.recoveryRequired }
    }
}

protocol MatrixKeychainReading: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
}
private struct SystemMatrixKeychainReader: MatrixKeychainReading {
    func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}

/// Shared codec, not authority: only the authenticated main writer can prepare
/// or promote a record. Fixed account selection is deployed before first use;
/// UUID-account survivors from earlier development are refused, never migrated.
enum MatrixCustodyRecord {
    static let accessGroup = "7D5FC62RXD.com.atum.mobile.matrix"
    static let service = "com.atum.mobile.matrix.custody.v1"
    static let account = "active-v1"
    static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    }
    static func load(issuer: String, clientID: String,
                     copy: ([String: Any]) -> (OSStatus, CFTypeRef?)) throws -> Envelope? {
        // Attributes-only presence check refuses legacy/coexisting survivors.
        // This inventory never selects an account or reads a legacy secret.
        var inventory = match
        inventory.removeValue(forKey: kSecAttrAccount as String)
        inventory[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        inventory[kSecMatchLimit as String] = kSecMatchLimitAll
        inventory[kSecReturnAttributes as String] = true
        inventory[kSecReturnData as String] = false
        let (presence, items) = copy(inventory)
        if presence == errSecItemNotFound { return nil }
        guard presence == errSecSuccess, let attributes = items as? [[String: Any]], attributes.count == 1 else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        try validateAttributes(attributes[0])
        var query = match
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true; query[kSecReturnData as String] = true
        let (status, value) = copy(query)
        guard status == errSecSuccess, let item = value as? [String: Any],
              let data = item[kSecValueData as String] as? Data, data.count <= 65_536 else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        try validateAttributes(item)
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            try validate(envelope, issuer: issuer, clientID: clientID)
            return envelope
        } catch { throw MatrixCustodyFailure.storageUnavailable }
    }
    private static func validateAttributes(_ attributes: [String: Any]) throws {
        let synchronizable = attributes[kSecAttrSynchronizable as String]
        guard attributes[kSecAttrAccessGroup as String] as? String == accessGroup,
              attributes[kSecAttrService as String] as? String == service,
              attributes[kSecAttrAccount as String] as? String == account,
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
              synchronizable == nil || (synchronizable as? Bool == false) else {
            throw MatrixCustodyFailure.storageUnavailable
        }
    }
    static func validate(_ e: Envelope, issuer: String, clientID: String) throws {
        func safe(_ value: String, _ max: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= max && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard e.version == 1, e.issuer == issuer, e.session.clientID == clientID, safe(e.subject, 1024),
              e.session.homeserver == MatrixAuthenticatedDevice.homeserver,
              e.session.userID.hasPrefix("@"), e.session.userID.dropFirst().contains(":"), safe(e.session.userID, 1024),
              !e.session.userID.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              e.session.deviceID.range(of: "\\A[A-Za-z0-9._-]{1,255}\\z", options: .regularExpression) != nil,
              e.session.clientID.range(of: "\\A[0-9A-HJKMNP-TV-Z]{26}\\z", options: .regularExpression) != nil,
              [e.session.accessToken, e.session.refreshToken].allSatisfy({ safe($0, 8192) && !$0.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) }),
              e.session.expiresAt.timeIntervalSince1970.isFinite, e.session.expiresAt.timeIntervalSince1970 >= 0,
              e.session.expiresAt.timeIntervalSince1970 < Double(NativeAPI.maximumInteger),
              Data(base64Encoded: e.passphrase)?.count == 32,
              (e.phase == .prepared) == (e.deviceKeys == nil),
              e.phase == .ready || e.refreshAttempt == nil,
              e.deviceKeys.map({ validKey($0.curve) && validKey($0.ed) }) ?? true else {
            throw MatrixCustodyFailure.storageUnavailable
        }
    }
    static func validKey(_ key: String) -> Bool {
        key.utf8.count == 43 && Data(base64Encoded: key + "=")?.count == 32
    }
    enum Phase: String, Codable, Sendable { case prepared, ready }
    struct DeviceKeys: Codable, Equatable, Sendable { let curve, ed: String }
    struct Envelope: Codable, Equatable, Sendable {
        let version: Int
        let installationID, generation: UUID
        let issuer, subject: String
        let session: MatrixStoredSession
        let passphrase: String
        let phase: Phase
        let deviceKeys: DeviceKeys?
        var refreshAttempt: UUID? = nil
    }
}
