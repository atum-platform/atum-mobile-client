import Foundation

/// Sync, send queues and the app's lifecycle for one Matrix session (plan
/// B9, B30, §2.8). The app's `SessionLifecycle` performs the actions; this
/// decides them, so the rules run in `swift test`.
///
/// - Foreground: start sync, wake every send queue, and on a return from the
///   background refresh the domain reads (agents, apps, store, wallet).
/// - Background: hold a short background task so pending sends can finish,
///   then stop sync. Coming back before the grace ends cancels the stop.
/// - Network regain: offline mode reports it as `offline` (or `error`) →
///   `running`; that wakes the send queues too, also during the background
///   grace (sync still runs then, and B9 sends "when the network returns").
///   No `NWPathMonitor`.
/// - The connection glyph (`wifi.slash`) shows only while sync is `offline`
///   or in `error`; never words in the transcript.
/// - Nothing starts sync or wakes queues while the session is not current
///   (the 300 s token expired): the app's keep-alive renews the runtime
///   first, and a queue woken with an expired token only parks its request
///   again (the hotfix's rule, `LiveAppModel.sceneBecameActive`).
public struct SessionLifecyclePolicy: Equatable, Sendable {
    /// How long pending sends get after the app leaves the foreground before
    /// sync stops. Well inside the system's background-task allowance; a
    /// device check (D7) confirms it.
    public static let backgroundGraceSeconds: TimeInterval = 8

    /// SwiftUI `ScenePhase`, as a plain value.
    public enum Phase: Equatable, Hashable, Sendable {
        case active
        case inactive
        case background
    }

    /// SDK `SyncServiceState` (`SDK:45153-45159`), as a plain value.
    public enum SyncState: Equatable, Hashable, Sendable {
        case idle
        case running
        case terminated
        case error
        case offline
    }

    public enum Event: Equatable, Hashable, Sendable {
        case scenePhase(Phase, sessionIsCurrent: Bool)
        case syncState(SyncState, sessionIsCurrent: Bool)
        /// The background grace scheduled by `.scheduleBackgroundStop` ended.
        case backgroundGraceElapsed
    }

    /// Why the send queues are woken; a closed log code.
    public enum WakeReason: String, Equatable, Hashable, Sendable {
        case foreground
        case syncRecovered = "sync_recovered"
    }

    public enum Action: Equatable, Hashable, Sendable {
        /// `SyncService.start()`.
        case startSync
        /// `SyncService.stop()`.
        case stopSync
        /// `Client.enableAllSendQueues(enable: true)`: resends what a network
        /// failure left behind, in order (B9).
        case wakeSendQueues(WakeReason)
        /// `UIApplication.beginBackgroundTask`.
        case beginBackgroundTask
        case endBackgroundTask
        /// Deliver `.backgroundGraceElapsed` after this many seconds.
        case scheduleBackgroundStop(after: TimeInterval)
        case cancelBackgroundStop
        /// Agents, apps, store and wallet, on every return to the foreground.
        case refreshDomainReads
    }

    /// Nil until the first scene phase arrives.
    public private(set) var phase: Phase?
    public private(set) var syncState: SyncState = .idle
    public private(set) var backgroundStopPending = false
    /// Set on entering the background and kept through `inactive` (iOS goes
    /// background → inactive → active on the way back).
    private var returningFromBackground = false

    public init() {}

    /// B30: the quiet `wifi.slash` glyph in the navigation bar.
    public var showsConnectionGlyph: Bool {
        syncState == .offline || syncState == .error
    }

    public mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case let .scenePhase(newPhase, sessionIsCurrent):
            return scene(newPhase, sessionIsCurrent: sessionIsCurrent)

        case let .syncState(newState, sessionIsCurrent):
            let previous = syncState
            syncState = newState
            guard newState == .running, previous == .offline || previous == .error,
                  sessionIsCurrent, phase != .background || backgroundStopPending else { return [] }
            return [.wakeSendQueues(.syncRecovered)]

        case .backgroundGraceElapsed:
            guard backgroundStopPending, phase == .background else { return [] }
            backgroundStopPending = false
            return [.stopSync, .endBackgroundTask]
        }
    }

    private mutating func scene(_ newPhase: Phase, sessionIsCurrent: Bool) -> [Action] {
        let previous = phase
        phase = newPhase
        guard newPhase != previous else { return [] }
        var actions: [Action] = []
        switch newPhase {
        case .active:
            if backgroundStopPending {
                backgroundStopPending = false
                actions += [.cancelBackgroundStop, .endBackgroundTask]
            }
            if returningFromBackground {
                returningFromBackground = false
                actions.append(.refreshDomainReads)
            }
            if sessionIsCurrent {
                if syncState != .running { actions.append(.startSync) }
                actions.append(.wakeSendQueues(.foreground))
            }
        case .inactive:
            // Control Center, the app switcher, a system sheet: keep syncing.
            break
        case .background:
            returningFromBackground = true
            backgroundStopPending = true
            actions += [.beginBackgroundTask, .scheduleBackgroundStop(after: Self.backgroundGraceSeconds)]
        }
        return actions
    }
}
