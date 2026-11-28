import Foundation
import Observation

/// Which picks the account's connected-plan catalog offers on the phone.
/// The owner write checks assistant and plan authorization on the server.
public enum WorkModelEligibility: Equatable, Sendable {
    case unknown
    case known(Set<WorkModelSelection>)

    public func allows(_ selection: WorkModelSelection) -> Bool {
        guard case let .known(models) = self else { return false }
        return models.contains(selection)
    }
}

public struct PhoneModelPickerWorkSelectionState: Equatable, Sendable {
    public enum SaveFailure: Equatable, Sendable { case conflict, other }
    public enum SaveState: Equatable, Sendable {
        case idle
        case saving(WorkModelSelection)
        case failed(SaveFailure)
    }

    public fileprivate(set) var snapshot: WorkModelSelectionSnapshot?
    public fileprivate(set) var readState: PhoneModelPickerReadState = .unavailable
    public fileprivate(set) var saveState: SaveState = .idle
    public fileprivate(set) var eligibility: WorkModelEligibility = .unknown

    public var readySnapshot: WorkModelSelectionSnapshot? {
        readState == .ready ? snapshot : nil
    }
}

/// The two owner calls a Work picker makes. The app binds them to the live
/// `NativeDomainClient`; the scripted host binds synthetic answers for
/// captures. Nothing here can name another assistant than the one bound.
public struct WorkSelectionCalls {
    public typealias Read = @MainActor (NativeID, @escaping NativeDispatchGate) async throws
        -> WorkModelSelectionSnapshot
    public typealias Write = @MainActor (NativeID, WorkModelSelection, Int64, @escaping NativeDispatchGate) async throws
        -> WorkModelSelectionWriteResult

    let read: Read
    let write: Write

    public init(read: @escaping Read, write: @escaping Write) {
        self.read = read
        self.write = write
    }

    @MainActor public init(client: NativeDomainClient) {
        read = { agent, isCurrent in try await client.workSelection(agentPrincipal: agent, isCurrent: isCurrent) }
        write = { agent, selection, revision, isCurrent in
            try await client.setWorkSelection(agentPrincipal: agent, selection: selection,
                                              expectedRevision: revision, isCurrent: isCurrent)
        }
    }
}

/// One picker's Work state for a single assistant and live owner session.
/// A new pick supersedes the previous pick. The dispatch gate also covers
/// token refresh, when sending a previously valid pick can become unsafe.
@available(macOS 14.0, *)
@MainActor @Observable
public final class PhoneModelPickerWorkSelection {
    public let agentPrincipal: NativeID
    public var value: PhoneModelPickerWorkSelectionState? {
        guard scopeIsCurrent else { return nil }
        var value = state
        value.eligibility = eligibility
        return value
    }

    public var rows: [PhoneModelPickerProjection.WorkRow] {
        guard let value else { return [] }
        return PhoneModelPickerProjection.workRows(reported: account.value?.workPlanHandoffs ?? [], state: value)
    }

    private let calls: WorkSelectionCalls
    private let account: PhoneModelPickerAccount
    private let isCurrent: NativeDispatchGate
    private var state = PhoneModelPickerWorkSelectionState()
    private var retired = false
    @ObservationIgnored private var generation: UInt64 = 0

    private var scopeIsCurrent: Bool { !retired && isCurrent() }

    private var eligibility: WorkModelEligibility {
        guard let snapshot = account.value, snapshot.accountConnectionsState == .ready else { return .unknown }
        return .known(Set(snapshot.workPlanHandoffs.flatMap { handoff in
            handoff.models.compactMap { WorkModelSelection(plan: handoff.plan, model: $0.id) }
        }))
    }

    public convenience init(agentPrincipal: NativeID, client: NativeDomainClient,
                            account: PhoneModelPickerAccount, isCurrent: @escaping NativeDispatchGate) {
        self.init(agentPrincipal: agentPrincipal, calls: WorkSelectionCalls(client: client),
                  account: account, isCurrent: isCurrent)
    }

    public init(agentPrincipal: NativeID, calls: WorkSelectionCalls,
                account: PhoneModelPickerAccount, isCurrent: @escaping NativeDispatchGate) {
        self.agentPrincipal = agentPrincipal
        self.calls = calls
        self.account = account
        self.isCurrent = isCurrent
    }

    public func reload(within budget: PhoneModelPickerRead = .init()) async {
        guard scopeIsCurrent, !Task.isCancelled else { return }
        if case .saving = state.saveState { return }
        generation &+= 1
        _ = await readSnapshot(generation, within: budget)
    }

    public func save(_ choice: WorkModelSelection) async {
        guard scopeIsCurrent, !Task.isCancelled, eligibility.allows(choice) else { return }
        generation &+= 1
        let mine = generation
        state.saveState = .saving(choice)
        defer {
            if owns(mine), case .saving = state.saveState { state.saveState = .idle }
        }

        var base: WorkModelSelectionSnapshot
        if let ready = state.readySnapshot {
            base = ready
        } else {
            guard let first = await readSnapshot(mine, within: .init()) else {
                if owns(mine), !Task.isCancelled { state.saveState = .failed(.other) }
                return
            }
            base = first
        }

        let canWrite: NativeDispatchGate = {
            self.owns(mine) && self.eligibility.allows(choice)
        }
        for attempt in 0...1 {
            guard canWrite(), !Task.isCancelled else { return }
            let result: WorkModelSelectionWriteResult
            do {
                result = try await calls.write(agentPrincipal, choice, base.revision, canWrite)
            } catch {
                // The write might have landed before its reply was lost. Keep
                // the name but require readback before another write.
                guard owns(mine) else { return }
                state.readState = .failed
                if canWrite(), !Task.isCancelled { state.saveState = .failed(.other) }
                return
            }
            guard owns(mine) else { return }
            guard !Task.isCancelled else {
                state.readState = .failed
                return
            }
            if case let .saved(saved) = result {
                state.snapshot = saved
                state.readState = .ready
                return
            }

            // Read back the server's choice even after a second conflict.
            // Only the first conflict can earn a retry, against a newer revision.
            let latest = await readSnapshot(mine, within: .init())
            guard owns(mine), !Task.isCancelled else { return }
            if latest?.selection == choice { return }
            guard attempt == 0, let latest, latest.revision > base.revision, canWrite() else {
                state.saveState = .failed(.conflict)
                return
            }
            base = latest
        }
    }

    public func retire() { retired = true }

    private func owns(_ operation: UInt64) -> Bool {
        generation == operation && scopeIsCurrent
    }

    private func readSnapshot(_ operation: UInt64, within budget: PhoneModelPickerRead) async
        -> WorkModelSelectionSnapshot? {
        guard owns(operation), !Task.isCancelled else { return nil }
        state.readState = .loading
        let current: NativeDispatchGate = { self.owns(operation) }
        let answer = await budget.withinSource { () -> WorkModelSelectionSnapshot? in
            guard current() else { return nil }
            return try? await self.calls.read(self.agentPrincipal, current)
        }
        guard owns(operation) else { return nil }
        guard !Task.isCancelled else {
            state.readState = .unavailable
            return nil
        }
        guard let snapshot = answer ?? nil else {
            state.readState = .failed
            return nil
        }
        state.snapshot = snapshot
        state.readState = .ready
        return snapshot
    }
}
