import Foundation
import Security

public enum MatrixRecoveryFailure: Error, Equatable {
    case storageUnavailable, survivorRequiresRecovery, invalidInput, identityChanged
}

/// Exported SDK preparation data, not publication authority. The SDK must
/// validate the Base58/MAC triple; this type enforces only storage bounds.
public struct MatrixRecoveryInput: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recoveryKey, keyID, metadataJSON: String
    public init(recoveryKey: String, keyID: String, metadataJSON: String) throws {
        self.recoveryKey = recoveryKey; self.keyID = keyID; self.metadataJSON = metadataJSON
        try validate()
    }
    func validate() throws {
        guard (1...128).contains(recoveryKey.utf8.count),
              recoveryKey.unicodeScalars.allSatisfy({ $0.isASCII && ($0 == " " || CharacterSet.alphanumerics.contains($0)) }),
              (1...255).contains(keyID.utf8.count),
              keyID.utf8.allSatisfy({ (33...126).contains($0) }),
              (1...1024).contains(metadataJSON.utf8.count) else { throw MatrixRecoveryFailure.invalidInput }
        // JSON is canonical SDK output. Actual MAC possession is checked by the
        // same SDK library, never approximated in Swift or inferred from JSON.
        guard let value = try? JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any],
              Set(value.keys) == ["algorithm", "iv", "mac"],
              value["algorithm"] as? String == "m.secret_storage.v1.aes-hmac-sha2",
              let iv = value["iv"] as? String, let mac = value["mac"] as? String,
              Self.base64(iv)?.count == 16, Self.base64(mac)?.count == 32,
              let canonical = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              canonical == Data(metadataJSON.utf8) else { throw MatrixRecoveryFailure.invalidInput }
    }
    private static func base64(_ string: String) -> Data? {
        guard string.range(of: "\\A[A-Za-z0-9+/]+\\z", options: .regularExpression) != nil else { return nil }
        let padded = string + String(repeating: "=", count: (4 - string.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), bytes.base64EncodedString().replacingOccurrences(of: "=", with: "") == string else { return nil }
        return bytes
    }
    public var description: String { "MatrixRecoveryInput(<private root and metadata withheld>)" }
    public var debugDescription: String { description }
}

/// Main-private first-use journal. The extension's Matrix group cannot reach
/// this service. No remote writes, published transition, removal or migration.
@MainActor public final class MatrixRecoveryKeychain {
    public static let accessGroup = OIDCDomainKeychain.accessGroup
    static let service = "com.atum.mobile.recovery.root.v1"
    static let account = "active-v1"
    private let operations: any OIDCKeychainOperations
    public convenience init() { self.init(operations: SystemOIDCKeychain()) }
    init(operations: any OIDCKeychainOperations) { self.operations = operations }

    /// Fresh-install preflight. Any valid, malformed, legacy or coexisting
    /// recovery record belongs to an explicit reconciliation path and is never
    /// replaced by a newly generated root.
    public func requireAbsentForExplicitSignIn() throws {
        guard try load() == nil else { throw MatrixRecoveryFailure.survivorRequiresRecovery }
    }

