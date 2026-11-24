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

    public init(unanswered: String?, working: Bool, scheduled: ChatScheduleExecution? = nil,
                hasScheduledWork: Bool = false) {
        self.unanswered = unanswered
        self.working = working
        self.scheduled = scheduled
        self.hasScheduledWork = hasScheduledWork || scheduled != nil
    }

    public static let idle = AssistantTurnSignal(unanswered: nil, working: false)

    /// Read from the projected rows. Only my assistant's chat has turns; every
    /// other kind is idle.
    public static func read(_ rows: [ChatRow], kind: RoomKind) -> AssistantTurnSignal {
        guard kind == .assistant else { return .idle }
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
                                               scheduled: progress.schedule, hasScheduledWork: true)
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
                return AssistantTurnSignal(unanswered: nil, working: working)
            }
            return AssistantTurnSignal(unanswered: eventID, working: working)
        }
        return AssistantTurnSignal(unanswered: nil, working: working)
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

    public private(set) var phase: Phase = .idle
    public private(set) var selection: AssistantTurnStopIntent.Target?
    public var target: String? {
        if case let .turn(eventID) = selection { return eventID }
        return nil
    }
    /// The key of this turn's stop request, kept for an idempotent retry.
    public private(set) var requestID: String?
    private var scheduledStopPending = false
    /// A confirmed exact scheduled Stop leaves "Stopped." under the composer
    /// after the run's marker clears, until another turn is named (desktop
    /// `useMatrixCloudStop().stopped`).
    public private(set) var scheduledStopConfirmed = false
    /// The timeline cleared this scheduled run's marker while its Stop was
    /// still in flight or pending. The exact attempt is kept so its receipt
    /// still resolves; a new target replaces it.
    public private(set) var scheduleMarkerCleared = false

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
        let selected = signal.hasScheduledWork
            ? signal.scheduled.map(AssistantTurnStopIntent.Target.schedule)
            : signal.unanswered.map { AssistantTurnStopIntent.Target.turn(eventID: $0) }
        // Preserve an acknowledged interruption after its footer clears:
        // the run is over (no Stop), and desktop's "Stopped." band stays
        // until another turn is named (`scheduledStopConfirmed`).
        if phase == .stopped, case .schedule = selection, !signal.hasScheduledWork, !signal.working {
            self = AssistantTurnStop()
            scheduledStopConfirmed = true
            return
        }
        // Keep the exact in-flight scheduled attempt when its marker clears
        // before the receipt: nothing else is named, so it is still the one
        // this chat is waiting on (review r1). A new turn or run replaces it.
        if selected == nil, !signal.hasScheduledWork, phase == .stopping, case .schedule = selection {
            scheduleMarkerCleared = true
            return
        }
        guard let selected else {
            let keepsStopped = scheduledStopConfirmed && !signal.hasScheduledWork
            self = AssistantTurnStop()
            scheduledStopConfirmed = keepsStopped
            // The composer can show an unavailable Stop while the exact
            // cron target is missing. It stays disabled until a tuple arrives.
            if signal.hasScheduledWork && signal.working { phase = .working }
            return
        }
        if selected == selection {
            // The latch: the same question stays the turn until it is
            // answered, even after the typing signal lapses.
            scheduleMarkerCleared = false
            return
        }
        guard signal.working else {
            // Nothing is named yet, so a scheduled "Stopped." stays.
            let keepsStopped = scheduledStopConfirmed && !signal.hasScheduledWork
            self = AssistantTurnStop()
            scheduledStopConfirmed = keepsStopped
            return
        }
        self = AssistantTurnStop()
        selection = selected
        phase = .working
    }

    /// The person tapped Stop. Returns what to send, or nil when there is
    /// nothing to stop or a request is already out (a second tap is a no-op).
    /// `newRequestID` is used only for this turn's first request; a retry
    /// after a failure re-sends the same key.
    public mutating func beginStop(newRequestID: String) -> AssistantTurnStopIntent? {
        guard offersStop, let selection else { return nil }
        let key = requestID ?? newRequestID
        requestID = key
        phase = .stopping
        return AssistantTurnStopIntent(target: selection, requestID: key)
    }

    /// The platform answered a request. An answer for a turn that is no
    /// longer shown (the person moved on) changes nothing.
    /// Returns whether the answer was accepted (it names the attempt shown).
    @discardableResult
    public mutating func resolve(_ result: AssistantTurnStopResult, for intent: AssistantTurnStopIntent) -> Bool {
        guard intent.target == selection, intent.requestID == requestID, phase == .stopping else { return false }
        if scheduleMarkerCleared {
            // The run already left the timeline: only a confirmed stop leaves
            // a word ("Stopped."); anything else settles quietly, as desktop
            // drops a status whose key is gone.
            let confirmed = result == .stopped
            self = AssistantTurnStop()
            scheduledStopConfirmed = confirmed
            return true
        }
        switch result {
        case .stopped:
            phase = .stopped
            if case .schedule = intent.target { scheduledStopConfirmed = true }
        case .stopRequested:
            if case .schedule = intent.target { scheduledStopPending = true }
            phase = .stopping
        case .completed: phase = .finishing
        case .failed: phase = .failed
        }
        return true
    }

    /// Desktop settles a turn's unconfirmed Stop after `settleDelay`: the
    /// "Stopping…" label goes, Stop stays disabled, nothing claims stopped.
    /// A scheduled Stop uses `retryPendingSchedule` instead.
    public mutating func settlePendingTurn(for intent: AssistantTurnStopIntent) {
        guard case .turn = intent.target, phase == .stopping, intent.target == selection,
              intent.requestID == requestID else { return }
        phase = .settled
    }

    /// Desktop re-offers Stop after a pending/unknown schedule receipt. This
    /// changes only availability. In-flight requests and other runs are untouched.
    public mutating func retryPendingSchedule(for intent: AssistantTurnStopIntent) {
        guard scheduledStopPending, phase == .stopping, intent.target == selection,
              intent.requestID == requestID else { return }
        guard !scheduleMarkerCleared else {
            // The run left the timeline while pending: nothing to re-offer.
            self = AssistantTurnStop()
            return
        }
        scheduledStopPending = false
        phase = .working
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
