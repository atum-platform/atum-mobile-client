import Foundation

// The `atum.company-workspace/1.1` wire (B19 S4). Everything here is a
// display-safe value or a refusal: no transport, no persistence and no
// authority. The 1.1 shapes are closed; a v1 answer is reported as `v1` and
// never widened, so the phone hides the feature against an older server.

public enum CompanyWire: String, Sendable, Equatable {
    case v1 = "1"
    case v1_1 = "1.1"
    /// Invite links (`CompanyInvites.swift`).
    case v1_2 = "1.2"
    /// Capability discovery (`GET /company-capabilities`).
    case v1_3 = "1.3"
    /// Company DMs and group DMs (`CompanyConversations.swift`).
    case v1_5 = "1.5"

    public static let headerName = "Atum-Company-Wire"
}

/// A company read that states which wire answered it. `.v1` is the server's
/// explicit "no 1.1 here" and hides every 1.1-only affordance.
public enum CompanyRead<Value: Equatable & Sendable>: Equatable, Sendable {
    case v1
    case v1_1(Value)

    public var value: Value? {
        if case let .v1_1(value) = self { return value }
        return nil
    }

    public var isSupported: Bool {
        if case .v1_1 = self { return true }
        return false
    }
}

public enum CompanyRole: String, Decodable, Equatable, Sendable {
    case admin, member
}

public enum CompanyMemberState: String, Decodable, Equatable, Sendable {
    case invited, active, revoking, removed
}

public enum CompanyRevocationState: String, Decodable, Equatable, Sendable {
    case revoking, removed
}

public enum CompanyChannelState: String, Decodable, Equatable, Sendable {
    case provisioning, active, archived
}

public struct CompanySummary: Decodable, Equatable, Sendable {
    public let id: NativeID
    public let displayName: String
    public let role: CompanyRole
    public let authorityGeneration: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "displayName", "role", "authorityGeneration"])
        id = try c.value("id")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        role = try c.value("role")
        authorityGeneration = try c.integer("authorityGeneration", minimum: 1)
    }
}

public struct CompanyInviter: Decodable, Equatable, Sendable {
    public let handle: String?
    public let displayName: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "displayName"])
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
}

public struct CompanyInvitation: Decodable, Equatable, Sendable {
    public let id: NativeID
    public let companyId: NativeID
    public let displayName: String
    public let role: CompanyRole
    public let inviter: CompanyInviter

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "companyId", "displayName", "role", "inviter"])
        id = try c.value("id")
        companyId = try c.value("companyId")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        role = try c.value("role")
        inviter = try c.value("inviter")
    }
}

public struct CompanyList: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let companies: [CompanySummary]
    public let invitations: [CompanyInvitation]
    public let canCreate: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "companies", "invitations", "canCreate"])
        let version = try c.integer("schemaVersion", minimum: 1)
        guard version == 2 else { throw ContractViolation.invalidValue }
        schemaVersion = Int(version)
        companies = try c.boundedArray("companies", maximum: 100)
        invitations = try c.boundedArray("invitations", maximum: 100)
        canCreate = try c.value("canCreate")
        guard Set(companies.map(\.id)).count == companies.count,
              Set(invitations.map(\.id)).count == invitations.count else {
            throw ContractViolation.invariant
        }
    }
}

public struct CompanyMember: Decodable, Equatable, Sendable {
    public let memberRef: String
    public let role: CompanyRole
    public let state: CompanyMemberState
    public let isSelf: Bool
    public let handle: String?
    public let displayName: String?
    public let avatarUri: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["memberRef", "role", "state", "self", "handle", "displayName", "avatarUri"])
        memberRef = try CompanyMemberRef.checked(try c.value("memberRef", as: String.self))
        role = try c.value("role")
        state = try c.value("state")
        isSelf = try c.value("self")
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
        if let raw = try c.optional("avatarUri", as: String.self) {
            avatarUri = try checkedString(raw, minimum: 10, maximum: 512,
                                           pattern: CompanyMember.avatarPattern)
        } else {
            avatarUri = nil
        }
        if state == .removed {
            // The projection withholds a removed person's profile.
            guard handle == nil, displayName == nil, avatarUri == nil, !isSelf else {
                throw ContractViolation.invariant
            }
        }
    }

    static let avatarPattern = "mxc://[A-Za-z0-9._-]{1,255}/[A-Za-z0-9_-]{1,255}"
}

