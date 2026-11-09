import AtumChat
import Foundation
import MatrixRustSDK
import SwiftUI

// Sync, send queues and the app's lifecycle for one Matrix runtime (plan
// B9, B30, §2.6, §2.8). The rules are AtumChat's `SessionLifecyclePolicy`;
// this file performs its actions on the SDK. A runtime renewal builds a new
// client, so the app builds a new `SessionLifecycle` with it and stops the
// old one; the scene phase comes from `LiveScenePhaseRelay`, which
// `AtumMobileApp` feeds.
//
// Kept from the hotfix (do not regress): every send queue is woken on
// session start, on foreground and when sync comes back after a network
// failure, and never while the session is not current (an expired 300 s
// token would only park the request again; the keep-alive renews first).

/// What the chat UI reads.
@MainActor
protocol SessionLifecycleControlling: AnyObject {
    /// B30: the quiet `wifi.slash` glyph in the navigation bar while sync is
    /// offline or in error (accessibility label "Đang kết nối", exported
    /// copy). Never words in the transcript.
    var showsConnectionGlyph: Bool { get }
    var syncState: SessionLifecyclePolicy.SyncState { get }
}

extension EnvironmentValues {
    /// B30: whether the chat screen shows the quiet `wifi.slash` glyph in its
    /// navigation bar. The app root sets it from the current runtime's
    /// `SessionLifecycleControlling.showsConnectionGlyph`; the chat screen
    /// reads it, so the store stays out of it (contract amendment, S1 day 1).
    @Entry var showsConnectionGlyph = false
}

@MainActor
@Observable
final class SessionLifecycle: SessionLifecycleControlling {
    /// §2.8: the sync service with offline mode, so sync recovers on its own
    /// when the network returns (B30). Until this object owns the service,
    /// `LiveMatrixSession.establishSession` takes the same builder: the one
    /// line WS3 hands WS1 is `.withOfflineMode()` before `.finish()`.
    static func makeSyncService(client: Client) async throws -> SyncService {
        try await client.syncService()
            .withOfflineMode()
            .withRoomListTimelineLimit(limit: 1)
            .finish()
    }

    private(set) var syncState: SessionLifecyclePolicy.SyncState = .idle
    private(set) var showsConnectionGlyph = false

    @ObservationIgnored private let client: Client
    @ObservationIgnored private let syncService: SyncService
    @ObservationIgnored private let sessionIsCurrent: @MainActor () -> Bool
    @ObservationIgnored private let refreshDomainReads: @MainActor () -> Void
    @ObservationIgnored private var policy = SessionLifecyclePolicy()
    @ObservationIgnored private var stateObserver: SessionSyncStateObserver?
    @ObservationIgnored private var stateHandle: TaskHandle?
    @ObservationIgnored private var lastStateSequence: UInt64 = 0
    @ObservationIgnored private var queueLogger: SessionSendQueueLogger?
    @ObservationIgnored private var queueHandle: TaskHandle?
    @ObservationIgnored private var scenePhaseToken: LiveScenePhaseRelay.Token?
    @ObservationIgnored private var backgroundStop: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: LiveBackgroundAssertion?
    /// Bumped on every trip to the background, so an end queued for an
    /// earlier trip never ends the task a later trip relies on.
    @ObservationIgnored private var backgroundTrip: UInt64 = 0
    @ObservationIgnored private var sdkTail: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// - `sessionIsCurrent`: the custody ticket is current and not about to
    ///   expire (the model's `MobileMatrixSessionKeepAlivePolicy` check).
    /// - `refreshDomainReads`: agents, apps, store and wallet, on every return
    ///   to the foreground (B30).
    init(client: Client, syncService: SyncService,
         sessionIsCurrent: @escaping @MainActor () -> Bool,
         refreshDomainReads: @escaping @MainActor () -> Void) {
        self.client = client
        self.syncService = syncService
        self.sessionIsCurrent = sessionIsCurrent
        self.refreshDomainReads = refreshDomainReads
    }

    /// Observes the sync state, logs each room whose send queue the SDK
    /// disables, and follows the scene phase; the current phase applies at
    /// once, so an active app starts sync and wakes every queue (the hotfix's
    /// `session_started` wake).
    func start() {
        guard !started else { return }
        started = true
        let observer = SessionSyncStateObserver { [weak self] sequence, state in
            Task { @MainActor in self?.syncStateChanged(state, sequence: sequence) }
        }
        stateObserver = observer
        stateHandle = syncService.state(listener: observer)
        let logger = SessionSendQueueLogger()
        queueLogger = logger
        queueHandle = client.subscribeToSendQueueStatus(listener: logger)
        scenePhaseToken = LiveScenePhaseRelay.shared.observe { [weak self] phase in
            self?.scenePhaseChanged(phase)
        }
    }