    /// Inventory survivors before asking the SDK to generate. A failed add or
    /// readback never authorizes publication, replacement or a second key.
    public func prepare(session: MatrixCustodyTicket, sessionStore: MatrixSessionKeychain,
                        marker: OIDCInstallationMarker, generate: () throws -> MatrixRecoveryInput) throws -> MatrixRecoveryTicket {
        try checkSession(session, store: sessionStore, marker: marker)
        guard try load() == nil else { throw MatrixRecoveryFailure.survivorRequiresRecovery }
        let input = try generate(); try input.validate()
        try checkSession(session, store: sessionStore, marker: marker)
        let value = Envelope(version: 1, binding: Binding(session.envelope), input: input)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8192 else { throw MatrixRecoveryFailure.invalidInput }
        let attributes = Self.match.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data]) { _, new in new }
        guard operations.add(attributes) == errSecSuccess, try load() == value else { throw MatrixRecoveryFailure.storageUnavailable }
        try checkSession(session, store: sessionStore, marker: marker)
        return MatrixRecoveryTicket(envelope: value)
    }

    /// Prepared input survives a process restart, but never automatically
    /// starts recovery publication. The explicit coordinator owns continuation.
    public func resumeForExplicitReconciliation(session: MatrixCustodyTicket, sessionStore: MatrixSessionKeychain,
                                                marker: OIDCInstallationMarker) throws -> MatrixRecoveryTicket {
        try checkSession(session, store: sessionStore, marker: marker)
        guard let value = try load(), value.binding == Binding(session.envelope) else { throw MatrixRecoveryFailure.identityChanged }
        return MatrixRecoveryTicket(envelope: value)
    }

    public func recheck(_ ticket: MatrixRecoveryTicket, session: MatrixCustodyTicket,
                        sessionStore: MatrixSessionKeychain, marker: OIDCInstallationMarker) throws {
        try checkSession(session, store: sessionStore, marker: marker)
        guard ticket.envelope.binding == Binding(session.envelope), try load() == ticket.envelope else { throw MatrixRecoveryFailure.identityChanged }
    }

    /// Reads this installation's already-validated recovery input for the S6
    /// show/save sheet. Callers must keep the returned root out of logs and
    /// persistence; every read rechecks the exact active Matrix session.
    public func currentInput(session: MatrixCustodyTicket,
                             sessionStore: MatrixSessionKeychain,
                             marker: OIDCInstallationMarker) throws -> MatrixRecoveryInput? {
        try checkSession(session, store: sessionStore, marker: marker)
        let value = try load()
        guard value == nil || value?.binding == Binding(session.envelope) else {
            throw MatrixRecoveryFailure.identityChanged
        }
        return value?.input
    }

    /// Reads the current installation's key before a Matrix runtime can be
    /// opened (S6's can't-connect escape). This is deliberately narrower than
    /// survivor recovery: both marker reads and the envelope's original local
    /// installation binding must match, so a reinstalled or different account
    /// can never reveal an old root through this path.
    public func currentInput(installation: OIDCInstallation,
                             marker: OIDCInstallationMarker) throws -> MatrixRecoveryInput? {
        guard try marker.load() == installation else {
            throw MatrixRecoveryFailure.identityChanged
        }
        let value = try load()
        guard value == nil || (value?.binding.installationID == installation.id
            && value?.binding.generation == installation.generation) else {
            throw MatrixRecoveryFailure.identityChanged
        }
        guard try marker.load() == installation else {
            throw MatrixRecoveryFailure.identityChanged
        }
        return value?.input
    }

    /// Replace the locally prepared root only after the Matrix SDK has
    /// successfully recovered with, and re-exported, the server's current
    /// default key. The existing session binding must match before and after
    /// the atomic Keychain update; no delete/add migration is permitted.
    @discardableResult
    public func replaceAfterVerifiedRecovery(
        _ input: MatrixRecoveryInput,
        session: MatrixCustodyTicket,
        sessionStore: MatrixSessionKeychain,
        marker: OIDCInstallationMarker
    ) throws -> MatrixRecoveryTicket {
        try input.validate()
        try checkSession(session, store: sessionStore, marker: marker)
        let binding = Binding(session.envelope)
        guard let existing = try load(), existing.binding == binding else {
            throw MatrixRecoveryFailure.identityChanged
        }
        let value = Envelope(version: 1, binding: binding, input: input)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8192 else { throw MatrixRecoveryFailure.invalidInput }
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        guard operations.update(Self.match, attributes: attributes) == errSecSuccess else {
            throw MatrixRecoveryFailure.storageUnavailable
        }
        let readback: Envelope?
        do { readback = try load() }
        catch { throw MatrixRecoveryFailure.storageUnavailable }
        guard readback == value else { throw MatrixRecoveryFailure.storageUnavailable }
        try checkSession(session, store: sessionStore, marker: marker)
        return MatrixRecoveryTicket(envelope: value)
    }

    private func checkSession(_ session: MatrixCustodyTicket, store: MatrixSessionKeychain, marker: OIDCInstallationMarker) throws {
        do { _ = try session.requiredDeviceKeys(); try store.recheck(session, marker: marker) }
        catch { throw MatrixRecoveryFailure.identityChanged }
    }
    private func load() throws -> Envelope? {
        // Attribute-only broad inventory detects synced/legacy/coexisting items
        // before any root secret is read. No survivor is repaired or removed.
        var inventory = Self.match
        inventory.removeValue(forKey: kSecAttrAccount as String)
        inventory[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        inventory[kSecMatchLimit as String] = kSecMatchLimitAll
        inventory[kSecReturnAttributes as String] = true
        let (status, raw) = operations.copy(inventory)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let items = raw as? [[String: Any]], items.count == 1,
              Self.validAttributes(items[0]) else { throw MatrixRecoveryFailure.survivorRequiresRecovery }
        var query = Self.match
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true; query[kSecReturnData as String] = true
        let (readStatus, readRaw) = operations.copy(query)
        guard readStatus == errSecSuccess, let item = readRaw as? [String: Any], Self.validAttributes(item),
              let data = item[kSecValueData as String] as? Data, data.count <= 8192 else { throw MatrixRecoveryFailure.storageUnavailable }
        do {
            let value = try JSONDecoder().decode(Envelope.self, from: data)
            guard value.version == 1 else { throw MatrixRecoveryFailure.storageUnavailable }
            try value.input.validate()
            return value
        } catch { throw MatrixRecoveryFailure.storageUnavailable }
    }
    private static func validAttributes(_ item: [String: Any]) -> Bool {
        item[kSecAttrService as String] as? String == service &&
        item[kSecAttrAccount as String] as? String == account &&
        item[kSecAttrAccessGroup as String] as? String == accessGroup &&
        item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String &&
        (item[kSecAttrSynchronizable as String] as? Bool ?? false) == false
    }
    private static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    }
    fileprivate struct Binding: Codable, Equatable {
        let installationID, generation: UUID
        let issuer, subject, userID, deviceID, homeserver, clientID: String
        init(_ session: MatrixCustodyRecord.Envelope) {
            installationID = session.installationID; generation = session.generation
            issuer = session.issuer; subject = session.subject; userID = session.session.userID
            deviceID = session.session.deviceID; homeserver = session.session.homeserver; clientID = session.session.clientID
        }
    }
    fileprivate struct Envelope: Codable, Equatable {
        let version: Int
        let binding: Binding
        let input: MatrixRecoveryInput
    }
}

/// Durable local input, not evidence that a backup/default was published.
public struct MatrixRecoveryTicket: CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let envelope: MatrixRecoveryKeychain.Envelope
    fileprivate init(envelope: MatrixRecoveryKeychain.Envelope) { self.envelope = envelope }
    public var preparedInput: MatrixRecoveryInput { envelope.input }
    public var description: String { "MatrixRecoveryTicket(<private input withheld>)" }
    public var debugDescription: String { description }
}
