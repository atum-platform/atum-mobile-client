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

    public init(unanswered: String?, working: Bool) {
        self.unanswered = unanswered
        self.working = working
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
                working = true
                continue
            case .message, .notice, .image, .file:
                break
            default:
                continue
            }
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
            guard item.threadRoot == nil else { continue }
            guard let eventID = item.eventID, eventID.hasPrefix("$"),
                  !ended.contains(eventID), !agentSpokeAfter else {
                return AssistantTurnSignal(unanswered: nil, working: working)
            }
            return AssistantTurnSignal(unanswered: eventID, working: working)
        }
        return AssistantTurnSignal(unanswered: nil, working: working)
    }
}

/// The platform's answer to one stop request (`cloud-execution/1` §3.5).
public enum AssistantTurnStopResult: Equatable, Sendable {
    /// `stopped`: final; nothing will ever dispatch the turn.
    case stopped
    /// `stop_requested`: the running holder was told; the room's answer or
    /// notice shows the end.
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
    public var eventID: String
    public var requestID: String
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
        /// "Stop requested. Waiting for confirmation." until the turn ends.
        case stopping
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
    /// The question of the turn in progress.
    public private(set) var target: String?
    /// The key of this turn's stop request, kept for an idempotent retry.
    public private(set) var requestID: String?

    public init() {}

    /// Stop is offered (and can be tapped) in these phases.
    public var offersStop: Bool { phase == .working || phase == .failed }
    /// The composer shows the turn as in progress.
    public var isWorking: Bool { phase != .idle }

    /// A new transcript reading.
    public mutating func observe(_ signal: AssistantTurnSignal) {
        guard let question = signal.unanswered else {
            self = AssistantTurnStop()
            return
        }
        if question == target {
            // The latch: the same question stays the turn until it is
            // answered, even after the typing signal lapses.
            return
        }
        guard signal.working else {
            self = AssistantTurnStop()
            return
        }
        self = AssistantTurnStop()
        target = question
        phase = .working
    }

    /// The person tapped Stop. Returns what to send, or nil when there is
    /// nothing to stop or a request is already out (a second tap is a no-op).
    /// `newRequestID` is used only for this turn's first request; a retry
    /// after a failure re-sends the same key.
    public mutating func beginStop(newRequestID: String) -> AssistantTurnStopIntent? {
        guard offersStop, let target else { return nil }
        let key = requestID ?? newRequestID
        requestID = key
        phase = .stopping
        return AssistantTurnStopIntent(eventID: target, requestID: key)
    }

    /// The platform answered a request. An answer for a turn that is no
    /// longer shown (the person moved on) changes nothing.
    public mutating func resolve(_ result: AssistantTurnStopResult, for intent: AssistantTurnStopIntent) {
        guard intent.eventID == target, intent.requestID == requestID, phase == .stopping else { return }
        switch result {
        case .stopped: phase = .stopped
        case .stopRequested: phase = .stopping
        case .completed: phase = .finishing
        case .failed: phase = .failed
        }
    }
}