    /// Sign-out or runtime replacement: stop following, stop sync.
    func stop() async {
        guard started else { return }
        started = false
        if let scenePhaseToken { LiveScenePhaseRelay.shared.remove(scenePhaseToken) }
        scenePhaseToken = nil
        stateHandle?.cancel()
        stateHandle = nil
        stateObserver = nil
        queueHandle?.cancel()
        queueHandle = nil
        queueLogger = nil
        backgroundStop?.cancel()
        backgroundStop = nil
        let pending = sdkTail
        await pending?.value
        await syncService.stop()
        backgroundTask?.end()
        backgroundTask = nil
    }

    // MARK: Events

    private func scenePhaseChanged(_ phase: ScenePhase) {
        let value: SessionLifecyclePolicy.Phase
        if phase == .active {
            value = .active
        } else if phase == .background {
            value = .background
        } else {
            value = .inactive
        }
        run(policy.handle(.scenePhase(value, sessionIsCurrent: sessionIsCurrent())))
    }

    private func syncStateChanged(_ state: SyncServiceState, sequence: UInt64) {
        guard started, sequence > lastStateSequence else { return }
        lastStateSequence = sequence
        let value: SessionLifecyclePolicy.SyncState
        switch state {
        case .idle: value = .idle
        case .running: value = .running
        case .terminated: value = .terminated
        case .error: value = .error
        case .offline: value = .offline
        }
        run(policy.handle(.syncState(value, sessionIsCurrent: sessionIsCurrent())))
        syncState = policy.syncState
        showsConnectionGlyph = policy.showsConnectionGlyph
    }

    private func endBackgroundTask(trip: UInt64) {
        guard trip == backgroundTrip else { return }
        backgroundTask?.end()
        backgroundTask = nil
    }

    private func backgroundGraceElapsed() {
        backgroundStop = nil
        run(policy.handle(.backgroundGraceElapsed))
    }

    // MARK: Actions

    private func run(_ actions: [SessionLifecyclePolicy.Action]) {
        for action in actions {
            switch action {
            case .startSync:
                let service = syncService
                enqueue { await service.start() }
            case .stopSync:
                let service = syncService
                enqueue { await service.stop() }
            case let .wakeSendQueues(reason):
                let client = client
                enqueue {
                    await client.enableAllSendQueues(enable: true)
                    LiveFlowLog.sendQueue(.allEnabled, outcome: reason.rawValue, roomID: nil)
                }
            case .beginBackgroundTask:
                backgroundTrip &+= 1
                if backgroundTask == nil { backgroundTask = LiveBackgroundAssertion(name: "atum.sync-grace") }
            case .endBackgroundTask:
                // Ends after the SDK calls queued before it (a stop must finish
                // before the app may be suspended), and only for this trip.
                let trip = backgroundTrip
                enqueue { [weak self] in self?.endBackgroundTask(trip: trip) }
            case let .scheduleBackgroundStop(after):
                backgroundStop?.cancel()
                backgroundStop = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(after))
                    guard !Task.isCancelled else { return }
                    self?.backgroundGraceElapsed()
                }
            case .cancelBackgroundStop:
                backgroundStop?.cancel()
                backgroundStop = nil
            case .refreshDomainReads:
                refreshDomainReads()
            }
        }
    }

    /// SDK calls run one at a time, in order: a stop never overtakes the start
    /// before it.
    private func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let previous = sdkTail
        sdkTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}

/// Numbers each SDK callback so the main actor can drop one that arrives
/// after a newer state.
private final class SessionSyncStateObserver: SyncServiceStateObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let deliver: @Sendable (UInt64, SyncServiceState) -> Void

    init(deliver: @escaping @Sendable (UInt64, SyncServiceState) -> Void) {
        self.deliver = deliver
    }

    func onUpdate(state: SyncServiceState) {
        lock.lock()
        sequence &+= 1
        let current = sequence
        lock.unlock()
        deliver(current, state)
    }
}

/// Logs (failure class only) each room whose send queue the SDK disables.
/// Re-enabling is explicit: the next send, "Thử lại", foreground, regain.
/// Same line as the hotfix's listener in `LiveMatrixSession`, which goes when
/// this object owns the session's sync.
private final class SessionSendQueueLogger: SendQueueRoomErrorListener, @unchecked Sendable {
    func onError(roomId: String, error: ClientError) {
        LiveFlowLog.sendQueue(.roomDisabled, outcome: Self.failureClass(error), roomID: roomId)
    }

    private static func failureClass(_ error: ClientError) -> String {
        switch error {
        case .Generic: return "generic"
        case let .MatrixApi(kind, _, _, _):
            switch kind {
            case .unknownToken: return "token_rejected"
            case .limitExceeded: return "rate_limited"
            case .forbidden: return "forbidden"
            default: return "matrix_api"
            }
        case .ContentScanner: return "content_scanner"
        }
    }
}
