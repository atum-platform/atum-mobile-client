import CryptoKit
import Foundation

// The `atum.company-workspace/1.5` wire: company DMs and group DMs (wire 1.5,
// message schema 6) and the 1.3 capability answer that says whether they are
// on. Everything here is a display-safe value or a refusal: no transport, no
// persistence and no authority. Shapes are closed, participants are opaque
// member refs, and an answer is believed only when its participant-set digest
// is the one its own participants hash to.

// MARK: Capabilities (the probe)

/// `GET /company-capabilities` under `Atum-Company-Wire: 1.3`. Only the fields
/// the phone decides on are kept; the shape is still closed, so an answer with
/// a key this build does not know is not an answer.
public struct CompanyCapabilities: Decodable, Equatable, Sendable {
    public static let orderedWires = ["1", "1.1", "1.2", "1.3", "1.4", "1.5"]

    public let supportedWireVersions: [String]
    public let companyConversationsFeature: Bool
    public let companyConversationsActive: Bool
    /// Team administration (C1) is on for this tenant.
    public let teamAdminActive: Bool
    public let channelAdmissionFeature: Bool
    /// Channel admission (C2) is on for this tenant.
    public let channelAdmissionActive: Bool
    /// The hosted room controller is ready, so a new channel can become a room.
    public let roomReconciliationReady: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "wireVersion", "supportedWireVersions", "features",
                      "activation", "controller"])
        guard try c.integer("schemaVersion", minimum: 1) == 4,
              try c.string("wireVersion", minimum: 1, maximum: 8) == "1.3" else {
            throw ContractViolation.invalidValue
        }
        let wires: [String] = try c.value("supportedWireVersions")
        // One ordered prefix of the known wires, at least through 1.3.
        guard (4...6).contains(wires.count),
              wires == Array(Self.orderedWires.prefix(wires.count)) else {
            throw ContractViolation.invariant
        }
        supportedWireVersions = wires

        let features = try c.nestedContainer(keyedBy: Field.self, forKey: Field("features"))
        try features.closed(["ownership", "invitationLifecycle", "capabilityDiscovery",
                             "channelAdmission", "companyConversations"])
        for key in ["ownership", "invitationLifecycle", "capabilityDiscovery"] {
            guard try features.value(key, as: Bool.self) else { throw ContractViolation.invalidValue }
        }
        channelAdmissionFeature = try features.value("channelAdmission", as: Bool.self)
        companyConversationsFeature = try features.value("companyConversations", as: Bool.self)

        let activation = try c.nestedContainer(keyedBy: Field.self, forKey: Field("activation"))
        try activation.closed(["teamAdmin", "channelAdmission", "companyConversations"])
        var active = [String: Bool]()
        for key in ["teamAdmin", "channelAdmission"] {
            let value = try activation.value(key, as: String.self)
            guard ["inactive", "active"].contains(value) else { throw ContractViolation.invalidValue }
            active[key] = value == "active"
        }
        teamAdminActive = active["teamAdmin"] ?? false
        channelAdmissionActive = active["channelAdmission"] ?? false
        let conversations = try activation.value("companyConversations", as: String.self)
        guard ["inactive", "active"].contains(conversations) else { throw ContractViolation.invalidValue }
        companyConversationsActive = conversations == "active"

        let controller = try c.nestedContainer(keyedBy: Field.self, forKey: Field("controller"))
        try controller.closed(["roomReconciliation"])
        let reconciliation = try controller.value("roomReconciliation", as: String.self)
        guard ["not_ready", "ready"].contains(reconciliation) else { throw ContractViolation.invalidValue }
        roomReconciliationReady = reconciliation == "ready"
    }

    /// "Direct messages" is offered only when all three say so: the wire is
    /// named, the feature is on, and the tenant's activation is `active`. Any
    /// one off hides the section and sends no 1.5 request.
    public var offersConversations: Bool {
        supportedWireVersions.contains(CompanyWire.v1_5.rawValue)
            && companyConversationsFeature && companyConversationsActive
    }
}

