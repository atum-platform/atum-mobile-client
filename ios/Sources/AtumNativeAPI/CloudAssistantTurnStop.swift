import AtumChat
import Foundation

/// The live bridge from the pure chat state machine to the native domain API.
/// No local executor lives on the phone. As in desktop's `cloudRoomAgent`,
/// only a positively cloud-answering roster agent gets the cloud route.
public struct CloudAssistantTurnStop: Equatable, Sendable {
    public let agentPrincipal: NativeID
    public let roomID: MatrixRoomID

    /// `routeAvailable` requires authenticated native-domain access and no
    /// known route/admission refusal. Typing and model choice are not authority.
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
                                onRouteUnavailable: @MainActor () -> Void = {}) async -> AssistantTurnStopResult {
        do {
            let request = try CloudTurnStop.Request(
                requestId: NativeID(intent.requestID), agentPrincipal: agentPrincipal,
                roomId: roomID, eventId: MatrixEventID(intent.eventID)
            )
            switch try await client.cloudStop(request).state {
            case .stopped: return .stopped
            case .stopRequested: return .stopRequested
            case .completed: return .completed
            }
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure,
               [.denied, .notFound, .unavailable].contains(http.response.error) {
                onRouteUnavailable()
            }
            return .failed
        } catch { return .failed }
    }
}
