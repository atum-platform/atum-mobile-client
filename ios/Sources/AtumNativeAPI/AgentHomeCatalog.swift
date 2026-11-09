import Foundation

public enum AgentHomeConnectionLabel: String, Codable, Sendable {
    case atum = "Atum"
    case chatGPT = "ChatGPT"
    case openAIAPI = "OpenAI API"
    case anthropicAPI = "Anthropic API"
    case googleAPI = "Google API"
    case openRouterAPI = "OpenRouter API"
    case localModel = "Local model"
}
public struct AgentHomeCatalogModel: Decodable, Equatable, Sendable {
    public let model: String
    public let label: String
    public let efforts: [AgentHomeModelEffort]
    public let defaultEffort: AgentHomeModelEffort

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["model", "modelLabel", "efforts", "defaultEffort"])
        model = try c.string("model", minimum: 1, maximum: 200,
                             pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
        label = try c.string("modelLabel", minimum: 1, maximum: 120,
                             pattern: "[A-Za-z0-9][A-Za-z0-9 ._+/-]{0,119}")
        efforts = try c.value("efforts")
        defaultEffort = try c.value("defaultEffort")
        guard (1...4).contains(efforts.count), Set(efforts).count == efforts.count,
              efforts.contains(defaultEffort) else { throw ContractViolation.invariant }
    }
}

public struct AgentHomeConnection: Decodable, Equatable, Identifiable, Sendable {
    public enum State: String, Decodable, Sendable { case available, needsAttention = "needs_attention" }

    public let connectionRef: String
    public let source: AgentHomeModelSource
    public let providerLabel: AgentHomeConnectionLabel
    public let state: State
    public let models: [AgentHomeCatalogModel]
    public var id: String { connectionRef }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["connectionRef", "source", "providerLabel", "state", "models"])
        connectionRef = try checkedString(c.value("connectionRef"), minimum: 21, maximum: 69,
                                          pattern: "conn_[A-Za-z0-9_-]{16,64}")
        source = try c.value("source")
        providerLabel = try c.value("providerLabel")
        state = try c.value("state")
        models = try c.value("models")
        guard (1...256).contains(models.count), Set(models.map(\.model)).count == models.count else {
            throw ContractViolation.invariant
        }
    }
}

public struct AgentHomeMacCatalog: Decodable, Equatable, Sendable {
    public enum Freshness: String, Decodable, Sendable { case fresh, stale, unavailable }
    public enum UnavailableReason: String, Decodable, Sendable {
        case homeOffline = "home_offline", catalogUnreachable = "catalog_unreachable"
        case catalogNotPublished = "catalog_not_published"
    }

    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let deviceServiceID: NativeID
    public let homeID: NativeID
    public let homeEpoch: Int64
    public let catalogRevision: Int64
    public let receivedAtPlatform: Int64
    public let freshUntilPlatform: Int64
    public let freshness: Freshness
    public let connections: [AgentHomeConnection]
    public let unavailableReason: UnavailableReason?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard AgentHomeContract.acceptsBodyProfile(try c.value("profile")) else {
            throw ContractViolation.invalidValue
        }
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        deviceServiceID = try c.value("deviceServiceId")
        homeID = try c.value("homeId")
        homeEpoch = try c.integer("homeEpoch", minimum: 1)
        catalogRevision = try c.integer("catalogRevision", minimum: 1)
        receivedAtPlatform = try c.integer("receivedAtPlatform")
        freshUntilPlatform = try c.integer("freshUntilPlatform")
        freshness = try c.value("freshness")
        connections = try c.value("connections")
        let common: Set<String> = ["profile", "ownerUserId", "agentPrincipal", "deviceServiceId",
                                   "homeId", "homeEpoch", "catalogRevision", "receivedAtPlatform",
                                   "freshUntilPlatform", "freshness", "connections"]
        switch freshness {
        case .fresh:
            try c.closed(common)
            unavailableReason = nil
            guard !connections.isEmpty, freshUntilPlatform > receivedAtPlatform else {
                throw ContractViolation.invariant
            }
        case .stale:
            try c.closed(common)
            unavailableReason = nil
        case .unavailable:
            try c.closed(common.union(["reason"]))
            unavailableReason = try c.value("reason")
            guard connections.isEmpty else { throw ContractViolation.invariant }
        }
        guard connections.count <= 64,
              Set(connections.map(\.connectionRef)).count == connections.count else {
            throw ContractViolation.invariant
        }
    }

    public func choice(connectionRef: String, model: String,
                       effort: AgentHomeModelEffort? = nil) throws -> AgentHomeModelChoice {
        guard freshness == .fresh,
              let connection = connections.first(where: { $0.connectionRef == connectionRef }),
              connection.state == .available,
              let offer = connection.models.first(where: { $0.model == model }) else {
            throw ContractViolation.invalidValue
        }
        let selectedEffort = effort ?? offer.defaultEffort
        guard offer.efforts.contains(selectedEffort) else { throw ContractViolation.invalidValue }
        return try AgentHomeModelChoice(home: .mac(deviceServiceID), source: connection.source,
                                        connectionRef: connection.connectionRef,
                                        model: offer.model, effort: selectedEffort)
    }
}

