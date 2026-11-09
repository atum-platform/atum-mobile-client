import Foundation

/// Frozen contract c. All correlations are display-only, never turn authority.
public enum AgentTurns {
    private static let agentForbidden: Set<String> = ["leaseToken", "accessToken", "token", "credential"]
    private static let platformForbidden: Set<String> = ["prompt", "body", "text", "executorId", "controllerId", "hostDevice", "deviceId", "accessToken", "refreshToken", "token", "credential", "password", "leaseToken", "recoveryKey"]
    public static func answer(_ data: Data) throws -> AgentAnswer {
        try NativeAPI.decode(AgentAnswer.self, from: data, forbidden: agentForbidden)
    }
    public static func notice(_ data: Data) throws -> AgentStatusNotice {
        try NativeAPI.decode(AgentStatusNotice.self, from: data, forbidden: agentForbidden.union(["io.atum.result"]))
    }
    public static func readiness(_ data: Data) throws -> AgentReadinessEntry {
        try NativeAPI.decode(AgentReadinessEntry.self, from: data, forbidden: platformForbidden)
    }
    public static func state(_ data: Data) throws -> AgentTurnStateResponse {
        try NativeAPI.decode(AgentTurnStateResponse.self, from: data, forbidden: platformForbidden)
    }
    public static func request(_ data: Data) throws -> AgentTurnStateRequest {
        try NativeAPI.decode(AgentTurnStateRequest.self, from: data,
            forbidden: ["owner", "principal", "ownerPrincipal", "accessToken", "refreshToken", "token", "credential", "password", "leaseToken", "recoveryKey"])
    }
}

public struct MatrixRoomID: Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws { rawValue = try checkedString(value, minimum: 2, maximum: 1024, pattern: "![!-~]+") }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
public struct MatrixEventID: Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws { rawValue = try checkedString(value, minimum: 2, maximum: 1024, pattern: "[$][!-~]+") }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
private struct RichReplyRelation: Decodable {
    struct Reply: Decodable {
        let eventID: MatrixEventID
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["event_id"])
            eventID = try c.value("event_id")
        }
    }
    let reply: Reply
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["m.in_reply_to"])
        reply = try c.value("m.in_reply_to")
    }
}

public struct AgentAnswer: Decodable, Equatable, Sendable {
    public struct Result: Decodable, Equatable, Sendable {
        public enum ProposedStatus: String, Decodable, Sendable {
            case stopped, failed, deadline, unfunded
            case couldntConfirm = "couldnt_confirm", trialExpired = "trial_expired", queueFull = "queue_full", memoryNotSaved = "memory_not_saved"
            case couldntVerifyMac = "couldnt_verify_mac", resumingOnDevice = "resuming_on_device", attachmentUnsupported = "attachment_unsupported"
            case threadUnsupported = "thread_unsupported", savedToDrive = "saved_to_drive", savedAsCopy = "saved_as_copy", saveUnconfirmed = "save_unconfirmed"
        }
        public let invocation: NativeID
        public let transaction: String
        /// Proposed/unshipped. M1 never requires or infers authority from this.
        public let status: ProposedStatus?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["invocation", "transaction", "status"])
            invocation = try c.value("invocation")
            transaction = try c.string("transaction", minimum: 1, maximum: 255, pattern: "[!-~]+")
            status = try c.optional("status")
        }
    }
    public let body: String
    public let replyTo: MatrixEventID
    public let result: Result
    public let localTurn: NativeID?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("msgtype", as: String.self) == "m.text" else { throw ContractViolation.invalidValue }
        body = try c.string("body", minimum: 1, maximum: 65_536)
        replyTo = try c.value("m.relates_to", as: RichReplyRelation.self).reply.eventID
        result = try c.value("io.atum.result"); localTurn = try c.optional("io.atum.turn")
        if let localTurn {
            _ = try checkedString(localTurn.rawValue, minimum: 36, maximum: 36, pattern: "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
        }
    }
}
public struct AgentStatusNotice: Decodable, Equatable, Sendable {
    public let body: String
    public let replyTo: MatrixEventID
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("msgtype", as: String.self) == "m.notice" else { throw ContractViolation.invalidValue }
        body = try c.string("body", minimum: 1, maximum: 1000)
        replyTo = try c.value("m.relates_to", as: RichReplyRelation.self).reply.eventID
    }
}
public enum AgentExecutorKind: String, Decodable, Sendable { case local, cloud }
public struct AgentReadinessEntry: Decodable, Equatable, Sendable {
    public struct Readiness: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case ready, starting, busy, offline, recoveryNeeded = "recovery_needed" }
        public let state: State
        public let executorKind: AgentExecutorKind?
        public let observedAt: Int64
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["state", "executorKind", "observedAt"])
            state = try c.value("state"); executorKind = try c.nullable("executorKind"); observedAt = try c.integer("observedAt")
        }
    }
    public let principal: NativeID
    public let readiness: Readiness
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        principal = try c.value("principal"); readiness = try c.value("readiness")
    }
}
public struct AgentTurnStateRequest: Codable, Equatable, Hashable, Sendable {
    public let agentPrincipal: NativeID
    public let roomId: MatrixRoomID
    public let eventId: MatrixEventID
    public init(agentPrincipal: NativeID, roomId: MatrixRoomID, eventId: MatrixEventID) {
        self.agentPrincipal = agentPrincipal; self.roomId = roomId; self.eventId = eventId
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["agentPrincipal", "roomId", "eventId"])
        agentPrincipal = try c.value("agentPrincipal"); roomId = try c.value("roomId"); eventId = try c.value("eventId")
    }
}
public struct AgentTurnStateResponse: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case recorded, claimed, dispatched, stopRequested = "stop_requested", stopped, completed }
    public enum Outcome: String, Decodable, Sendable { case answered, stopped, failed, uncertain }
    public let state: State
    public let updatedAt: Int64
    public let outcome: Outcome?
    public let executorKind: AgentExecutorKind?
    public let transactionId: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["state", "updatedAt", "outcome", "executorKind", "transactionId"])
        state = try c.value("state"); updatedAt = try c.integer("updatedAt"); outcome = try c.optional("outcome")
        executorKind = try c.optional("executorKind"); transactionId = try c.optional("transactionId")
        if let transactionId { _ = try checkedString(transactionId, minimum: 1, maximum: 255, pattern: "[!-~]+") }
    }
}

