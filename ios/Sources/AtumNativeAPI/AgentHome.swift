import Foundation

public enum AgentHomeContract {
    public static let profile = "atum.agent-home/2.5"
    public static let wireHeader = "Atum-Agent-Home-Wire"
    public static let wireVersion = "2.5"
    public static let managedConnectionRef = "conn_atummanaged000001"
    /// Reuse the native transport's established hard ceiling. A larger answer
    /// is refused instead of weakening the shared response bound.
    public static let maximumCatalogResponseBytes = 4_500_000

    /// The 2.5 pack deliberately retains every accepted 2.4 response fixture
    /// byte-for-byte. Transport negotiation is still strictly 2.5; this
    /// compatibility applies only to frozen body profiles inside that pack.
    static func acceptsBodyProfile(_ value: String) -> Bool {
        value == profile || value == "atum.agent-home/2.4"
    }
}
// MARK: - Signed metadata

public struct AgentHomePlatformMeta: Decodable, Equatable, Sendable {
    public let requestID: NativeID
    public let commandID: NativeID
    public let signerKeyID: String
    public let sequence: Int64
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let nonce: String
    public let signature: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["requestId", "commandId", "signer", "signerKeyId", "sequence",
                      "issuedAt", "expiresAt", "nonce", "signature"])
        requestID = try c.value("requestId")
        commandID = try c.value("commandId")
        guard try c.value("signer", as: String.self) == "platform_controller" else {
            throw ContractViolation.invalidValue
        }
        signerKeyID = try agentHomeB64(c.value("signerKeyId"), count: 43)
        sequence = try c.integer("sequence", minimum: 1)
        issuedAt = try c.integer("issuedAt")
        expiresAt = try c.integer("expiresAt")
        nonce = try agentHomeB64(c.value("nonce"), count: 43)
        signature = try agentHomeB64(c.value("signature"), count: 86)
        try agentHomeSignedLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
    }
}

public struct AgentHomeOwnerMeta: Codable, Equatable, Sendable {
    public enum Surface: String, Codable, Sendable { case phone, desktop }

    public let requestID: NativeID
    public let surface: Surface
    public let authenticatedChannel: Surface

    private struct Signed: Equatable, Sendable {
        let commandID: NativeID
        let signerKeyID: String
        let sequence: Int64
        let issuedAt: Int64
        let expiresAt: Int64
        let nonce: String
        let signature: String
    }
    private let signed: Signed?

    /// Phone owner writes are authorized by the MAS bearer. They intentionally
    /// carry no device key, signing window, sequence or signature fields.
    public init(requestID: NativeID) {
        self.requestID = requestID
        surface = .phone
        authenticatedChannel = .phone
        signed = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["requestId", "commandId", "signer", "signerKeyId", "sequence",
                      "issuedAt", "expiresAt", "nonce", "signature", "surface",
                      "authenticatedChannel"])
        requestID = try c.value("requestId")
        surface = try c.value("surface")
        authenticatedChannel = try c.value("authenticatedChannel")
        guard surface == authenticatedChannel else { throw ContractViolation.invalidValue }

        let signingKeys: Set<String> = ["commandId", "signer", "signerKeyId", "sequence",
                                        "issuedAt", "expiresAt", "nonce", "signature"]
        let present = Set(c.allKeys.map(\.stringValue))
        if signingKeys.isDisjoint(with: present) {
            signed = nil
        } else {
            guard signingKeys.isSubset(of: present),
                  try c.value("signer", as: String.self) == "owner_client" else {
                throw ContractViolation.invalidValue
            }
            let issuedAt = try c.integer("issuedAt")
            let expiresAt = try c.integer("expiresAt")
            try agentHomeSignedLifetime(issuedAt: issuedAt, expiresAt: expiresAt)
            signed = try Signed(
                commandID: c.value("commandId"),
                signerKeyID: agentHomeB64(c.value("signerKeyId"), count: 43),
                sequence: c.integer("sequence", minimum: 1),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                nonce: agentHomeB64(c.value("nonce"), count: 43),
                signature: agentHomeB64(c.value("signature"), count: 86)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(requestID, forKey: Field("requestId"))
        if let signed {
            try c.encode(signed.commandID, forKey: Field("commandId"))
            try c.encode("owner_client", forKey: Field("signer"))
            try c.encode(signed.signerKeyID, forKey: Field("signerKeyId"))
            try c.encode(signed.sequence, forKey: Field("sequence"))
            try c.encode(signed.issuedAt, forKey: Field("issuedAt"))
            try c.encode(signed.expiresAt, forKey: Field("expiresAt"))
            try c.encode(signed.nonce, forKey: Field("nonce"))
            try c.encode(signed.signature, forKey: Field("signature"))
        }
        try c.encode(surface, forKey: Field("surface"))
        try c.encode(authenticatedChannel, forKey: Field("authenticatedChannel"))
    }
}

// MARK: - Placement and reachability

public enum AgentHomeLocation: Codable, Equatable, Hashable, Sendable {
    case cloud
    case mac(NativeID)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let kind: String = try c.value("kind")
        switch kind {
        case "cloud":
            try c.closed(["kind"])
            self = .cloud
        case "mac":
            try c.closed(["kind", "deviceServiceId"])
            self = .mac(try c.value("deviceServiceId"))
        default: throw ContractViolation.invalidValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        switch self {
        case .cloud:
            try c.encode("cloud", forKey: Field("kind"))
        case let .mac(deviceID):
            try c.encode("mac", forKey: Field("kind"))
            try c.encode(deviceID, forKey: Field("deviceServiceId"))
        }
    }

    public var destinationID: String {
        switch self {
        case .cloud: "cloud"
        case let .mac(deviceID): "mac:" + deviceID.rawValue
        }
    }

    public var deviceID: NativeID? {
        if case let .mac(value) = self { value } else { nil }
    }
}

public enum AgentHomeReachability: Decodable, Equatable, Sendable {
    case reachable(lastSeenAtPlatform: Int64)
    case asleep(lastSeenAtPlatform: Int64)
    case offline(lastSeenAtPlatform: Int64?)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["state", "lastSeenAtPlatform"])
        switch try c.value("state", as: String.self) {
        case "reachable": self = .reachable(lastSeenAtPlatform: try c.integer("lastSeenAtPlatform"))
        case "asleep": self = .asleep(lastSeenAtPlatform: try c.integer("lastSeenAtPlatform"))
        case "offline": self = .offline(lastSeenAtPlatform: try c.nullableInteger("lastSeenAtPlatform"))
        default: throw ContractViolation.invalidValue
        }
    }

    public var state: String {
        switch self { case .reachable: "reachable"; case .asleep: "asleep"; case .offline: "offline" }
    }
}