public struct AgentHomeModelApplication: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case pending, applied, unavailable }
    public enum Reason: String, Decodable, Sendable {
        case waitingForHome = "waiting_for_home", turnInProgress = "turn_in_progress"
        case catalogRefreshRequired = "catalog_refresh_required", signInExpired = "sign_in_expired"
        case connectionUnavailable = "connection_unavailable"
        case connectionNeedsAttention = "connection_needs_attention"
        case modelUnavailable = "model_unavailable", effortUnavailable = "effort_unavailable"
        case catalogStale = "catalog_stale"
    }

    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let deviceServiceID: NativeID
    public let homeID: NativeID
    public let homeEpoch: Int64
    public let activeMoveID: NativeID?
    public let placementRevision: Int64
    public let choiceRevision: Int64
    public let catalogRevision: Int64
    public let choice: AgentHomeModelChoice
    public let status: Status
    public let reason: Reason?
    public let appliedAtPlatform: Int64?
    public let appliedTurnSequence: Int64?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "ownerUserId", "agentPrincipal", "deviceServiceId", "homeId",
                      "homeEpoch", "activeMoveId", "placementRevision", "choiceRevision",
                      "catalogRevision", "choice", "applicationBoundary", "preferencePersistence",
                      "status", "reason", "turnDisposition", "billingSourceChange",
                      "appliedAtPlatform", "appliedTurnSequence"])
        guard AgentHomeContract.acceptsBodyProfile(try c.value("profile")),
              try c.value("applicationBoundary", as: String.self) == "next_turn_boundary",
              try c.value("preferencePersistence", as: String.self) == "persisted" else {
            throw ContractViolation.invalidValue
        }
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        deviceServiceID = try c.value("deviceServiceId")
        homeID = try c.value("homeId")
        homeEpoch = try c.integer("homeEpoch", minimum: 1)
        activeMoveID = try c.nullable("activeMoveId")
        placementRevision = try c.integer("placementRevision", minimum: 1)
        choiceRevision = try c.integer("choiceRevision")
        catalogRevision = try c.integer("catalogRevision", minimum: 1)
        choice = try c.value("choice")
        status = try c.value("status")
        reason = try c.nullable("reason")
        appliedAtPlatform = try c.nullableInteger("appliedAtPlatform")
        appliedTurnSequence = try c.nullableInteger("appliedTurnSequence", minimum: 1)
        guard choice.destination == AgentHomeLocation.mac(deviceServiceID).destinationID else {
            throw ContractViolation.invariant
        }
        switch status {
        case .pending:
            guard [.waitingForHome, .turnInProgress, .catalogRefreshRequired].contains(reason),
                  try c.value("turnDisposition", as: String.self) == "held",
                  try c.value("billingSourceChange", as: String.self) == "forbidden",
                  appliedAtPlatform == nil, appliedTurnSequence == nil else {
                throw ContractViolation.invariant
            }
        case .applied:
            guard activeMoveID == nil, reason == nil,
                  try c.value("turnDisposition", as: String.self) == "ready",
                  try c.value("billingSourceChange", as: String.self) == "none",
                  appliedAtPlatform != nil, appliedTurnSequence != nil else {
                throw ContractViolation.invariant
            }
        case .unavailable:
            guard let reason,
                  [.signInExpired, .connectionUnavailable, .connectionNeedsAttention,
                   .modelUnavailable, .effortUnavailable, .catalogStale].contains(reason),
                  try c.value("turnDisposition", as: String.self) == "held",
                  try c.value("billingSourceChange", as: String.self) == "forbidden",
                  appliedAtPlatform == nil, appliedTurnSequence == nil else {
                throw ContractViolation.invariant
            }
        }
    }
}

/// Turns sanitized 2.4 catalog rows into the existing picker data. The opaque
/// connection ref is the section/list identity, so two ChatGPT plan
/// connections that offer the same model never collapse into one row.
public enum AgentHomeModelRows {
    public static func mac(_ catalog: AgentHomeMacCatalog,
                           selected: AgentHomeModelChoice?) -> [PhoneModelPickerProjection.Row] {
        catalog.connections.flatMap { connection in
            connection.models.map { model in
                let exact = selected?.connectionRef == connection.connectionRef
                    && selected?.model == model.model
                return PhoneModelPickerProjection.Row(
                    favoriteID: connection.connectionRef + ":" + model.model,
                    source: connection.source.managedDestinationSource,
                    model: model.model,
                    displayName: model.label,
                    selected: exact,
                    selectable: catalog.freshness == .fresh && connection.state == .available,
                    connectionID: connection.connectionRef,
                    connectionLabel: connection.providerLabel.rawValue
                )
            }
        }
    }

    public static func cloud(_ snapshot: ManagedModelSnapshot,
                             selected: AgentHomeModelChoice?) -> [PhoneModelPickerProjection.Row] {
        snapshot.models.compactMap { offer in
            guard ManagedModelLineup.servedAliases.contains(offer.alias) else { return nil }
            let ready = offer.eligibility == .ready
            return PhoneModelPickerProjection.Row(
                favoriteID: offer.alias,
                source: .atum,
                model: offer.alias,
                displayName: offer.displayName,
                selected: selected?.source == .atum && selected?.model == offer.alias,
                selectable: ready,
                badges: ready && offer.alias == ManagedModelLineup.defaultAlias ? [.default] : [],
                connectionID: AgentHomeContract.managedConnectionRef,
                connectionLabel: AgentHomeConnectionLabel.atum.rawValue
            )
        }
    }
}

public enum AgentHomeReadback: Equatable, Sendable {
    case applied
    case pending
    case unavailable(AgentHomeModelApplication.Reason)

    public init(_ application: AgentHomeModelApplication) {
        switch application.status {
        case .applied: self = .applied
        case .pending: self = .pending
        case .unavailable: self = .unavailable(application.reason!)
        }
    }

    /// Pending/unavailable means wait. It never grants a phone-side or paid
    /// Atum fallback for a Mac connection.
    public var mayAnswer: Bool { self == .applied }
}
