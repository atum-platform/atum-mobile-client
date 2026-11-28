import Foundation
import Observation

/// A model write rejected before applying the choice because its fence moved.
enum ManagedModelFenceConflict: String, Decodable, Error {
    case revision = "revision_conflict"
    case policy = "policy_changed"
}

struct ManagedModelFenceConflictResponse: Decodable {
    let reason: ManagedModelFenceConflict

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["error", "details", "revision", "policyDigest"])
        guard try c.value("error", as: NativeErrorResponse.Code.self) == .conflict,
              let details = try c.value("details", as: NativeErrorResponse.Details.self).reason,
              let reason = ManagedModelFenceConflict(rawValue: details) else {
            throw ContractViolation.invalidValue
        }
        if c.contains(Field("revision")) { _ = try c.integer("revision") }
        if c.contains(Field("policyDigest")) {
            _ = try c.string("policyDigest", minimum: 64, maximum: 64, pattern: "[a-f0-9]{64}")
        }
        self.reason = reason
    }
}

/// The selection sent by a picker, independent of its current revision and policy fence.
public enum ManagedModelPickerChoice: Equatable, Sendable {
    case offer(model: String, effort: ManagedModelEffort)
    case destination(ManagedModelDestinationID, model: String)
    case subscription(ManagedModelDestinationSource, model: String, effort: ManagedModelEffort)
}

/// One agent's offer or destination snapshot in the current account session.
/// The write generation fences reads even when the revision alone cannot tell
/// which response observed the current policy.
@MainActor @Observable public final class ManagedModelPickerState<Snapshot: Equatable & Sendable> {
    public enum SaveResult {
        case saved(Snapshot)
        case refused(Snapshot?)
        case failed
        /// The picker retired this selection. No further write is sent.
        case cancelled
        /// The write's precondition (a ChatGPT write's consent) no longer
        /// held when re-checked; nothing was retried. Carries a refreshed
        /// snapshot when one was read.
        case preconditionChanged(Snapshot?)
    }

    private let revision: KeyPath<Snapshot, Int64>
    public private(set) var snapshot: Snapshot?
    /// A submitted choice is shared by the pickers for this agent until it settles.
    public private(set) var submittedChoice: ManagedModelPickerChoice?
    @ObservationIgnored private var adoptedWrites = 0
    @ObservationIgnored private var latestIntent = 0
    @ObservationIgnored private var pending: (choice: ManagedModelPickerChoice, fence: Snapshot, id: NativeID)?

    public init(revision: KeyPath<Snapshot, Int64>) {
        self.revision = revision
    }

    public func read(isCurrent: () -> Bool, fetch: () async throws -> Snapshot) async throws -> Snapshot {
        guard isCurrent(), !Task.isCancelled else { throw NativeDomainClientFailure.cancelled }
        let writesAtStart = adoptedWrites
        let result: Result<Snapshot, Error>
        do { result = .success(try await fetch()) }
        catch { result = .failure(error) }
        guard isCurrent(), !Task.isCancelled else { throw NativeDomainClientFailure.cancelled }
        if adoptedWrites != writesAtStart, let snapshot { return snapshot }
        let snapshot = try result.get()
        if let held = self.snapshot, snapshot[keyPath: revision] < held[keyPath: revision] { return held }
        self.snapshot = snapshot
        return snapshot
    }

