import Foundation

public enum ManagedModelEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high
}

/// The two live Atum aliases and the announced third row are product names,
/// not provider labels. They stay untranslated and match the desktop lineup
/// (`apps/desktop/shared/matrix-models.ts`, release/0.20.21).
public enum ManagedModelLineup {
    public static let defaultAlias = "nguyet-thuc"
    public static let hardAlias = "nhat-thuc"
    public static let announcedAlias = "thai-cuc"
    public static let servedAliases = [defaultAlias, hardAlias]

    /// The one-line line-up row the desktop draws under the model's name. It
    /// says what the model is for; it never names a provider or a price.
    public enum Tagline: String, Equatable, Sendable {
        case everyday, hard, flagship
    }

    public struct Row: Equatable, Sendable {
        /// Nil for the announced row, which has no server alias to write.
        public let alias: String?
        public let name: String
        public let version: String?
        public let tagline: Tagline

        public init(alias: String?, name: String, version: String?, tagline: Tagline) {
            self.alias = alias
            self.name = name
            self.version = version
            self.tagline = tagline
        }

        /// "Nguyệt Thực 1.3": the product's own name, never the provider's.
        public var displayName: String {
            version.map { name + " " + $0 } ?? name
        }
    }

    /// The picker's rows, in the owner's order. The announced row is last and
    /// is never selectable.
    public static let lineup: [Row] = [
        Row(alias: defaultAlias, name: "Nguyệt Thực", version: "1.3", tagline: .everyday),
        Row(alias: hardAlias, name: "Nhật Thực", version: "1.1", tagline: .hard),
        Row(alias: nil, name: "Thái Cực", version: nil, tagline: .flagship),
    ]

    public static func displayName(for alias: String) -> String? {
        lineup.first { $0.alias == alias }?.displayName
            ?? (alias == announcedAlias ? "Thái Cực" : nil)
    }

    /// The compact chip uses the product name without a version. Versioned
    /// names remain available to detailed compatibility surfaces through
    /// `displayName(for:)`.
    public static func productName(for alias: String) -> String? {
        lineup.first { $0.alias == alias }?.name
            ?? (alias == announcedAlias ? "Thái Cực" : nil)
    }

    public static func tagline(for alias: String) -> Tagline? {
        lineup.first { $0.alias == alias }?.tagline
    }
}

public enum ManagedModelEligibilityReason: String, Decodable, Sendable {
    case policyDisabled = "policy_disabled"
    case modelNotAllowed = "model_not_allowed"
    case cloudUnavailable = "cloud_unavailable"
    case entitlementRequired = "entitlement_required"
    case consentRequired = "consent_required"
    case costLimit = "cost_limit"
    case dataRestricted = "data_restricted"
    case providerUnavailable = "provider_unavailable"
}

public enum ManagedModelEligibility: Decodable, Equatable, Sendable {
    case ready
    case unavailable(ManagedModelEligibilityReason)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("state")
        if state == "ready" {
            try c.closed(["state"])
            self = .ready
        } else if state == "unavailable" {
            try c.closed(["state", "reason"])
            self = .unavailable(try c.value("reason"))
        } else { throw ContractViolation.invalidValue }
    }
}

public struct ManagedModelOffer: Decodable, Equatable, Identifiable, Sendable {
    public let alias, displayName: String
    public let efforts: [ManagedModelEffort]
    public let defaultEffort: ManagedModelEffort
    public let eligibility: ManagedModelEligibility
    public var id: String { alias }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["alias", "displayName", "providerModel", "contextBudget", "outputBudget",
                      "efforts", "defaultEffort", "cost", "eligibility", "inputModalities",
                      "supportsTools"])
        alias = try c.string("alias", minimum: 1, maximum: 40, pattern: "[a-z0-9][a-z0-9-]*")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        _ = try c.string("providerModel", minimum: 1, maximum: 200,
                         pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
        _ = try c.integer("contextBudget", minimum: 1)
        _ = try c.integer("outputBudget", minimum: 1)
        efforts = try c.value("efforts")
        guard (1...3).contains(efforts.count), Set(efforts).count == efforts.count else {
            throw ContractViolation.invalidValue
        }
        defaultEffort = try c.value("defaultEffort")
        guard efforts.contains(defaultEffort) else { throw ContractViolation.invariant }
        _ = try c.value("cost", as: ManagedModelCost.self)
        eligibility = try c.value("eligibility")
        let modalities: [String] = try c.value("inputModalities")
        guard (1...5).contains(modalities.count), Set(modalities).count == modalities.count,
              modalities.contains("text"),
              Set(modalities).isSubset(of: ["text", "image", "video", "file", "audio"]),
              try c.value("supportsTools", as: Bool.self) else { throw ContractViolation.invalidValue }
    }
}

