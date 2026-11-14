import Foundation
import CryptoKit
import Security
import LocalAuthentication

// Slice 2b of phone approvals (design `phone-approvals.md`, slice 2): what
// "Approve on this iPhone" stores on the phone and how its registration lives
// and dies. Settings draws `PhoneApprovalStatus`; every server call goes
// through `PhoneApprovalServer` (device-service 1.3). Approving a request is
// slice 3 and is not here.

/// The owner's device-service registry, as the phone uses it. Production is
/// `NativeDomainClient`; tests and scripted screens use an in-memory double.
public protocol PhoneApprovalServer: Sendable {
    /// True only when the server implements the negotiated 1.3 phone registry.
    func supportsPhoneRegistry() async throws -> Bool
    func controllerKeyIDs() async throws -> [String]
    /// POSTs an already signed enrolment or rotation request.
    func enroll(_ request: Data) async throws -> PhoneRegistryRecord
    /// The negotiated (1.3) list: phones and Macs, revoked records included.
    func registrations() async throws -> [PhoneRegistryRecord]
    func revoke(_ id: UUID) async throws -> PhoneRegistryRecord
}

extension NativeDomainClient: PhoneApprovalServer {
    public nonisolated func supportsPhoneRegistry() async throws -> Bool { try await phoneRegistrySupported() }
    public nonisolated func controllerKeyIDs() async throws -> [String] { try await phoneControllerKeyIDs() }
    public nonisolated func enroll(_ request: Data) async throws -> PhoneRegistryRecord {
        try JSONDecoder().decode(PhoneRegistryRecord.self, from: await phoneDeviceServices(request: request))
    }
    public nonisolated func registrations() async throws -> [PhoneRegistryRecord] { try await listPhoneRegistrations() }
    public nonisolated func revoke(_ id: UUID) async throws -> PhoneRegistryRecord { try await revokePhone(id: id) }
}

/// Where approval keys live. Production is the Secure Enclave; there is no
/// software fallback outside DEBUG test doubles.
public protocol PhoneApprovalKeyVault: Sendable {
    func store(for namespace: PhoneKeyNamespace) -> PhoneApprovalKeyStore
    /// Without any prompt: whether both keys of this namespace still exist.
    func keysExist(for namespace: PhoneKeyNamespace) -> Bool
    /// Deletes both key roles of one namespace. True only when both are
    /// confirmed gone (an absent key counts as gone).
    func delete(_ namespace: PhoneKeyNamespace) -> Bool
    /// Sign-out sweep: deletes every approval key this app holds for `owner`,
    /// whatever namespace it is in, recorded or not. True only when none is
    /// left afterwards.
    func wipe(owner: String) -> Bool
}

public extension PhoneApprovalKeyVault {
    func delete(_ namespace: PhoneKeyNamespace) -> Bool {
        let keys = store(for: namespace)
        var deleted = true
        for role in [PhoneKeyRole.approval, .identity] {
            do { try keys.remove(role) } catch { deleted = false }
        }
        return deleted
    }
}

public struct SecureEnclavePhoneKeyVault: PhoneApprovalKeyVault {
    public init() {}
    public func store(for namespace: PhoneKeyNamespace) -> PhoneApprovalKeyStore {
        SecureEnclavePhoneKeyStore(namespace: namespace)
    }
    public func keysExist(for namespace: PhoneKeyNamespace) -> Bool {
        let store = SecureEnclavePhoneKeyStore(namespace: namespace)
        return store.exists(.identity) && store.exists(.approval)
    }
    public func wipe(owner: String) -> Bool {
        let prefix = Data(PhoneKeyNamespace.ownerPrefix(owner).utf8)
        guard let found = Self.tags(prefix: prefix) else { return false }
        for tag in found {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                           kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom] as CFDictionary)
        }
        return Self.tags(prefix: prefix)?.isEmpty == true
    }
    /// The application tags of this app's P-256 keys that start with
    /// `prefix`, read without any prompt. Nil when the Keychain cannot answer.
    private static func tags(prefix: Data) -> [Data]? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassKey,
                                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecUseAuthenticationContext as String: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        return items.compactMap { $0[kSecAttrApplicationTag as String] as? Data }.filter { $0.starts(with: prefix) }
    }
}