    /// `revalidate`, when given, is the write's precondition: it is checked
    /// again before the automatic retry after a fence conflict and after a
    /// refusal, so a retry never reuses a decision that no longer holds.
    public func save(from snapshot: Snapshot, choice: ManagedModelPickerChoice, requestID: NativeID,
                     refreshAfterSecondConflict: Bool, isCurrent: () -> Bool, fetch: () async throws -> Snapshot,
                     isSelectionCurrent: () -> Bool = { true }, revalidate: (() async -> Bool)? = nil,
                     refreshAfterTransportFailure: Bool = false,
                     write: @MainActor (Snapshot, NativeID) async throws -> Snapshot) async -> SaveResult {
        guard isSelectionCurrent() else { return .cancelled }
        guard isCurrent(), !Task.isCancelled else { return .failed }
        latestIntent += 1
        let intent = latestIntent
        submittedChoice = choice
        defer { if latestIntent == intent { submittedChoice = nil } }
        func current() -> Bool {
            isSelectionCurrent() && isCurrent() && !Task.isCancelled && latestIntent == intent
        }
        func inactiveResult() -> SaveResult { isSelectionCurrent() ? .failed : .cancelled }

        let retry = pending.flatMap { $0.choice == choice ? $0 : nil }
        var fence = retry?.fence ?? self.snapshot ?? snapshot
        var id = retry?.id ?? (fence == snapshot && pending == nil
            ? requestID : ModelWriteRequests<NativeID>.freshID())
        pending = nil
        var refreshed: Snapshot?

        func refuse() async -> SaveResult {
            guard current() else { return inactiveResult() }
            if let revalidate {
                let holds = await revalidate()
                guard current() else { return inactiveResult() }
                if !holds { return .preconditionChanged(refreshed) }
            }
            return .refused(refreshed)
        }

        for attempt in 0..<2 {
            guard current() else { return inactiveResult() }
            // Keep the actual in-flight write available for an identical
            // retry even if it loses its response or its view goes away.
            pending = (choice, fence, id)
            do {
                let saved = try await write(fence, id)
                guard current() else { return inactiveResult() }
                pending = nil
                if let held = self.snapshot, saved[keyPath: revision] < held[keyPath: revision] { return .saved(held) }
                adoptedWrites += 1
                self.snapshot = saved
                return .saved(saved)
            } catch is ManagedModelFenceConflict {
                guard current() else { return inactiveResult() }
                pending = nil
                if attempt == 1 && !refreshAfterSecondConflict { return await refuse() }
                guard let latest = try? await read(isCurrent: current, fetch: fetch), current() else {
                    return await refuse()
                }
                refreshed = latest
                if attempt == 1 { return await refuse() }
                if let revalidate {
                    let holds = await revalidate()
                    guard current() else { return inactiveResult() }
                    if !holds { return .preconditionChanged(latest) }
                }
                fence = latest
                // A changed fence makes this a new request under the platform's idempotency contract.
                id = ModelWriteRequests<NativeID>.freshID()
            } catch {
                guard current() else { return inactiveResult() }
                let refusal: Bool
                if case NativeDomainClientFailure.http = error { refusal = true } else { refusal = error is ContractViolation }
                guard refusal else {
                    if refreshAfterTransportFailure {
                        // The provider may have applied the write. Keep the replay key and adopt only its readback.
                        _ = try? await read(isCurrent: current, fetch: fetch)
                    }
                    return .failed
                }
                pending = nil
                return await refuse()
            }
        }
        return .refused(refreshed)
    }
}

public enum ManagedModelEffort: String, Codable, CaseIterable, Sendable {
    case none, minimal, low, medium, high, xhigh, max

