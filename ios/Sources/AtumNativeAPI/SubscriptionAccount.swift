import Foundation
import Observation

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
    /// The account's plans and where they run (`atum.account-connections/1`),
    /// for the picker's Connect entries. nil: not read, or unreadable.
    public let accountConnections: AccountConnections?

    public init(chatGPT: ChatGPTRelayStatus?, openCodeGo: ProviderConnectionsStatus?,
                accountConnections: AccountConnections? = nil) {
        self.chatGPT = chatGPT
        self.openCodeGo = openCodeGo
        self.accountConnections = accountConnections
    }
}

/// Orders subscription reads and Connect sheet landings for one picker.
/// A newer read (or retirement) drops an older read whole. A landing only
/// supersedes the registry: the read's ChatGPT and OpenCode Go statuses come
/// from independent endpoints and still apply, so a plan disconnected
/// elsewhere stops being offered even if a sheet landed meanwhile.
@available(macOS 14.0, *)
@MainActor @Observable
public final class PhoneModelPickerAccount {
    public private(set) var value: PhoneSubscriptionAccount?
    public private(set) var loading = false
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var registryGeneration = 0

    public init() {}

    public func reload(_ read: @MainActor () async -> PhoneSubscriptionAccount) async {
        readGeneration += 1
        let mine = readGeneration
        let registryMine = registryGeneration
        loading = true
        defer { if mine == readGeneration { loading = false } }
        let answer = await read()
        guard !Task.isCancelled, mine == readGeneration else { return }
        let registry = registryMine == registryGeneration ? answer.accountConnections : value?.accountConnections
        value = PhoneSubscriptionAccount(chatGPT: answer.chatGPT, openCodeGo: answer.openCodeGo,
                                         accountConnections: registry)
    }

    public func landed(_ registry: AccountConnections) {
        registryGeneration += 1
        value = PhoneSubscriptionAccount(chatGPT: value?.chatGPT, openCodeGo: value?.openCodeGo,
                                         accountConnections: registry)
    }

    public func retire() {
        readGeneration += 1
        registryGeneration += 1
        loading = false
    }
}

/// One model a subscription serves, as both closed status shapes describe it.
public struct SubscriptionModelDescriptor: Decodable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let efforts: [ManagedModelEffort]
    public let defaultEffort: ManagedModelEffort?
    private let usesDefaultOnly: Bool
    public let contextBudget: Int64
    public let outputBudget: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "displayName", "efforts", "defaultEffort", "contextBudget", "outputBudget"])
        id = try c.string("id", minimum: 1, maximum: 200, pattern: "[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
        displayName = try c.string("displayName", minimum: 1, maximum: 120)
        let levels: LossyDecodableArray<ManagedModelEffort> = try c.value("efforts")
        var seen = Set<ManagedModelEffort>()
        efforts = levels.elements.filter { seen.insert($0).inserted }
        usesDefaultOnly = levels.sourceCount == 0
        defaultEffort = try ManagedModelEffort(wireID: c.value("defaultEffort"))
        contextBudget = try c.integer("contextBudget", minimum: 1)
        outputBudget = try c.integer("outputBudget", minimum: 1)
    }

    /// The level a pick writes: the model's default when it accepts it (or
    /// lists no levels, where the server accepts only its default), else the
    /// first listed level the destination write profile accepts.
    public var writeEffort: ManagedModelEffort? {
        if let defaultEffort,
           defaultEffort.isDestinationWriteEffort,
           usesDefaultOnly || efforts.contains(defaultEffort) {
            return defaultEffort
        }
        return efforts.first(where: \.isDestinationWriteEffort)
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
