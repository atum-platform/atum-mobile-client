import Foundation

/// The relay's one line on an Atum chat turn, and the plan's usage phrase
/// (desktop `relay-chrome.tsx`, `relay-copy.ts` `workRelayTurnText` and
/// `workRelayUsageText`, `relay-view.ts` `WorkRelayTurnChrome`; wave 4, 4b).
/// UI chrome, never a message of the assistant and never a cost.
///
/// Pure words only. The desktop builds a turn's chrome from its Mac's own gate
/// (`electron/work/surface/relay.ts`: the gate's room status and the receipts
/// in its local ledger), which no platform route serves to a phone yet. Until
/// one does, the phone has no chrome to map and draws no relay line, as the
/// desktop draws none without Work (docs/ports/w4-e6-connections.md).
public enum RelayTurnChrome: Equatable, Sendable {
    public enum FallbackReason: String, Equatable, Sendable {
        case macOff = "mac_off", consentOff = "consent_off", switchOff = "switch_off", limit, other
    }

    case none
    /// Under the reply the Atum model gave instead.
    case fallback(FallbackReason)
    /// Held on the Mac; `waitingForAnswer` while the assistant's question waits
    /// on the owner, `invalidAnswer` after a reply that did not answer it.
    case waiting(waitingForAnswer: Bool = false, invalidAnswer: Bool = false)
    case needsOK
    /// Held at the plan's limit; the reset time when the plan reported one.
    case limit(resetsAt: String?)
    case stopping, stopped, queued
    /// Finished on the Mac long after it was sent, at this time.
    case late(finishedAt: String)
    case empty, failed

    /// Held states draw a soft live dot, so a waiting message reads as alive.
    public var isLive: Bool {
        switch self {
        case .waiting, .needsOK, .limit, .stopping: true
        default: false
        }
    }
}

public enum RelayTurnLine {
    /// An exported phrase and its arguments. A `phrase` argument is resolved
    /// first, then passed in as text (the fallback line's reason).
    public struct Phrase: Equatable, Sendable {
        public indirect enum Argument: Equatable, Sendable { case text(String), number(Int64), phrase(Phrase) }
        public let key: String
        public let arguments: [Argument]

        init(_ key: String, _ arguments: [Argument] = []) {
            self.key = key
            self.arguments = arguments
        }

        /// The text, with `text(key, arguments)` doing the lookup.
        public func resolve(_ text: (String, [Argument]) -> String) -> String {
            text(key, arguments.map { argument -> Argument in
                switch argument {
                case let .phrase(inner): .text(inner.resolve(text))
                case .text, .number: argument
                }
            })
        }
    }

    /// The line's words, or nil when nothing is drawn. `plan` is the plan's
    /// product name ("ChatGPT"), `model` the Atum model that answered instead.
    /// The desktop's one action (Stop, Open Work) needs the Mac's gate, so the
    /// phone offers none.
    public static func phrase(_ chrome: RelayTurnChrome, plan: String, model: String) -> Phrase? {
        switch chrome {
        case .none: nil
        case let .fallback(reason):
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallback",
                   [.text(model), .phrase(reasonPhrase(reason, plan: plan))])
        case .waiting(waitingForAnswer: true, invalidAnswer: true):
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.invalidAnswer")
        case .waiting(waitingForAnswer: true, invalidAnswer: false):
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.waitingForAnswer")
        case .waiting: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.waiting")
        case .needsOK: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.needsOk")
        case let .limit(at):
            at.map { Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.limitHeld", [.text(plan), .text($0)]) }
                ?? Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.limitHeld.at=null", [.text(plan), .text("")])
        case .stopping: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.stopping")
        case .stopped: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.stopped")
        case .queued: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.queued")
        case let .late(at): Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.late", [.text(at)])
        case .empty: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.empty")
        case .failed: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.failed")
        }
    }

    /// The fallback's reason in a few words. `mac_off` never names the plan.
    static func reasonPhrase(_ reason: RelayTurnChrome.FallbackReason, plan: String) -> Phrase {
        switch reason {
        case .macOff: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallbackWhy.mac_off")
        case .consentOff: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallbackWhy.consent_off", [.text(plan)])
        case .switchOff: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallbackWhy.switch_off", [.text(plan)])
        case .limit: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallbackWhy.limit", [.text(plan)])
        case .other: Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.fallbackWhy.other", [.text(plan)])
        }
    }

    /// The plan's usage (desktop `workRelayUsage`): used percent with its
    /// reset, the limit reached, or not reported.
    public enum Usage: Equatable, Sendable {
        case used(percent: Int64, resetsAt: String?)
        case limit(resetsAt: String?)
        case unknown
    }

    /// The usage phrase, then the scheduled runs in the plan's window when the
    /// gate counted them (`useWorkRelayUsageText`: joined with " · ").
    public static func usage(_ usage: Usage, scheduledRuns: Int64?) -> [Phrase] {
        guard let scheduledRuns else { return [usageHead(usage)] }
        return [usageHead(usage),
                Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageScheduled", [.number(scheduledRuns)])]
    }

    private static func usageHead(_ usage: Usage) -> Phrase {
        switch usage {
        case let .used(reported, at):
            let percent = Argument.number(min(100, max(0, reported)))
            return at.map { Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageUsed", [percent, .text($0)]) }
                ?? Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageUsed.at=null", [percent, .text("")])
        case let .limit(at):
            return at.map { Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageLimit", [.text($0)]) }
                ?? Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageLimit.at=null", [.text("")])
        case .unknown:
            return Phrase("src.matrix.mobile-copy.mobileScreensCopy.relay.usageUnknown")
        }
    }

    private typealias Argument = Phrase.Argument
}
