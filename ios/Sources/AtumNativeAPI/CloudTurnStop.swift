import Foundation

/// `POST /api/matrix/v1/cloud/stop` for one turn (`atum.cloud-execution/1`
/// §3.5, `atum.agent-turns/1` rule 5): the shapes only, no transport. The
/// desktop sends the same body (atum-app `apps/desktop/electron/matrix/device/
/// cloud-stop.ts`) and checks the same reply.
///
/// - The owner chooses the target; the client chooses the agent, the route and
///   the idempotency key. The platform is idempotent on `(owner, requestId)`,
///   so a retry of the same stop re-sends the same `requestId`.
/// - Only `{kind: "turn", roomId, eventId}` is sent; occurrences and executor
///   identities are never named.
/// - The reply must echo the agent and the exact target, with one of
///   `stopped`, `stop_requested` or `completed`. Anything else is
///   unconfirmed, and the turn is never shown as stopped on it.
public enum CloudTurnStop {
    public static let path = "/api/matrix/v1/cloud/stop"

    public struct Request: Encodable, Equatable, Sendable {
        public struct Target: Encodable, Equatable, Sendable {
            public let kind = "turn"
            public let roomId: MatrixRoomID
            public let eventId: MatrixEventID
        }

        public let requestId: NativeID
        public let agentPrincipal: NativeID
        public let target: Target

        public init(requestId: NativeID, agentPrincipal: NativeID, roomId: MatrixRoomID, eventId: MatrixEventID) {
            self.requestId = requestId
            self.agentPrincipal = agentPrincipal
            target = Target(roomId: roomId, eventId: eventId)
        }

        /// The exact body, keys sorted (no server-chosen or local fields).
        public func body() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    public enum State: String, Decodable, Equatable, Sendable {
        case stopped
        case stopRequested = "stop_requested"
        case completed
    }

    public struct Response: Decodable, Equatable, Sendable {
        public let agentPrincipal: NativeID
        public let roomId: MatrixRoomID
        public let eventId: MatrixEventID
        public let state: State
        public let stoppedAt: Int64

        private struct Target: Decodable {
            let roomId: MatrixRoomID
            let eventId: MatrixEventID
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Field.self)
                try c.closed(["kind", "roomId", "eventId"])
                guard try c.value("kind", as: String.self) == "turn" else { throw ContractViolation.invalidValue }
                roomId = try c.value("roomId")
                eventId = try c.value("eventId")
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["agentPrincipal", "target", "state", "stoppedAt"])
            agentPrincipal = try c.value("agentPrincipal")
            let target = try c.value("target", as: Target.self)
            roomId = target.roomId
            eventId = target.eventId
            state = try c.value("state")
            stoppedAt = try c.integer("stoppedAt")
        }
    }

    /// Decodes a `200` reply and checks it answers `request`. Throws on any
    /// other shape, a credential-like field, or a reply for another target.
    public static func response(_ data: Data, for request: Request) throws -> Response {
        let value = try NativeAPI.decode(Response.self, from: data,
                                         forbidden: ["executorId", "controllerId", "hostDevice", "deviceId",
                                                     "accessToken", "refreshToken", "token", "credential",
                                                     "password", "leaseToken", "recoveryKey"])
        guard value.agentPrincipal == request.agentPrincipal, value.roomId == request.target.roomId,
              value.eventId == request.target.eventId else { throw ContractViolation.invariant }
        return value
    }
}
