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

/// Registration metadata under Application Support (included in backups on
/// purpose: a restored iPhone then finds a registration whose device-only keys
/// did not come with it, revokes it and says "Approvals need setting up
/// again", instead of leaving a stale registration on the server).
public actor PhoneApprovalRegistrationStore {
    struct State: Codable, Equatable {
        var installation: UUID
        var registrations: [String: PhoneApprovalRegistration] = [:]
        var needsSetUpAgain: Set<String> = []
    }
    private let file: URL
    private var state: State

    /// Throws on an unreadable file: the caller fails closed (no Settings row)
    /// rather than forgetting a registration it may still have to revoke.
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else {
            state = State(installation: UUID())
        }
    }

    public var installation: UUID { state.installation }
    public func registration(owner: String) -> PhoneApprovalRegistration? { state.registrations[owner] }
    public func needsSetUpAgain(owner: String) -> Bool { state.needsSetUpAgain.contains(owner) }

    public func save(_ registration: PhoneApprovalRegistration) throws {
        var next = state
        next.registrations[registration.owner] = registration
        next.needsSetUpAgain.remove(registration.owner)
        try write(next)
    }
    public func remove(owner: String, needsSetUpAgain: Bool) throws {
        var next = state
        next.registrations.removeValue(forKey: owner)
        if needsSetUpAgain { next.needsSetUpAgain.insert(owner) } else { next.needsSetUpAgain.remove(owner) }
        try write(next)
    }

    private func write(_ next: State) throws {
        guard next != state || !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = next
    }
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