public struct AgentHomeNamedDevice: Decodable, Equatable, Identifiable, Sendable {
    public enum Eligibility: Equatable, Sendable {
        public enum Reason: String, Decodable, Sendable {
            case offline, notEnrolled = "not_enrolled", versionUnsupported = "version_unsupported"
            case homeConflict = "home_conflict", catalogUnavailable = "catalog_unavailable"
        }
        case ready
        case unavailable(Reason)
    }

    public let deviceServiceID: NativeID
    public let displayName: String
    public let eligibility: Eligibility
    public var id: NativeID { deviceServiceID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("eligibility")
        deviceServiceID = try c.value("deviceServiceId")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        switch state {
        case "ready":
            try c.closed(["deviceServiceId", "displayName", "eligibility"])
            eligibility = .ready
        case "unavailable":
            try c.closed(["deviceServiceId", "displayName", "eligibility", "reason"])
            eligibility = .unavailable(try c.value("reason"))
        default: throw ContractViolation.invalidValue
        }
    }
}

public struct AgentHomeActiveMove: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case requested, draining, readyToCommit = "ready_to_commit" }
    public let moveID: NativeID
    public let status: Status
    public let source: AgentHomeLocation
    public let target: AgentHomeLocation

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["moveId", "status", "source", "target"])
        moveID = try c.value("moveId")
        status = try c.value("status")
        source = try c.value("source")
        target = try c.value("target")
        guard source != target else { throw ContractViolation.invariant }
    }
}

public struct AgentHomePlacement: Decodable, Equatable, Sendable {
    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let homeID: NativeID
    public let location: AgentHomeLocation
    public let homeEpoch: Int64
    public let activeMove: AgentHomeActiveMove?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["ownerUserId", "agentPrincipal", "homeId", "location", "homeEpoch", "activeMove"])
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        homeID = try c.value("homeId")
        location = try c.value("location")
        homeEpoch = try c.integer("homeEpoch", minimum: 1)
        activeMove = try c.nullable("activeMove")
    }
}

public enum AgentHomeMoveCapability: Decodable, Equatable, Sendable {
    public enum Reason: String, Decodable, Sendable {
        case clientUpdateRequired = "client_update_required", platformNotReady = "platform_not_ready"
    }
    case available
    case unavailable(Reason)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("state")
        if state == "available" {
            try c.closed(["state", "profile"])
            guard AgentHomeContract.acceptsBodyProfile(try c.value("profile")) else {
                throw ContractViolation.invalidValue
            }
            self = .available
        } else if state == "unavailable" {
            try c.closed(["state", "reason"])
            self = .unavailable(try c.value("reason"))
        } else { throw ContractViolation.invalidValue }
    }
}

public struct AgentHomeSnapshot: Decodable, Equatable, Sendable {
    public let meta: AgentHomePlatformMeta
    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let placement: AgentHomePlacement
    public let currentHomeReachability: AgentHomeReachability
    public let eligibleDevices: [AgentHomeNamedDevice]
    public let moveCapability: AgentHomeMoveCapability
    public let observedAtPlatform: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "profile", "ownerUserId", "agentPrincipal", "placement",
                      "currentHomeReachability", "eligibleDevices", "moveCapability", "observedAtPlatform"])
        meta = try c.value("meta")
        guard AgentHomeContract.acceptsBodyProfile(try c.value("profile")) else {
            throw ContractViolation.invalidValue
        }
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        placement = try c.value("placement")
        currentHomeReachability = try c.value("currentHomeReachability")
        eligibleDevices = try c.value("eligibleDevices")
        guard eligibleDevices.count <= 64,
              Set(eligibleDevices.map(\.deviceServiceID)).count == eligibleDevices.count,
              placement.ownerUserID == ownerUserID,
              placement.agentPrincipal == agentPrincipal else { throw ContractViolation.invariant }
        moveCapability = try c.value("moveCapability")
        observedAtPlatform = try c.integer("observedAtPlatform")
    }

    public func device(_ id: NativeID) -> AgentHomeNamedDevice? {
        eligibleDevices.first(where: { $0.deviceServiceID == id })
    }

    /// The assistant lives on a Mac the platform cannot use right now (asleep,
    /// offline, or its models went stale), so it advertises no move: that is
    /// `platform_not_ready` for a Mac home. `client_update_required` is another
    /// matter, and a cloud home is not a Mac. The one way out the platform still
    /// supports is the owner's disclosed move to the cloud (the work since the
    /// last checkpoint is lost, and only if the owner accepts that).
    public var waitsForHomeMac: Bool {
        guard case .unavailable(.platformNotReady) = moveCapability else { return false }
        return placement.location.deviceID != nil
    }
}

// MARK: - Model choice

public enum AgentHomeModelEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, max
}

public enum AgentHomeModelSource: Codable, Equatable, Hashable, Sendable {
    case atum
    case chatGPTPlan
    case ownKey(String)

    public init(rawValue: String) throws {
        switch rawValue {
        case "atum": self = .atum
        case "chatgpt_plan": self = .chatGPTPlan
        default:
            guard rawValue.range(of: #"\Aown_key:[a-z0-9][a-z0-9_-]*\z"#,
                                   options: .regularExpression) != nil,
                  rawValue.unicodeScalars.count <= 80 else { throw ContractViolation.invalidValue }
            self = .ownKey(String(rawValue.dropFirst("own_key:".count)))
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .atum: "atum"
        case .chatGPTPlan: "chatgpt_plan"
        case let .ownKey(provider): "own_key:" + provider
        }
    }

    public var managedDestinationSource: ManagedModelDestinationSource {
        switch self {
        case .atum: .atum
        case .chatGPTPlan: .chatGPTPlan
        case let .ownKey(provider): .ownKey(provider)
        }
    }
}

public struct AgentHomeModelChoice: Codable, Equatable, Hashable, Sendable {
    public let destination: String
    public let deviceServiceID: NativeID?
    public let source: AgentHomeModelSource
    public let connectionRef: String
    public let model: String
    public let effort: AgentHomeModelEffort