/// How this iPhone can confirm it is its owner. Face ID or Touch ID comes
/// first; the passcode is the system's own fallback (`.userPresence`).
public enum PhoneApprovalAuthentication: String, Equatable, Sendable {
    case faceID, touchID
    /// A passcode but no enrolled biometric: approvals use the passcode.
    case passcodeOnly
    /// No device passcode: the approval key cannot exist.
    case noPasscode

    /// Reads the device now, without prompting.
    public static func current() -> PhoneApprovalAuthentication {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .noPasscode
        }
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .passcodeOnly
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .passcodeOnly
        }
    }
}

/// The phone facts an enrolment body carries.
public struct PhoneApprovalDeviceFacts: Equatable, Sendable {
    public let displayName: String
    public let osVersion: String
    public let authentication: PhoneApprovalAuthentication
    public init(displayName: String, osVersion: String, authentication: PhoneApprovalAuthentication) {
        self.displayName = PhoneApprovalDeviceFacts.registryName(displayName)
        self.osVersion = osVersion
        self.authentication = authentication
    }

    /// The registry's display-name rule: 1–64 UTF-16 units, no control
    /// characters. A longer name is cut on a character boundary.
    static func registryName(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        var name = ""
        for character in cleaned {
            guard (name + String(character)).utf16.count <= 64 else { break }
            name.append(character)
        }
        return name.isEmpty ? "iPhone" : name
    }
}

/// The signed-in Matrix device the registration binds to.
public struct PhoneApprovalMatrixIdentity: Equatable, Sendable {
    public let userID: String
    public let deviceID: String
    /// The device's ed25519 key, unpadded base64 (43 characters).
    public let fingerprint: String
    public init(userID: String, deviceID: String, fingerprint: String) {
        self.userID = userID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
    }
}

/// What this iPhone holds for one owner. Never a key, a bearer or a signature.
public struct PhoneApprovalRegistration: Codable, Equatable, Sendable {
    public let owner: String
    public let installation: UUID
    public let generation: UUID
    public let deviceServiceId: UUID
    public let enrollmentEpoch: Int64
    public let identityKeyId: String
    public let approvalKeyId: String
    /// The server's `createdAt` (ms): "On · since {date}".
    public let enrolledAt: Int64
    /// A rotation whose answer never arrived: its keys are kept until the
    /// server's list says which generation won.
    public var pendingGeneration: UUID?

    public var namespace: PhoneKeyNamespace {
        PhoneKeyNamespace(owner: owner, installation: installation, generation: generation)
    }
    var pendingNamespace: PhoneKeyNamespace? {
        pendingGeneration.map { PhoneKeyNamespace(owner: owner, installation: installation, generation: $0) }
    }
    public var since: Date { Date(timeIntervalSince1970: Double(enrolledAt) / 1_000) }
}

/// What Settings › Approve on this iPhone shows.
public enum PhoneApprovalStatus: Equatable, Sendable {
    /// The server does not advertise phone registration and this iPhone holds
    /// none: the row is hidden (fail closed).
    case unavailable
    case off
    case on(since: Date)
    /// The key is gone (restore, new iPhone, passcode turned off) or the
    /// server's record no longer matches it. The old registration is revoked.
    case needsSetUpAgain
}

/// Why setting up did not finish, in desktop's `cloud.enrollFailure` shape.
public enum PhoneApprovalSetupFailure: Error, Equatable, Sendable {
    /// Face ID or the passcode was cancelled: only "not set up".
    case cancelled
    /// The system could not ask for Face ID or the passcode.
    case noPrompt
    case noPasscode
    case offline
    /// The server refused the registration (4xx).
    case refused
    /// The server does not support phone registration.
    case unavailable
    case generic
}

/// Why Remove from this iPhone did not fully finish.
public enum PhoneApprovalRemoveFailure: Error, Equatable, Sendable {
    /// The revocation could not be recorded: nothing was removed.
    case notRecorded
    /// Revocation recorded and the registration dropped, but a key could not
    /// be deleted; its namespace is kept and deletion is retried.
    case keysRemain
}

