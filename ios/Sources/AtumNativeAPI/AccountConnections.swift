import Foundation

/// `atum.account-connections/1` (atum-platform `spec/account-connections/v1`,
/// `packages/protocol/src/account-connections`): the one account-scoped list of
/// what the owner has connected and where each connection can run. The phone
/// reads it with the request the desktop sends
/// (`apps/desktop/electron/work/surface/account-connections.ts`):
/// `POST /api/matrix/v1/device-services` with `{"operation":"account_connections_read"}`.
/// Shell derives the owner from the signed-in session; the body names nothing.
///
/// Device-held plans are facts ("a Mac has Claude signed in, these model
/// names"). No token, login or e-mail is ever part of it. Read as strictly as
/// the desktop's zod schema (`shared/account-connections.ts`): an answer that
/// does not parse is not shown, never partly shown.
public enum AccountConnectionsContract {
    public static let profile = "atum.account-connections/1"
    public static let operation = "account_connections_read"
    /// The request body, exactly.
    public static let requestBody = Data(#"{"operation":"account_connections_read"}"#.utf8)
    /// The desktop's bound for every device-services reply.
    public static let maximumResponseBytes = 256 * 1024
}

/// How a registry read may authorize. `.poll` is a follow-up read that may
/// run while the app is leaving the foreground: it never rotates the grant.
public enum AccountConnectionsReadMode: Sendable, Equatable {
    case foreground, poll
}

/// The three plans in the order the desktop lists them (`ACCOUNT_PLANS`).
public enum AccountPlan: String, CaseIterable, Sendable, Hashable, Decodable {
    case codex, claude, antigravity

    init?(registryID: String) {
        self.init(rawValue: registryID == "claude-plan" ? "claude" : registryID)
    }

    public init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let plan = Self(registryID: id) else { throw ContractViolation.invalidValue }
        self = plan
    }

    /// Desktop's picker provider ID. Work relay operations use the plan's raw value.
    public var pickerID: String {
        switch self {
        case .codex: "openai-codex"
        case .claude: "claude-plan"
        case .antigravity: "antigravity"
        }
    }

    /// The maker's product name, the same in every language
    /// (`ACCOUNT_PLAN_NAMES`, never translated, hard-coded on desktop too).
    public var productName: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        }
    }
}

public enum AccountConnectionStatus: String, Sendable, Hashable, Decodable {
    case connected
    case needsAttention = "needs_attention"
    case notConnected = "not_connected"
}

public struct AccountConnectionModel: Equatable, Sendable, Decodable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "displayName"])
        id = try c.string("id", minimum: 1, maximum: 200, pattern: "[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
        displayName = try AccountConnections.label(c.value("displayName"), maximum: 200)
    }
}

/// One Mac a plan is signed in on. `stale`: the platform has not heard from it
/// for 24 hours; its plan facts are the last known ones.
public struct AccountConnectionDevice: Equatable, Sendable, Decodable {
    public let deviceServiceID: String
    public let displayName: String
    public let stale: Bool
    public let observedAt: Int64

    public init(deviceServiceID: String, displayName: String, stale: Bool, observedAt: Int64) {
        self.deviceServiceID = deviceServiceID
        self.displayName = displayName
        self.stale = stale
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["deviceServiceId", "displayName", "status", "observedAt"])
        deviceServiceID = try c.string("deviceServiceId", minimum: 36, maximum: 36,
                                       pattern: AccountConnections.uuidPattern)
        displayName = try AccountConnections.label(c.value("displayName"), maximum: 128)
        switch try c.value("status", as: String.self) {
        case "connected": stale = false
        case "stale": stale = true
        default: throw ContractViolation.invalidValue
        }
        // The desktop validates a JavaScript number, including integral decimals.
        let number = try c.value("observedAt", as: Double.self)
        guard let timestamp = Int64(exactly: number), (0...NativeAPI.maximumInteger).contains(timestamp)
        else { throw ContractViolation.invalidValue }
        observedAt = timestamp
    }
}

public struct AccountConnection: Equatable, Sendable, Decodable {
    public enum Kind: String, Sendable, Hashable, Decodable {
        case plan, apiKey, integration, tools, app
    }

    /// `codex`, `claude` (also `claude-plan`), `antigravity`, `opencode_go`, `google`, `owner_chats`,
    /// `drive`, `home_hub:<name>` or `app:<slug>`; always equal to its provider.
    public let id: String
    public let kind: Kind
    public let status: AccountConnectionStatus
    /// The plan this row is, for `kind == .plan`.
    public let plan: AccountPlan?
    /// A plan's Macs (empty for a cloud row).
    public let devices: [AccountConnectionDevice]
    public let models: [AccountConnectionModel]

    public init(id: String, kind: Kind, status: AccountConnectionStatus,
                devices: [AccountConnectionDevice] = [], models: [AccountConnectionModel] = []) {
        self.id = id
        self.kind = kind
        self.status = status
        self.plan = kind == .plan ? AccountPlan(registryID: id) : nil
        self.devices = devices
        self.models = models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        id = try c.value("id")
        let provider: String = try c.value("provider")
        kind = try c.value("kind")
        status = try c.value("status")
        _ = try c.value("reach", as: Reach.self)
        if kind == .plan {
            try c.closed(["id", "kind", "provider", "custody", "status", "devices", "models", "reach"])
            guard let plan = AccountPlan(registryID: id), try c.value("custody", as: String.self) == "device"
            else { throw ContractViolation.invalidValue }
            guard AccountPlan(registryID: provider) == plan else { throw ContractViolation.invariant }
            self.plan = plan
            devices = try c.value("devices")
            models = try c.value("models")
        } else {
            try c.closed(["id", "kind", "provider", "custody", "status", "models", "reach"])
            guard provider == id else { throw ContractViolation.invariant }
            guard Self.isCloudID(id), try c.value("custody", as: String.self) == "cloud"
            else { throw ContractViolation.invalidValue }
            plan = nil
            devices = []
            models = try c.optional("models") ?? []
        }
    }

    /// Where a usable connection reaches. Validated, not shown: every row's
    /// `agents` is "all", and Work consent and live route checks stay in force.
    private struct Reach: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["chat", "work", "agents"])
            guard ["direct", "relay", "none"].contains(try c.value("chat", as: String.self)),
                  ["native", "none"].contains(try c.value("work", as: String.self)),
                  try c.value("agents", as: String.self) == "all"
            else { throw ContractViolation.invalidValue }
        }
    }

    private static func isCloudID(_ id: String) -> Bool {
        if ["opencode_go", "google", "owner_chats", "drive"].contains(id) { return true }
        if id.range(of: #"\Ahome_hub:[a-z0-9][a-z0-9-]{0,62}\z"#, options: .regularExpression) != nil { return true }
        return id.range(of: #"\Aapp:[a-z0-9][a-z0-9-]{1,62}\z"#, options: .regularExpression) != nil
    }
}

public struct AccountConnections: Equatable, Sendable, Decodable {
    public let connections: [AccountConnection]

    public init(connections: [AccountConnection]) {
        self.connections = connections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "connections"])
        guard try c.value("profile", as: String.self) == AccountConnectionsContract.profile else {
            throw ContractViolation.invalidValue
        }
        connections = try c.value("connections")
    }

    static let uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

    /// A display label: no `@` (never an address) and no control character.
    static func label(_ value: String, maximum: Int) throws -> String {
        guard (1...maximum).contains(value.utf16.count),
              value.range(of: #"\A[^@\p{Cc}]+\z"#, options: .regularExpression) != nil
        else { throw ContractViolation.invalidValue }
        return value
    }
}
