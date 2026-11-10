import Foundation

/// Read-only subset of the frozen private-CoS contracts. V2 changes execution,
/// not the GET view: the pinned Shell still returns the v1/v1.1 view shapes.
public struct CompanyPrivateCosView: Decodable, Equatable, Sendable {
    public struct Pair: Decodable, Equatable, Hashable, Sendable {
        public let companyPrincipal, memberPrincipal, membershipIncarnation: NativeID

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["companyPrincipal", "memberPrincipal", "membershipIncarnation"])
            companyPrincipal = try c.value("companyPrincipal")
            memberPrincipal = try c.value("memberPrincipal")
            membershipIncarnation = try c.value("membershipIncarnation")
        }
    }

    public struct Binding: Decodable, Equatable, Sendable {
        public struct Scope: Decodable, Equatable, Sendable {
            public let pair: Pair
            public let authorityEpoch, contextEpoch, homeGeneration: Int64
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Field.self)
                try c.closed(["pair", "authorityEpoch", "contextEpoch", "homeGeneration"])
                pair = try c.value("pair")
                authorityEpoch = try c.integer("authorityEpoch", minimum: 1)
                contextEpoch = try c.integer("contextEpoch", minimum: 1)
                homeGeneration = try c.integer("homeGeneration", minimum: 1)
            }
        }
        public let scope: Scope
        public let agentPrincipal, executorId, homeId: NativeID
        public let agentUserId, roomId, profileDigest: String
        public let storeGeneration: Int64

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["scope", "agentPrincipal", "agentUserId", "executorId", "homeId",
                          "roomId", "storeGeneration", "profileDigest"])
            scope = try c.value("scope")
            agentPrincipal = try c.value("agentPrincipal")
            executorId = try c.value("executorId")
            homeId = try c.value("homeId")
            agentUserId = try c.string("agentUserId", minimum: 4, maximum: 512,
                                       pattern: "@[!-9;-~]{1,255}:[!-~]{1,255}")
            roomId = try c.string("roomId", minimum: 4, maximum: 512,
                                  pattern: "![!-9;-~]{1,255}:[!-~]{1,255}")
            storeGeneration = try c.integer("storeGeneration", minimum: 1)
            profileDigest = try c.string("profileDigest", minimum: 64, maximum: 64,
                                         pattern: "[a-f0-9]{64}")
        }
    }

    public let pair: Pair
    public let state: String
    public let binding: Binding?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        pair = try c.value("pair")
        state = try c.value("state")
        let version = try c.integer("schemaVersion")
        let greeting: String = try c.value("greetingState")
        if version == 2 {
            try c.closed(["schemaVersion", "profile", "state", "pair", "greetingState", "operationId"])
            let profile: String = try c.value("profile")
            let _: NativeID = try c.value("operationId")
            guard profile == "atum.company-private-cos/1.1", state == "preparing", greeting == "pending"
            else { throw ContractViolation.invalidValue }
            binding = nil
        } else {
            guard version == 1 else { throw ContractViolation.invalidValue }
            if state == "uncreated" {
                try c.closed(["schemaVersion", "state", "pair", "greetingState"])
                guard greeting == "pending" else { throw ContractViolation.invalidValue }
                binding = nil
            } else {
                try c.closed(["schemaVersion", "state", "pair", "greetingState", "binding"])
                guard (state == "ready" && ["pending", "published"].contains(greeting))
                    || (state == "preparing" && ["pending", "publishing"].contains(greeting))
                else { throw ContractViolation.invalidValue }
                let value: Binding = try c.value("binding")
                guard value.scope.pair == pair else { throw ContractViolation.invariant }
                binding = value
            }
        }
    }
}

