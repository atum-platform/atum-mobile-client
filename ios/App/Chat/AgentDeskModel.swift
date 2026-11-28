import AtumNativeAPI
import Foundation
import Observation

/// The agent's desk's host state (W4-E3, desktop #51 `useOwnFiles` and
/// `useAgentSchedule`): its routines with their switches, and one folder of its
/// own files at a time. The page draws it; every host call goes through
/// `AgentDeskActions`, which checks the account, agent and Hermes runtime
/// before each send.
///
/// - Files: a folder is shown only once its listing arrives (the shown path and
///   its rows never disagree). The Shell admits one `files` read per agent every
///   10 s (platform migration 0471), so a busy reply is asked again after the
///   cooldown while that folder is still the one asked for. Confirmed listings
///   are kept for Back.
/// - Controls: one at a time, as the room mutation queue serializes a room
///   field (`RoomMutationQueue.swift:8`): every schedule switch is disabled
///   while one settles, so Pause and the routines reach the host in order. A
///   refusal undoes only what that control moved; an ambiguous failure reads
///   the host's schedule again.
@MainActor
@Observable
final class AgentDeskModel {
    enum Problem: Equatable { case failed, stopped }
    enum SectionState: Equatable { case unsupported, loading, empty, ready, failed, retrying }

    private(set) var jobs: [HostAgentDesk.Job]?
    private(set) var problem: Problem?
    private(set) var scheduleState: SectionState
    private(set) var filesState: SectionState
    /// A control is on its way to the host: every schedule switch waits.
    private(set) var controlPending = false
    /// The folder whose listing is shown (nil: the agent's home).
    private(set) var ownPath: String?
    private(set) var ownView: HostAgentDesk.Files?
    /// The folder asked for, including the target of a failed read until it is retried or replaced.
    private(set) var ownTarget: String?

    private let actions: AgentDeskActions
    private let readRetryDelay: Duration
    private let controlRetryDelay: Duration
    @ObservationIgnored private var ownCache: [String: HostAgentDesk.Files] = [:]
    @ObservationIgnored private var ownTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(actions: AgentDeskActions,
         readRetryDelay: Duration = HostAgentDesk.readRetryDelay,
         controlRetryDelay: Duration = HostAgentDesk.controlRetryDelay) {
        self.actions = actions
        self.readRetryDelay = readRetryDelay
        self.controlRetryDelay = controlRetryDelay
        scheduleState = actions.schedule == nil ? .unsupported : .loading
        filesState = actions.files == nil ? .unsupported : .loading
    }

    var showsPause: Bool { actions.schedule != nil && actions.control != nil }
    var controlsDisabled: Bool { controlPending || !showsPause || scheduleState != .ready }

    // MARK: Lifecycle

    func appear() {
        guard !started else { return }
        started = true
        startScheduleRead()
        load(ownPath)
    }

    /// The desk left the screen: nothing it started is sent any more, not even
    /// a control's delayed retry (desktop skips the retry after unmount).
    func disappear() {
        started = false
        scheduleTask?.cancel()
        scheduleTask = nil
        ownTask?.cancel()
        ownTask = nil
        ownTarget = ownPath
        if let controlTask {
            controlTask.cancel()
            self.controlTask = nil
            controlPending = false
            scheduleState = .loading
        }
    }

    // MARK: Files

    func open(_ path: String?) {
        // The same folder already on its way keeps its place in the cooldown.
        if ownTask != nil, path == ownTarget { return }
        load(path)
    }

    func back() {
        guard started else { return }
        let path = HostAgentDesk.parent(of: ownPath)
        if let cached = ownCache[Self.key(path)] {
            ownTask?.cancel()
            ownTask = nil
            ownTarget = path
            ownPath = path
            ownView = cached
            filesState = cached.rows.isEmpty ? .empty : .ready
        } else {
            open(path)
        }
    }

    func retryFiles() {
        guard started, filesState == .failed else { return }
        load(ownTarget, retrying: true)
    }

