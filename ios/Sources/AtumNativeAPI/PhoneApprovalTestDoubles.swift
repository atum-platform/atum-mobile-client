#if DEBUG
import Foundation
import CryptoKit
import Security

// DEBUG-only doubles for phone approvals: unit tests and the scripted
// Settings screens use them. Release builds compile none of this, so there is
// no software-key fallback in production.

/// An in-memory device-service 1.3 registry that checks what the platform
/// route checks (`apps/shell/src/lib/device-services.ts` on the slice 1
/// branch): both enrolment signatures, owner, pinned controller keys, epoch
/// chain, stored-key rotation, active key uniqueness, idempotent retries,
/// owner-scoped revoke.
public actor PhoneApprovalScriptedServer: PhoneApprovalServer {
    public enum Mode: Sendable { case phoneRegistry, legacyMacOnly, closed }
    public let owner: String
    public var mode: Mode
    /// Every call throws `transportUnavailable` while true.
    public var offline = false
    /// The next enrolments fail with these, in order, before reaching the registry.
    public var enrollFailures: [Error] = []
    /// The next enrolment is applied, then its answer is lost.
    public var dropNextEnrollAnswer = false
    public private(set) var enrollCalls = 0
    public private(set) var revokeCalls: [UUID] = []
    public let controllerKeys = [String(repeating: "c", count: 43)]
    private var records: [UUID: PhoneRegistryRecord] = [:]
    private var approvalKeys: [UUID: Data] = [:]
    private var requests: [UUID: Data] = [:]
    private var clock = Int64(Date().timeIntervalSince1970 * 1_000)

    public init(owner: String, mode: Mode = .phoneRegistry) {
        self.owner = owner
        self.mode = mode
    }

    public func set(mode: Mode) { self.mode = mode }
    public func set(offline: Bool) { self.offline = offline }
    public func failNextEnrolls(_ errors: [Error]) { enrollFailures = errors }
    public func loseNextEnrollAnswer() { dropNextEnrollAnswer = true }
    /// Holds each enrolment this long, so a screen can show "Setting up…".
    public var enrollDelay: Duration = .zero
    public func set(enrollDelay: Duration) { self.enrollDelay = enrollDelay }
    public func record(_ id: UUID) -> PhoneRegistryRecord? { records[id] }
    public func activePhones() -> [PhoneRegistryRecord] {
        records.values.filter { $0.platform == .ios && $0.state == .active }
    }

    private func reachable() throws {
        if offline { throw NativeDomainClientFailure.transportUnavailable }
        if mode == .closed { throw Self.error(503, nil) }
    }

    public func supportsPhoneRegistry() async throws -> Bool {
        try reachable()
        return mode == .phoneRegistry
    }

    public func controllerKeyIDs() async throws -> [String] {
        try reachable()
        return controllerKeys
    }

    public func registrations() async throws -> [PhoneRegistryRecord] {
        try reachable()
        let all = records.values.sorted { $0.createdAt < $1.createdAt }
        return mode == .phoneRegistry ? all : all.filter { $0.platform == .macos }
    }

    public func revoke(_ id: UUID) async throws -> PhoneRegistryRecord {
        try reachable()
        revokeCalls.append(id)
        guard let record = records[id] else { throw Self.error(404, "not_found") }
        clock += 1
        let revoked = record.with(state: .revoked, revokeSeq: record.revokeSeq + 1, revokedAt: clock)
        records[id] = revoked
        return revoked
    }

    /// Another device removes this registration (Your devices elsewhere).
    public func revokeElsewhere(_ id: UUID) async { _ = try? await revoke(id) }

    public func enroll(_ request: Data) async throws -> PhoneRegistryRecord {
        enrollCalls += 1
        if enrollDelay > .zero { try? await Task.sleep(for: enrollDelay) }
        try reachable()
        if !enrollFailures.isEmpty { throw enrollFailures.removeFirst() }
        guard mode == .phoneRegistry else { throw Self.error(400, "invalid") }
        let record = try admit(request)
        if dropNextEnrollAnswer {
            dropNextEnrollAnswer = false
            throw NativeDomainClientFailure.transportUnavailable
        }
        return record
    }

    private func admit(_ request: Data) throws -> PhoneRegistryRecord {
        guard let envelope = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let bodyObject = envelope["body"] as? [String: Any],
              let sigs = envelope["sigs"] as? [String: String] else { throw Self.error(400, "invalid") }
        let body = try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes: Data
        do { bytes = try PhoneEnrollment.canonicalBytes(body: body) } catch { throw Self.error(400, "invalid") }
        guard let identityKey = bodyObject["identityKey"] as? String, let approvalKey = bodyObject["approvalKey"] as? String,
              let idText = bodyObject["deviceServiceId"] as? String, let id = UUID(uuidString: idText),
              let epoch = (bodyObject["enrollmentEpoch"] as? NSNumber)?.int64Value,
              let matrix = bodyObject["matrix"] as? [String: String],
              let controllers = bodyObject["controllerKeys"] as? [String] else { throw Self.error(400, "invalid") }
        let identitySPKI = try PhoneEnrollment.decodeBase64URL(identityKey)
        let approvalSPKI = try PhoneEnrollment.decodeBase64URL(approvalKey)
        guard Self.verify(identitySPKI, bytes, sigs["identity"]), Self.verify(approvalSPKI, bytes, sigs["approval"]) else {
            throw Self.error(400, "bad_signature")
        }
        guard matrix["userId"] == owner else { throw Self.error(403, "wrong_owner") }
        guard Set(controllers).isSubset(of: controllerKeys) else { throw Self.error(400, "unknown_controller_key") }
        let approvalKid = PhoneEnrollment.keyID(spki: approvalSPKI)
        let stored = records[id]
        if let stored, requests[id] == request { return stored }   // identical retry
        if records.contains(where: { $0.key != id && $0.value.state == .active && $0.value.approvalKeyId == approvalKid }) {
            throw Self.error(409, "key_conflict")
        }
        clock += 1
        if epoch == 1 {
            guard stored == nil else { throw Self.error(409, "enrollment_conflict") }
        } else {
            guard let stored, stored.state == .active, let previousKey = approvalKeys[id],
                  bodyObject["previousApprovalKid"] as? String == stored.approvalKeyId,
                  stored.enrollmentEpoch + 1 == epoch,
                  Self.verify(previousKey, bytes, sigs["previousApproval"]) else {
                throw Self.error(403, stored?.state == .revoked ? "revoked" : "rotation_unauthorized")
            }
        }
        let record = PhoneRegistryRecord(
            deviceServiceId: id, displayName: bodyObject["displayName"] as? String ?? "", platform: .ios,
            identityKeyId: PhoneEnrollment.keyID(spki: identitySPKI), approvalKeyId: approvalKid,
            matrix: .init(deviceId: matrix["deviceId"] ?? "", fingerprint: matrix["fingerprint"] ?? ""),
            enrollmentEpoch: epoch, scopes: [], pinnedControllerKeys: controllers, state: .active,
            revokeSeq: stored?.revokeSeq ?? 0, createdAt: stored?.createdAt ?? clock,
            rotatedAt: epoch > 1 ? clock : nil, revokedAt: nil)
        records[id] = record
        approvalKeys[id] = approvalSPKI
        requests[id] = request
        return record
    }

    private static func verify(_ spki: Data, _ bytes: Data, _ signature: String?) -> Bool {
        guard let signature, let raw = try? PhoneEnrollment.decodeBase64URL(signature),
              let key = try? P256.Signing.PublicKey(derRepresentation: spki),
              let proof = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(proof, for: bytes)
    }

    static func error(_ status: Int, _ reason: String?) -> PhoneRegistryError {
        let reasonJSON = reason.map { ",\"details\":{\"reason\":\"\($0)\"}" } ?? ""
        return try! JSONDecoder().decode(PhoneRegistryError.self, from: Data("{\"error\":\"matrix_\(status)\"\(reasonJSON)}".utf8))
    }
}