    public init(home: AgentHomeLocation, source: AgentHomeModelSource, connectionRef: String,
                model: String, effort: AgentHomeModelEffort) throws {
        destination = home.destinationID
        deviceServiceID = home.deviceID
        self.source = source
        self.connectionRef = try agentHomeConnectionRef(connectionRef)
        self.model = try checkedString(model, minimum: 1, maximum: 200,
                                       pattern: "[A-Za-z0-9][A-Za-z0-9._/-]*")
        self.effort = effort
        try Self.validate(home: home, source: source, connectionRef: self.connectionRef, effort: effort)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let destination = try c.string("destination", minimum: 5, maximum: 132)
        let source: AgentHomeModelSource = try c.value("source")
        let home: AgentHomeLocation
        if destination == "cloud" {
            try c.closed(["destination", "source", "connectionRef", "model", "effort"])
            home = .cloud
        } else {
            try c.closed(["destination", "deviceServiceId", "source", "connectionRef", "model", "effort"])
            let deviceID: NativeID = try c.value("deviceServiceId")
            home = .mac(deviceID)
            guard destination == home.destinationID else { throw ContractViolation.invariant }
        }
        try self.init(home: home, source: source,
                      connectionRef: c.value("connectionRef"), model: c.value("model"),
                      effort: c.value("effort"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(destination, forKey: Field("destination"))
        if let deviceServiceID { try c.encode(deviceServiceID, forKey: Field("deviceServiceId")) }
        try c.encode(source, forKey: Field("source"))
        try c.encode(connectionRef, forKey: Field("connectionRef"))
        try c.encode(model, forKey: Field("model"))
        try c.encode(effort, forKey: Field("effort"))
    }

    private static func validate(home: AgentHomeLocation, source: AgentHomeModelSource,
                                 connectionRef: String, effort: AgentHomeModelEffort) throws {
        switch (home, source) {
        case (.cloud, .atum):
            guard connectionRef == AgentHomeContract.managedConnectionRef, effort != .max else {
                throw ContractViolation.invariant
            }
        case (.cloud, _): throw ContractViolation.invariant
        case (.mac, .atum):
            guard effort != .max else { throw ContractViolation.invariant }
        case (.mac, .chatGPTPlan), (.mac, .ownKey): break
        }
    }
}

// MARK: - Preflight and move requests

public struct AgentHomePreflightInput: Codable, Equatable, Sendable {
    public let idempotencyKey: NativeID
    public let agentPrincipal: NativeID
    public let target: AgentHomeLocation
    public let chosenModel: AgentHomeModelChoice
    public let catalogRevision: Int64
    public let expectedHomeEpoch: Int64
    public let expectedActiveMoveID: NativeID?

    public init(idempotencyKey: NativeID, agentPrincipal: NativeID, target: AgentHomeLocation,
                chosenModel: AgentHomeModelChoice, catalogRevision: Int64,
                expectedHomeEpoch: Int64, expectedActiveMoveID: NativeID?) throws {
        self.idempotencyKey = idempotencyKey
        self.agentPrincipal = agentPrincipal
        self.target = target
        self.chosenModel = chosenModel
        guard chosenModel.destination == target.destinationID,
              (target != .cloud || catalogRevision == 0),
              (0...NativeAPI.maximumInteger).contains(catalogRevision),
              (1...NativeAPI.maximumInteger).contains(expectedHomeEpoch) else {
            throw ContractViolation.invariant
        }
        self.catalogRevision = catalogRevision
        self.expectedHomeEpoch = expectedHomeEpoch
        self.expectedActiveMoveID = expectedActiveMoveID
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey, agentPrincipal, target, chosenModel, catalogRevision, expectedHomeEpoch
        case expectedActiveMoveID = "expectedActiveMoveId"
    }
}

public struct AgentHomePreflightRequest: Codable, Equatable, Sendable {
    public let meta: AgentHomeOwnerMeta
    public let input: AgentHomePreflightInput

    public init(meta: AgentHomeOwnerMeta, input: AgentHomePreflightInput) {
        self.meta = meta; self.input = input
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "idempotencyKey", "agentPrincipal", "target", "chosenModel",
                      "catalogRevision", "expectedHomeEpoch", "expectedActiveMoveId"])
        meta = try c.value("meta")
        input = try AgentHomePreflightInput(
            idempotencyKey: c.value("idempotencyKey"), agentPrincipal: c.value("agentPrincipal"),
            target: c.value("target"), chosenModel: c.value("chosenModel"),
            catalogRevision: c.integer("catalogRevision"), expectedHomeEpoch: c.integer("expectedHomeEpoch", minimum: 1),
            expectedActiveMoveID: c.nullable("expectedActiveMoveId")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(meta, forKey: Field("meta"))
        try c.encode(input.idempotencyKey, forKey: Field("idempotencyKey"))
        try c.encode(input.agentPrincipal, forKey: Field("agentPrincipal"))
        try c.encode(input.target, forKey: Field("target"))
        try c.encode(input.chosenModel, forKey: Field("chosenModel"))
        try c.encode(input.catalogRevision, forKey: Field("catalogRevision"))
        try c.encode(input.expectedHomeEpoch, forKey: Field("expectedHomeEpoch"))
        try c.encode(input.expectedActiveMoveID, forKey: Field("expectedActiveMoveId"))
    }
}

public enum AgentHomeFeatureLoss: String, Codable, CaseIterable, Comparable, Sendable {
    case googleProtectedRoute = "google_protected_route"
    case protectedPrivateSkill = "protected_private_skill"
    case cloudBrowserSession = "cloud_browser_session"
    case cloudComputer = "cloud_computer"
    case drivePublication = "drive_publication"
    case routineExecution = "routine_execution"
    case pushDelivery = "push_delivery"
    case changesSinceLastCheckpointLost = "changes_since_last_checkpoint_lost"
    case modelSourceChangesToAtum = "model_source_changes_to_atum"
    case localToolsUnavailable = "local_tools_unavailable"
    case localFilesUnavailable = "local_files_unavailable"
    case localBrowserSessionsUnavailable = "local_browser_sessions_unavailable"
    case conversationOverridesCleared = "conversation_overrides_cleared"

    public static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
}

public enum AgentHomeCheckpointLoss: Codable, Equatable, Hashable, Sendable {
    case notRequired
    case disclosed(lastCheckpointAtPlatform: Int64)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("state")
        if state == "not_required" {
            try c.closed(["state"])
            self = .notRequired
        } else if state == "disclosed" {
            try c.closed(["state", "lossCode", "lastCheckpointAtPlatform"])
            guard try c.value("lossCode", as: String.self) == AgentHomeFeatureLoss.changesSinceLastCheckpointLost.rawValue else {
                throw ContractViolation.invalidValue
            }
            self = .disclosed(lastCheckpointAtPlatform: try c.integer("lastCheckpointAtPlatform"))
        } else { throw ContractViolation.invalidValue }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        switch self {
        case .notRequired:
            try c.encode("not_required", forKey: Field("state"))
        case let .disclosed(timestamp):
            try c.encode("disclosed", forKey: Field("state"))
            try c.encode(AgentHomeFeatureLoss.changesSinceLastCheckpointLost.rawValue,
                         forKey: Field("lossCode"))
            try c.encode(timestamp, forKey: Field("lastCheckpointAtPlatform"))
        }
    }
}

