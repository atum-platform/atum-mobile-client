import Foundation

/// How phone-approval state files are written. Tests inject a writer that can
/// fail on demand (a full disk); production writes atomically with file
/// protection.
public struct PhoneApprovalFileWriter: Sendable {
    public let write: @Sendable (Data, URL) throws -> Void
    public init(_ write: @escaping @Sendable (Data, URL) throws -> Void) { self.write = write }

    public static let atomic = PhoneApprovalFileWriter { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Recovery from an undecodable state file: set it aside (never delete it)
/// and read what is still readable.
enum PhoneApprovalSalvage {
    static func setAside(_ file: URL) throws {
        let aside = file.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: file, to: aside)
    }

    /// Every JSON object anywhere in `data`, depth first. Nothing when the
    /// bytes are not JSON at all.
    static func objects(in data: Data, _ visit: ([String: Any]) -> Void) {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                visit(object)
                object.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)
    }
}

/// An enrolment or rotation that has keys and may have reached the server.
/// It is written before any key exists or any request is sent, and removed
/// only once the attempt is registered, or revoked and its keys deleted.
public struct PhoneApprovalPendingAttempt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case enroll, rotate }
    public let owner: String
    public let deviceServiceId: UUID
    public let installation: UUID
    public let generation: UUID
    public let kind: Kind
    public var namespace: PhoneKeyNamespace {
        PhoneKeyNamespace(owner: owner, installation: installation, generation: generation)
    }
}

/// Keys whose deletion failed: kept until both roles are confirmed gone.
public struct PhoneApprovalOrphanKeys: Codable, Equatable, Sendable {
    public let owner: String
    public let installation: UUID
    public let generation: UUID
    public init(_ namespace: PhoneKeyNamespace, owner: String) {
        self.owner = owner
        installation = namespace.installation
        generation = namespace.generation
    }
    public var namespace: PhoneKeyNamespace {
        PhoneKeyNamespace(owner: owner, installation: installation, generation: generation)
    }
}

public enum PhoneApprovalStoreFailure: Error, Equatable, Sendable {
    /// The owner signed out (or another fence moved) after the operation began.
    case fenced
}

