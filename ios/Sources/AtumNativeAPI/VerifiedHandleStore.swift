import Foundation

/// Account-scoped directory evidence, shared by owner identity, rosters and pickers.
/// Values are bare handles; presentation adds the at sign. Failures publish nothing.
@MainActor public final class VerifiedHandleStore {
    public typealias Current = @MainActor () async throws -> AliasCurrentResponse
    public typealias Contacts = @MainActor (AliasContactsRequest) async throws -> AliasContactsResponse
    public var onChange: (@MainActor ([String: String]) -> Void)?
    public private(set) var owner: String?
    public private(set) var knownHandles: [String: String] = [:]
    public var ownHandle: String? { owner.flatMap { knownHandles[$0] } }
    public func handle(for userID: String) -> String? { knownHandles[userID] }

    private struct Entry: Codable {
        var handle: String
        var at: Date
        var exact: Bool
    }
    private let defaults: UserDefaults?
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var current: Current?
    private var contacts: Contacts?
    private var ownAnswered: Set<String> = []
    private var ownTask: Task<Void, Never>?
    private var contactsTask: Task<Void, Never>?
    private var queued: [String] = []
    private var inFlight: Set<String> = []
    private var misses: [String: Date] = [:]
    private var revision: Int64?
    private var legacy = false
    private var sentAt: [Date] = []
    private var failures = 0
    private var waitUntil = Date.distantPast
    private static let keep: TimeInterval = 7 * 24 * 60 * 60
    public static let refreshInterval: TimeInterval = 30 * 60
    private static let nullMemory: TimeInterval = 2 * 60 * 60
    private static let prefix = "atum.matrix.verified-handles.v1:"

    public init(defaults: UserDefaults? = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Bind before publishing an account. A → signed out → A fences old work too.
    public func bind(owner: String?) {
        guard self.owner != owner else { return }
        stopRequests()
        current = nil
        contacts = nil
        self.owner = owner
        entries = [:]
        if let owner, let data = defaults?.data(forKey: Self.prefix + owner),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let date = now()
            entries = stored.filter { user, entry in
                (try? NativeMatrixUser(user)) != nil && (try? NativeHandle(entry.handle)) != nil
                    && entry.at <= date && date.timeIntervalSince(entry.at) < Self.keep
            }
        }
        publish()
    }

    /// Replace on bearer-client changes, even for the same account. Retain evidence,
    /// but retire old in-flight reads and stop queued work while the directory is off.
    public func setDirectory(current: Current?, contacts: Contacts?) {
        stopRequests()
        self.current = current
        self.contacts = contacts
    }

    private func stopRequests() {
        generation &+= 1
        ownTask?.cancel(); ownTask = nil
        contactsTask?.cancel(); contactsTask = nil
        queued = []; inFlight = []; misses = [:]; revision = nil
        legacy = false; sentAt = []; failures = 0; waitUntil = .distantPast
    }

