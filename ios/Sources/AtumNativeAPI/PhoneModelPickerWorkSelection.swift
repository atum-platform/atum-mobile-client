import Foundation
import Observation
import os

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
    public fileprivate(set) var planEligibility: WorkPlanEligibilitySnapshot?

    public var readySnapshot: WorkModelSelectionSnapshot? {
        readState == .ready ? snapshot : nil
    }

    public var eligibility: WorkModelEligibility {
        guard planEligibility != nil else { return .unknown }
        return .known(Set(selectableModels.map(\.choice)))
    }

    var selectableModels: [(choice: WorkModelSelection, name: String)] {
        (planEligibility?.plans ?? []).flatMap { row -> [(WorkModelSelection, String)] in
            guard row.status == .selectable, let plan = AccountPlan(rawValue: row.plan) else { return [] }
            return row.models.compactMap { model in
                WorkModelSelection(plan: plan, model: model.id).map { ($0, model.displayName) }
            }
        }
    }
}

/// Orders in-flight intents per assistant across picker and client lifetimes.
@MainActor private final class WorkSelectionWriteQueue {
    private static var active: [NativeID: WorkSelectionWriteQueue] = [:]
    private var latest: UUID
    private var pending: CheckedContinuation<Bool, Never>?

    private init(latest: UUID) { self.latest = latest }

    static func run(for assistant: NativeID, onQueued: () -> Void,
                    _ work: (_ isLatest: @escaping NativeDispatchGate) async -> Void) async {
        let intent = UUID()
        let queue: WorkSelectionWriteQueue
        if let running = active[assistant] {
            queue = running
            queue.latest = intent
            onQueued()
            let promoted = await withCheckedContinuation { next in
                queue.pending?.resume(returning: false)
                queue.pending = next
            }
            guard promoted else { return }
        } else {
            queue = WorkSelectionWriteQueue(latest: intent)
            active[assistant] = queue
        }
        defer {
            if let next = queue.pending {
                queue.pending = nil
                next.resume(returning: true)
            } else {
                active[assistant] = nil
            }
        }
        guard queue.latest == intent, !Task.isCancelled else { return }
        await work { queue.latest == intent }
    }
}

/// Owner calls shared by the live client and the scripted picker.
public struct WorkSelectionCalls {
    public typealias Read = @MainActor (NativeID, NativeDispatchGate) async throws
        -> WorkModelSelectionSnapshot
    public typealias ReadEligibility = @MainActor (NativeID, NativeDispatchGate) async throws
        -> WorkPlanEligibilitySnapshot
    public typealias Write = @MainActor (NativeID, WorkModelSelection, Int64, NativeDispatchGate) async throws
        -> WorkModelSelectionWriteResult

    let read: Read
    let readEligibility: ReadEligibility
    let write: Write

    public init(read: @escaping Read, readEligibility: @escaping ReadEligibility, write: @escaping Write) {
        self.read = read
        self.readEligibility = readEligibility
        self.write = write
    }

    @MainActor public init(client: NativeDomainClient) {
        read = { agent, isCurrent in try await client.workSelection(agentPrincipal: agent, isCurrent: isCurrent) }
        readEligibility = { agent, isCurrent in
            try await client.workPlanEligibility(agentPrincipal: agent, isCurrent: isCurrent)
        }
        write = { agent, selection, revision, isCurrent in
            try await client.setWorkSelection(agentPrincipal: agent, selection: selection,
                                              expectedRevision: revision, isCurrent: isCurrent)
        }
    }
}

/// One picker's Work state for a single assistant and live owner session.
@available(macOS 14.0, *)
@MainActor @Observable
public final class PhoneModelPickerWorkSelection {
    public typealias ReadSelection = @MainActor (NativeDispatchGate) async throws -> WorkModelSelectionSnapshot
    public typealias ReadEligibility = @MainActor (NativeDispatchGate) async throws -> WorkPlanEligibilitySnapshot
    public typealias WriteSelection = @MainActor (WorkModelSelection, Int64, NativeDispatchGate) async throws
        -> WorkModelSelectionWriteResult

    public let agentPrincipal: NativeID
    public var value: PhoneModelPickerWorkSelectionState? { scopeIsCurrent ? state : nil }
    public var rows: [PhoneModelPickerProjection.WorkRow] { PhoneModelPickerProjection.workRows(state: value) }

    private let readSelection: ReadSelection
    private let readEligibility: ReadEligibility
    private let writeSelection: WriteSelection
    private let isCurrent: NativeDispatchGate
    private var state = PhoneModelPickerWorkSelectionState()
    private var retired = false
    @ObservationIgnored private var generation: UInt64 = 0

    private var scopeIsCurrent: Bool { !retired && isCurrent() }

    public convenience init(agentPrincipal: NativeID, client: NativeDomainClient,
                            isCurrent: @escaping NativeDispatchGate) {
        self.init(agentPrincipal: agentPrincipal, calls: WorkSelectionCalls(client: client), isCurrent: isCurrent)
    }