/// Registration metadata under Application Support (included in backups on
/// purpose: a restored iPhone then finds a registration whose device-only keys
/// did not come with it, revokes it and says "Approvals need setting up
/// again", instead of leaving a stale registration on the server).
///
/// One store per app, shared by every lifecycle, so the per-owner fence and
/// the in-flight set cover lifecycles created for replacement clients.
public actor PhoneApprovalRegistrationStore {
    struct State: Codable, Equatable {
        var installation: UUID
        var registrations: [String: PhoneApprovalRegistration] = [:]
        var needsSetUpAgain: Set<String> = []
        var pending: [PhoneApprovalPendingAttempt] = []
        var orphans: [PhoneApprovalOrphanKeys] = []

        init(installation: UUID) { self.installation = installation }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            installation = try c.decode(UUID.self, forKey: .installation)
            registrations = try c.decodeIfPresent([String: PhoneApprovalRegistration].self, forKey: .registrations) ?? [:]
            needsSetUpAgain = try c.decodeIfPresent(Set<String>.self, forKey: .needsSetUpAgain) ?? []
            pending = try c.decodeIfPresent([PhoneApprovalPendingAttempt].self, forKey: .pending) ?? []
            orphans = try c.decodeIfPresent([PhoneApprovalOrphanKeys].self, forKey: .orphans) ?? []
        }
    }
    private let file: URL
    private let writer: PhoneApprovalFileWriter
    private var state: State
    /// Per-owner fence, in memory: sign-out moves it, and an operation that
    /// began before cannot commit after.
    private var epochs: [String: Int] = [:]
    /// Attempts a live operation is still working on (not stale).
    private var inFlight: Set<UUID> = []

    /// Strict: throws on an unreadable file.
    public init(file: URL, writer: PhoneApprovalFileWriter = .atomic) throws {
        self.file = file
        self.writer = writer
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else {
            state = State(installation: UUID())
        }
    }

    private init(file: URL, writer: PhoneApprovalFileWriter, state: State) {
        self.file = file
        self.writer = writer
        self.state = state
    }

    /// For the app: an undecodable file is set aside (kept) and every
    /// registration, pending attempt or orphan still readable in it becomes a
    /// pending attempt or orphan of a fresh state, so the next refresh or
    /// sign-out revokes it and deletes its keys. Throws only when the file
    /// cannot be read, set aside or replaced.
    public static func recovering(file: URL, writer: PhoneApprovalFileWriter = .atomic) throws -> PhoneApprovalRegistrationStore {
        do { return try PhoneApprovalRegistrationStore(file: file, writer: writer) } catch {
            let data = try Data(contentsOf: file)
            try PhoneApprovalSalvage.setAside(file)
            var fresh = State(installation: UUID())
            PhoneApprovalSalvage.objects(in: data) { object in
                guard let owner = object["owner"] as? String,
                      let installation = (object["installation"] as? String).flatMap(UUID.init(uuidString:)),
                      let generation = (object["generation"] as? String).flatMap(UUID.init(uuidString:)) else { return }
                if let id = (object["deviceServiceId"] as? String).flatMap(UUID.init(uuidString:)) {
                    let attempt = PhoneApprovalPendingAttempt(owner: owner, deviceServiceId: id, installation: installation,
                                                              generation: generation, kind: .enroll)
                    if !fresh.pending.contains(attempt) { fresh.pending.append(attempt) }
                    fresh.needsSetUpAgain.insert(owner)
                } else {
                    let orphan = PhoneApprovalOrphanKeys(PhoneKeyNamespace(owner: owner, installation: installation,
                                                                           generation: generation), owner: owner)
                    if !fresh.orphans.contains(orphan) { fresh.orphans.append(orphan) }
                }
            }
            try writer.write(JSONEncoder().encode(fresh), file)
            return PhoneApprovalRegistrationStore(file: file, writer: writer, state: fresh)
        }
    }

    public var installation: UUID { state.installation }
    public func registration(owner: String) -> PhoneApprovalRegistration? { state.registrations[owner] }
    public func needsSetUpAgain(owner: String) -> Bool { state.needsSetUpAgain.contains(owner) }

    // MARK: Fence

    public func epoch(owner: String) -> Int { epochs[owner, default: 0] }
    /// Moves the owner's fence: every operation that began before is stale.
    @discardableResult
    public func fence(owner: String) -> Int {
        epochs[owner, default: 0] += 1
        return epochs[owner, default: 0]
    }

    // MARK: Attempts

    /// Records the attempt durably before any key or request exists.
    public func begin(_ attempt: PhoneApprovalPendingAttempt, epoch: Int) throws {
        guard epoch == self.epoch(owner: attempt.owner) else { throw PhoneApprovalStoreFailure.fenced }
        var next = state
        next.pending.append(attempt)
        try write(next)
        inFlight.insert(attempt.deviceServiceId)
    }
    /// The live operation has finished with the attempt (resolved or not).
    public func end(_ id: UUID) { inFlight.remove(id) }
    public func pending(owner: String) -> [PhoneApprovalPendingAttempt] { state.pending.filter { $0.owner == owner } }
    /// Attempts no live operation owns: left by a failure, a crash or a fence.
    public func stalePending(owner: String) -> [PhoneApprovalPendingAttempt] {
        pending(owner: owner).filter { !inFlight.contains($0.deviceServiceId) }
    }
    public func resolve(_ id: UUID) throws {
        var next = state
        next.pending.removeAll { $0.deviceServiceId == id }
        try write(next)
    }

    /// Registers `registration` and drops its attempt in one write, only if
    /// the owner's fence has not moved since `epoch`. False: fenced, nothing
    /// written.
    public func commit(_ registration: PhoneApprovalRegistration, attempt id: UUID, epoch: Int) throws -> Bool {
        guard epoch == self.epoch(owner: registration.owner) else { return false }
        var next = state
        next.registrations[registration.owner] = registration
        next.needsSetUpAgain.remove(registration.owner)
        next.pending.removeAll { $0.deviceServiceId == id }
        try write(next)
        return true
    }

    // MARK: Registrations

    public func save(_ registration: PhoneApprovalRegistration) throws {
        var next = state
        next.registrations[registration.owner] = registration
        next.needsSetUpAgain.remove(registration.owner)
        try write(next)
    }

    /// Replaces the owner's registration only while it is still `expected`
    /// (same ID and generation). False: it changed meanwhile, nothing written.
    public func replace(expected: PhoneApprovalRegistration, with next: PhoneApprovalRegistration) throws -> Bool {
        guard Self.same(state.registrations[expected.owner], expected) else { return false }
        var updated = state
        updated.registrations[expected.owner] = next
        try write(updated)
        return true
    }

    /// Removes the owner's registration only while it is still `expected`.
    /// False: it changed meanwhile (a newer registration is never dropped).
    public func remove(expected: PhoneApprovalRegistration, needsSetUpAgain: Bool) throws -> Bool {
        guard Self.same(state.registrations[expected.owner], expected) else { return false }
        var next = state
        next.registrations.removeValue(forKey: expected.owner)
        if needsSetUpAgain { next.needsSetUpAgain.insert(expected.owner) } else { next.needsSetUpAgain.remove(expected.owner) }
        try write(next)
        return true
    }

    /// Sign-out: forgets everything about the owner except orphan keys.
    public func forget(owner: String) throws {
        var next = state
        next.registrations.removeValue(forKey: owner)
        next.needsSetUpAgain.remove(owner)
        next.pending.removeAll { $0.owner == owner }
        try write(next)
    }

    public func clearNeedsSetUpAgain(owner: String) throws {
        var next = state
        next.needsSetUpAgain.remove(owner)
        try write(next)
    }

    // MARK: Orphan keys

    public func orphans() -> [PhoneApprovalOrphanKeys] { state.orphans }
    public func addOrphan(_ orphan: PhoneApprovalOrphanKeys) throws {
        guard !state.orphans.contains(orphan) else { return }
        var next = state
        next.orphans.append(orphan)
        try write(next)
    }
    public func removeOrphan(_ orphan: PhoneApprovalOrphanKeys) throws {
        var next = state
        next.orphans.removeAll { $0 == orphan }
        try write(next)
    }

    private static func same(_ a: PhoneApprovalRegistration?, _ b: PhoneApprovalRegistration) -> Bool {
        a?.deviceServiceId == b.deviceServiceId && a?.generation == b.generation
    }

    private func write(_ next: State) throws {
        guard next != state || !FileManager.default.fileExists(atPath: file.path) else { return }
        try writer.write(JSONEncoder().encode(next), file)
        state = next
    }
}
