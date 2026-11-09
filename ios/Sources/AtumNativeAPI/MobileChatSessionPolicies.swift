import Foundation

/// Pure rules behind the 2026-10-10 phone chat hotfix (revamp plan §5.1, C1).
/// They hold no SDK state, credentials or message content, so the live
/// adapter and the host tests share them.

/// The Matrix access token lives about 300 s and the SDK's own refresh is off
/// (custody owns the one-time refresh-token spend). While the app is in the
/// foreground the phone renews the session shortly before expiry, through the
/// same runtime replacement pull-to-refresh uses.
public enum MobileMatrixSessionKeepAlivePolicy {
    /// Renew this long before the access token expires.
    public static let refreshLeadSeconds: TimeInterval = 60
    /// Two renewal attempts (successful or not) are at least this far apart,
    /// so an offline phone or a grant shorter than the lead cannot spin.
    public static let attemptSpacingSeconds: TimeInterval = 30
    /// The loop never sleeps for less than this between checks.
    public static let minimumWaitSeconds: TimeInterval = 5

    public enum Step: Equatable, Sendable {
        case renewNow
        case wait(seconds: TimeInterval)
    }

    /// True when the token is expired or inside the renewal lead.
    public static func needsRefresh(expiresAt: Date, now: Date) -> Bool {
        let remaining = expiresAt.timeIntervalSince(now)
        return !remaining.isFinite || remaining <= refreshLeadSeconds
    }

    public static func isExpired(expiresAt: Date, now: Date) -> Bool {
        let remaining = expiresAt.timeIntervalSince(now)
        return !remaining.isFinite || remaining <= 0
    }

    /// What the foreground keep-alive does next.
    public static func nextStep(expiresAt: Date, now: Date, lastAttemptAt: Date?) -> Step {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining.isFinite else { return .renewNow }
        if remaining > refreshLeadSeconds {
            return .wait(seconds: max(minimumWaitSeconds, remaining - refreshLeadSeconds))
        }
        if let lastAttemptAt {
            let elapsed = now.timeIntervalSince(lastAttemptAt)
            if elapsed.isFinite, elapsed >= 0, elapsed < attemptSpacingSeconds {
                return .wait(seconds: max(minimumWaitSeconds, attemptSpacingSeconds - elapsed))
            }
        }
        return .renewNow
    }

    /// A session that reported itself invalid is renewed automatically only
    /// when the reason is plain expiry, the app is in the foreground and no
    /// attempt ran in the last `attemptSpacingSeconds`. Any other invalid
    /// state keeps today's behaviour (custody decides on the next refresh).
    public static func renewsInvalidSession(expiresAt: Date, now: Date, isForeground: Bool,
                                            lastAttemptAt: Date?) -> Bool {
        guard isForeground, isExpired(expiresAt: expiresAt, now: now) else { return false }
        return nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: lastAttemptAt) == .renewNow
    }
}

/// Failed sends (SDK `EventSendState.sendingFailed(error:isRecoverable:)`).
public enum MobileSendRecoveryPolicy {
    public enum RetryAction: Equatable, Sendable {
        /// A recoverable failure disabled the room's send queue; re-enabling
        /// it resends the room's queue in order.
        case enableRoomQueue
        /// An unrecoverable failure parked the request; only an explicit
        /// retry of that item unparks it.
        case retryParkedRequest
    }

    public static func retryAction(isRecoverable: Bool) -> RetryAction {
        isRecoverable ? .enableRoomQueue : .retryParkedRequest
    }

    /// A request parked because the access token was rejected is retried once
    /// on a renewed session without asking: the SDK only unparks these on its
    /// own token refresh, which the phone does not use. Each item is retried
    /// at most once per session, so a still-rejected token cannot loop.
    public static func autoRetriesAfterRenewal(failureIsExpiredToken: Bool, isRecoverable: Bool,
                                               alreadyRetried: Bool) -> Bool {
        failureIsExpiredToken && !isRecoverable && !alreadyRetried
    }
}

/// Instant send: the composer clears before the SDK call. A send the phone
/// refused before it reached the SDK puts its text back in the composer. If
/// the person already typed something new, the refused text goes after it on
/// a new line (chained sends are refused in tap order, so their order holds).
/// Text refused after the person left the room is not put into another
/// room's composer; the caller logs that case.
public enum MobileComposerDraftPolicy {
    public struct Outcome: Equatable, Sendable {
        public let draft: String
        public let droppedRefusedText: Bool
    }

    public static func draftAfterRefusedSend(currentDraft: String, sentBody: String,
                                             sameRoomOpen: Bool) -> Outcome {
        guard sameRoomOpen else { return Outcome(draft: currentDraft, droppedRefusedText: !sentBody.isEmpty) }
        guard !currentDraft.isEmpty else { return Outcome(draft: sentBody, droppedRefusedText: false) }
        guard !sentBody.isEmpty else { return Outcome(draft: currentDraft, droppedRefusedText: false) }
        return Outcome(draft: currentDraft + "\n" + sentBody, droppedRefusedText: false)
    }
}

/// A renewed session reopens the room with a new timeline that starts with
/// only its latest events and pages older ones in. While that runs, the rows
/// already on screen that are older than everything the new timeline has
/// stay above it, so the transcript neither shrinks nor moves under a person
/// reading further up. Identity is the stable row ID (Matrix event ID).
public enum MobileTimelineHandoverPolicy {
    public static func rows<Row, ID: Equatable>(displayed: [Row], incoming: [Row],
                                               id: (Row) -> ID) -> [Row] {
        // An empty first publish never blanks a transcript that had rows.
        guard let oldestIncoming = incoming.first.map(id) else { return displayed }
        // The new timeline does not overlap what is shown: show it as is.
        guard let overlap = displayed.firstIndex(where: { id($0) == oldestIncoming }) else { return incoming }
        return Array(displayed[..<overlap]) + incoming
    }
}

/// Single flight for the Matrix runtime renewal. The refresh token is
/// one-time: a second replacement started while one is spending would strand
/// custody. A caller that arrives while a run is in progress waits for that
/// run and does not start its own.
@MainActor
public final class MobileSingleFlight {
    private var current: (id: UInt64, task: Task<Void, Never>)?
    private var nextID: UInt64 = 0

    public init() {}

    public var isRunning: Bool { current != nil }

    /// Waits for the run in progress, if any. Returns false when none was.
    public func joinIfRunning() async -> Bool {
        guard let current else { return false }
        await current.task.value
        return true
    }

    /// Returns true when this call ran `operation`, false when it joined a
    /// run that was already in progress.
    @discardableResult
    public func run(_ operation: @escaping @MainActor () async -> Void) async -> Bool {
        if let current {
            await current.task.value
            return false
        }
        nextID &+= 1
        let id = nextID
        let task = Task { @MainActor [weak self] in
            await operation()
            // Cleared inside the run, so no caller can join a finished run.
            if self?.current?.id == id { self?.current = nil }
        }
        current = (id, task)
        await task.value
        return true
    }
}