private struct ManagedModelCost: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["currency", "inputPerMtok", "outputPerMtok", "maxTurnMicroProtons"])
        guard try c.value("currency", as: String.self) == "USD" else { throw ContractViolation.invalidValue }
        for key in ["inputPerMtok", "outputPerMtok"] {
            _ = try c.string(key, minimum: 1, maximum: 64, pattern: "(?:0|[1-9][0-9]*)(?:[.][0-9]{1,8})?")
        }
        _ = try c.integer("maxTurnMicroProtons", minimum: 1)
    }
}

public struct ManagedModelChoice: Codable, Equatable, Sendable {
    public let model: String
    public let effort: ManagedModelEffort?

    public init(model: String, effort: ManagedModelEffort?) throws {
        self.model = try checkedString(model, minimum: 1, maximum: 40,
                                       pattern: "[a-z0-9][a-z0-9-]*")
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["v", "source", "model", "effort"])
        guard try c.value("v", as: Int.self) == 2,
              try c.value("source", as: String.self) == "atum" else { throw ContractViolation.invalidValue }
        try self.init(model: c.value("model"), effort: c.optional("effort"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(2, forKey: Field("v"))
        try c.encode("atum", forKey: Field("source"))
        try c.encode(model, forKey: Field("model"))
        if let effort { try c.encode(effort, forKey: Field("effort")) }
    }
}

public struct ManagedModelSnapshot: Decodable, Equatable, Sendable {
    public enum Source: String, Decodable, Sendable { case `default`, saved }
    public let agentPrincipal: NativeID
    public let revision: Int64
    public let source: Source
    public let policyVersion, policyDigest: String
    public let choice: ManagedModelChoice
    public let models: [ManagedModelOffer]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "agentPrincipal", "revision", "source", "policyVersion",
                      "policyDigest", "choice", "models", "runtimes", "grant"])
        guard try c.value("profile", as: String.self) == "atum.model-choice/1.1" else {
            throw ContractViolation.invalidValue
        }
        agentPrincipal = try c.value("agentPrincipal")
        revision = try c.integer("revision")
        source = try c.value("source")
        guard (revision == 0) == (source == .default) else { throw ContractViolation.invariant }
        policyVersion = try c.string("policyVersion", minimum: 12, maximum: 64,
                                     pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}[.][1-9][0-9]*")
        policyDigest = try c.string("policyDigest", minimum: 64, maximum: 64, pattern: "[a-f0-9]{64}")
        choice = try c.value("choice")
        models = try c.value("models")
        guard (1...16).contains(models.count), Set(models.map(\.alias)).count == models.count,
              let selected = models.first(where: { $0.alias == choice.model }) else {
            throw ContractViolation.invariant
        }
        let effectiveEffort = choice.effort ?? selected.defaultEffort
        guard selected.efforts.contains(effectiveEffort) else { throw ContractViolation.invariant }
        let runtimes: [ManagedCloudRuntime] = try c.value("runtimes")
        guard runtimes.count == 1 else { throw ContractViolation.invalidValue }
        let grant: ManagedModelGrant = try c.value("grant")
        guard grant.policyDigest == policyDigest else { throw ContractViolation.invariant }
        switch (grant, selected.eligibility) {
        case let (.active(alias, model, effort, _, context, output, maxTurn), .ready):
            let expectedAlias = source == .default ? "default" : selected.alias
            guard alias == expectedAlias, model == selected.alias, effort == effectiveEffort,
                  context > 0, output > 0, maxTurn > 0 else { throw ContractViolation.invariant }
        case let (.unavailable(reason, _), .unavailable(expected)):
            guard reason == expected else { throw ContractViolation.invariant }
        default: throw ContractViolation.invariant
        }
    }
}

private struct ManagedCloudRuntime: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["runtime"])
        guard try c.value("runtime", as: String.self) == "cloud" else { throw ContractViolation.invalidValue }
    }
}

private enum ManagedModelGrant: Decodable {
    case active(alias: String, model: String, effort: ManagedModelEffort,
                digest: String, context: Int64, output: Int64, maxTurn: Int64)
    case unavailable(ManagedModelEligibilityReason, digest: String)

