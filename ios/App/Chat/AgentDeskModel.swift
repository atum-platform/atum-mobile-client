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

    private(set) var jobs: [HostAgentDesk.Job]?
    private(set) var problem: Problem?
    /// A control is on its way to the host: every schedule switch waits.
    private(set) var controlPending = false
    /// The folder whose listing is shown (nil: the agent's home).
    private(set) var ownPath: String?
    private(set) var ownView: HostAgentDesk.Files?
    /// The folder asked for, shown once its listing arrives.
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
    }

    var canControl: Bool { actions.control != nil && !(jobs ?? []).isEmpty }

    /// Desktop shows its own files only while the folder has rows or is a subfolder.
    var shownOwnView: HostAgentDesk.Files? {
        guard let ownView, !ownView.rows.isEmpty || ownPath != nil else { return nil }
        return ownView
    }

    // MARK: Lifecycle

    func appear() {
        guard !started else { return }
        started = true
        scheduleTask = Task { [weak self] in await self?.readSchedule() }
        load(ownPath)
    }

    /// The desk left the screen: nothing it started is sent any more, not even
    /// a control's delayed retry (desktop skips the retry after unmount).
    func disappear() {
        started = false
        scheduleTask?.cancel()
        ownTask?.cancel()
        ownTask = nil
        ownTarget = ownPath
        if let controlTask {
            controlTask.cancel()
            self.controlTask = nil
            controlPending = false
        }
    }

    // MARK: Files

    func open(_ path: String?) {
        // The same folder already on its way keeps its place in the cooldown.
        if ownTask != nil, path == ownTarget { return }
        if let cached = ownCache[Self.key(path)] {
            ownTask?.cancel()
            ownTask = nil
            ownTarget = path
            ownPath = path
            ownView = cached
            return
        }
        load(path)
    }

    func back() { open(HostAgentDesk.parent(of: ownPath)) }

    private func load(_ path: String?) {
        ownTask?.cancel()
        ownTarget = path
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
                ownTask = nil
                return
            case .busy:
                do { try await Task.sleep(for: readRetryDelay) } catch { return }
            case .cancelled, .failed:
                // A refused home reads as none; a cancelled read keeps the shown listing.
                if outcome == .failed, path == nil, ownPath == nil { ownView = nil }
                ownTarget = ownPath
                ownTask = nil
                return
            }
        }
    }

    private static func key(_ path: String?) -> String { path ?? "" }

    // MARK: Schedule

    private func readSchedule() async {
        guard let read = actions.schedule, let schedule = await read(), !Task.isCancelled else { return }
        jobs = schedule.jobs
    }

    /// Optimistic: the switch moves at once and rolls back if the host refuses
    /// or changes nothing; a busy reply (the shared cooldown) is retried once.
    func run(_ control: HostAgentDesk.Control) {
        guard !controlPending, let send = actions.control, let before = jobs else { return }
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
                    self.undo(control, before)
                    self.problem = .failed
                    // It may have reached the host: the host's schedule decides.
                    if outcome == .failed { await self.readSchedule() }
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
