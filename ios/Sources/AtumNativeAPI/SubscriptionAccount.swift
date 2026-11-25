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
/// phone draws. Each source reports its read state independently of its data.
public struct PhoneSubscriptionAccount: Equatable, Sendable {
    public fileprivate(set) var chatGPT: ChatGPTRelayStatus?
    public fileprivate(set) var openCodeGo: ProviderConnectionsStatus?
    /// The account's plans and where they run (`atum.account-connections/1`),
    /// for the picker's Connect entries.
    public fileprivate(set) var accountConnections: AccountConnections?
    public fileprivate(set) var chatGPTState: PhoneModelPickerReadState
    public fileprivate(set) var openCodeGoState: PhoneModelPickerReadState
    public fileprivate(set) var accountConnectionsState: PhoneModelPickerReadState

    /// Plan catalogs reported by Work on a Mac. A ChatGPT catalog already
    /// supplied by the cloud relay is shown through its own source.
    public var workPlanHandoffs: [PhoneModelPickerProjection.WorkPlanHandoff] {
        guard accountConnectionsState == .ready else { return [] }
        return AccountConnectionsView.planRows(accountConnections).compactMap { row in
            guard !row.offersConnect, !row.models.isEmpty,
                  row.plan != .codex || chatGPT?.state != .enabled else { return nil }
            return .init(plan: row.plan, models: row.models)
        }
    }

    public init(chatGPT: ChatGPTRelayStatus?, openCodeGo: ProviderConnectionsStatus?,
                accountConnections: AccountConnections? = nil) {
        self.chatGPT = chatGPT
        self.openCodeGo = openCodeGo
        self.accountConnections = accountConnections
        chatGPTState = chatGPT?.state == .enabled ? .ready : .unavailable
        openCodeGoState = openCodeGo?.state == .connected && openCodeGo?.models.isEmpty == false
            ? .ready : .unavailable
        accountConnectionsState = accountConnections == nil ? .unavailable : .ready
    }
}

public enum PhoneModelPickerReadState: Equatable, Sendable {
    case loading, ready, unavailable, failed
}

public enum PhoneModelPickerReadResult<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable
    case failed

    public var state: PhoneModelPickerReadState {
        switch self {
        case .value: .ready
        case .unavailable: .unavailable
        case .failed: .failed
        }
    }
}

/// A destination can name the saved model from cache while a new picker session
/// waits for its own readback. Only a settled read or write makes it actionable.
public struct PhoneModelPickerDestinationRead: Sendable {
    public private(set) var snapshot: ManagedModelDestinationSnapshot?
    public private(set) var state: PhoneModelPickerReadState

    public init(cached: ManagedModelDestinationSnapshot? = nil, canRead: Bool) {
        snapshot = cached
        state = canRead ? .loading : .unavailable
    }

    public var readySnapshot: ManagedModelDestinationSnapshot? {
        state == .ready ? snapshot : nil
    }

    public mutating func begin() { state = .loading }

    public mutating func settle(_ result: PhoneModelPickerReadResult<ManagedModelDestinationSnapshot>) {
        state = result.state
        if case let .value(value) = result { snapshot = value }
    }
}

/// A monotonic budget shared by the reads started on a single picker load.
public struct PhoneModelPickerRead: Sendable {
    private let now: @MainActor @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void
    private let sourceDeadline: ContinuousClock.Instant
    private let overallDeadline: ContinuousClock.Instant

    public init(sourceLimit: Duration = .seconds(4), overallLimit: Duration = .seconds(8)) {
        let clock = ContinuousClock()
        self.init(start: clock.now, sourceLimit: sourceLimit, overallLimit: overallLimit,
                  now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
    }

    init(start: ContinuousClock.Instant, sourceLimit: Duration, overallLimit: Duration,
         now: @escaping @MainActor @Sendable () -> ContinuousClock.Instant,
         sleepUntil: @escaping @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.now = now
        self.sleepUntil = sleepUntil
        overallDeadline = start.advanced(by: overallLimit)
        sourceDeadline = min(start.advanced(by: sourceLimit), overallDeadline)
    }

    @MainActor public func withinOverall<Value: Sendable>(
        _ read: @escaping @MainActor () async -> Value
    ) async -> Value? {
        await bounded(until: overallDeadline, read)
    }

    /// An expired budget is a failure. A retired scope settles as unavailable
    /// and cannot publish either a successful reply or a transport error.
    @MainActor public func scoped<Value: Sendable>(
        isCurrent: @escaping @MainActor () -> Bool,
        _ read: @escaping @MainActor () async -> PhoneModelPickerReadResult<Value>
    ) async -> PhoneModelPickerReadResult<Value> {
        guard !Task.isCancelled, isCurrent() else { return .unavailable }
        let result = await withinOverall(read) ?? .failed
        guard !Task.isCancelled, isCurrent() else { return .unavailable }
        return result
    }

    @MainActor fileprivate func withinSource<Value: Sendable>(
        _ read: @escaping @MainActor () async -> Value
    ) async -> Value? {
        await bounded(until: sourceDeadline, read)
    }

    @MainActor private func bounded<Value: Sendable>(
        until deadline: ContinuousClock.Instant, _ read: @escaping @MainActor () async -> Value
    ) async -> Value? {
        guard !Task.isCancelled, now() < deadline else { return nil }
        let (answers, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingOldest(1))
        // The first task to finish the stream wins. A buffered reply remains
        // available even if the caller resumes after the deadline.
        let request = Task {
            guard !Task.isCancelled else { return }
            let value = await read()
            guard !Task.isCancelled else { return }
            continuation.yield(value)
            continuation.finish()
        }
        let timer = Task {
            do { try await sleepUntil(deadline) } catch { return }
            continuation.finish()
        }
        defer {
            continuation.finish()
            request.cancel()
            timer.cancel()
        }
        for await answer in answers { return answer }
        return nil
    }
}

public struct PhoneSubscriptionAccountReads: Sendable {
    public let chatGPT: @MainActor @Sendable () async throws -> ChatGPTRelayStatus?
    public let openCodeGo: @MainActor @Sendable () async throws -> ProviderConnectionsStatus?
    public let accountConnections: @MainActor @Sendable () async throws -> AccountConnections?
    public let isCurrent: @MainActor @Sendable () -> Bool