public struct AgentHomePreflightCommon: Decodable, Equatable, Sendable {
    public let meta: AgentHomePlatformMeta
    public let requestID: NativeID
    public let preflightID: NativeID
    public let preflightRevision: Int64
    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let source: AgentHomeLocation
    public let target: AgentHomeLocation
    public let chosenModel: AgentHomeModelChoice
    public let catalogRevision: Int64
    public let expectedHomeEpoch: Int64
    public let expectedActiveMoveID: NativeID?
    public let featureInventoryRevision: Int64
    public let evaluatedAtPlatform: Int64
    public let expiresAtPlatform: Int64
    public let sourceReachability: AgentHomeReachability
    public let lastCheckpointAtPlatform: Int64?
    public let checkpointLoss: AgentHomeCheckpointLoss
    public let conversationOverrideCount: Int64
    public let featureLosses: [AgentHomeFeatureLoss]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "requestId", "preflightId", "preflightRevision", "ownerUserId",
                      "agentPrincipal", "source", "target", "chosenModel", "catalogRevision",
                      "expectedHomeEpoch", "expectedActiveMoveId", "featureInventoryRevision",
                      "evaluatedAtPlatform", "expiresAtPlatform", "sourceReachability",
                      "lastCheckpointAtPlatform", "checkpointLoss", "conversationOverrideCount",
                      "featureLosses"])
        meta = try c.value("meta")
        requestID = try c.value("requestId")
        preflightID = try c.value("preflightId")
        preflightRevision = try c.integer("preflightRevision", minimum: 1)
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        source = try c.value("source")
        target = try c.value("target")
        chosenModel = try c.value("chosenModel")
        catalogRevision = try c.integer("catalogRevision")
        expectedHomeEpoch = try c.integer("expectedHomeEpoch", minimum: 1)
        expectedActiveMoveID = try c.nullable("expectedActiveMoveId")
        featureInventoryRevision = try c.integer("featureInventoryRevision", minimum: 1)
        evaluatedAtPlatform = try c.integer("evaluatedAtPlatform")
        expiresAtPlatform = try c.integer("expiresAtPlatform")
        sourceReachability = try c.value("sourceReachability")
        lastCheckpointAtPlatform = try c.nullableInteger("lastCheckpointAtPlatform")
        checkpointLoss = try c.value("checkpointLoss")
        conversationOverrideCount = try c.integer("conversationOverrideCount")
        featureLosses = try c.value("featureLosses")
        try validate()
    }

    private func validate() throws {
        guard source != target, expiresAtPlatform > evaluatedAtPlatform,
              chosenModel.destination == target.destinationID,
              target != .cloud || catalogRevision == 0,
              featureLosses.count <= AgentHomeFeatureLoss.allCases.count,
              Set(featureLosses).count == featureLosses.count,
              featureLosses == featureLosses.sorted(),
              (conversationOverrideCount > 0) == featureLosses.contains(.conversationOverridesCleared)
        else { throw ContractViolation.invariant }

        if case .mac = source, sourceReachability.state != "reachable" {
            guard featureLosses.contains(.changesSinceLastCheckpointLost),
                  let lastCheckpointAtPlatform,
                  checkpointLoss == .disclosed(lastCheckpointAtPlatform: lastCheckpointAtPlatform) else {
                throw ContractViolation.invariant
            }
        }
        if target == .cloud {
            let required: Set<AgentHomeFeatureLoss> = [.modelSourceChangesToAtum, .localToolsUnavailable,
                                                       .localFilesUnavailable, .localBrowserSessionsUnavailable]
            guard required.isSubset(of: Set(featureLosses)) else { throw ContractViolation.invariant }
        }
    }

    public var accepted: AgentHomeAcceptedPreflight {
        AgentHomeAcceptedPreflight(preflightID: preflightID, preflightRevision: preflightRevision,
                                   expiresAtPlatform: expiresAtPlatform,
                                   featureInventoryRevision: featureInventoryRevision,
                                   catalogRevision: catalogRevision, chosenModel: chosenModel,
                                   featureLosses: featureLosses,
                                   lastCheckpointAtPlatform: lastCheckpointAtPlatform,
                                   conversationOverrideCount: conversationOverrideCount,
                                   checkpointLoss: checkpointLoss)
    }
}

public struct AgentHomeMovePreflight: Decodable, Equatable, Sendable {
    public enum Outcome: String, Decodable, Sendable { case ready, blocked }
    public enum BlockReason: String, Decodable, Sendable {
        case unknownExportClass = "unknown_export_class", targetUnavailable = "target_unavailable"
        case connectionUnavailable = "connection_unavailable", catalogStale = "catalog_stale"
        case notEligible = "not_eligible"
        case cloudControllerVersionUnsupported = "cloud_controller_version_unsupported"
    }
    public let common: AgentHomePreflightCommon
    public let outcome: Outcome
    public let reason: BlockReason?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["common", "outcome", "reason"])
        common = try c.value("common")
        outcome = try c.value("outcome")
        reason = try c.nullable("reason")
        guard (outcome == .ready) == (reason == nil) else { throw ContractViolation.invariant }
    }
}

public struct AgentHomeAcceptedPreflight: Codable, Equatable, Hashable, Sendable {
    public let preflightID: NativeID
    public let preflightRevision: Int64
    public let expiresAtPlatform: Int64
    public let featureInventoryRevision: Int64
    public let catalogRevision: Int64
    public let chosenModel: AgentHomeModelChoice
    public let featureLosses: [AgentHomeFeatureLoss]
    public let lastCheckpointAtPlatform: Int64?
    public let conversationOverrideCount: Int64
    public let checkpointLoss: AgentHomeCheckpointLoss