/// The phone half of slice 2's lifecycle: set up, refresh, remove, sign out,
/// rotate, recover from key loss, and retry revocations. One per app.
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
        if await registrations.needsSetUpAgain(owner: owner) { return .needsSetUpAgain }
        return supported == true ? .off : .unavailable
    }

    /// Retries owed revocations, asks the server what it supports, checks the
    /// local keys, and reconciles this iPhone's registration with the server's
    /// list (removed elsewhere, or rotated while the answer was lost).
    @discardableResult
    public func refresh(owner: String) async -> PhoneApprovalStatus {
        await retryRevocations(owner: owner)
        await probe()
        guard var registration = await registrations.registration(owner: owner) else {
            if await registrations.needsSetUpAgain(owner: owner) { return supported == false ? .unavailable : .needsSetUpAgain }
            return supported == true ? .off : .unavailable
        }
        guard vault.keysExist(for: registration.namespace) else {
            await discard(registration, needsSetUpAgain: true, revoke: true)
            return .needsSetUpAgain
        }
        guard supported != false, let list = try? await server.registrations() else {
            return .on(since: registration.since)
        }
        let record = list.first { $0.deviceServiceId == registration.deviceServiceId }
        if let pending = registration.pendingNamespace {
            let pendingKeys = vault.store(for: pending)
            let pendingKid = (try? pendingKeys.publicKey(.approval)).map(PhoneEnrollment.keyID(spki:))
            if let record, record.state == .active, record.approvalKeyId == pendingKid {
                // The lost rotation did land: promote it, drop the old keys.
                let promoted = PhoneApprovalRegistration(
                    owner: owner, installation: registration.installation, generation: pending.generation,
                    deviceServiceId: registration.deviceServiceId, enrollmentEpoch: record.enrollmentEpoch,
                    identityKeyId: record.identityKeyId, approvalKeyId: record.approvalKeyId,
                    enrolledAt: record.createdAt, pendingGeneration: nil)
                guard (try? await registrations.save(promoted)) != nil else { return .on(since: registration.since) }
                remove(vault.store(for: registration.namespace))
                return .on(since: promoted.since)
            }
            remove(pendingKeys)
            registration.pendingGeneration = nil
            try? await registrations.save(registration)
        }
        guard let record, record.state == .active else {
            // Removed in Your devices on another device, or never admitted.
            await discard(registration, needsSetUpAgain: false, revoke: false)
            return .off
        }
        guard record.platform == .ios, record.approvalKeyId == registration.approvalKeyId else {
            await discard(registration, needsSetUpAgain: true, revoke: true)
            return .needsSetUpAgain
        }
        return .on(since: registration.since)
    }

    /// Creates both keys in a new namespace, signs the enrolment with a fresh
    /// Face ID or passcode, and registers. Never reuses an old registration.
    public func setUp(owner: String, identity: PhoneApprovalMatrixIdentity, device: PhoneApprovalDeviceFacts,
                      reason: String) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        guard device.authentication != .noPasscode else { throw .noPasscode }
        guard identity.userID == owner else { throw .generic }
        await probe()
        guard let supported else { throw .offline }
        guard supported else { throw .unavailable }
        if let stale = await registrations.registration(owner: owner) {
            // One registration per iPhone and owner: the old one goes first.
            guard (try? await revocations.enqueue(owner: owner, id: stale.deviceServiceId)) != nil else { throw .generic }
            await discard(stale, needsSetUpAgain: false, revoke: true)
        }
        let controllers: [String]
        do { controllers = try await server.controllerKeyIDs() } catch { throw Self.failure(error) }
        let id = UUID()
        let namespace = PhoneKeyNamespace(owner: owner, installation: await registrations.installation, generation: UUID())
        let keys = vault.store(for: namespace)
        let request: Data
        do {
            try keys.create(.identity)
            try keys.create(.approval)
            let body = try PhoneEnrollment.body(
                id: id, displayName: device.displayName, osVersion: device.osVersion,
                matrixUserID: identity.userID, matrixDeviceID: identity.deviceID,
                matrixFingerprint: identity.fingerprint, controllerKeyIDs: controllers,
                issuedAt: Int64(now().timeIntervalSince1970 * 1_000), keys: keys)
            request = try PhoneEnrollment.request(body: body, keys: keys, reason: reason)
        } catch {
            remove(keys)
            throw Self.signingFailure(error)
        }
        let approvalKid: String
        do { approvalKid = PhoneEnrollment.keyID(spki: try keys.publicKey(.approval)) }
        catch { remove(keys); throw .generic }
        let record: PhoneRegistryRecord
        do {
            record = try await post(request)
        } catch {
            remove(keys)
            // The answer may have been lost after the server enrolled: revoke
            // that ID so no registration outlives its deleted key.
            if Self.isAmbiguous(error) {
                try? await revocations.enqueue(owner: owner, id: id)
                await retryRevocations(owner: owner)
            }
            throw Self.failure(error)
        }
        guard record.deviceServiceId == id, record.platform == .ios, record.state == .active,
              record.enrollmentEpoch == 1, record.approvalKeyId == approvalKid, record.scopes.isEmpty else {
            remove(keys)
            try? await revocations.enqueue(owner: owner, id: id)
            await retryRevocations(owner: owner)
            throw .refused
        }
        let registration = PhoneApprovalRegistration(
            owner: owner, installation: namespace.installation, generation: namespace.generation,
            deviceServiceId: id, enrollmentEpoch: 1, identityKeyId: record.identityKeyId,
            approvalKeyId: record.approvalKeyId, enrolledAt: record.createdAt, pendingGeneration: nil)
        do { try await registrations.save(registration) } catch {
            remove(keys)
            try? await revocations.enqueue(owner: owner, id: id)
            await retryRevocations(owner: owner)
            throw .generic
        }
        return .on(since: registration.since)
    }

    /// Remove from this iPhone: the revocation is made durable first, then
    /// tried; local authority goes even offline. Throws only when the
    /// revocation could not be recorded (nothing was removed then).
    public func remove(owner: String) async throws -> PhoneApprovalStatus {
        guard let registration = await registrations.registration(owner: owner) else {
            try? await registrations.remove(owner: owner, needsSetUpAgain: false)
            return supported == false ? .unavailable : .off
        }
        try await revocations.enqueue(owner: owner, id: registration.deviceServiceId)
        await discard(registration, needsSetUpAgain: false, revoke: true)
        return supported == false ? .unavailable : .off
    }

    /// Sign-out: call while the bearer still works. False means the
    /// revocation could not be recorded, so the caller must keep credentials.
    public func signOut(owner: String) async -> Bool {
        do { _ = try await remove(owner: owner) } catch { return false }
        supported = nil
        return true
    }

    /// Rotation: new keys in a new generation, signed by them and by the
    /// current approval key (two system prompts), at the next epoch.
    public func rotate(owner: String, identity: PhoneApprovalMatrixIdentity, device: PhoneApprovalDeviceFacts,
                       reason: String) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        guard device.authentication != .noPasscode else { throw .noPasscode }
        guard var current = await registrations.registration(owner: owner), current.pendingGeneration == nil else { throw .generic }
        guard vault.keysExist(for: current.namespace) else {
            // Recovery, never rotation, when the old key is gone.
            await discard(current, needsSetUpAgain: true, revoke: true)
            throw .generic
        }
        let controllers: [String]
        do { controllers = try await server.controllerKeyIDs() } catch { throw Self.failure(error) }
        let previous = vault.store(for: current.namespace)
        let namespace = PhoneKeyNamespace(owner: owner, installation: current.installation, generation: UUID())
        let keys = vault.store(for: namespace)
        let epoch = current.enrollmentEpoch + 1
        let request: Data
        do {
            try keys.create(.identity)
            try keys.create(.approval)
            let body = try PhoneEnrollment.body(
                id: current.deviceServiceId, displayName: device.displayName, osVersion: device.osVersion,
                matrixUserID: identity.userID, matrixDeviceID: identity.deviceID,
                matrixFingerprint: identity.fingerprint, epoch: epoch, controllerKeyIDs: controllers,
                issuedAt: Int64(now().timeIntervalSince1970 * 1_000), keys: keys, previous: previous)
            request = try PhoneEnrollment.request(body: body, keys: keys, rotatingFrom: previous, reason: reason)
        } catch {
            remove(keys)
            throw Self.signingFailure(error)
        }
        let record: PhoneRegistryRecord
        do {
            record = try await post(request)
        } catch {
            if Self.isAmbiguous(error) {
                // Keep both generations; `refresh` learns which one won.
                current.pendingGeneration = namespace.generation
                try? await registrations.save(current)
            } else {
                remove(keys)
            }
            throw Self.failure(error)
        }
        let approvalKid = (try? keys.publicKey(.approval)).map(PhoneEnrollment.keyID(spki:))
        guard record.deviceServiceId == current.deviceServiceId, record.state == .active,
              record.enrollmentEpoch == epoch, record.approvalKeyId == approvalKid else {
            remove(keys)
            throw .refused
        }
        let rotated = PhoneApprovalRegistration(
            owner: owner, installation: current.installation, generation: namespace.generation,
            deviceServiceId: current.deviceServiceId, enrollmentEpoch: epoch,
            identityKeyId: record.identityKeyId, approvalKeyId: record.approvalKeyId,
            enrolledAt: current.enrolledAt, pendingGeneration: nil)
        do { try await registrations.save(rotated) } catch {
            current.pendingGeneration = namespace.generation
            try? await registrations.save(current)
            throw .generic
        }
        remove(previous)
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
    private func post(_ request: Data) async throws -> PhoneRegistryRecord {
        var attempt = 0
        while true {
            do { return try await server.enroll(request) }
            catch where Self.isTransient(error) && attempt < retryDelays.count {
                try? await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private func discard(_ registration: PhoneApprovalRegistration, needsSetUpAgain: Bool, revoke: Bool) async {
        if revoke {
            try? await revocations.enqueue(owner: registration.owner, id: registration.deviceServiceId)
        }
        remove(vault.store(for: registration.namespace))
        if let pending = registration.pendingNamespace { remove(vault.store(for: pending)) }
        try? await registrations.remove(owner: registration.owner, needsSetUpAgain: needsSetUpAgain)
        if revoke { await retryRevocations(owner: registration.owner) }
    }

    private nonisolated func remove(_ keys: PhoneApprovalKeyStore) {
        try? keys.remove(.approval)
        try? keys.remove(.identity)
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
