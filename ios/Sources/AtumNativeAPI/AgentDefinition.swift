import Foundation

public enum AssistantNameRefusal: String, Decodable, Equatable, Sendable {
    case invalid = "assistant_name_invalid"
    case reserved = "assistant_name_reserved"
    case taken = "assistant_name_taken"
}

struct AssistantNameRefusalResponse: Decodable {
    let error: AssistantNameRefusal
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["error"])
        error = try c.value("error")
    }
}

public struct AgentCreateRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let displayName: String

    public init(requestId: NativeID, displayName: String) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ContractViolation.invalidValue }
        self.requestId = requestId
        self.displayName = name
    }

    private enum CodingKeys: String, CodingKey { case requestId, displayName }
}

public enum PortableModelAlias: String, Codable, Sendable {
    case binhMinh = "binh-minh"
    case nguyetThuc = "nguyet-thuc"
    case nhatThuc = "nhat-thuc"
}

public enum PortableReasoningEffort: String, Codable, Sendable {
    case minimal, low, medium, high, xhigh, max
}

public struct PortableReasoning: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let effort: PortableReasoningEffort?

    public init(enabled: Bool, effort: PortableReasoningEffort?) throws {
        guard enabled == (effort != nil) else { throw ContractViolation.invariant }
        self.enabled = enabled
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["enabled", "effort"])
        try self.init(enabled: c.value("enabled"), effort: c.nullable("effort"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(enabled, forKey: Field("enabled"))
        try c.encode(effort, forKey: Field("effort"))
    }
}

public struct PortableSkillReference: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String

    public init(name: String, sha256: String) throws {
        guard (1...200).contains(name.count), !name.contains("\\"),
              !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              sha256.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil
        else { throw ContractViolation.invalidValue }
        self.name = name
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["name", "sha256"])
        try self.init(name: c.value("name"), sha256: c.value("sha256"))
    }
}

public struct PortableAssistantDefinition: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var soul: String
    public let modelAlias: PortableModelAlias
    public let reasoning: PortableReasoning?
    public let skills: [PortableSkillReference]

    public init(soul: String, modelAlias: PortableModelAlias,
                reasoning: PortableReasoning?, skills: [PortableSkillReference]) throws {
        guard soul.utf8.count <= 65_536, skills.count <= 512,
              Set(skills.map(\.name)).count == skills.count else { throw ContractViolation.invalidValue }
        schemaVersion = 1
        self.soul = soul
        self.modelAlias = modelAlias
        self.reasoning = reasoning
        self.skills = skills
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schema_version", "soul", "model_alias", "reasoning", "skills"])
        guard try c.value("schema_version", as: Int.self) == 1 else { throw ContractViolation.invalidValue }
        try self.init(soul: c.value("soul"), modelAlias: c.value("model_alias"),
                      reasoning: c.nullable("reasoning"), skills: c.value("skills"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(1, forKey: Field("schema_version"))
        try c.encode(soul, forKey: Field("soul"))
        try c.encode(modelAlias, forKey: Field("model_alias"))
        try c.encode(reasoning, forKey: Field("reasoning"))
        try c.encode(skills, forKey: Field("skills"))
    }
}

public struct AgentDefinitionAssistant: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case active, retired }
    public let id, identityID, principal: NativeID
    public let displayName, avatar: String
    public let avatarURL: String?
    public let isDefault: Bool
    public let lifecycleRevision, identityRevision, definitionRevision: Int64
    public let status: Status

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        id = try c.value("id"); identityID = try c.value("identity_id"); principal = try c.value("principal")
        displayName = try c.string("display_name", minimum: 1, maximum: 40)
        avatar = try c.string("avatar", maximum: 16)
        avatarURL = try c.nullable("avatar_url")
        isDefault = try c.value("is_default")
        lifecycleRevision = try c.integer("lifecycle_revision", minimum: 1)
        identityRevision = try c.integer("identity_revision", minimum: 1)
        definitionRevision = try c.integer("definition_revision")
        status = try c.value("status")
        guard status == .active else { throw ContractViolation.invalidValue }
        if let avatarURL {
            _ = try checkedString(avatarURL, minimum: 9, maximum: 2_048, pattern: "https://[!-~]+")
        }
    }
}

public struct AgentDefinitionSnapshot: Decodable, Equatable, Sendable {
    public let assistant: AgentDefinitionAssistant
    public let definition: PortableAssistantDefinition?
    public let definitionRevision, identityRevision: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["assistant", "definition", "definition_revision", "identity_revision"])
        assistant = try c.value("assistant")
        definition = try c.nullable("definition")
        definitionRevision = try c.integer("definition_revision")
        identityRevision = try c.integer("identity_revision", minimum: 1)
        guard assistant.definitionRevision == definitionRevision,
              assistant.identityRevision == identityRevision,
              (definition == nil) == (definitionRevision == 0)
        else { throw ContractViolation.invariant }
    }
}

public struct AgentDefinitionWrite: Encodable, Equatable, Sendable {
    public let expectedDefinitionRevision, expectedIdentityRevision: Int64
    public let displayName, avatar: String
    public let definition: PortableAssistantDefinition

    public init(snapshot: AgentDefinitionSnapshot,
                displayName: String? = nil, avatar: String? = nil,
                definition: PortableAssistantDefinition) throws {
        let name = (displayName ?? snapshot.assistant.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        let mark = (avatar ?? snapshot.assistant.avatar).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), mark.count <= 16 else { throw ContractViolation.invalidValue }
        expectedDefinitionRevision = snapshot.definitionRevision
        expectedIdentityRevision = snapshot.identityRevision
        self.displayName = name
        self.avatar = mark
        self.definition = definition
    }

    private enum CodingKeys: String, CodingKey {
        case expectedDefinitionRevision = "expected_definition_revision"
        case expectedIdentityRevision = "expected_identity_revision"
        case displayName = "display_name"
        case avatar, definition
    }
}

public struct AgentAvatarImage: Encodable, Equatable, Sendable {
    public enum ContentType: String, Encodable, Sendable {
        case jpeg = "image/jpeg"
        case png = "image/png"
        case webp = "image/webp"
    }

    public let type: ContentType
    public let base64: String

    public init(type: ContentType, data: Data) throws {
        guard (1...(2 * 1_024 * 1_024)).contains(data.count) else {
            throw ContractViolation.invalidValue
        }
        let validMagic = switch type {
        case .jpeg: data.starts(with: [0xff, 0xd8, 0xff])
        case .png: data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case .webp:
            data.count >= 12 && data.starts(with: [0x52, 0x49, 0x46, 0x46])
                && data[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50])
        }
        guard validMagic else { throw ContractViolation.invalidValue }
        self.type = type
        base64 = data.base64EncodedString()
    }
}

public struct AgentAvatarWrite: Encodable, Equatable, Sendable {
    public let originPrincipal: NativeID?
    public let targetPrincipal: NativeID
    public let avatar: AgentAvatarImage?

    public init(originPrincipal: NativeID? = nil, targetPrincipal: NativeID,
                avatar: AgentAvatarImage?) {
        self.originPrincipal = originPrincipal
        self.targetPrincipal = targetPrincipal
        self.avatar = avatar
    }

    private enum CodingKeys: String, CodingKey { case originPrincipal, targetPrincipal, avatar }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let originPrincipal { try c.encode(originPrincipal, forKey: .originPrincipal) }
        else { try c.encodeNil(forKey: .originPrincipal) }
        try c.encode(targetPrincipal, forKey: .targetPrincipal)
        if let avatar { try c.encode(avatar, forKey: .avatar) }
        else { try c.encodeNil(forKey: .avatar) }
    }
}