    public init(preflightID: NativeID, preflightRevision: Int64, expiresAtPlatform: Int64,
                featureInventoryRevision: Int64, catalogRevision: Int64,
                chosenModel: AgentHomeModelChoice, featureLosses: [AgentHomeFeatureLoss],
                lastCheckpointAtPlatform: Int64?, conversationOverrideCount: Int64,
                checkpointLoss: AgentHomeCheckpointLoss) {
        self.preflightID = preflightID; self.preflightRevision = preflightRevision
        self.expiresAtPlatform = expiresAtPlatform; self.featureInventoryRevision = featureInventoryRevision
        self.catalogRevision = catalogRevision; self.chosenModel = chosenModel
        self.featureLosses = featureLosses; self.lastCheckpointAtPlatform = lastCheckpointAtPlatform
        self.conversationOverrideCount = conversationOverrideCount; self.checkpointLoss = checkpointLoss
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["preflightId", "preflightRevision", "expiresAtPlatform",
                      "featureInventoryRevision", "catalogRevision", "chosenModel", "featureLosses",
                      "lastCheckpointAtPlatform", "conversationOverrideCount", "checkpointLoss"])
        preflightID = try c.value("preflightId")
        preflightRevision = try c.integer("preflightRevision", minimum: 1)
        expiresAtPlatform = try c.integer("expiresAtPlatform")
        featureInventoryRevision = try c.integer("featureInventoryRevision", minimum: 1)
        catalogRevision = try c.integer("catalogRevision")
        chosenModel = try c.value("chosenModel")
        featureLosses = try c.value("featureLosses")
        lastCheckpointAtPlatform = try c.nullableInteger("lastCheckpointAtPlatform")
        conversationOverrideCount = try c.integer("conversationOverrideCount")
        checkpointLoss = try c.value("checkpointLoss")
        guard featureLosses.count <= AgentHomeFeatureLoss.allCases.count,
              Set(featureLosses).count == featureLosses.count,
              featureLosses == featureLosses.sorted() else { throw ContractViolation.invariant }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(preflightID, forKey: Field("preflightId"))
        try c.encode(preflightRevision, forKey: Field("preflightRevision"))
        try c.encode(expiresAtPlatform, forKey: Field("expiresAtPlatform"))
        try c.encode(featureInventoryRevision, forKey: Field("featureInventoryRevision"))
        try c.encode(catalogRevision, forKey: Field("catalogRevision"))
        try c.encode(chosenModel, forKey: Field("chosenModel"))
        try c.encode(featureLosses, forKey: Field("featureLosses"))
        try c.encode(lastCheckpointAtPlatform, forKey: Field("lastCheckpointAtPlatform"))
        try c.encode(conversationOverrideCount, forKey: Field("conversationOverrideCount"))
        try c.encode(checkpointLoss, forKey: Field("checkpointLoss"))
    }

    private enum CodingKeys: String, CodingKey {
        case preflightID = "preflightId", preflightRevision, expiresAtPlatform, featureInventoryRevision
        case catalogRevision, chosenModel, featureLosses, lastCheckpointAtPlatform
        case conversationOverrideCount, checkpointLoss
    }
}

public struct AgentHomeMoveInput: Codable, Equatable, Sendable {
    public let moveID: NativeID
    public let idempotencyKey: NativeID
    public let agentPrincipal: NativeID
    public let target: AgentHomeLocation
    public let expectedHomeEpoch: Int64
    public let expectedActiveMoveID: NativeID?
    public let acceptedPreflight: AgentHomeAcceptedPreflight
    public let acceptCheckpointLoss: Bool

