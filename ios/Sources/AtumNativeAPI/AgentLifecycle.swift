import Foundation

public struct AgentLifecycleCapability: Decodable, Equatable, Sendable {
    public let available: Bool
    public let disclosureVersion: Int?
    public let reason: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "available", "disclosureVersion", "reason"])
        guard try c.value("profile", as: String.self) == "atum.agent-lifecycle/1" else {
            throw ContractViolation.invalidValue
        }
        available = try c.value("available")
        disclosureVersion = try c.optional("disclosureVersion")
        reason = try c.optional("reason")
        if let disclosureVersion { guard disclosureVersion >= 1 else { throw ContractViolation.invalidValue } }
        if let reason { _ = try checkedString(reason, minimum: 1, maximum: 64, pattern: "[a-z_]+") }
        guard available == (disclosureVersion != nil && reason == nil) || !available else {
            throw ContractViolation.invariant
        }
    }
}

public struct AgentLifecycleBegin: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let displayName: String
    public let ownerDevice: String
    public let disclosureVersion: Int

    public init(requestId: NativeID, displayName: String,
                ownerDevice: String, disclosureVersion: Int) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), disclosureVersion >= 1,
              ownerDevice.range(of: "\\A[!-~]{1,255}\\z", options: .regularExpression) != nil,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ContractViolation.invalidValue }
        self.requestId = requestId
        self.displayName = name
        self.ownerDevice = ownerDevice
        self.disclosureVersion = disclosureVersion
    }

    private enum CodingKeys: String, CodingKey {
        case operation, requestId, displayName, ownerDevice, disclosureVersion
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("begin", forKey: .operation)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(ownerDevice, forKey: .ownerDevice)
        try c.encode(disclosureVersion, forKey: .disclosureVersion)
    }
}

public struct AgentLifecycleResume: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public init(requestId: NativeID) { self.requestId = requestId }
    private enum CodingKeys: String, CodingKey { case operation, requestId }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("resume", forKey: .operation)
        try c.encode(requestId, forKey: .requestId)
    }
}

public struct AgentLifecycleEnrollment: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case provisioning, awaitingTrust = "awaiting_trust", active, revoking, revoked
    }
    public enum Trust: String, Decodable, Sendable { case pending, trusted, recoveryNeeded = "recovery_needed" }
    public let enrollmentID, agentPrincipal, executorID: NativeID
    public let state: State
    public let trust: Trust
    public let conversationReady: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed([
            "enrollmentId", "kind", "agentPrincipal", "executorId",
            "state", "trust", "conversationReady",
        ])
        enrollmentID = try c.value("enrollmentId")
        agentPrincipal = try c.value("agentPrincipal")
        executorID = try c.value("executorId")
        state = try c.value("state")
        trust = try c.value("trust")
        conversationReady = try c.optional("conversationReady") ?? false
        guard try c.value("kind", as: String.self) == "cloud" else { throw ContractViolation.invalidValue }
    }
}

public struct AgentLifecycleSnapshot: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case creatingIdentity = "creating_identity"
        case creatingRuntime = "creating_runtime"
        case creatingRoom = "creating_room"
        case starting, ready
    }
    public let requestID: NativeID
    public let state: State
    public let assistant: AgentsResponse.Agent?
    public let enrollment: AgentLifecycleEnrollment?
    public let roomID: String?

    /// The complete server-owned readiness relation. Callers still have to
    /// prove that the selected Matrix session has published this exact room
    /// with this exact assistant as a joined member before navigating to it.
    public var isAuthoritativeReady: Bool {
        guard state == .ready,
              let assistant, let enrollment, roomID != nil else { return false }
        return assistant.status == .active
            && assistant.answering == .cloud
            && assistant.matrixUser != nil
            && assistant.principal == enrollment.agentPrincipal
            && enrollment.state == .active
            && enrollment.trust == .trusted
            && enrollment.conversationReady
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "requestId", "state", "assistant", "enrollment", "roomId"])
        guard try c.value("profile", as: String.self) == "atum.agent-lifecycle/1" else {
            throw ContractViolation.invalidValue
        }
        requestID = try c.value("requestId")
        state = try c.value("state")
        assistant = try c.optional("assistant")
        enrollment = try c.optional("enrollment")
        roomID = try c.optional("roomId")
        if let roomID {
            _ = try checkedString(roomID, minimum: 2, maximum: 1_024, pattern: "![!-~]+")
        }
        guard (assistant == nil) == (state == .creatingIdentity),
              (enrollment == nil) == [.creatingIdentity, .creatingRuntime].contains(state),
              roomID == nil || enrollment != nil,
              assistant == nil || enrollment == nil
                || assistant?.principal == enrollment?.agentPrincipal,
              state != .ready || isAuthoritativeReady
        else { throw ContractViolation.invariant }
    }
}