    /// Successful current reads (including null) are reused per account for this store's lifetime.
    /// Concurrent consumers join one read. An unanswered read is eligible next time.
    public func loadOwnHandle() async {
        guard let owner, !ownAnswered.contains(owner), let current else { return }
        if let ownTask { await ownTask.value; return }
        let epoch = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.ownTask = nil } }
            do {
                let result = try await current()
                guard self.generation == epoch, !Task.isCancelled, let owner = self.owner else { return }
                self.ownAnswered.insert(owner)
                switch result {
                case let .assigned(handle, _): self.remember(userID: owner, handle: handle.rawValue)
                case .none: self.entries.removeValue(forKey: owner); self.publish()
                }
            } catch { /* Additive evidence only; keep the last good answer. */ }
        }
        ownTask = task
        await task.value
    }

    /// Only directory-proven search/current/lookup answers belong here.
    public func remember(userID: String, handle: String) {
        remember(userID: userID, handle: handle, exact: true)
    }

    private func remember(userID: String, handle: String, exact: Bool) {
        guard owner != nil, (try? NativeMatrixUser(userID)) != nil,
              (try? NativeHandle(handle)) != nil else { return }
        let previous = entries[userID]
        if !exact, let previous, previous.exact, previous.handle != handle,
           now().timeIntervalSince(previous.at) < Self.refreshInterval { return }
        // A handle has one holder; a fresh proof moves it rather than duplicating it.
        entries = entries.filter { $0.key == userID || $0.value.handle != handle }
        entries[userID] = Entry(handle: handle, at: now(), exact: exact || previous?.exact == true)
        publish()
    }

    private func publish() {
        let next = entries.mapValues(\.handle)
        if next != knownHandles { knownHandles = next; onChange?(next) }
        if let owner, let data = try? JSONEncoder().encode(entries) {
            defaults?.set(data, forKey: Self.prefix + owner)
        }
    }

    /// Pool one render's IDs for 250 ms, then send distinct same-server IDs in
    /// batches of 50. Calling again is safe; fresh hits/misses/in-flight IDs skip.
    public func requestHandles(for userIDs: [String]) {
        guard let owner, contacts != nil else { return }
        let server = owner.split(separator: ":", maxSplits: 1).last
        let date = now()
        for user in userIDs {
            guard user != owner, AliasContactsRequest.accepts(user),
                  user.split(separator: ":", maxSplits: 1).last == server,
                  !queued.contains(user), !inFlight.contains(user),
                  entries[user].map({ date.timeIntervalSince($0.at) >= Self.refreshInterval }) ?? true,
                  misses[user].map({ date.timeIntervalSince($0) >= Self.nullMemory }) ?? true else { continue }
            queued.append(user)
        }
        schedule(after: 0.25)
    }

    private func schedule(after delay: TimeInterval) {
        guard contactsTask == nil, inFlight.isEmpty, !queued.isEmpty else { return }
        let epoch = generation
        contactsTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == epoch else { return }
            self.contactsTask = nil
            await self.flush()
        }
    }

    /// Internal deterministic seam: tests can drain pooled work without wall-clock sleeps.
    func flush() async {
        guard inFlight.isEmpty, !queued.isEmpty, let contacts else { return }
        contactsTask?.cancel(); contactsTask = nil
        let date = now()
        sentAt = sentAt.filter { date.timeIntervalSince($0) < 24 * 60 * 60 }
        let recent = sentAt.filter { date.timeIntervalSince($0) < 10 * 60 }
        let allowedAt = max(waitUntil,
                            recent.count >= 12 ? recent[0].addingTimeInterval(10 * 60) : date,
                            sentAt.count >= 96 ? sentAt[0].addingTimeInterval(24 * 60 * 60) : date)
        if allowedAt > date { schedule(after: allowedAt.timeIntervalSince(date)); return }
        let epoch = generation
        let batch = Array(queued.prefix(AliasContactsRequest.maximumCount))
        queued.removeFirst(batch.count)
        inFlight = Set(batch)
        sentAt.append(date)
        do {
            let result: AliasContactsResponse
            do {
                result = try await contacts(AliasContactsRequest(matrixUsers: batch, versioned: !legacy))
            } catch {
                // Desktop negotiates down only for a versioned 400, never arbitrary failures.
                guard !legacy, AgentAliasRefusal.from(error) == .invalid,
                      generation == epoch, !Task.isCancelled else { throw error }
                result = try await contacts(AliasContactsRequest(matrixUsers: batch, versioned: false))
                guard generation == epoch, !Task.isCancelled else { return }
                legacy = true
            }
            guard generation == epoch, !Task.isCancelled else { return }
            guard result.contacts.map({ $0.matrixUser.rawValue }) == batch else {
                throw NativeDomainClientFailure.invalidResponse
            }
            failures = 0
            if revision != (result.revision ?? 0) { revision = result.revision ?? 0; misses = [:] }
            for contact in result.contacts {
                let user = contact.matrixUser.rawValue
                if let handle = contact.handle {
                    remember(userID: user, handle: handle.rawValue, exact: false)
                } else {
                    if entries[user]?.exact == false { entries.removeValue(forKey: user); publish() }
                    misses[user] = now()
                }
            }
        } catch {
            guard generation == epoch, !Task.isCancelled else { return }
            // Errors are never negative evidence; preserve the cache and retry later.
            queued = batch + queued
            failures += 1
            let wait: TimeInterval
            switch AgentAliasRefusal.from(error) {
            case let .limit(seconds): wait = seconds.map(TimeInterval.init) ?? 600
            case .denied, .authentication, .missing: wait = Self.refreshInterval
            default: wait = min(Self.refreshInterval, 30 * pow(2, Double(min(failures - 1, 6))))
            }
            waitUntil = now().addingTimeInterval(wait)
        }
        guard generation == epoch else { return }
        inFlight = []
        schedule(after: 0.25)
    }
}