    public init(chatGPT: @escaping @MainActor @Sendable () async throws -> ChatGPTRelayStatus?,
                openCodeGo: @escaping @MainActor @Sendable () async throws -> ProviderConnectionsStatus?,
                accountConnections: @escaping @MainActor @Sendable () async throws -> AccountConnections?,
                isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.chatGPT = chatGPT
        self.openCodeGo = openCodeGo
        self.accountConnections = accountConnections
        self.isCurrent = isCurrent
    }
}

/// Publishes each account source as it settles. A newer read or retirement
/// supersedes the whole load. A Connect landing supersedes only the registry.
@available(macOS 14.0, *)
@MainActor @Observable
public final class PhoneModelPickerAccount {
    public var value: PhoneSubscriptionAccount? {
        guard let published, isCurrentScope?() == true else { return nil }
        return published
    }
    private var published: PhoneSubscriptionAccount?
    @ObservationIgnored private var isCurrentScope: (@MainActor () -> Bool)?
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var registryGeneration = 0

    public init() {}

    public func reload(_ reads: PhoneSubscriptionAccountReads, within budget: PhoneModelPickerRead = .init()) async {
        guard reads.isCurrent(), !Task.isCancelled else { return }
        readGeneration += 1
        let mine = readGeneration
        let registryMine = registryGeneration
        var loading = value ?? PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil)
        loading.chatGPTState = .loading
        loading.openCodeGoState = .loading
        loading.accountConnectionsState = .loading
        isCurrentScope = reads.isCurrent
        published = loading

        let current: @MainActor () -> Bool = { mine == self.readGeneration && reads.isCurrent() }
        async let chatGPT: Void = settle(reads.chatGPT, within: budget, isCurrent: current,
                                         data: \.chatGPT, state: \.chatGPTState) {
            $0.state == .enabled
        }
        async let openCodeGo: Void = settle(reads.openCodeGo, within: budget, isCurrent: current,
                                            data: \.openCodeGo, state: \.openCodeGoState) {
            $0.state == .connected && !$0.models.isEmpty
        }
        async let registry: Void = settle(reads.accountConnections, within: budget, isCurrent: {
            current() && registryMine == self.registryGeneration
        }, data: \.accountConnections, state: \.accountConnectionsState) { _ in true }
        _ = await (chatGPT, openCodeGo, registry)
        if mine == readGeneration, Task.isCancelled || !current() { retire(keepingSettled: true) }
    }

    private func settle<Value: Sendable>(
        _ read: @escaping @MainActor () async throws -> Value?, within budget: PhoneModelPickerRead,
        isCurrent: @escaping @MainActor () -> Bool,
        data: WritableKeyPath<PhoneSubscriptionAccount, Value?>,
        state: WritableKeyPath<PhoneSubscriptionAccount, PhoneModelPickerReadState>,
        isAvailable: (Value) -> Bool
    ) async {
        guard isCurrent() else { return }
        let result = await budget.withinSource {
            guard isCurrent() else { return Result<Value?, Error>.success(nil) }
            do { return Result<Value?, Error>.success(try await read()) }
            catch { return .failure(error) }
        }
        guard !Task.isCancelled, isCurrent(), var next = value else { return }
        switch result {
        case let .success(answer)?:
            next[keyPath: data] = answer
            next[keyPath: state] = answer.map(isAvailable) == true ? .ready : .unavailable
        case .failure?, nil:
            next[keyPath: data] = nil
            next[keyPath: state] = .failed
        }
        published = next
    }

    public func landed(_ registry: AccountConnections) {
        guard var next = value else { return }
        registryGeneration += 1
        next.accountConnections = registry
        next.accountConnectionsState = .ready
        published = next
    }

    public func retire(keepingSettled: Bool = false) {
        readGeneration += 1
        registryGeneration += 1
        guard keepingSettled, var next = value else {
            isCurrentScope = nil
            published = nil
            return
        }
        // The composer can keep the picker catalog for naming its saved model.
        // A source that was still loading cannot answer for the closed picker.
        if next.chatGPTState == .loading {
            next.chatGPT = nil
            next.chatGPTState = .unavailable
        }
        if next.openCodeGoState == .loading {
            next.openCodeGo = nil
            next.openCodeGoState = .unavailable
        }
        if next.accountConnectionsState == .loading {
            next.accountConnections = nil
            next.accountConnectionsState = .unavailable
        }
        published = next
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
