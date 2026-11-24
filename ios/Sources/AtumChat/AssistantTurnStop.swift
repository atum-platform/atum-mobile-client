import Foundation

// The composer's working state and its Stop (review C1), on the authority the
// desktop uses for a cloud turn: `atum.agent-turns/1` rule 5 and
// `atum.cloud-execution/1` §3.5, `POST /api/matrix/v1/cloud/stop` with
// `{requestId, agentPrincipal, target: {kind: "turn", roomId, eventId}}`,
// idempotent on `(owner, requestId)`. Which turn is in progress follows the
// desktop's `matrixCloudStopTarget` (atum-app `apps/desktop/src/matrix/
// cloud-stop.ts`) for a turn this device has no ledger entry for: my newest
// unanswered question, while the agent shows it is working, latched so the
// button does not vanish when the short-lived typing signal lapses.
//
// Display correlation only, never authority: the platform's answer decides
// whether anything stopped, and the room's answer or notice ends the turn.

/// What the transcript shows about my assistant's work right now.
public struct AssistantTurnSignal: Equatable, Sendable {
    public struct Reply: Equatable, Sendable {
        public let eventID: String
        public let timestamp: Date

        public init(eventID: String, timestamp: Date) {
            self.eventID = eventID
            self.timestamp = timestamp
        }
    }

    /// My newest top-level message the agent has not answered yet (its
    /// event ID), or nil.
    public var unanswered: String?
    /// The agent shows it is working: its typing row or a live
    /// `io.atum.progress` working line.
    public var working: Bool
    /// Cron has no source question. An unresolved cron marker still takes
    /// priority and must never fall back to stopping an unrelated question.
    public var scheduled: ChatScheduleExecution?
    public var hasScheduledWork: Bool
    public var scheduledSince: Date?
    public var latestReply: Reply?

    public init(unanswered: String?, working: Bool, scheduled: ChatScheduleExecution? = nil,
                hasScheduledWork: Bool = false, scheduledSince: Date? = nil, latestReply: Reply? = nil) {
        self.unanswered = unanswered
        self.working = working
        self.scheduled = scheduled
        self.hasScheduledWork = hasScheduledWork || scheduled != nil
        self.scheduledSince = scheduledSince
        self.latestReply = latestReply
    }

    public static let idle = AssistantTurnSignal(unanswered: nil, working: false)

    /// Read from the projected rows. Only my assistant's chat has turns; every
    /// other kind is idle.
    public static func read(_ rows: [ChatRow], kind: RoomKind) -> AssistantTurnSignal {
        guard kind == .assistant else { return .idle }
        // Read this independently of the Stop target. A scheduled footer can
        // hide the question, and a finished reply can leave no question at all.
        let latestReply = rows.reversed().lazy.compactMap { row -> Reply? in
            let item = row.item
            guard !item.isOwn, !item.interim, !item.isProgressLine, item.threadRoot == nil,
                  let eventID = item.eventID, eventID.hasPrefix("$") else { return nil }
            switch item.kind {
            case .message, .notice, .image, .file: return Reply(eventID: eventID, timestamp: item.timestamp)
            default: return nil
            }
        }.first
        var working = false
        // Event IDs the agent has answered or ended with a status line.
        var ended = Set<String>()
        // A later agent message that names no question still ends what came
        // before it, for hiding Stop only (the safe direction).
        var agentSpokeAfter = false
        for row in rows.reversed() {
            let item = row.item
            switch item.kind {
            case .typing:
                if item.companyTurn != nil { return .idle }
                if let progress = item.progress, progress.isScheduled {
                    return AssistantTurnSignal(unanswered: nil, working: true,
                                               scheduled: progress.schedule, hasScheduledWork: true,
                                               scheduledSince: progress.schedule == nil ? nil : item.timestamp,
                                               latestReply: latestReply)
                }
                working = true
                continue
            case .message, .notice, .image, .file:
                break
            default:
                continue
            }
            // A native Matrix thread reply can carry a reply fallback to
            // the room question without answering it in the room timeline.
            guard item.threadRoot == nil else { continue }
            if item.isProgressLine {
                if item.progress?.phase != .settled { working = true }
                continue
            }
            if !item.isOwn {
                if item.interim { continue }
                if let replyTo = item.replyTo { ended.insert(replyTo) } else { agentSpokeAfter = true }
                continue
            }
            // My message: the newest top-level one decides.
            guard let eventID = item.eventID, eventID.hasPrefix("$"),
                  !ended.contains(eventID), !agentSpokeAfter else {
                return AssistantTurnSignal(unanswered: nil, working: working, latestReply: latestReply)
            }
            return AssistantTurnSignal(unanswered: eventID, working: working, latestReply: latestReply)
        }
        return AssistantTurnSignal(unanswered: nil, working: working, latestReply: latestReply)
    }
}