    var policyDigest: String {
        switch self { case let .active(_, _, _, digest, _, _, _), let .unavailable(_, digest): digest }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("profile", as: String.self) == "atum.model-grant/1" else {
            throw ContractViolation.invalidValue
        }
        let state: String = try c.value("state")
        if state == "active" {
            try c.closed(["profile", "state", "alias", "model", "effort", "policyDigest",
                          "contextBudget", "outputBudget", "maxTurnMicroProtons"])
            self = .active(
                alias: try c.string("alias", minimum: 1, maximum: 40),
                model: try c.string("model", minimum: 1, maximum: 40),
                effort: try c.value("effort"),
                digest: try c.string("policyDigest", minimum: 64, maximum: 64, pattern: "[a-f0-9]{64}"),
                context: try c.integer("contextBudget", minimum: 1),
                output: try c.integer("outputBudget", minimum: 1),
                maxTurn: try c.integer("maxTurnMicroProtons", minimum: 1)
            )
        } else if state == "unavailable" {
            try c.closed(["profile", "state", "reason", "policyDigest"])
            self = .unavailable(
                try c.value("reason"),
                digest: try c.string("policyDigest", minimum: 64, maximum: 64, pattern: "[a-f0-9]{64}")
            )
        } else { throw ContractViolation.invalidValue }
    }
}

public struct ManagedModelWrite: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let expectedRevision: Int64
    public let policyDigest: String
    public let choice: ManagedModelChoice

    public init(requestId: NativeID, snapshot: ManagedModelSnapshot,
                model: String, effort: ManagedModelEffort) throws {
        guard let offer = snapshot.models.first(where: { $0.alias == model }),
              offer.eligibility == .ready, offer.efforts.contains(effort) else {
            throw ContractViolation.invalidValue
        }
        self.requestId = requestId
        expectedRevision = snapshot.revision
        policyDigest = snapshot.policyDigest
        choice = try ManagedModelChoice(model: model, effort: effort)
    }

    private enum CodingKeys: String, CodingKey {
        case profile, requestId, expectedRevision, policyDigest, choice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("atum.model-choice/1.1", forKey: .profile)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(policyDigest, forKey: .policyDigest)
        try c.encode(choice, forKey: .choice)
    }
}

// MARK: - Per-destination defaults (`atum.model-choice/1.3`)

public enum ManagedProductEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, max
}

public struct ManagedModelDestinationID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(_ value: String) throws {
        if value == "cloud" {
            rawValue = value
            return
        }
        rawValue = try checkedString(value, minimum: 5, maximum: 132,
                                     pattern: "mac:[A-Za-z0-9_-]+")
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var isCloud: Bool { rawValue == "cloud" }
    public var macIdentifier: String? {
        guard rawValue.hasPrefix("mac:") else { return nil }
        return String(rawValue.dropFirst(4))
    }
}

public enum ManagedModelDestinationSource: Equatable, Sendable {
    case atum
    case chatGPTPlan
    /// The account-wide OpenCode Go subscription (model-choice/1.4). Only a
    /// cloud destination may name it; a Mac keeps its own choice.
    case opencodeGo
    case ownKey(String)

    fileprivate init(_ value: String) throws {
        switch value {
        case "atum": self = .atum
        case "chatgpt_plan": self = .chatGPTPlan
        case "opencode_go": self = .opencodeGo
        default:
            guard value.range(of: #"\Aown_key:[a-z0-9][a-z0-9_-]*\z"#,
                              options: .regularExpression) != nil else {
                throw ContractViolation.invalidValue
            }
            self = .ownKey(String(value.dropFirst("own_key:".count)))
        }
    }

    fileprivate var rawValue: String {
        switch self {
        case .atum: "atum"
        case .chatGPTPlan: "chatgpt_plan"
        case .opencodeGo: "opencode_go"
        case let .ownKey(provider): "own_key:" + provider
        }
    }

    /// A subscription the person connected to their account, rather than
    /// Atum's own model or a key on one Mac.
    public var isSubscription: Bool {
        switch self {
        case .chatGPTPlan, .opencodeGo: true
        case .atum, .ownKey: false
        }
    }
}

public struct ManagedModelDestinationChoice: Codable, Equatable, Sendable {
    public let destination: ManagedModelDestinationID
    public let source: ManagedModelDestinationSource
    public let model: String
    public let effort: String