extension PhoneRegistryRecord {
    func with(state: State, revokeSeq: Int64, revokedAt: Int64?) -> PhoneRegistryRecord {
        PhoneRegistryRecord(deviceServiceId: deviceServiceId, displayName: displayName, platform: platform,
                            identityKeyId: identityKeyId, approvalKeyId: approvalKeyId, matrix: matrix,
                            enrollmentEpoch: enrollmentEpoch, scopes: scopes, pinnedControllerKeys: pinnedControllerKeys,
                            state: state, revokeSeq: revokeSeq, createdAt: createdAt, rotatedAt: rotatedAt,
                            revokedAt: revokedAt)
    }
}

/// Software P-256 keys keyed by namespace, standing in for the Secure Enclave.
/// `nextSign` scripts the system prompt's answer.
public final class PhoneApprovalSoftwareKeyVault: PhoneApprovalKeyVault, @unchecked Sendable {
    public enum Prompt: Sendable { case match, cancel, fail }
    private let lock = NSLock()
    private var keys: [String: P256.Signing.PrivateKey] = [:]
    private var prompts: [Prompt] = []
    private var signatures = 0

    public init() {}

    /// The answers of the next system prompts, in order (then `.match`).
    public func script(_ next: [Prompt]) { lock.locked { prompts = next } }
    /// How many approval-key signatures (system prompts) were asked for.
    public var promptCount: Int { lock.locked { signatures } }
    /// Simulates a restore or the passcode being turned off.
    public func loseAllKeys() { lock.locked { keys.removeAll() } }
    public var keyCount: Int { lock.locked { keys.count } }