/// The platform's answer to a turn Stop or an exact scheduled Stop.
public enum AssistantTurnStopResult: Equatable, Sendable {
    /// The turn cannot dispatch, or the exact execution confirmed interruption.
    case stopped
    /// Stop is pending. The running holder or the timeline may confirm it.
    case stopRequested
    /// `completed`: the turn had already finished; nothing was stopped.
    case completed
    /// No confirmed answer (transport, refusal, unreadable reply). The turn
    /// may still be running; nothing is claimed.
    case failed
}

/// One stop request: the turn's question and the idempotency key it is sent
/// with. A retry of the same turn sends the same key.
public struct AssistantTurnStopIntent: Equatable, Sendable {
    public enum Target: Hashable, Sendable {
        case turn(eventID: String)
        case schedule(ChatScheduleExecution)
    }

    public let target: Target
    public let requestID: String

    public init(target: Target, requestID: String) {
        self.target = target
        self.requestID = requestID
    }

    public init(eventID: String, requestID: String) {
        self.init(target: .turn(eventID: eventID), requestID: requestID)
    }

    /// Legacy event accessor for turn-only callers. Scheduled Stop dispatch
    /// uses the typed target, which has no source event.
    public var eventID: String {
        if case let .turn(eventID) = target { return eventID }
        return ""
    }
}