    public init(moveID: NativeID, idempotencyKey: NativeID, agentPrincipal: NativeID,
                target: AgentHomeLocation, expectedHomeEpoch: Int64,
                expectedActiveMoveID: NativeID?, acceptedPreflight: AgentHomeAcceptedPreflight,
                acceptCheckpointLoss: Bool) throws {
        self.moveID = moveID
        self.idempotencyKey = idempotencyKey
        self.agentPrincipal = agentPrincipal
        self.target = target
        self.expectedHomeEpoch = expectedHomeEpoch
        self.expectedActiveMoveID = expectedActiveMoveID
        self.acceptedPreflight = acceptedPreflight
        self.acceptCheckpointLoss = acceptCheckpointLoss
        guard (1...NativeAPI.maximumInteger).contains(expectedHomeEpoch),
              acceptedPreflight.chosenModel.destination == target.destinationID,
              target != .cloud || acceptedPreflight.catalogRevision == 0 else {
            throw ContractViolation.invariant
        }
        if acceptCheckpointLoss {
            guard acceptedPreflight.featureLosses.contains(.changesSinceLastCheckpointLost),
                  let timestamp = acceptedPreflight.lastCheckpointAtPlatform,
                  acceptedPreflight.checkpointLoss == .disclosed(lastCheckpointAtPlatform: timestamp) else {
                throw ContractViolation.invariant
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case moveID = "moveId", idempotencyKey, agentPrincipal, target, expectedHomeEpoch
        case expectedActiveMoveID = "expectedActiveMoveId", acceptedPreflight, acceptCheckpointLoss
    }
}

public struct AgentHomeMoveRequest: Codable, Equatable, Sendable {
    public let meta: AgentHomeOwnerMeta
    public let input: AgentHomeMoveInput

    public init(meta: AgentHomeOwnerMeta, input: AgentHomeMoveInput) { self.meta = meta; self.input = input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "moveId", "idempotencyKey", "agentPrincipal", "target",
                      "expectedHomeEpoch", "expectedActiveMoveId", "acceptedPreflight", "acceptCheckpointLoss"])
        meta = try c.value("meta")
        input = try AgentHomeMoveInput(moveID: c.value("moveId"), idempotencyKey: c.value("idempotencyKey"),
                                       agentPrincipal: c.value("agentPrincipal"), target: c.value("target"),
                                       expectedHomeEpoch: c.integer("expectedHomeEpoch", minimum: 1),
                                       expectedActiveMoveID: c.nullable("expectedActiveMoveId"),
                                       acceptedPreflight: c.value("acceptedPreflight"),
                                       acceptCheckpointLoss: c.value("acceptCheckpointLoss"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(meta, forKey: Field("meta"))
        try c.encode(input.moveID, forKey: Field("moveId"))
        try c.encode(input.idempotencyKey, forKey: Field("idempotencyKey"))
        try c.encode(input.agentPrincipal, forKey: Field("agentPrincipal"))
        try c.encode(input.target, forKey: Field("target"))
        try c.encode(input.expectedHomeEpoch, forKey: Field("expectedHomeEpoch"))
        try c.encode(input.expectedActiveMoveID, forKey: Field("expectedActiveMoveId"))
        try c.encode(input.acceptedPreflight, forKey: Field("acceptedPreflight"))
        try c.encode(input.acceptCheckpointLoss, forKey: Field("acceptCheckpointLoss"))
    }
}

public struct AgentHomeCancelInput: Codable, Equatable, Sendable {
    public let cancelID: NativeID
    public let idempotencyKey: NativeID
    public let agentPrincipal: NativeID
    public let moveID: NativeID
    public let expectedHomeEpoch: Int64
    public let expectedActiveMoveID: NativeID

    public init(cancelID: NativeID, idempotencyKey: NativeID, agentPrincipal: NativeID,
                moveID: NativeID, expectedHomeEpoch: Int64, expectedActiveMoveID: NativeID) throws {
        guard moveID == expectedActiveMoveID,
              (1...NativeAPI.maximumInteger).contains(expectedHomeEpoch) else {
            throw ContractViolation.invariant
        }
        self.cancelID = cancelID; self.idempotencyKey = idempotencyKey
        self.agentPrincipal = agentPrincipal; self.moveID = moveID
        self.expectedHomeEpoch = expectedHomeEpoch; self.expectedActiveMoveID = expectedActiveMoveID
    }

    private enum CodingKeys: String, CodingKey {
        case cancelID = "cancelId", idempotencyKey, agentPrincipal, moveID = "moveId", expectedHomeEpoch
        case expectedActiveMoveID = "expectedActiveMoveId"
    }
}

public struct AgentHomeCancelRequest: Codable, Equatable, Sendable {
    public let meta: AgentHomeOwnerMeta
    public let input: AgentHomeCancelInput

    public init(meta: AgentHomeOwnerMeta, input: AgentHomeCancelInput) { self.meta = meta; self.input = input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "cancelId", "idempotencyKey", "agentPrincipal", "moveId",
                      "expectedHomeEpoch", "expectedActiveMoveId"])
        meta = try c.value("meta")
        input = try AgentHomeCancelInput(cancelID: c.value("cancelId"), idempotencyKey: c.value("idempotencyKey"),
                                         agentPrincipal: c.value("agentPrincipal"), moveID: c.value("moveId"),
                                         expectedHomeEpoch: c.integer("expectedHomeEpoch", minimum: 1),
                                         expectedActiveMoveID: c.value("expectedActiveMoveId"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(meta, forKey: Field("meta"))
        try c.encode(input.cancelID, forKey: Field("cancelId"))
        try c.encode(input.idempotencyKey, forKey: Field("idempotencyKey"))
        try c.encode(input.agentPrincipal, forKey: Field("agentPrincipal"))
        try c.encode(input.moveID, forKey: Field("moveId"))
        try c.encode(input.expectedHomeEpoch, forKey: Field("expectedHomeEpoch"))
        try c.encode(input.expectedActiveMoveID, forKey: Field("expectedActiveMoveId"))
    }
}

public struct AgentHomeMoveRefusal: Decodable, Equatable, Sendable {
    public enum Operation: String, Decodable, Sendable { case request, cancel }
    public enum Reason: String, Decodable, Sendable {
        case anotherMoveInProgress = "another_move_in_progress", stale, notEligible = "not_eligible"
        case preflightRequired = "preflight_required", preflightExpired = "preflight_expired"
        case featureLossesChanged = "feature_losses_changed"
        case cloudControllerVersionUnsupported = "cloud_controller_version_unsupported"
        case catalogStale = "catalog_stale", idempotencyConflict = "idempotency_conflict"
        case committedEpochPreserved = "committed_epoch_preserved", surfaceMismatch = "surface_mismatch"
    }
    public let meta: AgentHomePlatformMeta
    public let operation: Operation
    public let requestID: NativeID
    public let moveID: NativeID?
    public let reason: Reason
    public let currentHomeEpoch: Int64
    public let currentActiveMoveID: NativeID?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "operation", "requestId", "moveId", "outcome", "reason",
                      "currentHomeEpoch", "currentActiveMoveId"])
        guard try c.value("outcome", as: String.self) == "refused" else { throw ContractViolation.invalidValue }
        meta = try c.value("meta"); operation = try c.value("operation")
        requestID = try c.value("requestId"); moveID = try c.nullable("moveId")
        reason = try c.value("reason"); currentHomeEpoch = try c.integer("currentHomeEpoch", minimum: 1)
        currentActiveMoveID = try c.nullable("currentActiveMoveId")
    }
}

// MARK: - Progress