    init?(wireID: String) {
        switch wireID {
        case "off": self = .none
        case "extra-high", "extra_high": self = .xhigh
        case "maximum": self = .max
        default: self.init(rawValue: wireID)
        }
    }

    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let effort = Self(wireID: id) else { throw ContractViolation.invalidValue }
        self = effort
    }

    /// The destination write contracts for Atum and cloud subscriptions accept these levels.
    var isDestinationWriteEffort: Bool {
        switch self {
        case .low, .medium, .high: true
        default: false
        }
    }
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
    private let effortIDs: [ManagedModelEffort: String]
    fileprivate let defaultEffortID: String
    public let efforts: [ManagedModelEffort]
    public var defaultEffort: ManagedModelEffort? { ManagedModelEffort(wireID: defaultEffortID) }
    public var selectionEffort: ManagedModelEffort? { defaultEffort ?? efforts.first }
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
        let ids: LossyDecodableArray<String> = try c.value("efforts")
        guard ids.sourceCount > 0 else { throw ContractViolation.invalidValue }
        var knownIDs: [ManagedModelEffort: String] = [:]
        for id in ids.elements {
            guard let effort = ManagedModelEffort(wireID: id) else { continue }
            // Use the canonical spelling when advertised alongside an alias.
            if knownIDs[effort] == nil || id == effort.rawValue { knownIDs[effort] = id }
        }
        effortIDs = knownIDs
        efforts = ManagedModelEffort.allCases.filter { knownIDs[$0] != nil }
        defaultEffortID = try c.value("defaultEffort")
        if let level = ManagedModelEffort(wireID: defaultEffortID), knownIDs[level] == nil {
            throw ContractViolation.invariant
        }
        _ = try c.value("cost", as: ManagedModelCost.self)
        eligibility = try c.value("eligibility")
        let modalities: [String] = try c.value("inputModalities")
        guard (1...5).contains(modalities.count), Set(modalities).count == modalities.count,
              modalities.contains("text"),
              Set(modalities).isSubset(of: ["text", "image", "video", "file", "audio"]),
              try c.value("supportsTools", as: Bool.self) else { throw ContractViolation.invalidValue }
    }

    /// Labels group aliases, while a write uses the token the model advertised.
    fileprivate func effortID(for effort: ManagedModelEffort) -> String? {
        effortIDs[effort]
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
    fileprivate let effortID: String?
    public var effort: ManagedModelEffort? { effortID.flatMap(ManagedModelEffort.init(wireID:)) }

    public init(model: String, effort: ManagedModelEffort?) throws {
        try self.init(model: model, effortID: effort?.rawValue)
    }

    fileprivate init(model: String, effortID: String?) throws {
        self.model = try checkedString(model, minimum: 1, maximum: 40,
                                       pattern: "[a-z0-9][a-z0-9-]*")
        self.effortID = effortID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["v", "source", "model", "effort"])
        guard try c.value("v", as: Int.self) == 2,
              try c.value("source", as: String.self) == "atum" else { throw ContractViolation.invalidValue }
        try self.init(model: c.value("model"), effortID: c.optional("effort"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(2, forKey: Field("v"))
        try c.encode("atum", forKey: Field("source"))
        try c.encode(model, forKey: Field("model"))
        try c.encodeIfPresent(effortID, forKey: Field("effort"))
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
    public let currentEffort: ManagedModelEffort?

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
        let selectedModel = choice.model
        guard (1...16).contains(models.count), Set(models.map(\.alias)).count == models.count,
              let selected = models.first(where: { $0.alias == selectedModel }) else {
            throw ContractViolation.invariant
        }
        let effectiveEffort = ManagedModelEffort(wireID: choice.effortID ?? selected.defaultEffortID)
        if let effectiveEffort, !selected.efforts.contains(effectiveEffort) {
            throw ContractViolation.invariant
        }
        currentEffort = effectiveEffort
        let runtimes: [ManagedCloudRuntime] = try c.value("runtimes")
        guard runtimes.count == 1 else { throw ContractViolation.invalidValue }
        let grant: ManagedModelGrant = try c.value("grant")
        guard grant.policyDigest == policyDigest else { throw ContractViolation.invariant }
        switch (grant, selected.eligibility) {
        case let (.active(alias, model, effort, _, context, output, maxTurn), .ready):
            let expectedAlias = source == .default ? "default" : selected.alias
            guard alias == expectedAlias, model == selected.alias,
                  effort == nil || effectiveEffort == nil || effort == effectiveEffort,
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
    case active(alias: String, model: String, effort: ManagedModelEffort?,
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
                effort: try ManagedModelEffort(wireID: c.value("effort")),
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
              offer.eligibility == .ready, let effortID = offer.effortID(for: effort) else {
            throw ContractViolation.invalidValue
        }
        self.requestId = requestId
        expectedRevision = snapshot.revision
        policyDigest = snapshot.policyDigest
        choice = try ManagedModelChoice(model: model, effortID: effortID)
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
        case .opencodeGo:
            // 1.4 widens only the cloud destination to the account-wide
            // subscription; a Mac may not name it.
            guard destination.isCloud else { throw ContractViolation.invariant }
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
        case .chatGPTPlan:
            // model-choice/1.5 adds the account's ChatGPT relay to the cloud.
            // The same source remains valid for a Mac's local subscription.
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
        case .ownKey:
            guard !destination.isCloud else { throw ContractViolation.invariant }
            self.model = try checkedString(model, minimum: 1, maximum: 200,
                                           pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
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
        return ManagedModelEffort(wireID: effort)
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
        private let effortID: String
        public var effort: ManagedModelEffort? { ManagedModelEffort(wireID: effortID) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["source", "model", "effort"])
            guard try c.value("source", as: String.self) == "atum" else {
                throw ContractViolation.invalidValue
            }
            model = try c.string("model", minimum: 1, maximum: 40,
                                 pattern: "[a-z0-9][a-z0-9-]*")
            effortID = try c.value("effort")
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

    /// Prefer the saved effort for the same Atum model, then the recommendation.
    /// A newer read vocabulary cannot supply an effort to an older writer.
    func atumWriteEffort(for destination: ManagedModelDestinationID, model: String) -> ManagedModelEffort? {
        if let saved = choice(for: destination), saved.model == model,
           let effort = saved.managedEffort, effort.isDestinationWriteEffort {
            return effort
        }
        guard let effort = recommended.effort, effort.isDestinationWriteEffort else { return nil }
        return effort
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
        guard let effort = snapshot.atumWriteEffort(for: destination, model: model) else {
            throw ContractViolation.invalidValue
        }
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
/// Destination writes use the product effort vocabulary accepted by these profiles.
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
        guard effort.isDestinationWriteEffort else { throw ContractViolation.invalidValue }
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