// MARK: Conversations (schema 6)

public enum CompanyConversationKind: String, Decodable, Equatable, Sendable {
    case dm
    case groupDM = "group_dm"
}

public enum CompanyConversationState: String, Decodable, Equatable, Sendable {
    case provisioning, active
    case readOnly = "read_only"
}

public struct CompanyConversationParticipant: Decodable, Equatable, Sendable {
    public let memberRef: String
    public let admissionEpoch: Int64
    public let handle: String?
    public let displayName: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["memberRef", "admissionEpoch", "handle", "displayName"])
        memberRef = try CompanyMemberRef.checked(try c.value("memberRef", as: String.self))
        admissionEpoch = try c.integer("admissionEpoch", minimum: 1)
        if let raw = try c.nullable("handle", as: String.self) {
            handle = try CompanyHandle.checked(raw)
        } else {
            handle = nil
        }
        if let raw = try c.nullable("displayName", as: String.self) {
            displayName = try checkedString(raw, minimum: 1, maximum: 120)
        } else {
            displayName = nil
        }
    }

    init(memberRef: String, admissionEpoch: Int64, handle: String?, displayName: String?) {
        self.memberRef = memberRef
        self.admissionEpoch = admissionEpoch
        self.handle = handle
        self.displayName = displayName
    }
}

public struct CompanyConversation: Decodable, Equatable, Sendable {
    public static let maximumParticipants = 9

    public let id: NativeID
    public let companyId: NativeID
    public let kind: CompanyConversationKind
    public let state: CompanyConversationState
    public let participants: [CompanyConversationParticipant]
    public let participantSetDigest: String
    public let authorityGeneration: Int64
    public let conversationGeneration: Int64
    public let room: CompanyChannelRoom
    public let hidden: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "companyId", "kind", "state", "participants", "participantSetDigest",
                      "authorityGeneration", "conversationGeneration", "room", "hidden"])
        id = try c.value("id")
        companyId = try c.value("companyId")
        kind = try c.value("kind")
        state = try c.value("state")
        let people: [CompanyConversationParticipant] = try c.value("participants")
        guard (2...Self.maximumParticipants).contains(people.count) else { throw ContractViolation.invalidValue }
        participants = people
        participantSetDigest = try c.string("participantSetDigest", minimum: 64, maximum: 64,
                                            pattern: "[0-9a-f]{64}")
        authorityGeneration = try c.integer("authorityGeneration", minimum: 1)
        conversationGeneration = try c.integer("conversationGeneration", minimum: 1)
        room = try c.value("room")
        hidden = try c.value("hidden")

        let refs = people.map(\.memberRef)
        guard Set(refs).count == refs.count else { throw ContractViolation.invariant }
        // Canonical order: ascending bytes of the member ref.
        guard zip(refs, refs.dropFirst()).allSatisfy({ CompanyConversationDigest.precedes($0, $1) }) else {
            throw ContractViolation.invariant
        }
        switch kind {
        case .dm: guard people.count == 2 else { throw ContractViolation.invariant }
        case .groupDM: guard people.count >= 3 else { throw ContractViolation.invariant }
        }
        // The answer's own digest must be the digest of its own participants.
        guard participantSetDigest == CompanyConversationDigest.digest(
            companyID: companyId.rawValue, kind: kind,
            participants: people.map { (memberRef: $0.memberRef, admissionEpoch: $0.admissionEpoch) })
        else { throw ContractViolation.invariant }
    }

    public var isReadOnly: Bool { state == .readOnly }
}

public struct CompanyConversationDirectory: Decodable, Equatable, Sendable {
    public static let schemaVersion: Int64 = 6

    public let conversations: [CompanyConversation]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "conversations"])
        guard try c.integer("schemaVersion", minimum: 1) == Self.schemaVersion else {
            throw ContractViolation.invalidValue
        }
        let values: [CompanyConversation] = try c.value("conversations")
        guard values.count <= 100 else { throw ContractViolation.invalidValue }
        guard Set(values.map(\.id)).count == values.count else { throw ContractViolation.invariant }
        conversations = values
    }
}