    public func store(for namespace: PhoneKeyNamespace) -> PhoneApprovalKeyStore {
        Store(vault: self, namespace: namespace.value)
    }
    public func keysExist(for namespace: PhoneKeyNamespace) -> Bool {
        lock.locked { keys[namespace.value + ".identity"] != nil && keys[namespace.value + ".approval"] != nil }
    }

    fileprivate func create(_ tag: String) throws {
        try lock.locked {
            guard keys[tag] == nil else { throw PhoneApprovalFailure.keychain(errSecDuplicateItem) }
            keys[tag] = P256.Signing.PrivateKey()
        }
    }
    fileprivate func key(_ tag: String) throws -> P256.Signing.PrivateKey {
        try lock.locked {
            guard let key = keys[tag] else { throw PhoneApprovalFailure.setupRequired }
            return key
        }
    }
    fileprivate func prompt() -> Prompt {
        lock.locked {
            signatures += 1
            return prompts.isEmpty ? .match : prompts.removeFirst()
        }
    }
    fileprivate func remove(_ tag: String) { lock.locked { _ = keys.removeValue(forKey: tag) } }

    private final class Store: PhoneApprovalKeyStore {
        let vault: PhoneApprovalSoftwareKeyVault
        let namespace: String
        init(vault: PhoneApprovalSoftwareKeyVault, namespace: String) {
            self.vault = vault
            self.namespace = namespace
        }
        func create(_ role: PhoneKeyRole) throws { try vault.create(namespace + "." + role.rawValue) }
        func publicKey(_ role: PhoneKeyRole) throws -> Data {
            try vault.key(namespace + "." + role.rawValue).publicKey.derRepresentation
        }
        func sign(_ bytes: Data, role: PhoneKeyRole, reason: String) throws -> Data {
            let key = try vault.key(namespace + "." + role.rawValue)
            // Only the approval key carries userPresence.
            if role == .approval {
                switch vault.prompt() {
                case .match: break
                case .cancel: throw PhoneApprovalFailure.cancelled
                case .fail: throw PhoneApprovalFailure.authenticationFailed
                }
            }
            return try key.signature(for: bytes).rawRepresentation
        }
        func remove(_ role: PhoneKeyRole) throws { vault.remove(namespace + "." + role.rawValue) }
    }
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