public struct AgentHomeMoveProgress: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case finishingCurrentWork = "finishing_current_work", moving
        case waitingForDestination = "waiting_for_destination", reconciling, ready, failed
    }
    public enum BaseStatus: String, Decodable, Sendable {
        case requested, draining, readyToCommit = "ready_to_commit", committed, aborted, superseded
    }
    public enum FailureReason: String, Decodable, Sendable {
        case preflightStale = "preflight_stale", targetUnavailable = "target_unavailable"
        case sourceUnreachable = "source_unreachable", drainFailed = "drain_failed"
        case archiveExportFailed = "archive_export_failed", archiveConversionFailed = "archive_conversion_failed"
        case archiveImportFailed = "archive_import_failed", integrityCheckFailed = "integrity_check_failed"
        case placementConflict = "placement_conflict", modelUnavailable = "model_unavailable"
        case ownerCancelled = "owner_cancelled", superseded, sleepBudgetElapsed = "sleep_budget_elapsed"
        case destinationUnreachable = "destination_unreachable"
    }
    public enum ModelApplication: String, Decodable, Sendable {
        case notSelected = "not_selected", pendingNextTurn = "pending_next_turn", applied, unavailable
    }
    public enum ServingSigner: String, Decodable, Sendable { case cloudWorkload = "cloud_workload", macExecutor = "mac_executor" }

    public let ownerUserID: NativeMatrixUser
    public let agentPrincipal: NativeID
    public let moveID: NativeID
    public let sequence: Int64
    public let source: AgentHomeLocation
    public let target: AgentHomeLocation
    public let updatedAtPlatform: Int64
    public let state: State
    public let baseStatus: BaseStatus
    public let authoritativeHome: AgentHomeLocation
    public let failureReason: FailureReason?
    public let oldHomeResumed: Bool?
    public let servingSigner: ServingSigner?
    public let modelApplication: ModelApplication?
    public let conversationOverridesCleared: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard AgentHomeContract.acceptsBodyProfile(try c.value("profile")) else {
            throw ContractViolation.invalidValue
        }
        ownerUserID = try c.value("ownerUserId")
        agentPrincipal = try c.value("agentPrincipal")
        moveID = try c.value("moveId")
        sequence = try c.integer("sequence", minimum: 1)
        source = try c.value("source")
        target = try c.value("target")
        updatedAtPlatform = try c.integer("updatedAtPlatform")
        state = try c.value("state")
        baseStatus = try c.value("baseMoveStatus")

        let common: Set<String> = ["profile", "ownerUserId", "agentPrincipal", "moveId", "sequence",
                                   "source", "target", "updatedAtPlatform", "state", "baseMoveStatus", "reason"]
        guard source != target else { throw ContractViolation.invariant }
        switch state {
        case .finishingCurrentWork:
            try c.closed(common.union(["authoritativeHome"]))
            guard try c.decodeNil(forKey: Field("reason")), [.requested, .draining].contains(baseStatus) else {
                throw ContractViolation.invariant
            }
            authoritativeHome = try c.value("authoritativeHome")
            failureReason = nil; oldHomeResumed = nil; servingSigner = nil
            modelApplication = nil; conversationOverridesCleared = nil
            guard authoritativeHome == source else { throw ContractViolation.invariant }
        case .moving:
            try c.closed(common.union(["authoritativeHome"]))
            guard try c.decodeNil(forKey: Field("reason")), baseStatus == .readyToCommit else {
                throw ContractViolation.invariant
            }
            authoritativeHome = try c.value("authoritativeHome")
            failureReason = nil; oldHomeResumed = nil; servingSigner = nil
            modelApplication = nil; conversationOverridesCleared = nil
            guard authoritativeHome == source else { throw ContractViolation.invariant }
        case .waitingForDestination:
            try c.closed(common.union(["authoritativeHome"]))
            guard try c.value("reason", as: String.self) == "destination_not_serving",
                  baseStatus == .committed else { throw ContractViolation.invariant }
            authoritativeHome = try c.value("authoritativeHome")
            failureReason = nil; oldHomeResumed = nil; servingSigner = nil
            modelApplication = nil; conversationOverridesCleared = nil
            guard authoritativeHome == target else { throw ContractViolation.invariant }
        case .reconciling:
            try c.closed(common.union(["authoritativeHome"]))
            guard try c.value("reason", as: String.self) == "effect_unknown",
                  [.requested, .draining, .readyToCommit, .committed].contains(baseStatus) else {
                throw ContractViolation.invariant
            }
            authoritativeHome = try c.value("authoritativeHome")
            failureReason = nil; oldHomeResumed = nil; servingSigner = nil
            modelApplication = nil; conversationOverridesCleared = nil
            guard authoritativeHome == (baseStatus == .committed ? target : source) else {
                throw ContractViolation.invariant
            }
        case .ready:
            try c.closed(common.union(["authoritativeHome", "servingSigner", "modelApplication",
                                       "conversationOverridesCleared"]))
            guard try c.decodeNil(forKey: Field("reason")), baseStatus == .committed else {
                throw ContractViolation.invariant
            }
            authoritativeHome = try c.value("authoritativeHome")
            servingSigner = try c.value("servingSigner")
            modelApplication = try c.value("modelApplication")
            conversationOverridesCleared = try c.value("conversationOverridesCleared")
            failureReason = nil; oldHomeResumed = nil
            guard authoritativeHome == target,
                  (target == .cloud && servingSigner == .cloudWorkload)
                    || (target.deviceID != nil && servingSigner == .macExecutor) else {
                throw ContractViolation.invariant
            }
        case .failed:
            try c.closed(common.union(["currentAuthoritativeHome", "oldHomeResumed"]))
            authoritativeHome = try c.value("currentAuthoritativeHome")
            failureReason = try c.value("reason")
            oldHomeResumed = try c.value("oldHomeResumed")
            servingSigner = nil; modelApplication = nil; conversationOverridesCleared = nil
            try validateFailure()
        }
    }

    private func validateFailure() throws {
        guard let failureReason, let oldHomeResumed else { throw ContractViolation.invariant }
        let precommit: Set<FailureReason> = [.preflightStale, .targetUnavailable, .sourceUnreachable,
                                             .drainFailed, .archiveExportFailed, .archiveConversionFailed,
                                             .archiveImportFailed, .integrityCheckFailed, .placementConflict,
                                             .modelUnavailable, .ownerCancelled, .sleepBudgetElapsed]
        let coherent = failureReason == .superseded ? baseStatus == .superseded
            : failureReason == .destinationUnreachable ? baseStatus == .committed
            : precommit.contains(failureReason) && baseStatus == .aborted
        guard coherent,
              oldHomeResumed == (authoritativeHome == source),
              oldHomeResumed || authoritativeHome == target else { throw ContractViolation.invariant }
    }

    public var isTerminal: Bool { state == .ready || state == .failed }
}

public struct AgentHomeProgressTracker: Equatable, Sendable {
    public private(set) var progress: AgentHomeMoveProgress?
    public init() {}

    /// Progress is monotonic per move, and only a LOWER sequence is stale: the
    /// contract tells a client to ignore a record whose sequence is lower than
    /// the highest it has seen. An EQUAL sequence is not ignored. The platform
    /// derives `waiting_for_destination` versus `ready` (and the cleared
    /// override flag) from live readiness without always bumping the sequence,
    /// so a record that differs from the one shown at the same sequence is
    /// newer information and replaces it. An identical duplicate paints nothing.
    /// Returns whether the shown record changed.
    @discardableResult public mutating func receive(_ value: AgentHomeMoveProgress) -> Bool {
        if let progress {
            guard progress.moveID == value.moveID, value.sequence >= progress.sequence,
                  value != progress else { return false }
        }
        progress = value
        return true
    }
}

public enum AgentHomeModelRoute: Equatable, Sendable {
    /// Current-home changes are authoritative writes. A choice for another
    /// home is staged only inside preflight; it must never go through frozen
    /// model-choice/1.3 or mutate a destination before the move is accepted.
    case currentHomeWrite
    case movePreflight

    public static func select(currentHome: AgentHomeLocation,
                              selectedHome: AgentHomeLocation) -> Self {
        currentHome == selectedHome ? .currentHomeWrite : .movePreflight
    }
}

// MARK: - Model choice writes and results

public struct AgentHomeModelChoiceInput: Codable, Equatable, Sendable {
    public let idempotencyKey: NativeID
    public let agentPrincipal: NativeID
    public let currentHome: AgentHomeLocation
    public let expectedHomeID: NativeID
    public let expectedHomeEpoch: Int64
    public let expectedActiveMoveID: NativeID?
    public let expectedChoiceRevision: Int64
    public let choice: AgentHomeModelChoice