/// Both frozen capability advertisements understood by this consumer. The only
/// write is `ensure` (the frozen v1 request); no execution, spend or stop.
public struct CompanyPrivateCosCapability: Decodable, Equatable, Sendable {
    public let profile: String
    /// The 1.3 advertisement's frozen `displayName` ("Chief of Staff"); nil for v2.
    public let displayName: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        profile = try c.value("profile")
        let version = try c.integer("schemaVersion")
        let wire: Wire = try c.value("wire")
        guard wire.header == CompanyWire.headerName else { throw ContractViolation.invalidValue }
        if profile == "atum.company-private-cos/2" {
            try c.closed(["schemaVersion", "profile", "wire", "execution", "fundingProfile", "roomType",
                          "roomEncrypted", "greetingVersion", "ensureLocale", "purgeAfterDays",
                          "userExport", "retiredIncarnationRestore"])
            let _: Execution = try c.value("execution")
            let funding: String = try c.value("fundingProfile")
            let restore: Bool = try c.value("retiredIncarnationRestore")
            guard version == 5, wire.value == "2", funding == "atum.company-funding/2.2", !restore
            else { throw ContractViolation.invalidValue }
            displayName = nil
        } else {
            try c.closed(["schemaVersion", "profile", "capability", "supportedProfiles", "wire", "displayName",
                          "teamDmPosition", "lazyCreation", "fundingKind", "separatePrice", "purgeAfterDays",
                          "userExport", "roomType", "roomName", "roomEncrypted", "greetingVersion", "ensureLocale"])
            let capability: String = try c.value("capability")
            let profiles: [String] = try c.value("supportedProfiles")
            let name: String = try c.value("displayName")
            let roomName: String = try c.value("roomName")
            let position = try c.integer("teamDmPosition")
            let lazy: Bool = try c.value("lazyCreation")
            let funding: String = try c.value("fundingKind")
            let price: Bool = try c.value("separatePrice")
            guard version == 4, profile == "atum.company-private-cos/1.3", wire.value == "1.3",
                  capability == "company.private-cos", profiles == ["atum.company-private-cos/1",
                    "atum.company-private-cos/1.1", "atum.company-private-cos/1.2", "atum.company-private-cos/1.3"],
                  name == "Chief of Staff", roomName == name, position == 2, lazy,
                  funding == "company_wallet", !price else { throw ContractViolation.invalidValue }
            displayName = name
        }
        let roomType: String = try c.value("roomType")
        let encrypted: Bool = try c.value("roomEncrypted")
        let greeting = try c.integer("greetingVersion")
        let locale: Bool = try c.value("ensureLocale")
        let purge = try c.integer("purgeAfterDays")
        let export: Bool = try c.value("userExport")
        guard roomType == "io.atum.assistant", !encrypted, greeting == 2, locale, purge == 30, !export
        else { throw ContractViolation.invalidValue }
    }

    private struct Wire: Decodable {
        let header, value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["header", "value"])
            header = try c.value("header"); value = try c.value("value")
        }
    }
    private struct Execution: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["profile", "runtime", "toolProfile", "promptSchemaSnapshot", "deltaStreaming"])
            let profile: String = try c.value("profile")
            let runtime: String = try c.value("runtime")
            let tool: String = try c.value("toolProfile")
            let snapshot: String = try c.value("promptSchemaSnapshot")
            let streaming: Bool = try c.value("deltaStreaming")
            guard profile == "atum.company-agent/1", runtime == "cloud_agent", tool == "peer",
                  snapshot == "conversation_epoch", !streaming else { throw ContractViolation.invalidValue }
        }
    }
}

@MainActor public protocol CompanyPrivateCosAPI: AnyObject {
    func companyPrivateCosCapability() async throws -> CompanyPrivateCosCapability
    func companyPrivateCosView(companyID: NativeID) async throws -> CompanyPrivateCosView
    /// `POST /companies/{id}/private-cos` (frozen v1 ensure; 200 bound, 202 v1.1 preparing).
    func ensureCompanyPrivateCos(companyID: NativeID,
                                 request: CompanyPrivateCosEnsureRequest) async throws -> CompanyPrivateCosView
}

public extension CompanyPrivateCosAPI {
    /// A read-only consumer (a test double) has no ensure: it is "not available".
    func ensureCompanyPrivateCos(companyID: NativeID,
                                 request: CompanyPrivateCosEnsureRequest) async throws -> CompanyPrivateCosView {
        throw CompanyAPIError.unavailable
    }
}

/// The frozen v1 ensure body (`lazy-first-open.ensure.request.json`). The
/// request ID is kept across a retry of the same trigger, so a lost answer
/// replays instead of provisioning twice.
public struct CompanyPrivateCosEnsureRequest: Encodable, Equatable, Sendable {
    public enum Trigger: String, Encodable, Sendable {
        case dmOpen = "dm_open"
        case firstCompanyVisit = "first_company_visit"
    }
    public let schemaVersion = 1
    public let requestId: NativeID
    public let action = "ensure"
    public let trigger: Trigger
    /// 1.3 only: `en`, `vi`, `ja`, `zh`, `zh-hant`.
    public let locale: String?

    public init(requestId: NativeID, trigger: Trigger, locale: String? = nil) {
        self.requestId = requestId
        self.trigger = trigger
        self.locale = locale.flatMap { Self.locales.contains($0) ? $0 : nil }
    }

    public static let locales: Set<String> = ["en", "vi", "ja", "zh", "zh-hant"]

    private enum CodingKeys: String, CodingKey { case schemaVersion, requestId, action, trigger, locale }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(action, forKey: .action)
        try c.encode(trigger, forKey: .trigger)
        try c.encodeIfPresent(locale, forKey: .locale)
    }
}