public struct CompanyProject: Decodable, Equatable, Sendable {
    public let id: NativeID
    public let displayName: String
    public let memberRefs: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "displayName", "memberRefs", "collaboration"])
        id = try c.value("id")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        memberRefs = try c.boundedArray("memberRefs", maximum: 100)
            .map { try CompanyMemberRef.checked($0) }
        let collaboration = try c.string("collaboration", minimum: 1, maximum: 64)
        guard collaboration == "not_provisioned",
              Set(memberRefs).count == memberRefs.count else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct CompanySnapshot: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let company: CompanySummary
    public let members: [CompanyMember]
    public let projects: [CompanyProject]
    public let defaultChannelId: NativeID?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "company", "members", "projects", "defaultChannelId"])
        let version = try c.integer("schemaVersion", minimum: 1)
        guard version == 2 else { throw ContractViolation.invalidValue }
        schemaVersion = Int(version)
        company = try c.value("company")
        members = try c.boundedArray("members", maximum: 100)
        projects = try c.boundedArray("projects", maximum: 100)
        defaultChannelId = try c.nullable("defaultChannelId", as: NativeID.self)
        guard !members.isEmpty,
              Set(members.map(\.memberRef)).count == members.count,
              members.filter(\.isSelf).count <= 1,
              Set(projects.map(\.id)).count == projects.count else {
            throw ContractViolation.invariant
        }
    }
}

public struct CompanyChannelRoom: Decodable, Equatable, Sendable {
    public let state: String
    public let roomId: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["state", "roomId"])
        let state = try c.string("state", minimum: 1, maximum: 32)
        let roomId = try c.nullable("roomId", as: String.self)
        switch state {
        case "ready":
            guard let roomId else { throw ContractViolation.invariant }
            self.roomId = try checkedString(roomId, minimum: 4, maximum: 512, pattern: CompanyChannelRoom.pattern)
        case "not_provisioned", "provisioning", "reconciling", "failed":
            guard roomId == nil else { throw ContractViolation.invariant }
            self.roomId = nil
        default:
            throw ContractViolation.invalidValue
        }
        self.state = state
    }

    static let pattern = "![!-9;-~]{1,255}:[!-~]{1,255}"
}

public struct CompanyChannel: Decodable, Equatable, Sendable {
    public let id: NativeID
    public let companyId: NativeID
    public let displayName: String
    public let state: CompanyChannelState
    public let projectId: NativeID?
    public let authorityGeneration: Int64
    public let channelGeneration: Int64
    public let systemKey: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "companyId", "displayName", "visibility", "state", "projectId",
                      "authorityGeneration", "channelGeneration", "systemKey"])
        id = try c.value("id")
        companyId = try c.value("companyId")
        displayName = try c.string("displayName", minimum: 1, maximum: 80)
        let visibility = try c.string("visibility", minimum: 1, maximum: 16)
        guard visibility == "company" else { throw ContractViolation.invalidValue }
        state = try c.value("state")
        projectId = try c.nullable("projectId", as: NativeID.self)
        authorityGeneration = try c.integer("authorityGeneration", minimum: 1)
        channelGeneration = try c.integer("channelGeneration", minimum: 1)
        systemKey = try c.optional("systemKey", as: String.self)
        if let systemKey, systemKey != "default" { throw ContractViolation.invalidValue }
    }

    public var isDefault: Bool { systemKey == "default" }
}

public struct CompanyChannelEntry: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: CompanyChannel
    public let memberCount: Int64
    public let room: CompanyChannelRoom

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "channel", "memberCount", "room"])
        let version = try c.integer("schemaVersion", minimum: 1)
        guard version == 2 else { throw ContractViolation.invalidValue }
        schemaVersion = Int(version)
        channel = try c.value("channel")
        memberCount = try c.integer("memberCount", minimum: 0)
        guard memberCount <= 100 else { throw ContractViolation.invalidValue }
        room = try c.value("room")
    }
}

public struct CompanyChannelDirectory: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channels: [CompanyChannelEntry]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "channels"])
        let version = try c.integer("schemaVersion", minimum: 1)
        guard version == 2 else { throw ContractViolation.invalidValue }
        schemaVersion = Int(version)
        channels = try c.boundedArray("channels", maximum: 100)
        guard Set(channels.map(\.channel.id)).count == channels.count else {
            throw ContractViolation.invariant
        }
    }
}

public struct CompanyLeaveAcknowledgement: Decodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let companyId: NativeID
    public let state: CompanyRevocationState
    public let retired: Bool
    public let authorityGeneration: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "companyId", "state", "retired", "authorityGeneration"])
        let version = try c.integer("schemaVersion", minimum: 1)
        guard version == 2 else { throw ContractViolation.invalidValue }
        schemaVersion = Int(version)
        companyId = try c.value("companyId")
        state = try c.value("state")
        retired = try c.value("retired")
        authorityGeneration = try c.integer("authorityGeneration", minimum: 1)
    }

    public var isFinished: Bool { state == .removed || retired }
}

