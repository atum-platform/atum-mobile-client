import Foundation
import Observation

/// One chat's Stop, owned by the room's conversation store rather than the
/// composer view (review r1): opening and closing in-chat search rebuilds the
/// composer, and a view-owned state came back offering Stop while the first
/// request was still out, so a second tap sent a second request ID. The state,
/// the in-flight request and its timers live here for as long as the room is
/// open; a new room has a new store and a new controller.
@MainActor @Observable
public final class AssistantTurnStopController {
    /// What VoiceOver hears, only for an accepted transition in this chat.
    public enum Announcement: Equatable, Sendable {
        case stopping
        case refused
        case scheduledStopped
    }

    public private(set) var stop = AssistantTurnStop()
    /// Set by the chat screen while it is shown, nil otherwise.
    @ObservationIgnored public var announce: (@MainActor (Announcement) -> Void)?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// A new transcript reading.
    public func observe(_ signal: AssistantTurnSignal) {
        var next = stop
        next.observe(signal)
        if next != stop { stop = next }
    }

    /// The person tapped Stop. Sends at most one request for the attempt
    /// shown; a tap while one is out, or after it was answered, sends nothing.
    /// `onResult` gets every receipt and whether it was accepted.
    @discardableResult
    public func tap(newRequestID: String,
                    send: @escaping @MainActor (AssistantTurnStopIntent) async -> AssistantTurnStopResult,
                    onResult: (@MainActor (AssistantTurnStopIntent, AssistantTurnStopResult, Bool) -> Void)? = nil)
        -> Task<Void, Never>? {
        guard let intent = stop.beginStop(newRequestID: newRequestID) else { return nil }
        announce?(.stopping)
        return Task { @MainActor [weak self] in
            let result = await send(intent)
            guard let self else { return }
            let before = self.stop.notice
            let accepted = self.stop.resolve(result, for: intent)
            onResult?(intent, result, accepted)
            if accepted, let after = self.stop.notice, after != before {
                self.announce?(after == .refused ? .refused : .scheduledStopped)
            }
            guard accepted, result == .stopRequested, self.stop.phase == .stopping else { return }
            if case .schedule = intent.target {
                // Desktop re-offers an exact scheduled Stop after the delay.
                do { try await self.sleep(AssistantTurnStop.scheduledRetryDelay) } catch { return }
                self.stop.retryPendingSchedule(for: intent)
            } else {
                // Desktop settles a turn's unconfirmed Stop quietly.
                do { try await self.sleep(AssistantTurnStop.settleDelay) } catch { return }
                self.stop.settlePendingTurn(for: intent)
            }
        }
    }
}