/// What the phone knows about one company's private Chief of Staff, as the
/// desktop's `private-cos-store.ts` keeps it: the last strict view the platform
/// served, its availability, and the ensure request a retry replays.
public struct CompanyPrivateCosState: Equatable, Sendable {
    public enum Availability: Equatable, Sendable { case preparing, ready, paused, unavailable }

    public var view: CompanyPrivateCosView
    public var availability: Availability
    public var loading: Bool
    public var ensureRequestID: String?
    public var ensureTrigger: CompanyPrivateCosEnsureRequest.Trigger?

    public init(view: CompanyPrivateCosView, loading: Bool = false) {
        self.view = view
        availability = view.state == "ready" && view.binding != nil ? .ready : .preparing
        self.loading = loading
    }

    /// A served view replaces the last one; the ensure request stays only for the same pair.
    public mutating func served(_ next: CompanyPrivateCosView) {
        if next.pair != view.pair { ensureRequestID = nil; ensureTrigger = nil }
        view = next
        availability = next.state == "ready" && next.binding != nil ? .ready : .preparing
        loading = false
    }

    /// A read or ensure that failed but did not end the scope.
    public mutating func failed(_ error: Error) {
        loading = false
        availability = CompanyPrivateCosRowProjection.isPause(error) ? .paused : .unavailable
    }

    public var isUncreated: Bool { view.state == "uncreated" }
    public var roomID: String? { view.state == "ready" ? view.binding?.roomId : nil }
}

/// The desktop's discovery state before a strict view is served.
public enum CompanyPrivateCosDiscovery: Equatable, Sendable {
    case checking
    case notAvailable
}

/// The one honest line a Chief of Staff row shows (desktop
/// `companyPrivateCosRowStatus`, `team-space/conversation-sections.tsx:118–136`).
public enum CompanyPrivateCosRowStatus: Equatable, Sendable {
    case settingUp
    case ready
    case paused
    case notAvailable

    /// Not available and paused offer Retry (the ensure route).
    public var offersRetry: Bool { self == .notAvailable || self == .paused }
}

public enum CompanyPrivateCosRowProjection {
    /// No served view: still asking (setting up) or asked and nothing usable came back.
    public static func status(state: CompanyPrivateCosState?,
                              discovery: CompanyPrivateCosDiscovery?) -> CompanyPrivateCosRowStatus {
        guard let state else { return discovery == .notAvailable ? .notAvailable : .settingUp }
        if state.loading { return .settingUp }
        switch state.availability {
        case .ready: return .ready
        case .preparing: return .settingUp
        case .paused: return .paused
        case .unavailable: return .notAvailable
        }
    }

    /// The platform's pause reasons (desktop `private-cos-store.ts`).
    public static func isPause(_ error: Error) -> Bool {
        guard case let .refused(_, reason, _)? = error as? CompanyAPIError, let reason else { return false }
        return ["budget_exhausted", "ai_disabled", "stopped"].contains(reason)
    }

    /// A refusal that ends the served row: the member, company or wire no longer admits it.
    public static func endsScope(_ error: Error) -> Bool {
        if error is CompanyWireRefusal { return true }
        switch error as? CompanyAPIError {
        case .refused(.authentication, _, _)?, .refused(.denied, _, _)?, .refused(.missing, _, _)?,
             .refused(.invalid, _, _)?, .invalid?:
            return true
        default:
            return false
        }
    }
}

/// In-memory positive bindings only. An empty or failed read supplies no
/// negative classification. Account replacement, company removal, and a new
/// membership incarnation end the old binding's scope.
public struct CompanyPrivateCosBindings: Equatable, Sendable {
    public private(set) var accountID: String?
    public private(set) var views: [String: CompanyPrivateCosView] = [:]
    public init() {}

    public mutating func beginAccount(_ id: String?) {
        guard accountID != id else { return }
        accountID = id
        views.removeAll()
    }
    public mutating func retain(companies: Set<String>) {
        views = views.filter { companies.contains($0.key) }
    }
    public mutating func apply(_ view: CompanyPrivateCosView, companyID: String, accountID: String) {
        guard self.accountID == accountID, view.pair.companyPrincipal.rawValue == companyID else { return }
        if let previous = views[companyID], previous.pair != view.pair {
            views[companyID] = nil
        }
        // An uncreated/async response does not prove a previously bound room personal.
        if view.binding != nil { views[companyID] = view }
    }
    public var roomIDs: Set<String> { Set(views.values.compactMap { $0.binding?.roomId }) }
    public var agentUserIDs: Set<String> { Set(views.values.compactMap { $0.binding?.agentUserId }) }
    public var agentPrincipals: Set<String> { Set(views.values.compactMap { $0.binding?.agentPrincipal.rawValue }) }
    public func companyID(owning roomID: String) -> String? {
        views.first { $0.value.binding?.roomId == roomID }?.key
    }
}