/// The answer to open, expand and read: one conversation, and whether the
/// answer was a replay.
public struct CompanyConversationAnswer: Decodable, Equatable, Sendable {
    public let conversation: CompanyConversation
    public let replayed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "conversation", "replayed"])
        guard try c.integer("schemaVersion", minimum: 1) == CompanyConversationDirectory.schemaVersion else {
            throw ContractViolation.invalidValue
        }
        conversation = try c.value("conversation")
        replayed = try c.value("replayed")
    }
}

public struct CompanyConversationHiddenAnswer: Decodable, Equatable, Sendable {
    public let conversationId: NativeID
    public let hidden: Bool
    public let replayed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "conversationId", "hidden", "replayed"])
        guard try c.integer("schemaVersion", minimum: 1) == CompanyConversationDirectory.schemaVersion else {
            throw ContractViolation.invalidValue
        }
        conversationId = try c.value("conversationId")
        hidden = try c.value("hidden")
        replayed = try c.value("replayed")
    }
}

// MARK: Requests

public struct CompanyConversationOpenRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let participantMemberRefs: [String]

    public init(requestId: NativeID, participantMemberRefs: [String]) {
        self.requestId = requestId
        self.participantMemberRefs = participantMemberRefs
    }
}

public struct CompanyConversationExpandRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let sourceConversationId: NativeID
    public let participantMemberRefs: [String]

    public init(requestId: NativeID, sourceConversationId: NativeID, participantMemberRefs: [String]) {
        self.requestId = requestId
        self.sourceConversationId = sourceConversationId
        self.participantMemberRefs = participantMemberRefs
    }
}

public struct CompanyConversationHiddenRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let hidden: Bool

    public init(requestId: NativeID, hidden: Bool) {
        self.requestId = requestId
        self.hidden = hidden
    }
}

// MARK: Digest

/// The participant-set digest (`atum.company-conversation-participant-set/1`):
/// the identity of a conversation, normative for SQL, TypeScript and Swift.
/// Participants sort by the ascending UTF-8 bytes of the member ref; the
/// preimage is UTF-8 with LF line endings, no BOM and a final LF; the hash is
/// SHA-256, lowercase hexadecimal.
public enum CompanyConversationDigest {
    public static let prefix = "atum.company-conversation-participant-set/1"

    public static func digest(companyID: String, kind: CompanyConversationKind,
                              participants: [(memberRef: String, admissionEpoch: Int64)]) -> String {
        let sorted = participants.sorted { precedes($0.memberRef, $1.memberRef) }
        var lines = [prefix, "companyId=" + companyID, "kind=" + kind.rawValue]
        lines += sorted.map { "member=\($0.memberRef):\($0.admissionEpoch)" }
        let preimage = lines.joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(preimage.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Byte order of the UTF-8 encoding (the refs are ASCII, so it is also the
    /// string order, but the rule is the bytes').
    static func precedes(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }
}

// MARK: Decoding

public enum CompanyConversationWire {
    public static let maximumBytes = 262_144

    public static func decodeCapabilities(_ data: Data) throws -> CompanyCapabilities {
        try decode(CompanyCapabilities.self, from: data)
    }

    public static func decodeDirectory(_ data: Data) throws -> CompanyConversationDirectory {
        try decode(CompanyConversationDirectory.self, from: data)
    }

    public static func decodeAnswer(_ data: Data) throws -> CompanyConversationAnswer {
        try decode(CompanyConversationAnswer.self, from: data)
    }

    public static func decodeHidden(_ data: Data) throws -> CompanyConversationHiddenAnswer {
        try decode(CompanyConversationHiddenAnswer.self, from: data)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= maximumBytes else { throw ContractViolation.invalidValue }
        return try NativeAPI.decode(type, from: data)
    }
}