    private func load(_ path: String?, retrying: Bool = false) {
        guard started, actions.files != nil else { return }
        ownTask?.cancel()
        ownTarget = path
        filesState = retrying ? .retrying : .loading
        ownTask = Task { [weak self] in await self?.listFolder(path) }
    }

    private func listFolder(_ path: String?) async {
        guard let list = actions.files else { return }
        while !Task.isCancelled {
            let outcome = await list(path)
            guard !Task.isCancelled, ownTarget == path else { return }
            switch outcome {
            case let .listed(files):
                ownCache[Self.key(path)] = files
                ownPath = path
                ownView = files
                filesState = files.rows.isEmpty ? .empty : .ready
                ownTask = nil
                return
            case .busy:
                do { try await Task.sleep(for: readRetryDelay) } catch { return }
            case .failed:
                // A failed navigation keeps the confirmed folder and retries the requested one.
                if path == nil, ownPath == nil { ownView = nil }
                filesState = .failed
                ownTask = nil
                return
            case .cancelled:
                ownTask = nil
                return
            }
        }
    }

    private static func key(_ path: String?) -> String { path ?? "" }

    // MARK: Schedule

    func retrySchedule() {
        guard started, scheduleState == .failed, !controlPending else { return }
        startScheduleRead(retrying: true)
    }

    private func startScheduleRead(retrying: Bool = false) {
        guard actions.schedule != nil else { return }
        scheduleTask?.cancel()
        scheduleState = retrying ? .retrying : .loading
        scheduleTask = Task { [weak self] in await self?.readSchedule(clearingProblem: retrying) }
    }

    /// An entry or reconciliation read can land inside the host's cooldown.
    /// A successful manual retry clears the earlier control failure.
    private func readSchedule(clearingProblem: Bool = false) async {
        guard let read = actions.schedule else { return }
        for attempt in 0...1 {
            guard !Task.isCancelled else { return }
            do {
                guard let schedule = try await read(), !Task.isCancelled else { return }
                jobs = schedule.jobs
                scheduleState = schedule.jobs.isEmpty ? .empty : .ready
                if clearingProblem { problem = nil }
                return
            } catch is HostAgentDesk.ReadBusy where attempt == 0 {
                do { try await Task.sleep(for: readRetryDelay) } catch { return }
            } catch {
                if !Task.isCancelled { scheduleState = .failed }
                return
            }
        }
    }

    /// Optimistic: the switch moves at once and rolls back if the host refuses
    /// or changes nothing; a busy reply (the shared cooldown) is retried once.
    func run(_ control: HostAgentDesk.Control) {
        guard started, !controlsDisabled, let send = actions.control, let before = jobs else { return }
        // An entry read from a previous schedule must not overwrite this control.
        scheduleTask?.cancel()
        problem = nil
        controlPending = true
        jobs = HostAgentDesk.optimistic(control, before)
        controlTask = Task { [weak self] in
            var retried = false
            while true {
                guard !Task.isCancelled else { return }
                let outcome = await send(control)
                guard !Task.isCancelled, let self else { return }
                switch HostAgentDesk.resolve(outcome, for: control, retried: retried) {
                case .keep:
                    break
                case .rollBack:
                    self.undo(control, before)
                case .rollBackStopped:
                    self.undo(control, before)
                    self.problem = .stopped
                case .rollBackFailed:
                    self.problem = .failed
                    // It may have reached the host: the host's schedule decides.
                    if outcome == .failed {
                        self.scheduleState = .loading
                        await self.readSchedule()
                    } else {
                        self.undo(control, before)
                    }
                case .retryAfterCooldown:
                    retried = true
                    do { try await Task.sleep(for: self.controlRetryDelay) } catch { return }
                    continue
                }
                guard !Task.isCancelled else { return }
                self.controlPending = false
                self.controlTask = nil
                return
            }
        }
    }

    private func undo(_ control: HostAgentDesk.Control, _ before: [HostAgentDesk.Job]) {
        guard let jobs else { return }
        self.jobs = HostAgentDesk.rollBack(control, from: before, in: jobs)
    }
}
