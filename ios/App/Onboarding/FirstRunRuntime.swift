import Foundation

/// The account-wide first-run record desktop already writes
/// (`apps/desktop/src/matrix/first-run-onboarding.ts`). Presence is the whole
/// contract: any existing record is an answer, including one this build cannot
/// read; only a missing record is `unseen`. The phone's legacy-v1
/// `folders:"declined"` means the phone checklist was finished or dismissed.
/// It is not evidence the person was asked about Mac folder access, rejected a
/// permission, or changed one, and another device's record is never rewritten.
enum FirstRunMarkerRecord {
    static let eventType = "io.atum.onboarding.first_run"

    static func state(from content: String?) -> FirstRunMarkerState {
        content == nil ? .unseen : .answered
    }

    /// The phone cannot review Mac folders. This legacy-v1 completion shape
    /// records that the phone's own onboarding finished; desktop still reads
    /// presence only, so the account does not restart onboarding elsewhere.
    static func phoneCompletionAnswerJSON(nowMilliseconds: Int64) -> String? {
        guard nowMilliseconds >= 0 else { return nil }
        return #"{"v":1,"folders":"declined","at":\#(nowMilliseconds)}"#
    }
}

enum FirstRunMarkerFailure: Error, Equatable, Sendable {
    case stale
    case unavailable
    case failed
}

/// The pinned Rust SDK exposes only the synchronized state-store read for
/// global account data; its network `fetch_account_data` is not in the FFI.
/// `RoomListServiceState.settingUp` is the first-sync milestone (the state
/// machine documents it as "the first rooms have been synced"), so a missing
/// account-data record before that point is not authoritative.
enum FirstRunMarkerReadiness {
    static func canRead(sessionReady: Bool, completedInitialSync: Bool) -> Bool {
        sessionReady && completedInitialSync
    }
}

/// Owns one signed-in runtime's marker state. The owner never writes when its
/// synchronized read already shows an answer, never publishes a late result
/// after its account, device or runtime changed, and never turns an `answered`
/// record back into an offer after a read failure. The read is the SDK cache,
/// not desktop's authoritative network GET, so an answer from another device
/// can lag sync; this is not an atomic first-writer-wins guarantee.
@MainActor
final class FirstRunMarkerCoordinator {
    struct IO {
        let read: @MainActor () async throws -> String?
        let write: @MainActor (String) async throws -> Void
        let isCurrent: @MainActor () -> Bool
        let nowMilliseconds: @MainActor () -> Int64

        init(read: @escaping @MainActor () async throws -> String?,
             write: @escaping @MainActor (String) async throws -> Void,
             isCurrent: @escaping @MainActor () -> Bool,
             nowMilliseconds: @escaping @MainActor () -> Int64) {
            self.read = read
            self.write = write
            self.isCurrent = isCurrent
            self.nowMilliseconds = nowMilliseconds
        }
    }

    private(set) var state: FirstRunMarkerState = .unknown

    private let io: IO
    private var generation: UInt64 = 0
    private var inFlightAnswer: Task<Void, Error>?
    private var inFlightGeneration: UInt64?
    private var inFlightAnswerID: UInt64 = 0
    private var nextAnswerID: UInt64 = 0

    init(io: IO) {
        self.io = io
    }

    var isCurrent: Bool { io.isCurrent() }

    func reset() {
        generation &+= 1
        inFlightAnswer?.cancel()
        inFlightAnswer = nil
        inFlightGeneration = nil
        state = .unknown
    }

    func refresh() async {
        let expected = generation
        let content: String?
        do {
            content = try await io.read()
        } catch {
            guard generation == expected, io.isCurrent() else { return }
            // An answered account stays answered through an outage. An unseen
            // account becomes unknown rather than being offered again.
            if state != .answered { state = .unknown }
            return
        }
        guard generation == expected, io.isCurrent() else { return }
        let next = FirstRunMarkerRecord.state(from: content)
        guard !(state == .answered && next == .unseen) else { return }
        state = next
    }

    /// Records the phone completion only when the synchronized account-data
    /// store still has no record. Concurrent local callers share one bounded
    /// read/write task; an in-flight task never crosses a generation reset.
    ///
    /// Matrix account data has no compare-and-swap PUT, and the pinned SDK
    /// exposes only the synchronized cache. The read before the write is a
    /// local/cache preflight, not desktop's authoritative network GET: another
    /// device's answer can be absent from the cache until a later sync, so this
    /// is best effort rather than first-writer-wins.
    func answer() async throws {
        guard io.isCurrent() else { throw FirstRunMarkerFailure.stale }

        // The local latch: once this owner knows the account answered, do not
        // issue another GET or PUT.
        if state == .answered { return }

        let expected = generation
        if let inFlight = inFlightAnswer, inFlightGeneration == expected {
            try await inFlight.value
            return
        }

        nextAnswerID &+= 1
        let answerID = nextAnswerID
        let task = Task { @MainActor [weak self] in
            guard let self else { throw FirstRunMarkerFailure.stale }
            defer {
                if self.inFlightAnswerID == answerID {
                    self.inFlightAnswer = nil
                    self.inFlightGeneration = nil
                }
            }
            try await self.performAnswer(expected: expected)
        }
        inFlightAnswer = task
        inFlightGeneration = expected
        inFlightAnswerID = answerID
        try await task.value
    }

    private func performAnswer(expected: UInt64) async throws {
        guard generation == expected, io.isCurrent() else { throw FirstRunMarkerFailure.stale }
        if state == .answered { return }

        let existing: String?
        do {
            existing = try await io.read()
        } catch {
            guard generation == expected, io.isCurrent() else { throw FirstRunMarkerFailure.stale }
            throw FirstRunMarkerFailure.failed
        }
        guard generation == expected, io.isCurrent() else { throw FirstRunMarkerFailure.stale }

        if existing != nil {
            state = .answered
            return
        }

        // A refresh or another local read may have learned about an answer
        // while this task was suspended. Never write over that local truth.
        if state == .answered { return }

        guard let payload = FirstRunMarkerRecord.phoneCompletionAnswerJSON(
            nowMilliseconds: io.nowMilliseconds()
        ) else {
            throw FirstRunMarkerFailure.unavailable
        }

        do {
            try await io.write(payload)
        } catch {
            guard generation == expected, io.isCurrent() else { throw FirstRunMarkerFailure.stale }
            throw FirstRunMarkerFailure.failed
        }
        guard generation == expected, io.isCurrent() else { throw FirstRunMarkerFailure.stale }
        state = .answered
    }
}