/// What sign-out learned. Credentials may go only when `allowsSignOut`.
public struct PhoneApprovalSignOutResult: Equatable, Sendable {
    /// Every approval key of the owner on this iPhone is confirmed deleted.
    public let keysDeleted: Bool
    /// Every known registration's revocation is durably recorded.
    public let revocationRecorded: Bool
    /// The server confirmed no active registration of this iPhone remains.
    public let serverRevoked: Bool
    /// A journalled attempt was unresolved at sign-out: the server may admit
    /// it later, so a 404 or an empty list proves nothing about it.
    public let unresolvedAttempt: Bool
    /// Deleting the keys is all that can be done: there is no client (the
    /// session was refused), or there is no local state to record anything in.
    public let keysSuffice: Bool

    /// A signed-out iPhone must not keep a usable approval key.
    /// - When only key deletion can be done, confirmed deletion is enough: a
    ///   registration without its Secure Enclave key cannot sign, and holding
    ///   sign-out would trap the person.
    /// - Otherwise the keys must be gone, or the server must have revoked
    ///   them (which never counts while an attempt is unresolved); and the
    ///   revocation must be recorded or confirmed.
    public var allowsSignOut: Bool {
        if keysSuffice { return keysDeleted }
        let serverCoversKeys = serverRevoked && !unresolvedAttempt
        return (keysDeleted || serverCoversKeys) && (revocationRecorded || serverRevoked)
    }
}

