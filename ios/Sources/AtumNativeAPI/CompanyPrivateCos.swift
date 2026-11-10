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

/// Both frozen capability advertisements understood by this read-only consumer.
/// No execution, ensure, spend or stop methods are exposed.
public struct CompanyPrivateCosCapability: Decodable, Equatable, Sendable {
    public let profile: String

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