    fileprivate init(destination: ManagedModelDestinationID,
                     source: ManagedModelDestinationSource,
                     model: String,
                     effort: String) throws {
        self.destination = destination
        self.source = source
        switch source {
        case .atum:
            self.model = try checkedString(model, minimum: 1, maximum: 40,
                                           pattern: "[a-z0-9][a-z0-9-]*")
            guard ManagedModelEffort(rawValue: effort) != nil else {
                throw ContractViolation.invalidValue
            }
        case .opencodeGo:
            // 1.4 widens only the cloud destination to the account-wide
            // subscription; a Mac may not name it.
            guard destination.isCloud else { throw ContractViolation.invariant }
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
            guard ManagedProductEffort(rawValue: effort) != nil else {
                throw ContractViolation.invalidValue
            }
        case .chatGPTPlan:
            // model-choice/1.5 adds the account's ChatGPT relay to the cloud.
            // The same source remains valid for a Mac's local subscription.
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
            guard ManagedProductEffort(rawValue: effort) != nil else {
                throw ContractViolation.invalidValue
            }
        case .ownKey:
            guard !destination.isCloud else { throw ContractViolation.invariant }
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
            guard ManagedProductEffort(rawValue: effort) != nil else {
                throw ContractViolation.invalidValue
            }
        }
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["destination", "source", "model", "effort"])
        let destination: ManagedModelDestinationID = try c.value("destination")
        let source = try ManagedModelDestinationSource(c.value("source"))
        try self.init(destination: destination, source: source,
                      model: c.value("model"), effort: c.value("effort"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(destination, forKey: Field("destination"))
        try c.encode(source.rawValue, forKey: Field("source"))
        try c.encode(model, forKey: Field("model"))
        try c.encode(effort, forKey: Field("effort"))
    }

    public var managedEffort: ManagedModelEffort? {
        guard source == .atum else { return nil }
        return ManagedModelEffort(rawValue: effort)
    }
}

/// A destination list is open to new provider sources, but known sources keep
/// their full invariants. An unknown source contributes no phone row; a known
/// source on an impossible destination still rejects the authoritative
/// snapshot instead of being mistaken for an optional future provider.
private struct CompatibleManagedModelDestinationChoice: Decodable {
    let choice: ManagedModelDestinationChoice?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["destination", "source", "model", "effort"])
        let destination: ManagedModelDestinationID = try c.value("destination")
        let rawSource: String = try c.value("source")
        guard let source = try? ManagedModelDestinationSource(rawSource) else {
            choice = nil
            return
        }
        choice = try ManagedModelDestinationChoice(
            destination: destination,
            source: source,
            model: c.value("model"),
            effort: c.value("effort")
        )
    }
}

public struct ManagedModelDestinationSnapshot: Decodable, Equatable, Sendable {
    public struct Recommendation: Decodable, Equatable, Sendable {
        public let model: String
        public let effort: ManagedModelEffort

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["source", "model", "effort"])
            guard try c.value("source", as: String.self) == "atum" else {
                throw ContractViolation.invalidValue
            }
            model = try c.string("model", minimum: 1, maximum: 40,
                                 pattern: "[a-z0-9][a-z0-9-]*")
            effort = try c.value("effort")
        }
    }

    public struct DailyCap: Decodable, Equatable, Sendable {
        public let dailyProtons: Int64
        public let timeZone: String
        public let warningPercent: Int64
        public let counts: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["dailyProtons", "timeZone", "warningPercent", "counts"])
            dailyProtons = try c.integer("dailyProtons")
            timeZone = try c.value("timeZone")
            warningPercent = try c.integer("warningPercent")
            counts = try c.value("counts")
            guard timeZone == "Asia/Ho_Chi_Minh", warningPercent == 80,
                  counts == "atum_billed_only" else { throw ContractViolation.invariant }
        }
    }

    public struct Spend: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case normal, warning, exhausted }
        public enum Notice: String, Decodable, Sendable {
            case none
            case eightyPercent = "eighty_percent"
            case exhausted
        }

        public let day: String
        public let usedProtons: Int64
        public let state: State
        public let notice: Notice

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["day", "usedProtons", "state", "notice"])
            day = try c.string("day", minimum: 10, maximum: 10,
                               pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}")
            usedProtons = try c.integer("usedProtons")
            state = try c.value("state")
            notice = try c.value("notice")
            guard (state == .normal && notice == .none)
                    || (state == .warning && notice == .eightyPercent)
                    || (state == .exhausted && notice == .exhausted) else {
                throw ContractViolation.invariant
            }
        }
    }

    public let agentPrincipal: NativeID
    public let revision: Int64
    public let policyDigest: String
    public let recommended: Recommendation
    public let choices: [ManagedModelDestinationChoice]
    public let dailyCap: DailyCap
    public let spend: Spend

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "agentPrincipal", "revision", "policyDigest",
                      "recommended", "choices", "dailyCap", "spend"])
        // 1.4 adds OpenCode Go and 1.5 adds the cloud ChatGPT relay without
        // changing the snapshot's fields. The phone reads all three shapes.
        let profile: String = try c.value("profile")
        guard ["atum.model-choice/1.3", "atum.model-choice/1.4", "atum.model-choice/1.5"]
            .contains(profile) else {
            throw ContractViolation.invalidValue
        }
        agentPrincipal = try c.value("agentPrincipal")
        revision = try c.integer("revision")
        policyDigest = try c.string("policyDigest", minimum: 64, maximum: 64,
                                    pattern: "[a-f0-9]{64}")
        recommended = try c.value("recommended")
        let decodedChoices: [CompatibleManagedModelDestinationChoice] = try c.value("choices")
        choices = decodedChoices.compactMap(\.choice)
        guard decodedChoices.count <= 65,
              Set(choices.map(\.destination)).count == choices.count,
              profile == "atum.model-choice/1.5"
                || !choices.contains(where: { $0.destination.isCloud && $0.source == .chatGPTPlan }) else {
            throw ContractViolation.invariant
        }
        dailyCap = try c.value("dailyCap")
        spend = try c.value("spend")

        let expectedState: Spend.State
        if dailyCap.dailyProtons == 0 {
            expectedState = .normal
        } else {
            let warningAt = (dailyCap.dailyProtons * 80 + 99) / 100
            expectedState = spend.usedProtons >= dailyCap.dailyProtons
                ? .exhausted : spend.usedProtons >= warningAt ? .warning : .normal
        }
        guard spend.state == expectedState else { throw ContractViolation.invariant }
    }

    public func choice(for destination: ManagedModelDestinationID) -> ManagedModelDestinationChoice? {
        choices.first(where: { $0.destination == destination })
    }

    public func effectiveModel(for destination: ManagedModelDestinationID) -> String {
        guard let choice = choice(for: destination), choice.source == .atum,
              ManagedModelLineup.displayName(for: choice.model) != nil else {
            return recommended.model
        }
        return choice.model
    }
}