/// The phone half of slice 2's lifecycle: set up, refresh, remove, sign out,
/// rotate, recover from key loss, and retry revocations.
public actor PhoneApprovalLifecycle {
    private let server: PhoneApprovalServer
    private let vault: PhoneApprovalKeyVault
    private let registrations: PhoneApprovalRegistrationStore
    private let revocations: PhoneRevocationQueue
    private let now: @Sendable () -> Date
    private let retryDelays: [Duration]
    /// nil until the probe answers. Only a "yes" is kept for the session.
    private var supported: Bool?

    public init(server: PhoneApprovalServer, vault: PhoneApprovalKeyVault,
                registrations: PhoneApprovalRegistrationStore, revocations: PhoneRevocationQueue,
                now: @escaping @Sendable () -> Date = Date.init,
                retryDelays: [Duration] = [.seconds(1), .seconds(3)]) {
        self.server = server
        self.vault = vault
        self.registrations = registrations
        self.revocations = revocations
        self.now = now
        self.retryDelays = retryDelays
    }

    /// From local state only, without the network.
    public func status(owner: String) async -> PhoneApprovalStatus {
        if let registration = await registrations.registration(owner: owner) { return .on(since: registration.since) }
        if await registrations.needsSetUpAgain(owner: owner) { return supported == false ? .unavailable : .needsSetUpAgain }
        return supported == true ? .off : .unavailable
    }

    /// Retries owed revocations and key deletions, resolves attempts no live
    /// operation owns, asks the server what it supports, checks the local
    /// keys, and reconciles this iPhone's registration with the server's list.
    /// A result is applied only if the registration is still the one this
    /// refresh started from.
    @discardableResult
    public func refresh(owner: String) async -> PhoneApprovalStatus {
        await retryRevocations(owner: owner)
        await retryOrphans()
        await resolveStaleAttempts(owner: owner)
        await probe()
        guard let registration = await registrations.registration(owner: owner) else {
            return await status(owner: owner)
        }
        guard vault.keysExist(for: registration.namespace) else {
            _ = await discard(registration, needsSetUpAgain: true, revoke: true)
            return await status(owner: owner)
        }
        guard supported != false, let list = try? await server.registrations() else {
            return await status(owner: owner)
        }
        // The list took time: the registration may have been removed or
        // replaced meanwhile. Never apply this answer to another one.
        guard let current = await registrations.registration(owner: owner),
              current.deviceServiceId == registration.deviceServiceId,
              current.generation == registration.generation else {
            return await status(owner: owner)
        }
        let record = list.first { $0.deviceServiceId == registration.deviceServiceId }
        if let pending = registration.pendingNamespace {
            let pendingKid = (try? vault.store(for: pending).publicKey(.approval)).map(PhoneEnrollment.keyID(spki:))
            if let record, record.state == .active, record.approvalKeyId == pendingKid {
                // The lost rotation did land: promote it, drop the old keys.
                let promoted = PhoneApprovalRegistration(
                    owner: owner, installation: registration.installation, generation: pending.generation,
                    deviceServiceId: registration.deviceServiceId, enrollmentEpoch: record.enrollmentEpoch,
                    identityKeyId: record.identityKeyId, approvalKeyId: record.approvalKeyId,
                    enrolledAt: record.createdAt, pendingGeneration: nil)
                guard (try? await registrations.replace(expected: registration, with: promoted)) == true else {
                    return await status(owner: owner)
                }
                await deleteOrRemember(registration.namespace, owner: owner)
                return await status(owner: owner)
            }
            var settled = registration
            settled.pendingGeneration = nil
            guard (try? await registrations.replace(expected: registration, with: settled)) == true else {
                return await status(owner: owner)
            }
            await deleteOrRemember(pending, owner: owner)
            return await reconcile(settled, record: record)
        }
        return await reconcile(registration, record: record)
    }

    private func reconcile(_ registration: PhoneApprovalRegistration, record: PhoneRegistryRecord?) async -> PhoneApprovalStatus {
        guard let record, record.state == .active else {
            // Removed in Your devices on another device, or never admitted.
            _ = await discard(registration, needsSetUpAgain: false, revoke: false)
            return await status(owner: registration.owner)
        }
        guard record.platform == .ios, record.approvalKeyId == registration.approvalKeyId else {
            _ = await discard(registration, needsSetUpAgain: true, revoke: true)
            return await status(owner: registration.owner)
        }
        return .on(since: registration.since)
    }

    /// Creates both keys in a new namespace, signs the enrolment with a fresh
    /// Face ID or passcode, and registers. Never reuses an old registration.
    /// The attempt is journalled before any key or request exists, and a
    /// completion after the owner signed out is revoked, never saved.
    public func setUp(owner: String, identity: PhoneApprovalMatrixIdentity, device: PhoneApprovalDeviceFacts,
                      reason: String) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        guard device.authentication != .noPasscode else { throw .noPasscode }
        guard identity.userID == owner else { throw .generic }
        let epoch = await registrations.epoch(owner: owner)
        await probe()
        guard let supported else { throw .offline }
        guard supported else { throw .unavailable }
        if let stale = await registrations.registration(owner: owner) {
            // One registration per iPhone and owner: the old one goes first.
            guard await discard(stale, needsSetUpAgain: false, revoke: true) else { throw .generic }
        }
        let controllers: [String]
        do { controllers = try await server.controllerKeyIDs() } catch { throw Self.failure(error) }
        let attempt = PhoneApprovalPendingAttempt(owner: owner, deviceServiceId: UUID(),
                                                  installation: await registrations.installation,
                                                  generation: UUID(), kind: .enroll)
        do { try await registrations.begin(attempt, epoch: epoch) } catch { throw .generic }
        do {
            let status = try await enroll(attempt, identity: identity, device: device, controllers: controllers,
                                          reason: reason, epoch: epoch)
            await registrations.end(attempt.deviceServiceId)
            return status
        } catch {
            await registrations.end(attempt.deviceServiceId)
            throw error
        }
    }

    private func enroll(_ attempt: PhoneApprovalPendingAttempt, identity: PhoneApprovalMatrixIdentity,
                        device: PhoneApprovalDeviceFacts, controllers: [String], reason: String,
                        epoch: Int) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        let owner = attempt.owner, id = attempt.deviceServiceId
        let keys = vault.store(for: attempt.namespace)
        let request: Data
        let approvalKid: String
        do {
            try keys.create(.identity)
            try keys.create(.approval)
            let body = try PhoneEnrollment.body(
                id: id, displayName: device.displayName, osVersion: device.osVersion,
                matrixUserID: identity.userID, matrixDeviceID: identity.deviceID,
                matrixFingerprint: identity.fingerprint, controllerKeyIDs: controllers,
                issuedAt: Int64(now().timeIntervalSince1970 * 1_000), keys: keys)
            approvalKid = PhoneEnrollment.keyID(spki: try keys.publicKey(.approval))
            request = try PhoneEnrollment.request(body: body, keys: keys, reason: reason)
        } catch {
            await abandon(attempt, mayHaveLanded: false)
            throw Self.signingFailure(error)
        }
        // Signed out during the prompt: send nothing.
        guard await registrations.epoch(owner: owner) == epoch else {
            await abandon(attempt, mayHaveLanded: false)
            throw .generic
        }
        let outcome = await post(request)
        let record: PhoneRegistryRecord
        switch outcome.result {
        case let .success(value): record = value
        case let .failure(error):
            // Any lost answer on the way keeps the attempt uncertain, even
            // if the last answer was a refusal.
            await abandon(attempt, mayHaveLanded: outcome.mayHaveLanded)
            throw Self.failure(error)
        }
        guard record.deviceServiceId == id, record.platform == .ios, record.state == .active,
              record.enrollmentEpoch == 1, record.approvalKeyId == approvalKid, record.scopes.isEmpty else {
            await abandon(attempt, mayHaveLanded: true)
            throw .refused
        }
        let registration = PhoneApprovalRegistration(
            owner: owner, installation: attempt.installation, generation: attempt.generation,
            deviceServiceId: id, enrollmentEpoch: 1, identityKeyId: record.identityKeyId,
            approvalKeyId: record.approvalKeyId, enrolledAt: record.createdAt, pendingGeneration: nil)
        let committed: Bool
        do { committed = try await registrations.commit(registration, attempt: id, epoch: epoch) } catch {
            // The disk refused: the journalled attempt is still on disk, so
            // the ID survives for a later refresh or sign-out to revoke.
            await abandon(attempt, mayHaveLanded: true)
            throw .generic
        }
        guard committed else {
            // Signed out while the request was in flight: revoke, never save.
            await abandon(attempt, mayHaveLanded: true)
            throw .generic
        }
        return .on(since: registration.since)
    }

    /// Ends an attempt that did not register: records its revocation when it
    /// may have reached the server and deletes its keys. The journal entry
    /// (which names the keys) is dropped only when the keys are confirmed
    /// gone and the revocation, if needed, is recorded; until then the
    /// attempt stays unresolved and every refresh and sign-out retries it.
    private func abandon(_ attempt: PhoneApprovalPendingAttempt, mayHaveLanded: Bool) async {
        var settled = vault.delete(attempt.namespace)
        if mayHaveLanded {
            if (try? await revocations.enqueue(owner: attempt.owner, id: attempt.deviceServiceId)) == nil { settled = false }
        }
        if settled { try? await registrations.resolve(attempt.deviceServiceId) }
        if mayHaveLanded { await retryRevocations(owner: attempt.owner) }
    }

    /// Remove from this iPhone: the revocation is made durable first, then
    /// tried; local authority goes even offline.
    public func remove(owner: String) async throws(PhoneApprovalRemoveFailure) -> PhoneApprovalStatus {
        guard let registration = await registrations.registration(owner: owner) else {
            try? await registrations.clearNeedsSetUpAgain(owner: owner)
            return await status(owner: owner)
        }
        do { try await revocations.enqueue(owner: owner, id: registration.deviceServiceId) } catch { throw .notRecorded }
        var deleted = vault.delete(registration.namespace)
        if let pending = registration.pendingNamespace { deleted = vault.delete(pending) && deleted }
        if !deleted {
            // Keep the namespace until both roles are confirmed gone.
            do {
                try await registrations.addOrphan(PhoneApprovalOrphanKeys(registration.namespace, owner: owner))
                if let pending = registration.pendingNamespace {
                    try await registrations.addOrphan(PhoneApprovalOrphanKeys(pending, owner: owner))
                }
            } catch { throw .notRecorded }
        }
        _ = try? await registrations.remove(expected: registration, needsSetUpAgain: false)
        await retryRevocations(owner: owner)
        if !deleted { throw .keysRemain }
        return await status(owner: owner)
    }

    /// Sign-out, while the bearer still works. Fences every in-flight
    /// operation of the owner (on any lifecycle sharing the store), records
    /// the revocation of the registration and of every journalled attempt,
    /// asks the server to revoke them and sweeps any other active
    /// registration bound to this Matrix device, then deletes every approval
    /// key of the owner. Credentials may go only when `allowsSignOut`.
    /// `hasClient` false: the session was refused and `server` cannot reach
    /// anything, so confirmed key deletion is all that can be asked.
    public func signOut(owner: String, matrixDeviceID: String?, hasClient: Bool = true) async -> PhoneApprovalSignOutResult {
        await registrations.fence(owner: owner)
        let attempts = await registrations.pending(owner: owner)
        let registration = await registrations.registration(owner: owner)
        var ids = attempts.map(\.deviceServiceId)
        if let registration { ids.insert(registration.deviceServiceId, at: 0) }
        var recorded = true
        for id in ids where (try? await revocations.enqueue(owner: owner, id: id)) == nil { recorded = false }
        await retryRevocations(owner: owner)
        let swept = await Self.sweep(server: server, matrixDeviceID: matrixDeviceID)
        let owed = await revocations.pending(owner: owner)
        let serverRevoked = swept && owed.isEmpty
        var keysDeleted = vault.wipe(owner: owner)
        if !keysDeleted { keysDeleted = vault.wipe(owner: owner) }   // one retry
        if keysDeleted {
            for orphan in await registrations.orphans() where orphan.owner == owner {
                try? await registrations.removeOrphan(orphan)
            }
        }
        // Forget only what is settled: while keys remain, the registration and
        // every attempt stay recorded (they name the keys), so a later
        // sign-out still treats them as unresolved.
        if keysDeleted && recorded { try? await registrations.forget(owner: owner) }
        supported = nil
        return PhoneApprovalSignOutResult(keysDeleted: keysDeleted, revocationRecorded: recorded,
                                          serverRevoked: serverRevoked, unresolvedAttempt: !attempts.isEmpty,
                                          keysSuffice: !hasClient)
    }

    /// Sign-out when the state files cannot be opened at all: nothing can be
    /// recorded locally, so it deletes every key of the owner (which is what
    /// releases sign-out) and, best effort, revokes on the server every active
    /// registration bound to this Matrix device. Offline, without a client or
    /// without a Matrix device ID, the sweep is skipped, never a blocker.
    public static func signOutWithoutState(owner: String, matrixDeviceID: String?, server: PhoneApprovalServer?,
                                           vault: PhoneApprovalKeyVault) async -> PhoneApprovalSignOutResult {
        var keysDeleted = vault.wipe(owner: owner)
        if !keysDeleted { keysDeleted = vault.wipe(owner: owner) }
        let swept = await sweep(server: server, matrixDeviceID: matrixDeviceID)
        return PhoneApprovalSignOutResult(keysDeleted: keysDeleted, revocationRecorded: false,
                                          serverRevoked: swept, unresolvedAttempt: false, keysSuffice: true)
    }

    /// Revokes every active iOS registration bound to `matrixDeviceID`. True
    /// when the server confirmed none remains active.
    static func sweep(server: PhoneApprovalServer?, matrixDeviceID: String?) async -> Bool {
        guard let server, let matrixDeviceID, let list = try? await server.registrations() else { return false }
        var clean = true
        for record in list where record.platform == .ios && record.state == .active && record.matrix.deviceId == matrixDeviceID {
            do { _ = try await server.revoke(record.deviceServiceId) }
            catch let error as PhoneRegistryError where error.error == .notFound { /* already gone */ }
            catch { clean = false }
        }
        return clean
    }

    /// Rotation: new keys in a new generation, signed by them and by the
    /// current approval key (two system prompts), at the next epoch.
    ///
    /// Not reachable from the app (review round 2, option b): it has no
    /// screen, and its orphan journalling of the new generation is not yet
    /// safe against a crash mid-promotion. Internal, for tests only, until
    /// rotation gets a screen and a single-write promotion.
    func rotate(owner: String, identity: PhoneApprovalMatrixIdentity, device: PhoneApprovalDeviceFacts,
                       reason: String) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        guard device.authentication != .noPasscode else { throw .noPasscode }
        let epoch = await registrations.epoch(owner: owner)
        guard let current = await registrations.registration(owner: owner), current.pendingGeneration == nil else { throw .generic }
        guard vault.keysExist(for: current.namespace) else {
            // Recovery, never rotation, when the old key is gone.
            _ = await discard(current, needsSetUpAgain: true, revoke: true)
            throw .generic
        }
        let controllers: [String]
        do { controllers = try await server.controllerKeyIDs() } catch { throw Self.failure(error) }
        let previous = vault.store(for: current.namespace)
        let namespace = PhoneKeyNamespace(owner: owner, installation: current.installation, generation: UUID())
        // Journal the new generation's keys first (as an orphan to delete
        // unless the rotation registers), so a failure cannot leak them.
        let orphan = PhoneApprovalOrphanKeys(namespace, owner: owner)
        do { try await registrations.addOrphan(orphan) } catch { throw .generic }
        let keys = vault.store(for: namespace)
        let epochNext = current.enrollmentEpoch + 1
        let request: Data
        do {
            try keys.create(.identity)
            try keys.create(.approval)
            let body = try PhoneEnrollment.body(
                id: current.deviceServiceId, displayName: device.displayName, osVersion: device.osVersion,
                matrixUserID: identity.userID, matrixDeviceID: identity.deviceID,
                matrixFingerprint: identity.fingerprint, epoch: epochNext, controllerKeyIDs: controllers,
                issuedAt: Int64(now().timeIntervalSince1970 * 1_000), keys: keys, previous: previous)
            request = try PhoneEnrollment.request(body: body, keys: keys, rotatingFrom: previous, reason: reason)
        } catch {
            await deleteOrRemember(namespace, owner: owner, clearing: orphan)
            throw Self.signingFailure(error)
        }
        let outcome = await post(request)
        let record: PhoneRegistryRecord
        switch outcome.result {
        case let .success(value): record = value
        case let .failure(error):
            if outcome.mayHaveLanded {
                // Keep both generations; `refresh` learns which one won.
                var pending = current
                pending.pendingGeneration = namespace.generation
                if (try? await registrations.replace(expected: current, with: pending)) == true {
                    try? await registrations.removeOrphan(orphan)
                }
            } else {
                await deleteOrRemember(namespace, owner: owner, clearing: orphan)
            }
            throw Self.failure(error)
        }
        let approvalKid = (try? keys.publicKey(.approval)).map(PhoneEnrollment.keyID(spki:))
        guard record.deviceServiceId == current.deviceServiceId, record.state == .active,
              record.enrollmentEpoch == epochNext, record.approvalKeyId == approvalKid else {
            await deleteOrRemember(namespace, owner: owner, clearing: orphan)
            throw .refused
        }
        let rotated = PhoneApprovalRegistration(
            owner: owner, installation: current.installation, generation: namespace.generation,
            deviceServiceId: current.deviceServiceId, enrollmentEpoch: epochNext,
            identityKeyId: record.identityKeyId, approvalKeyId: record.approvalKeyId,
            enrolledAt: current.enrolledAt, pendingGeneration: nil)
        guard await registrations.epoch(owner: owner) == epoch,
              (try? await registrations.replace(expected: current, with: rotated)) == true else {
            // Signed out or changed meanwhile: the new keys go (the old
            // registration's revocation is sign-out's job).
            await deleteOrRemember(namespace, owner: owner, clearing: orphan)
            throw .generic
        }
        try? await registrations.removeOrphan(orphan)
        await deleteOrRemember(current.namespace, owner: owner)
        return .on(since: rotated.since)
    }

    /// Owed revocations for this owner, on every authenticated connection.
    public func retryRevocations(owner: String) async {
        let server = self.server
        try? await revocations.retry(owner: owner) { id in _ = try await server.revoke(id) }
    }

    public func pendingRevocations(owner: String) async -> [UUID] {
        await revocations.pending(owner: owner).map(\.id)
    }

    // MARK: Internals

    private func probe() async {
        guard supported != true else { return }
        do { supported = try await server.supportsPhoneRegistry() } catch { /* unknown: stay closed */ }
    }

    /// The identical signed request again, for transient failures only.
    /// `mayHaveLanded` stays true once any attempt's answer was lost.
    private func post(_ request: Data) async -> (result: Result<PhoneRegistryRecord, Error>, mayHaveLanded: Bool) {
        var attempt = 0
        var mayHaveLanded = false
        while true {
            do { return (.success(try await server.enroll(request)), mayHaveLanded) }
            catch {
                if Self.isAmbiguous(error) { mayHaveLanded = true }
                guard Self.isTransient(error), attempt < retryDelays.count else { return (.failure(error), mayHaveLanded) }
                try? await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Attempts left by a failure, a crash or a fence: revoke and delete.
    private func resolveStaleAttempts(owner: String) async {
        for attempt in await registrations.stalePending(owner: owner) {
            await abandon(attempt, mayHaveLanded: true)
        }
    }

    /// Retries deleting orphaned keys, never a namespace a registration or a
    /// live attempt still uses.
    private func retryOrphans() async {
        for orphan in await registrations.orphans() {
            guard await !registrations.inUse(orphan.namespace) else { continue }
            if vault.delete(orphan.namespace) { try? await registrations.removeOrphan(orphan) }
        }
    }

    /// Deletes a namespace's keys, or records it as an orphan to retry.
    /// False when the keys remain and recording them failed: the caller must
    /// keep whatever record still names them.
    @discardableResult
    private func deleteOrRemember(_ namespace: PhoneKeyNamespace, owner: String,
                                  clearing journal: PhoneApprovalOrphanKeys? = nil) async -> Bool {
        if vault.delete(namespace) {
            if let journal { try? await registrations.removeOrphan(journal) }
            return true
        }
        return (try? await registrations.addOrphan(PhoneApprovalOrphanKeys(namespace, owner: owner))) != nil
    }

    /// Drops `registration` (only if it is still the owner's current one),
    /// recording its revocation first when asked. Keys that cannot be
    /// deleted are remembered. False when nothing could be recorded.
    private func discard(_ registration: PhoneApprovalRegistration, needsSetUpAgain: Bool, revoke: Bool) async -> Bool {
        if revoke {
            guard (try? await revocations.enqueue(owner: registration.owner, id: registration.deviceServiceId)) != nil else {
                return false
            }
        }
        guard await deleteOrRemember(registration.namespace, owner: registration.owner) else { return false }
        if let pending = registration.pendingNamespace {
            guard await deleteOrRemember(pending, owner: registration.owner) else { return false }
        }
        _ = try? await registrations.remove(expected: registration, needsSetUpAgain: needsSetUpAgain)
        if revoke { await retryRevocations(owner: registration.owner) }
        return true
    }

    static func isTransient(_ error: Error) -> Bool {
        if let registry = error as? PhoneRegistryError { return registry.error == .unavailable }
        if let client = error as? NativeDomainClientFailure { return client == .transportUnavailable }
        return error is URLError
    }

    /// The request may have reached the server.
    static func isAmbiguous(_ error: Error) -> Bool {
        if error is PhoneRegistryError { return isTransient(error) }
        return true
    }

    static func failure(_ error: Error) -> PhoneApprovalSetupFailure {
        if isTransient(error) { return .offline }
        if let registry = error as? PhoneRegistryError {
            return registry.error == .unauthenticated ? .generic : .refused
        }
        return .generic
    }

    static func signingFailure(_ error: Error) -> PhoneApprovalSetupFailure {
        switch error as? PhoneApprovalFailure {
        case .cancelled?: return .cancelled
        // Key creation or the prompt could not start (locked, no Secure Enclave).
        case .setupRequired?, .keychain?: return .noPrompt
        default: return .generic
        }
    }
}

/// Stands in for the registry when no authenticated client exists (sign-out
/// after the session was refused): every call is "offline", so a removal
/// records its revocation for the next sign-in and discards local authority.
public struct PhoneApprovalUnreachableServer: PhoneApprovalServer {
    public init() {}
    public func supportsPhoneRegistry() async throws -> Bool { throw NativeDomainClientFailure.transportUnavailable }
    public func controllerKeyIDs() async throws -> [String] { throw NativeDomainClientFailure.transportUnavailable }
    public func enroll(_ request: Data) async throws -> PhoneRegistryRecord { throw NativeDomainClientFailure.transportUnavailable }
    public func registrations() async throws -> [PhoneRegistryRecord] { throw NativeDomainClientFailure.transportUnavailable }
    public func revoke(_ id: UUID) async throws -> PhoneRegistryRecord { throw NativeDomainClientFailure.transportUnavailable }
}