    public init(idempotencyKey: NativeID, agentPrincipal: NativeID, currentHome: AgentHomeLocation,
                expectedHomeID: NativeID, expectedHomeEpoch: Int64,
                expectedActiveMoveID: NativeID?, expectedChoiceRevision: Int64,
                choice: AgentHomeModelChoice) throws {
        guard choice.destination == currentHome.destinationID,
              (1...NativeAPI.maximumInteger).contains(expectedHomeEpoch),
              (0...NativeAPI.maximumInteger).contains(expectedChoiceRevision) else {
            throw ContractViolation.invariant
        }
        self.idempotencyKey = idempotencyKey; self.agentPrincipal = agentPrincipal
        self.currentHome = currentHome; self.expectedHomeID = expectedHomeID
        self.expectedHomeEpoch = expectedHomeEpoch; self.expectedActiveMoveID = expectedActiveMoveID
        self.expectedChoiceRevision = expectedChoiceRevision; self.choice = choice
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey, agentPrincipal, currentHome, expectedHomeEpoch, expectedChoiceRevision, choice
        case expectedHomeID = "expectedHomeId", expectedActiveMoveID = "expectedActiveMoveId"
    }
}

public struct AgentHomeModelChoiceWrite: Codable, Equatable, Sendable {
    public let meta: AgentHomeOwnerMeta
    public let input: AgentHomeModelChoiceInput

    public init(meta: AgentHomeOwnerMeta, input: AgentHomeModelChoiceInput) { self.meta = meta; self.input = input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "idempotencyKey", "agentPrincipal", "currentHome", "expectedHomeId",
                      "expectedHomeEpoch", "expectedActiveMoveId", "expectedChoiceRevision", "choice"])
        meta = try c.value("meta")
        input = try AgentHomeModelChoiceInput(
            idempotencyKey: c.value("idempotencyKey"), agentPrincipal: c.value("agentPrincipal"),
            currentHome: c.value("currentHome"), expectedHomeID: c.value("expectedHomeId"),
            expectedHomeEpoch: c.integer("expectedHomeEpoch", minimum: 1),
            expectedActiveMoveID: c.nullable("expectedActiveMoveId"),
            expectedChoiceRevision: c.integer("expectedChoiceRevision"), choice: c.value("choice")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(meta, forKey: Field("meta"))
        try c.encode(input.idempotencyKey, forKey: Field("idempotencyKey"))
        try c.encode(input.agentPrincipal, forKey: Field("agentPrincipal"))
        try c.encode(input.currentHome, forKey: Field("currentHome"))
        try c.encode(input.expectedHomeID, forKey: Field("expectedHomeId"))
        try c.encode(input.expectedHomeEpoch, forKey: Field("expectedHomeEpoch"))
        try c.encode(input.expectedActiveMoveID, forKey: Field("expectedActiveMoveId"))
        try c.encode(input.expectedChoiceRevision, forKey: Field("expectedChoiceRevision"))
        try c.encode(input.choice, forKey: Field("choice"))
    }
}

public struct AgentHomeModelChoiceReceipt: Decodable, Equatable, Sendable {
    public enum Outcome: String, Decodable, Sendable { case applied, replay }
    public let meta: AgentHomePlatformMeta
    public let requestID: NativeID
    public let idempotencyKey: NativeID
    public let choiceRevision: Int64
    public let choice: AgentHomeModelChoice
    public let outcome: Outcome

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "requestId", "idempotencyKey", "choiceRevision", "choice",
                      "outcome", "applicationBoundary"])
        meta = try c.value("meta"); requestID = try c.value("requestId")
        idempotencyKey = try c.value("idempotencyKey")
        choiceRevision = try c.integer("choiceRevision", minimum: 1)
        choice = try c.value("choice"); outcome = try c.value("outcome")
        guard try c.value("applicationBoundary", as: String.self) == "next_turn_boundary" else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct AgentHomeModelChoiceRefusal: Decodable, Equatable, Sendable {
    public enum Reason: String, Decodable, Sendable {
        case staleHome = "stale_home", activeMoveChanged = "active_move_changed"
        case staleChoiceRevision = "stale_choice_revision", catalogStale = "catalog_stale"
        case connectionUnavailable = "connection_unavailable", modelUnavailable = "model_unavailable"
        case idempotencyConflict = "idempotency_conflict", destinationNotCurrent = "destination_not_current"
        case surfaceMismatch = "surface_mismatch"
    }
    public let meta: AgentHomePlatformMeta
    public let requestID: NativeID
    public let idempotencyKey: NativeID
    public let reason: Reason
    public let currentHome: AgentHomeLocation
    public let currentHomeEpoch: Int64
    public let currentActiveMoveID: NativeID?
    public let currentChoiceRevision: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["meta", "requestId", "idempotencyKey", "outcome", "reason", "currentHome",
                      "currentHomeEpoch", "currentActiveMoveId", "currentChoiceRevision"])
        guard try c.value("outcome", as: String.self) == "refused" else { throw ContractViolation.invalidValue }
        meta = try c.value("meta"); requestID = try c.value("requestId")
        idempotencyKey = try c.value("idempotencyKey"); reason = try c.value("reason")
        currentHome = try c.value("currentHome"); currentHomeEpoch = try c.integer("currentHomeEpoch", minimum: 1)
        currentActiveMoveID = try c.nullable("currentActiveMoveId")
        currentChoiceRevision = try c.integer("currentChoiceRevision")
    }
}

public enum AgentHomeMoveCommandResult: Decodable, Equatable, Sendable {
    case progress(AgentHomeMoveProgress)
    case refused(AgentHomeMoveRefusal)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        if try c.optional("outcome", as: String.self) == "refused" {
            self = .refused(try AgentHomeMoveRefusal(from: decoder))
        } else {
            self = .progress(try AgentHomeMoveProgress(from: decoder))
        }
    }
}

public enum AgentHomeModelChoiceResult: Decodable, Equatable, Sendable {
    case receipt(AgentHomeModelChoiceReceipt)
    case refused(AgentHomeModelChoiceRefusal)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        if try c.optional("outcome", as: String.self) == "refused" {
            self = .refused(try AgentHomeModelChoiceRefusal(from: decoder))
        } else {
            self = .receipt(try AgentHomeModelChoiceReceipt(from: decoder))
        }
    }
}

// MARK: - Private validation

private func agentHomeSignedLifetime(issuedAt: Int64, expiresAt: Int64) throws {
    guard expiresAt > issuedAt, expiresAt <= issuedAt + 7_200_000 else {
        throw ContractViolation.invariant
    }
}

private func agentHomeB64(_ value: String, count: Int) throws -> String {
    try checkedString(value, minimum: count, maximum: count, pattern: "[A-Za-z0-9_-]{\(count)}")
}

private func agentHomeConnectionRef(_ value: String) throws -> String {
    try checkedString(value, minimum: 21, maximum: 69, pattern: "conn_[A-Za-z0-9_-]{16,64}")
}
