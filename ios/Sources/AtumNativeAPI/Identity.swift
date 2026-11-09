import Foundation

public struct AgentsResponse: Decodable, Equatable, Sendable {
    public let agents: [Agent]
    public init(from decoder: Decoder) throws {
        let decoded = try LossyDecodableArray<Agent>(from: decoder)
        guard decoded.sourceCount <= 51,
              decoded.sourceCount == 0 || !decoded.elements.isEmpty else {
            throw ContractViolation.invalidValue
        }
        agents = decoded.elements
    }
    public struct Agent: Decodable, Equatable, Identifiable, Sendable {
        public enum Status: Decodable, Equatable, Sendable {
            case active, retired, unknown

            public init(from decoder: Decoder) throws {
                switch try decoder.singleValueContainer().decode(String.self) {
                case "active": self = .active
                case "retired": self = .retired
                default: self = .unknown
                }
            }
        }
        public enum Answering: Decodable, Equatable, Sendable {
            case local, cloud, unknown

            public init(from decoder: Decoder) throws {
                switch try decoder.singleValueContainer().decode(String.self) {
                case "local": self = .local
                case "cloud": self = .cloud
                default: self = .unknown
                }
            }
        }
        public let id: NativeID
        public let identityID: NativeID?
        public let displayName: String
        public let slug: String?
        public let avatar: String
        public let avatarURL: String?
        public let title: String?
        public let mark: AgentMark?
        public let isDefault: Bool
        public let lifecycleRevision, identityRevision, definitionRevision: Int64
        public let status: Status
        public let answering: Answering?
        public let principal: NativeID
        public let matrixUser: NativeMatrixUser?
        public let retiredAgents: [RetiredAgent]?
        public var canOpenChat: Bool { status == .active && matrixUser != nil }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            // The contract explicitly allows additional noncredential fields.
            id = try c.value("id")
            identityID = try c.nullable("identity_id")
            displayName = try c.string("display_name", minimum: 1, maximum: 64)
            let rawSlug: String? = try c.nullable("slug")
            if let rawSlug { _ = try checkedString(rawSlug, minimum: 1, maximum: 64) }
            slug = rawSlug
            let rawAvatar: String? = c.lossyNullable("avatar")
            avatar = rawAvatar.flatMap { (try? checkedString($0, maximum: 16)) == nil ? nil : $0 } ?? ""
            let rawAvatarURL: String? = try c.nullable("avatar_url")
            avatarURL = rawAvatarURL.flatMap {
                (try? checkedString($0, minimum: 9, maximum: 2_048,
                                    pattern: "https://[!-~]+")) == nil ? nil : $0
            }
            isDefault = try c.value("is_default")
            let rawTitle: String? = c.lossyNullable("title")
            title = rawTitle.flatMap { value in
                guard (try? checkedString(value, minimum: 1, maximum: 80)) != nil,
                      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                else { return nil }
                return value
            }
            let shape = c.lossyNullable("mark_shape", as: String.self)
                .flatMap(AgentMarkShape.init(rawValue:))
            let color = c.lossyNullable("mark_color", as: String.self)
                .flatMap(AgentMarkColor.init(rawValue:))
            mark = shape.flatMap { knownShape in
                color.map { AgentMark(shape: knownShape, color: $0) }
            }
            lifecycleRevision = try c.integer("lifecycle_revision", minimum: 1)
            identityRevision = try c.integer("identity_revision"); definitionRevision = try c.integer("definition_revision")
            status = try c.value("status")
            answering = c.lossyNullable("answering")
            principal = try c.value("principal")
            let rawMatrixUser: String? = try c.nullable("matrixUser")
            matrixUser = rawMatrixUser.flatMap { try? NativeMatrixUser($0) }
            retiredAgents = c.lossyNullable("retired_agents")
            guard (retiredAgents?.count ?? 0) <= 1000 else { throw ContractViolation.invalidValue }
        }
    }
    public struct RetiredAgent: Decodable, Equatable, Identifiable, Sendable {
        public let id, principal: NativeID
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            id = try c.value("id"); principal = try c.value("principal")
            guard try c.value("status", as: String.self) == "retired" else { throw ContractViolation.invalidValue }
        }
    }
}

public enum AliasLookupResponse: Decodable, Equatable, Sendable {
    public enum UnassignedState: String, Decodable, Sendable { case invalid, available, unavailable }
    public enum Kind: String, Decodable, Sendable { case human, agent, app, organization }
    public struct Assignment: Equatable, Sendable {
        public let handle: NativeHandle
        public let principal: NativeID
        public let kind: Kind
        public let generation: Int64
        public let matrixUser: NativeMatrixUser?
    }
    case unassigned(handle: NativeHandle?, state: UnassignedState)
    case assigned(Assignment)

    /// This is a lookup result, not permission to create a room. Caller must
    /// additionally reject self, bots and organization/company identities.
    public var humanMessageTarget: NativeMatrixUser? {
        if case .assigned(let value) = self, value.kind == .human { return value.matrixUser }
        return nil
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("state")
        if state == "assigned" {
            try c.closed(["handle", "state", "principal", "kind", "generation", "matrixUser"])
            self = .assigned(Assignment(handle: try c.value("handle"), principal: try c.value("principal"),
                kind: try c.value("kind"), generation: try c.integer("generation", minimum: 1), matrixUser: try c.nullable("matrixUser")))
        } else {
            try c.closed(["handle", "state"])
            self = .unassigned(handle: try c.nullable("handle"), state: try c.value("state"))
        }
    }
}

public enum AliasCurrentResponse: Decodable, Equatable, Sendable {
    case none
    case assigned(handle: NativeHandle, generation: Int64)
    public init(from decoder: Decoder) throws {
        if try decoder.singleValueContainer().decodeNil() { self = .none; return }
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "generation"])
        self = .assigned(handle: try c.value("handle"), generation: try c.integer("generation", minimum: 1))
    }
}

public struct AliasCheckResponse: Decodable, Equatable, Sendable {
    public enum Code: String, Decodable, Sendable {
        case invalid = "alias_invalid", botSuffixRequired = "alias_bot_suffix_required", botSuffixReserved = "alias_bot_suffix_reserved"
        case reserved = "alias_reserved", unavailable = "alias_unavailable"
    }
    public let handle: NativeHandle?
    public let available: Bool
    public let code: Code?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "available", "code"])
        handle = try c.nullable("handle"); available = try c.value("available"); code = try c.nullable("code")
    }
}

public struct AliasClaimRequest: Codable, Equatable, Sendable {
    public let handle: String
    public let requestId: NativeID
    public let assistantId: NativeID?
    public init(handle: String, requestId: NativeID, assistantId: NativeID? = nil) throws {
        self.handle = try checkedString(handle, minimum: 1, maximum: 33)
        self.requestId = requestId; self.assistantId = assistantId
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "requestId", "assistantId"])
        try self.init(handle: c.string("handle", minimum: 1, maximum: 33), requestId: c.value("requestId"), assistantId: c.optional("assistantId"))
    }
}

public struct AliasClaimResponse: Decodable, Equatable, Sendable {
    public let handle: NativeHandle
    public let principal: NativeID
    public let generation: Int64
    public let replayed: Bool?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "state", "principal", "generation", "replayed"])
        handle = try c.value("handle"); principal = try c.value("principal"); generation = try c.integer("generation", minimum: 1)
        guard try c.value("state", as: String.self) == "assigned" else { throw ContractViolation.invalidValue }
        replayed = try c.optional("replayed")
        guard replayed != false else { throw ContractViolation.invalidValue }
    }
}
