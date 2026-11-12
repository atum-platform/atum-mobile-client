import SwiftUI
import UIKit
import UserNotifications
import AtumChat

@main
struct AtumMobileApp: App {
    @UIApplicationDelegateAdaptor(AtumAppDelegate.self) private var appDelegate
    /// `-AtumUITestNoAnimations` (Debug only, plan §2.10).
    private let disablesAnimations: Bool

    init() {
        LiveReporting.shared.start()
        Task { await AttachmentPreparer.shared.cleanForLaunch() }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        disablesAnimations = AtumDebugLaunch.configure(arguments: arguments)
        AtumDebugLaunch.configureS6(arguments: arguments)
        AtumScriptedLaunch.configure(arguments: arguments)
        #if targetEnvironment(simulator)
        // Simulator proof of communication notifications only: `simctl` cannot
        // grant notification permission, so a UI test passes this flag and
        // taps Allow (CommunicationNotificationCaptureUITests).
        if arguments.contains("-AtumRequestNotificationAuthorization") {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
        }
        ScriptedNotificationPoster.configure(arguments: arguments)
        #endif
        #else
        disablesAnimations = false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                .background { LiveScenePhaseReader() }
                .background { LiveAppearanceApplier() }
            #if DEBUG
                .transaction { [disablesAnimations] transaction in
                    guard disablesAnimations else { return }
                    transaction.disablesAnimations = true
                    transaction.animation = nil
                }
            #endif
        }
    }

    /// The live app. Debug only: `-AtumScripted <chat scenario>` opens the
    /// scripted chat on the real `ChatScreen`, and a roster scenario shows
    /// today's Home on the scripted rooms; neither signs in (plan §2.10).
    @ViewBuilder private var root: some View {
        #if DEBUG
        if AtumDebugLaunch.showsExpiredSessionPreview {
            ExpiredSessionPreviewHost()
        } else if let scenario = AtumDebugLaunch.s6Scenario {
            S6ScriptedHost(scenario: scenario)
        } else if let script = AtumScriptedLaunch.selection?.chat {
            ScriptedChatHost(script: script)
        } else if let roster = AtumScriptedLaunch.selection?.roster {
            ScriptedHomeHost(roster: roster)
        } else {
            AppRoot()
        }
        #else
        AppRoot()
        #endif
    }
}

/// Feeds `LiveScenePhaseRelay` from a leaf view. Reading `scenePhase` in
/// `AtumMobileApp` would make the app's body depend on it and rebuild
/// `AppRoot` (its initialisers: the model, the design files, the fonts)
/// on every phase change; here only this empty view re-renders. The iPhone
/// app has one scene, so its phase is the app's.
private struct LiveScenePhaseReader: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: scenePhase, initial: true) { _, phase in
                LiveScenePhaseRelay.shared.deliver(phase)
            }
    }
}

/// The app's scene phase for objects no view owns (revamp plan §2.8): one
/// `SessionLifecycle` per Matrix runtime, replaced on every token renewal.
/// `LiveScenePhaseReader` delivers every change; an observer that attaches
/// later is told the latest phase at once.
@MainActor
final class LiveScenePhaseRelay {
    static let shared = LiveScenePhaseRelay()

    struct Token: Hashable {
        fileprivate let id: UInt64
    }

    private(set) var phase: ScenePhase?
    private var observers: [UInt64: @MainActor (ScenePhase) -> Void] = [:]
    private var nextID: UInt64 = 0

    /// Calls `handler` now with the latest phase, if one arrived, and then on
    /// every change until the token is removed.
    func observe(_ handler: @escaping @MainActor (ScenePhase) -> Void) -> Token {
        nextID &+= 1
        observers[nextID] = handler
        if let phase { handler(phase) }
        return Token(id: nextID)
    }

    func remove(_ token: Token) {
        observers[token.id] = nil
    }

    func deliver(_ newPhase: ScenePhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        for id in observers.keys.sorted() {
            observers[id]?(newPhase)
        }
    }
}

/// APNs reports the device token to the app delegate. The relay hands it to
/// whichever signed-in model is listening, keeping the latest value for a
/// listener that attaches later. It holds no other state.
@MainActor
final class LiveRemoteNotificationRelay {
    static let shared = LiveRemoteNotificationRelay()

    private var pendingToken: Data?
    private var pendingRoomIntent: String?
    private var onToken: ((Data) -> Void)?
    private var onFailure: ((any Error) -> Void)?
    private var onRoomIntent: ((String) -> Void)?
    private var screen: PushPresentation.Screen = .other
    /// Whether a room's notification may show in the foreground (a room that only claims the
    /// company conversation type has no directory record behind it).
    var presents: (String) -> Bool = { _ in true }

    func attach(onToken: @escaping (Data) -> Void,
                onFailure: @escaping (any Error) -> Void,
                onRoomIntent: @escaping (String) -> Void) {
        self.onToken = onToken
        self.onFailure = onFailure
        self.onRoomIntent = onRoomIntent
        if let pendingToken { onToken(pendingToken) }
        if let pendingRoomIntent {
            self.pendingRoomIntent = nil
            onRoomIntent(pendingRoomIntent)
        }
    }

    func update(screen: PushPresentation.Screen) {
        self.screen = screen
    }

    func deliver(token: Data) {
        pendingToken = token
        onToken?(token)
    }

    func deliver(failure: any Error) {
        onFailure?(failure)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
        guard let roomID = LivePushRouting.roomID(from: userInfo) else { return }
        deliver(roomID: roomID)
    }

    func deliver(roomID: String) {
        guard let onRoomIntent else {
            pendingRoomIntent = roomID
            return
        }
        onRoomIntent(roomID)
    }

    func foregroundOptions(userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        guard let roomID = LivePushRouting.roomID(from: userInfo) else { return [] }
        return foregroundOptions(roomID: roomID)
    }

    func foregroundOptions(roomID: String) -> UNNotificationPresentationOptions {
        guard presents(roomID) else { return [] }
        return LivePushRouting.options(for: PushPresentation.decide(
            screen: screen, notificationRoomID: roomID
        ))
    }
}

final class AtumAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { LiveRemoteNotificationRelay.shared.deliver(token: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        MainActor.assumeIsolated { LiveRemoteNotificationRelay.shared.deliver(failure: error) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        #if DEBUG && targetEnvironment(simulator)
        if ScriptedNotificationPoster.owns(notification.request.identifier) { return [.banner, .list] }
        #endif
        guard let roomID = LivePushRouting.roomID(from: notification.request.content.userInfo) else { return [] }
        return await MainActor.run {
            LiveRemoteNotificationRelay.shared.foregroundOptions(roomID: roomID)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let roomID = LivePushRouting.roomID(
            from: response.notification.request.content.userInfo
        ) else { return }
        await MainActor.run {
            LiveRemoteNotificationRelay.shared.deliver(roomID: roomID)
        }
    }
}