/// Exact client_turn transition machine. Readiness and m.typing have no input.
public struct ClientTurn: Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case sent, working, stopping, answered, stopped, failed, uncertain
        case statusShown = "status_shown", notAnswered = "not_answered"
    }
    public enum Event: String, Decodable, Sendable {
        case running = "turn_state_claimed_or_dispatched", notice = "status_notice_reply", answer = "answer_reply", lateAnswer = "late_answer_reply"
        case stopSent = "stop_sent", stopped = "stop_result_or_outcome_stopped", completedBeforeStop = "completed_before_stop"
        case m1BoundElapsed = "m1_bound_elapsed", failed = "outcome_failed", uncertain = "outcome_uncertain"
    }
    public let key: AgentTurnStateRequest
    public let sentAt: Date
    public let automaticAnswering: Bool
    public let expectedAgentSender: String
    public private(set) var state = State.sent
    public private(set) var answer: AgentAnswer?
    public private(set) var notices: [AgentStatusNotice] = []
    public init(key: AgentTurnStateRequest, sentAt: Date, automaticAnswering: Bool, expectedAgentSender: String) throws {
        _ = try checkedString(expectedAgentSender, minimum: 4, maximum: 1024, pattern: "@[!-9;-~]+:[!-~]+")
        self.key = key; self.sentAt = sentAt; self.automaticAnswering = automaticAnswering; self.expectedAgentSender = expectedAgentSender
    }
    public var m1Deadline: Date { sentAt.addingTimeInterval(automaticAnswering ? 900 : 120) }
    @discardableResult public mutating func advance(_ event: Event) -> Bool {
        let next: State?
        switch (state, event) {
        case (.sent, .running): next = .working
        case (.sent, .notice), (.working, .notice), (.statusShown, .notice): next = .statusShown
        case (.sent, .answer), (.working, .answer), (.statusShown, .answer), (.notAnswered, .lateAnswer), (.stopping, .completedBeforeStop): next = .answered
        case (.sent, .stopSent), (.working, .stopSent), (.statusShown, .stopSent): next = .stopping
        case (.stopping, .stopped): next = .stopped
        case (.sent, .m1BoundElapsed), (.statusShown, .m1BoundElapsed): next = .notAnswered
        case (.sent, .failed), (.working, .failed): next = .failed
        case (.sent, .uncertain), (.working, .uncertain): next = .uncertain
        default: next = nil
        }
        guard let next else { return false }; state = next; return true
    }
    @discardableResult public mutating func expireM1(at now: Date) -> Bool {
        guard now >= m1Deadline else { return false }
        return advance(.m1BoundElapsed)
    }
    @discardableResult public mutating func receive(_ value: AgentStatusNotice, room: MatrixRoomID, sender: String) -> Bool {
        guard room == key.roomId, sender == expectedAgentSender, value.replyTo == key.eventId, advance(.notice) else { return false }
        if !notices.contains(value) { notices.append(value) }; return true
    }
    @discardableResult public mutating func receive(_ value: AgentAnswer, room: MatrixRoomID, sender: String) -> Bool {
        guard room == key.roomId, sender == expectedAgentSender, value.replyTo == key.eventId else { return false }
        let event: Event = state == .notAnswered ? .lateAnswer : state == .stopping ? .completedBeforeStop : .answer
        guard advance(event) else { return false }; answer = value; return true
    }
}
