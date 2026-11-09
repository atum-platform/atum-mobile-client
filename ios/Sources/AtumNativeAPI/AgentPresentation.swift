import Foundation

public enum AgentMarkShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle
    case roundedSquare = "rounded_square"
    case diamond, spark, clover, heart, flower, drop, pebble, triangle, pentagon, star, hexagon
    public var id: String { rawValue }
}

public enum AgentMarkColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case snow, earth, coral, orange, amber, mint, teal, blue, violet, pink, stone
    public var id: String { rawValue }
}

public struct AgentMark: Codable, Equatable, Sendable {
    public let shape: AgentMarkShape
    public let color: AgentMarkColor

    public init(shape: AgentMarkShape, color: AgentMarkColor) {
        self.shape = shape
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["shape", "color"])
        shape = try c.value("shape")
        color = try c.value("color")
    }
}

public struct AgentPresentationSnapshot: Decodable, Equatable, Sendable {
    public let assistantID, assistantPrincipal: NativeID
    public let title: String?
    public let mark, defaultMark: AgentMark
    public let avatarURL: String?
    public let identityRevision: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "assistant_id", "assistant_principal", "title", "mark",
                      "default_mark", "avatar_url", "identity_revision"])
        guard try c.value("profile", as: String.self) == "atum.agent-presentation/1" else {
            throw ContractViolation.invalidValue
        }
        assistantID = try c.value("assistant_id")
        assistantPrincipal = try c.value("assistant_principal")
        title = try c.nullable("title")
        defaultMark = try c.value("default_mark")
        // A future presentation mark is cosmetic. Keep the card usable with
        // the server's known reset target instead of failing the whole read.
        mark = c.lossyNullable("mark") ?? defaultMark
        avatarURL = try c.nullable("avatar_url")
        identityRevision = try c.integer("identity_revision", minimum: 1)
        if let title {
            let checked = try checkedString(title, minimum: 1, maximum: 80)
            guard checked == title.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw ContractViolation.invalidValue }
        }
        if let avatarURL {
            _ = try checkedString(avatarURL, minimum: 9, maximum: 2_048, pattern: "https://[!-~]+")
        }
    }
}

public struct AgentPresentationWrite: Encodable, Equatable, Sendable {
    public let expectedIdentityRevision: Int64
    public let title: String?
    public let mark: AgentMark

    public init(snapshot: AgentPresentationSnapshot, title: String?, mark: AgentMark) throws {
        let normalized = title?.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            guard normalized.unicodeScalars.count <= 80,
                  !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw ContractViolation.invalidValue }
            self.title = normalized
        } else {
            self.title = nil
        }
        expectedIdentityRevision = snapshot.identityRevision
        self.mark = mark
    }

    private enum CodingKeys: String, CodingKey {
        case expectedIdentityRevision = "expected_identity_revision"
        case title, mark
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedIdentityRevision, forKey: .expectedIdentityRevision)
        if let title { try c.encode(title, forKey: .title) }
        else { try c.encodeNil(forKey: .title) }
        try c.encode(mark, forKey: .mark)
    }
}