    public convenience init(agentPrincipal: NativeID, calls: WorkSelectionCalls,
                            isCurrent: @escaping NativeDispatchGate) {
        self.init(agentPrincipal: agentPrincipal,
                  readSelection: { try await calls.read(agentPrincipal, $0) },
                  readEligibility: { try await calls.readEligibility(agentPrincipal, $0) },
                  writeSelection: { selection, revision, current in
                      try await calls.write(agentPrincipal, selection, revision, current)
                  },
                  isCurrent: isCurrent)
    }

    public init(agentPrincipal: NativeID, readSelection: @escaping ReadSelection,
                readEligibility: @escaping ReadEligibility, writeSelection: @escaping WriteSelection,
                isCurrent: @escaping NativeDispatchGate) {
        self.agentPrincipal = agentPrincipal
        self.readSelection = readSelection
        self.readEligibility = readEligibility
        self.writeSelection = writeSelection
        self.isCurrent = isCurrent
    }

    public func reload(within budget: PhoneModelPickerRead = .init()) async {
        guard scopeIsCurrent, !Task.isCancelled else { return }
        if case .saving = state.saveState { return }
        generation &+= 1
        let current: NativeDispatchGate = { [mine = generation] in self.owns(mine) }
        state.planEligibility = nil
        async let selection = refreshSelection(within: budget, isCurrent: current)
        async let eligibility: Void = refreshEligibility(within: budget, isCurrent: current)
        _ = await (selection, eligibility)
    }

    public func save(_ choice: WorkModelSelection) async {
        guard scopeIsCurrent, !Task.isCancelled, state.eligibility.allows(choice) else { return }
        generation &+= 1
        let mine = generation
        state.saveState = .saving(choice)
        defer {
            if owns(mine), case .saving = state.saveState { state.saveState = .idle }
        }

        await WorkSelectionWriteQueue.run(for: agentPrincipal, onQueued: {
            // The prior write can change the revision before this pick runs.
            state.readState = .unavailable
        }) { isLatest in
            let current: NativeDispatchGate = { self.owns(mine) && isLatest() }
            defer {
                if self.owns(mine), !isLatest() { self.state.readState = .unavailable }
            }
            await self.performSave(choice, while: current)
        }
    }

    private func performSave(_ choice: WorkModelSelection, while current: @escaping NativeDispatchGate) async {
        var base: WorkModelSelectionSnapshot
        if let ready = state.readySnapshot {
            base = ready
        } else {
            guard let first = await refreshSelection(within: .init(), isCurrent: current) else {
                if current(), !Task.isCancelled { state.saveState = .failed(.other) }
                return
            }
            base = first
        }

        // A publication can expire while the picker is open.
        await refreshEligibility(within: .init(), isCurrent: current)
        let canWrite: NativeDispatchGate = { current() && self.state.eligibility.allows(choice) }
        if current(), state.planEligibility == nil, !Task.isCancelled {
            state.saveState = .failed(.other)
        }
        for attempt in 0...1 {
            guard canWrite(), !Task.isCancelled else { return }
            let result: WorkModelSelectionWriteResult
            do {
                let revision = base.revision
                // Keep the queue occupied until the transport settles, even
                // when a caller cancels or a newer pick withdraws retries.
                let cancelled = OSAllocatedUnfairLock(initialState: false)
                result = try await withTaskCancellationHandler {
                    try await Task { @MainActor in
                        try await self.writeSelection(choice, revision) {
                            canWrite() && !cancelled.withLock { $0 }
                        }
                    }.value
                } onCancel: {
                    cancelled.withLock { $0 = true }
                }
            } catch {
                guard current() else { return }
                state.readState = .failed
                if canWrite(), !Task.isCancelled { state.saveState = .failed(.other) }
                return
            }
            guard current() else { return }
            guard !Task.isCancelled else {
                state.readState = .failed
                return
            }
            if case let .saved(saved) = result {
                state.snapshot = saved
                state.readState = .ready
                return
            }

            guard attempt == 0 else {
                state.readState = .failed
                state.saveState = .failed(.conflict)
                return
            }
            let latest = await refreshSelection(within: .init(), isCurrent: current)
            guard current(), !Task.isCancelled else { return }
            if latest?.selection == choice { return }
            guard let latest, latest.revision > base.revision, canWrite() else {
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

    private func refreshSelection(within budget: PhoneModelPickerRead, isCurrent: @escaping NativeDispatchGate) async
        -> WorkModelSelectionSnapshot? {
        guard isCurrent(), !Task.isCancelled else { return nil }
        state.readState = .loading
        let answer = await budget.withinSource {
            try? await self.readSelection(isCurrent)
        } ?? nil
        guard isCurrent() else { return nil }
        guard !Task.isCancelled else {
            state.readState = .unavailable
            return nil
        }
        guard let snapshot = answer else {
            state.readState = .failed
            return nil
        }
        state.snapshot = snapshot
        state.readState = .ready
        return snapshot
    }

    private func refreshEligibility(within budget: PhoneModelPickerRead, isCurrent: @escaping NativeDispatchGate) async {
        guard isCurrent(), !Task.isCancelled else { return }
        let answer = await budget.withinSource {
            try? await self.readEligibility(isCurrent)
        } ?? nil
        guard isCurrent(), !Task.isCancelled else { return }
        state.planEligibility = answer
    }
}
