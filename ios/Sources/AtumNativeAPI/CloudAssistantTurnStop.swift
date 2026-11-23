import AtumChat
import Foundation

/// The live bridge from the pure chat state machine to the native domain API.
/// No local executor lives on the phone. As in desktop's `cloudRoomAgent`,
/// only a positively cloud-answering roster agent gets the cloud route.
public struct CloudAssistantTurnStop: Equatable, Sendable {
    public let agentPrincipal: NativeID
    public let roomID: MatrixRoomID

    /// `routeAvailable` requires authenticated native-domain access and
    /// an active roster binding. Source refusals are checked at dispatch.
    public init?(agent: AgentsResponse.Agent?, roomID: String, routeAvailable: Bool) {
        guard routeAvailable, let agent, agent.canOpenChat, agent.answering == .cloud,
              let roomID = try? MatrixRoomID(roomID) else { return nil }
        agentPrincipal = agent.principal
        self.roomID = roomID
    }

    /// The state machine owns the request ID (including retries). A refusal,
    /// missing route, transport failure or malformed reply never claims a stop.
    @MainActor public func stop(_ intent: AssistantTurnStopIntent,
                                using client: NativeDomainClient,
                                unavailableTargets: Set<AssistantTurnStopIntent.Target> = [],
                                onRouteUnavailable: @MainActor (AssistantTurnStopIntent.Target) -> Void = { _ in })
        async -> AssistantTurnStopResult {
        guard !unavailableTargets.contains(intent.target) else { return .failed }
        do {
            switch intent.target {
            case let .schedule(execution):
                // The authenticated host route checks the owned Hermes
                // runtime and matches the native execution before interrupting.
                return try await client.cloudScheduleStop(CloudScheduleStop.Request(
                    agent: agentPrincipal, execution: execution), onRouteUnavailable: {
                        onRouteUnavailable(intent.target)
                    })
            case let .turn(eventID):
                let request = try CloudTurnStop.Request(
                    requestId: NativeID(intent.requestID), agentPrincipal: agentPrincipal,
                    roomId: roomID, eventId: MatrixEventID(eventID)
                )
                switch try await client.cloudStop(request).state {
                case .stopped: return .stopped
                case .stopRequested: return .stopRequested
                case .completed: return .completed
                }
            }
        } catch let failure as NativeDomainClientFailure {
            if case .turn = intent.target, case let .http(http) = failure,
               [.denied, .notFound, .unavailable].contains(http.response.error) {
                onRouteUnavailable(intent.target)
            }
            return .failed
        } catch { return .failed }
    }
}