public struct ManagedModelDestinationWrite: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let expectedRevision: Int64
    public let policyDigest: String
    public let choice: ManagedModelDestinationChoice

    public init(requestId: NativeID,
                snapshot: ManagedModelDestinationSnapshot,
                destination: ManagedModelDestinationID,
                model: String) throws {
        let current = snapshot.choice(for: destination)
        let effort = current?.source == .atum && current?.model == model
            ? current?.managedEffort ?? snapshot.recommended.effort
            : snapshot.recommended.effort
        self.requestId = requestId
        expectedRevision = snapshot.revision
        policyDigest = snapshot.policyDigest
        choice = try ManagedModelDestinationChoice(
            destination: destination, source: .atum, model: model, effort: effort.rawValue
        )
    }

    private enum CodingKeys: String, CodingKey {
        case profile, requestId, expectedRevision, policyDigest, choice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("atum.model-choice/1.3", forKey: .profile)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(policyDigest, forKey: .policyDigest)
        try c.encode(choice, forKey: .choice)
    }
}

/// The cloud destination switched to one model of an account subscription:
/// the same `PUT agents/{principal}/model-destinations` the desktop sends
/// (`matrixSubscriptionDestinationWrite`, `model-destinations.ts`). OpenCode Go
/// is written as `atum.model-choice/1.4`; a ChatGPT plan, which the cloud
/// reaches through an owner Mac's relay, as `atum.model-choice/1.5` (the
/// platform refuses it under any other profile: `relay_profile_required`).
/// The level is Atum's three-level vocabulary, as the cloud row requires.
public struct ManagedModelSubscriptionWrite: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let expectedRevision: Int64
    public let policyDigest: String
    public let choice: ManagedModelDestinationChoice

    public init(requestId: NativeID,
                snapshot: ManagedModelDestinationSnapshot,
                source: ManagedModelDestinationSource,
                model: String,
                effort: ManagedModelEffort) throws {
        guard source == .chatGPTPlan || source == .opencodeGo else { throw ContractViolation.invariant }
        self.requestId = requestId
        expectedRevision = snapshot.revision
        policyDigest = snapshot.policyDigest
        choice = try ManagedModelDestinationChoice(
            destination: ManagedModelDestinationID("cloud"), source: source,
            model: model, effort: effort.rawValue
        )
    }

    public var profile: String {
        choice.source == .chatGPTPlan ? "atum.model-choice/1.5" : "atum.model-choice/1.4"
    }

    private enum CodingKeys: String, CodingKey {
        case profile, requestId, expectedRevision, policyDigest, choice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .profile)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(policyDigest, forKey: .policyDigest)
        try c.encode(choice, forKey: .choice)
    }
}