/// The composer's turn state: working → stopping → stopped, or back to
/// working-with-a-failure that may be retried with the same request.
public struct AssistantTurnStop: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No turn in progress: the composer is as usual.
        case idle
        /// A turn is in progress and may be stopped.
        case working
        /// A stop was sent and not answered, or answered `stop_requested`:
        /// the control reads "Stopping…" (desktop `cloud.stopping`, #46)
        /// until the turn ends or the settle delay passes.
        case stopping
        /// A turn's `stop_requested` outlived the settle delay without the
        /// agent confirming: desktop's `settled`. Stop stays, disabled and
        /// quiet, until the turn ends. Never shown as stopped.
        case settled
        /// The platform answered `stopped`.
        case stopped
        /// The platform answered `completed`: nothing to stop; the answer is
        /// on its way. No Stop and no line.
        case finishing
        /// The last stop was not confirmed. The turn is still shown as in
        /// progress and Stop is offered again.
        case failed
    }

    private typealias Target = AssistantTurnStopIntent.Target

    private struct Attempt: Equatable, Sendable {
        let requestID: String
        var phase: Phase = .stopping
        var pending = false
        var replyAtTap: AssistantTurnSignal.Reply?
        var scheduledSince: Date?
    }

    // A projection may lose or replace a target while its request is active.
    // Keep the request and its terminal state under the exact target.
    private var attempts = [Target: Attempt]()
    private var unavailableSchedule = false
    private var clearedSchedule: ChatScheduleExecution?
    private var confirmedSchedule: ChatScheduleExecution?
    private var latestReply: AssistantTurnSignal.Reply?
    private var scheduledSince: Date?

    public private(set) var selection: AssistantTurnStopIntent.Target?
    public var phase: Phase {
        if let selection { return attempts[selection]?.phase ?? .working }
        if clearedSchedule != nil { return .stopping }
        return unavailableSchedule ? .working : .idle
    }
    public var target: String? {
        if case let .turn(eventID) = selection { return eventID }
        return nil
    }
    /// The key of this turn's stop request, kept for an idempotent retry.
    public var requestID: String? {
        let target = selection ?? clearedSchedule.map(Target.schedule)
        return target.flatMap { attempts[$0]?.requestID }
    }
    public var scheduledStopConfirmed: Bool { confirmedSchedule != nil }
    public var scheduleMarkerCleared: Bool { clearedSchedule != nil }

    public static let scheduledRetryDelay: Duration = .seconds(15)
    /// Desktop `MATRIX_STOP_SETTLE_MS`: how long an unconfirmed Stop keeps
    /// saying "Stopping…".
    public static let settleDelay: Duration = .seconds(15)

    public init() {}

    /// Stop is offered (and can be tapped) in these phases.
    public var offersStop: Bool { selection != nil && (phase == .working || phase == .failed) }
    /// The composer shows the turn as in progress.
    public var isWorking: Bool { phase != .idle }

    /// A new transcript reading.
    public mutating func observe(_ signal: AssistantTurnSignal) {
        if let reply = signal.latestReply, latestReply.map({ reply.timestamp >= $0.timestamp }) ?? true {
            latestReply = reply
        }
        let previousSchedule: ChatScheduleExecution? = if case let .schedule(execution) = selection {
            execution
        } else {
            clearedSchedule
        }
        let candidate = signal.hasScheduledWork
            ? signal.scheduled.map(Target.schedule)
            : signal.unanswered.map { Target.turn(eventID: $0) }
        // Latch an identified turn through a typing lapse. A returning exact
        // target can also recover its attempt before typing starts again.
        selection = candidate.flatMap { target in
            signal.working || target == selection || attempts[target] != nil ? target : nil
        }
        unavailableSchedule = signal.hasScheduledWork && signal.working && candidate == nil
        scheduledSince = signal.scheduledSince

        // A marker clearing on its own can still leave a confirmation. A
        // different target or a finished reply takes over the composer.
        clearedSchedule = nil
        if candidate == nil, !signal.hasScheduledWork, let execution = previousSchedule,
           let attempt = attempts[.schedule(execution)], attempt.phase == .stopping,
           !hasNewerReply(than: attempt) {
            clearedSchedule = execution
        }
        if let execution = confirmedSchedule {
            let target = Target.schedule(execution)
            if selection != target && (selection != nil || signal.hasScheduledWork)
                || attempts[target].map(hasNewerReply) == true {
                confirmedSchedule = nil
            }
        }
    }

    private func hasNewerReply(than attempt: Attempt) -> Bool {
        guard let latestReply, latestReply.eventID != attempt.replyAtTap?.eventID else { return false }
        return attempt.scheduledSince.map { latestReply.timestamp >= $0 } ?? true
    }

    /// The person tapped Stop. Returns what to send, or nil when there is
    /// nothing to stop or a request is already out (a second tap is a no-op).
    /// `newRequestID` is used only for this turn's first request; a retry
    /// after a failure re-sends the same key.
    public mutating func beginStop(newRequestID: String) -> AssistantTurnStopIntent? {
        guard offersStop, let selection else { return nil }
        let key = attempts[selection]?.requestID ?? newRequestID
        attempts[selection] = Attempt(requestID: key, replyAtTap: latestReply, scheduledSince: scheduledSince)
        return AssistantTurnStopIntent(target: selection, requestID: key)
    }

    /// Resolve the exact attempt even when it is hidden. The return value
    /// tells the controller whether the receipt belongs to the composer.
    @discardableResult
    public mutating func resolve(_ result: AssistantTurnStopResult, for intent: AssistantTurnStopIntent) -> Bool {
        guard var attempt = attempts[intent.target], attempt.requestID == intent.requestID,
              attempt.phase == .stopping, !attempt.pending else { return false }
        let markerCleared = clearedSchedule.map(Target.schedule) == intent.target
        var visible = selection == intent.target || markerCleared
        if case let .schedule(execution) = intent.target {
            visible = visible && !hasNewerReply(than: attempt)
            if markerCleared { clearedSchedule = nil }
            if result == .stopped, visible { confirmedSchedule = execution }
        }
        switch result {
        case .stopped: attempt.phase = .stopped
        case .stopRequested: attempt.pending = true
        case .completed: attempt.phase = .finishing
        case .failed: attempt.phase = .failed
        }
        attempts[intent.target] = attempt
        return visible
    }

    /// Desktop settles a turn's unconfirmed Stop after `settleDelay`: the
    /// "Stopping…" label goes, Stop stays disabled, nothing claims stopped.
    /// A scheduled Stop uses `retryPendingSchedule` instead.
    public mutating func settlePendingTurn(for intent: AssistantTurnStopIntent) {
        guard case .turn = intent.target, var attempt = attempts[intent.target],
              attempt.requestID == intent.requestID, attempt.pending else { return }
        attempt.pending = false
        attempt.phase = .settled
        attempts[intent.target] = attempt
    }

    /// Desktop re-offers Stop after a pending/unknown schedule receipt. This
    /// changes only availability. In-flight requests and other runs are untouched.
    public mutating func retryPendingSchedule(for intent: AssistantTurnStopIntent) {
        guard case let .schedule(execution) = intent.target, var attempt = attempts[intent.target],
              attempt.requestID == intent.requestID, attempt.pending else { return }
        attempt.pending = false
        attempt.phase = .working
        attempts[intent.target] = attempt
        if clearedSchedule == execution { clearedSchedule = nil }
    }

    /// What the composer draws for this state, as the desktop composer
    /// renders it (`app.tsx` `cloudStop.shown` / `stopping` / `ready`).
    public enum Control: Equatable, Sendable {
        /// No Stop: the send circle (or nothing) as usual.
        case hidden
        /// The stop glyph. Disabled while a request was already answered
        /// for this turn, or while a scheduled run has no exact target.
        case stop(enabled: Bool)
        /// The labelled, disabled "Stopping…" control.
        case stopping
    }

    /// The one line above the composer (desktop `NoticeBand`).
    public enum Notice: Equatable, Sendable {
        /// `cloud.stopRefused`: the request was refused or unreachable.
        case refused
        /// `matrixAgentStatusCopy.stopped`: a confirmed exact scheduled Stop.
        case scheduledStopped
    }

    public var control: Control {
        switch phase {
        case .idle: return .hidden
        case .working, .failed: return .stop(enabled: offersStop)
        case .stopping: return .stopping
        case .settled, .stopped, .finishing: return .stop(enabled: false)
        }
    }

    /// A draft that can be sent takes the slot from a disabled Stop glyph.
    public func control(canSend: Bool) -> Control {
        if canSend, control == .stop(enabled: false) { return .hidden }
        return control
    }

    public var notice: Notice? {
        if phase == .failed { return .refused }
        if scheduledStopConfirmed && (phase == .stopped || phase == .idle) { return .scheduledStopped }
        return nil
    }
}