public struct CompanyAcceptRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let invitationId: NativeID

    public init(requestId: NativeID, invitationId: NativeID) {
        self.requestId = requestId
        self.invitationId = invitationId
    }
}

public struct CompanyLeaveRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID

    public init(requestId: NativeID) {
        self.requestId = requestId
    }
}

/// `POST /companies` (the same body on both wires). The request ID is what
/// makes a retry the same company instead of a second one.
public struct CompanyCreateRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let displayName: String

    public init(requestId: NativeID, displayName: String) {
        self.requestId = requestId
        self.displayName = displayName
    }
}

/// Decodes the 1.1 messages and refuses everything the pack refuses. A v1
/// answer is not decoded at all: it is the server saying "no 1.1 here", which
/// the phone surfaces as a hidden feature rather than as an error.
public enum CompanyWorkspaceWire {
    public static let maximumBytes = 262_144

    public static func decodeList(_ data: Data) throws -> CompanyRead<CompanyList> {
        try decode(data, as: CompanyList.self)
    }

    public static func decodeSnapshot(_ data: Data) throws -> CompanyRead<CompanySnapshot> {
        try decode(data, as: CompanySnapshot.self)
    }

    public static func decodeChannelDirectory(_ data: Data) throws -> CompanyRead<CompanyChannelDirectory> {
        try decode(data, as: CompanyChannelDirectory.self)
    }

    public static func decodeChannelSnapshot(_ data: Data) throws -> CompanyRead<CompanyChannelEntry> {
        try decode(data, as: CompanyChannelEntry.self)
    }

    public static func decodeSnapshotV11(_ data: Data) throws -> CompanySnapshot {
        guard case let .v1_1(value) = try decode(data, as: CompanySnapshot.self) else {
            throw CompanyWireRefusal.v1Answer
        }
        return value
    }

    public static func decodeLeave(_ data: Data) throws -> CompanyLeaveAcknowledgement {
        let (root, version) = try inspect(data)
        guard version == 2 else { throw CompanyWireRefusal.v1Answer }
        try rejectPrincipalFields(root)
        return try decodeClosed(CompanyLeaveAcknowledgement.self, from: data)
    }

    public static func probe(_ data: Data) throws -> CompanyWire {
        let (_, version) = try inspect(data)
        switch version {
        case 1: return .v1
        case 2: return .v1_1
        default: throw ContractViolation.invalidValue
        }
    }

    private static func decode<Value: Decodable & Equatable & Sendable>(
        _ data: Data, as type: Value.Type
    ) throws -> CompanyRead<Value> {
        let (root, version) = try inspect(data)
        switch version {
        case 1: return .v1
        case 2:
            try rejectPrincipalFields(root)
            return .v1_1(try decodeClosed(type, from: data))
        default:
            throw ContractViolation.invalidValue
        }
    }

    private static func decodeClosed<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try NativeAPI.decode(type, from: data)
    }

    private static func inspect(_ data: Data) throws -> (Any, Int) {
        guard data.count <= maximumBytes else { throw ContractViolation.invalidValue }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
        catch { throw ContractViolation.invalidValue }
        guard let object = root as? [String: Any],
              let raw = object["schemaVersion"] as? NSNumber,
              !["d", "f", "c", "B"].contains(String(cString: raw.objCType)),
              let version = Int(exactly: raw.int64Value) else {
            throw ContractViolation.invalidValue
        }
        return (root, version)
    }

    /// The 1.1 direction forbids every key containing "principal" at every
    /// nesting level, so a caller that asked for 1.1 never receives one.
    private static func rejectPrincipalFields(_ value: Any) throws {
        if let object = value as? [String: Any] {
            guard object.keys.allSatisfy({ !$0.lowercased().contains("principal") }) else {
                throw ContractViolation.forbiddenField
            }
            for child in object.values { try rejectPrincipalFields(child) }
        } else if let array = value as? [Any] {
            for child in array { try rejectPrincipalFields(child) }
        }
    }
}

public enum CompanyWireRefusal: Error, Equatable {
    /// The answer was v1, so a 1.1-only read/write is not available.
    case v1Answer
}

public enum CompanyHandle {
    public static func checked(_ value: String) throws -> String {
        try checkedString(value, minimum: 3, maximum: 32, pattern: "[a-z][a-z0-9_]{2,31}")
    }
}

public enum CompanyMemberRef {
    public static func checked(_ value: String) throws -> String {
        try checkedString(value, minimum: 43, maximum: 43, pattern: "[A-Za-z0-9_-]{43}")
    }
}

private extension KeyedDecodingContainer where Key == Field {
    func boundedArray<Value: Decodable>(_ key: String, maximum: Int) throws -> [Value] {
        let values = try value(key, as: [Value].self)
        guard values.count <= maximum else { throw ContractViolation.invalidValue }
        return values
    }
}
