import AtumNativeAPI
import Foundation
import MatrixRustSDK
import Security

enum MatrixSecurityFailure: Error, Equatable {
    case sessionUnavailable
    case busy
    case crossSigningBootstrapUnavailable
    case verificationRequired
    case existingRecovery
    case recoveryNotReady
    case recoveryKeyUnavailable
    case secureStorageUnavailable
    case saveCancelled
    case platformSaveUnavailable
    case notHuman
    case invalidParticipants
    case roomUnavailable
}

struct MatrixSecuritySnapshot: Equatable, Sendable {
    let sessionVerified: Bool
    let recoveryEnabled: Bool
    let backupEnabled: Bool
    let recoveryKeyConfirmed: Bool
    let pendingSaveID: UUID?

    var canCreatePrivateChat: Bool {
        sessionVerified && recoveryEnabled && backupEnabled && recoveryKeyConfirmed
    }
}

/// App-private Keychain, with the same device-only protection as the
/// existing recovery journal. The ordinary SDK restore never exports a key
/// into this store. Retain a fresh key until it is saved, then retain only its
/// confirmation and the matching server secret-storage key ID.
@MainActor
struct MatrixRecoverySaveStore {
    struct Record: Codable, Equatable, CustomDebugStringConvertible {
        let userID: String
        let deviceID: String
        let id: UUID
        let storageKeyID: String?
        let pendingKey: String?

        var pendingSaveID: UUID? { pendingKey == nil ? nil : id }

        var debugDescription: String { "MatrixRecoverySaveStore.Record(<redacted>)" }
    }

    let ticket: MatrixCustodyTicket

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.atum.mobile.recovery.save.v1",
            kSecAttrAccount as String: ticket.generation.uuidString,
            kSecAttrAccessGroup as String: MatrixRecoveryKeychain.accessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func read() throws -> Record? {
        let lookup = query.merging([kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.userID == ticket.session.userID, record.deviceID == ticket.session.deviceID
        else { throw MatrixSecurityFailure.secureStorageUnavailable }
        return record
    }

    func write(id: UUID, storageKeyID: String?, pendingKey: String?) throws {
        let entry = Record(userID: ticket.session.userID, deviceID: ticket.session.deviceID,
                           id: id, storageKeyID: storageKeyID, pendingKey: pendingKey)
        let data: Data
        do { data = try JSONEncoder().encode(entry) }
        catch { throw MatrixSecurityFailure.secureStorageUnavailable }
        let value = [kSecValueData as String: data]
        let exists = try read() != nil
        let status: OSStatus
        if exists {
            status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        } else {
            let attributes = query.merging(value) { _, new in new }.merging([
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess, try read() == entry else {
            throw MatrixSecurityFailure.secureStorageUnavailable
        }
    }

    static func defaultKeyID(in accountData: String?) -> String? {
        guard let accountData, accountData.utf8.count <= 4_096,
              let event = try? JSONSerialization.jsonObject(with: Data(accountData.utf8)) as? [String: Any]
        else { return nil }
        let content = event["content"] as? [String: Any] ?? event
        guard let id = content["key"] as? String, (1...255).contains(id.utf8.count),
              id.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return id
    }
}

/// The callback can carry the newly generated secret. Use the result of the
/// awaited operation in the runtime and never stringify progress or raw errors.
final class MatrixRecoverySetupProgress: EnableRecoveryProgressListener, @unchecked Sendable {
    private let lock = NSLock()
    private var generatedKey: String?

    func onUpdate(status: EnableRecoveryProgress) {
        guard case .done(let recoveryKey) = status else { return }
        lock.withLock { generatedKey = recoveryKey }
    }

    func keyAfterPartialSetup() -> String? { lock.withLock { generatedKey } }
}
