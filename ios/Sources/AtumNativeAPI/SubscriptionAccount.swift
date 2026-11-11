import Foundation

// MARK: - The account's subscriptions, as the cloud can use them

/// What the cloud can run from the account's own subscriptions, read from the
/// two owner routes the desktop reads for a cloud assistant's picker
/// (`apps/desktop/electron/matrix/main.ts` `subscriptionsStatus`):
///
/// - `GET /api/matrix/v1/chatgpt-relay` (`atum.chatgpt-relay/1`): whether one
///   of the owner's Macs is relaying its signed-in ChatGPT plan to the cloud,
///   and the models it relays.
/// - `GET /api/matrix/v1/provider-connections` (`atum.provider-connections/1`):
///   the account-wide OpenCode Go connection and the models it serves.
///
/// Neither carries a credential, a device name or an account identifier the
/// phone draws. A route that could not be read is nil: the picker then keeps
/// the saved choice read-only rather than guessing a state.
public struct PhoneSubscriptionAccount: Equatable, Sendable {
    public let chatGPT: ChatGPTRelayStatus?
    public let openCodeGo: ProviderConnectionsStatus?

    public init(chatGPT: ChatGPTRelayStatus?, openCodeGo: ProviderConnectionsStatus?) {
        self.chatGPT = chatGPT
        self.openCodeGo = openCodeGo
    }
}

/// One model a subscription serves, as both closed status shapes describe it.
public struct SubscriptionModelDescriptor: Decodable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let efforts: [ManagedModelEffort]
    public let defaultEffort: ManagedModelEffort
    public let contextBudget: Int64
    public let outputBudget: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "displayName", "efforts", "defaultEffort", "contextBudget", "outputBudget"])
        id = try c.string("id", minimum: 1, maximum: 200, pattern: "[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        efforts = try c.value("efforts")
        guard efforts.count <= 3, Set(efforts).count == efforts.count else {
            throw ContractViolation.invalidValue
        }
        defaultEffort = try c.value("defaultEffort")
        contextBudget = try c.integer("contextBudget", minimum: 1)
        outputBudget = try c.integer("outputBudget", minimum: 1)
    }

    /// The level a pick writes: the model's default when it accepts it (or
    /// lists no levels, where the server accepts only its default), else the
    /// first level it lists. The platform refuses any other level
    /// (`0336_chatgpt_relay.sql`, `effort_unavailable`).
    public var writeEffort: ManagedModelEffort {
        efforts.isEmpty || efforts.contains(defaultEffort) ? defaultEffort : efforts[0]
    }
}

/// `atum.chatgpt-relay/1` status. Enabled means a Mac the owner chose relays
/// its ChatGPT plan, so cloud assistants can run these models now.
public struct ChatGPTRelayStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case disabled, enabled }

    public let revision: Int64
    public let state: State
    /// Empty unless enabled; an enabled relay always names at least one.
    public let models: [SubscriptionModelDescriptor]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("profile", as: String.self) == "atum.chatgpt-relay/1" else {
            throw ContractViolation.invalidValue
        }
        revision = try c.integer("revision")
        state = try c.value("state")
        models = try c.value("models")
        switch state {
        case .enabled:
            try c.closed(["profile", "revision", "state", "deviceServiceId", "selectedAt", "models"])
            _ = try c.value("deviceServiceId", as: NativeID.self)
            _ = try c.integer("selectedAt")
            guard revision >= 1, (1...64).contains(models.count) else { throw ContractViolation.invariant }
        case .disabled:
            try c.closed(["profile", "revision", "state", "models"])
            guard models.isEmpty else { throw ContractViolation.invariant }
        }
    }
}

/// `atum.provider-connections/1` status: exactly one `opencode_go` row.
public struct ProviderConnectionsStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case connected, disconnected }

    public let revision: Int64
    public let state: State
    /// The models the connection serves; only a connected one is usable.
    public let models: [SubscriptionModelDescriptor]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "revision", "connections"])
        guard try c.value("profile", as: String.self) == "atum.provider-connections/1" else {
            throw ContractViolation.invalidValue
        }
        revision = try c.integer("revision")
        let rows: [Connection] = try c.value("connections")
        guard rows.count == 1, rows[0].revision <= revision else { throw ContractViolation.invariant }
        state = rows[0].state
        models = rows[0].models
    }

    private struct Connection: Decodable {
        let state: State
        let revision: Int64
        let models: [SubscriptionModelDescriptor]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            guard try c.value("provider", as: String.self) == "opencode_go" else {
                throw ContractViolation.invalidValue
            }
            state = try c.value("state")
            revision = try c.integer("revision")
            models = try c.value("models")
            guard models.count <= 64 else { throw ContractViolation.invalidValue }
            let policy: String = try c.value("modelPolicy")
            switch state {
            case .connected:
                try c.closed(["provider", "state", "revision", "models", "modelPolicy",
                              "connectedAt", "keyVersion"])
                _ = try c.integer("connectedAt")
                let keyVersion = try c.integer("keyVersion", minimum: 1)
                guard policy == "subscription", keyVersion <= 2_147_483_647 else {
                    throw ContractViolation.invariant
                }
            case .disconnected:
                try c.closed(["provider", "state", "revision", "models", "modelPolicy"])
                guard policy == "none" else { throw ContractViolation.invariant }
            }
        }
    }
}
