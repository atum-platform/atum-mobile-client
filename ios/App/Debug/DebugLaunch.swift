#if DEBUG
import AtumChat
import SwiftUI
import UIKit

/// Debug-only launch handling (plan §2.10). Release builds compile none of
/// it. The owner never passes launch arguments: tapping the icon starts the
/// normal app, with the probe log recording in the background.
@MainActor
enum AtumDebugLaunch {
    /// Reads the launch arguments once at startup. Returns true when SwiftUI
    /// animations must be off too (`-AtumUITestNoAnimations`).
    static func configure(arguments: [String]) -> Bool {
        ProbeFileSink.install()
        let parsed = AtumLaunchArguments(arguments)
        if parsed.disablesAnimations {
            UIView.setAnimationsEnabled(false)
        }
        return parsed.disablesAnimations
    }

    static private(set) var s6Scenario: S6ScriptedScenario?
    static private(set) var s6ClockZero: Date?

    static func configureS6(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: AtumLaunchArguments.scriptedFlag),
              flag + 1 < arguments.count else {
            s6Scenario = nil
            s6ClockZero = nil
            return
        }
        s6Scenario = S6ScriptedScenario(rawValue: arguments[flag + 1])
        if let start = arguments.firstIndex(of: "-AtumScriptedStartAt"),
           start + 1 < arguments.count,
           let seconds = TimeInterval(arguments[start + 1]) {
            s6ClockZero = Date(timeIntervalSince1970: seconds)
        } else {
            s6ClockZero = nil
        }
    }

    /// `-AtumExpiredSessionPreview`: the expired-session sign-in screen
    /// alone (W4 E3, decision 11), for its U screenshot and audit. Reaching
    /// it live takes a stranded custody record, which a simulator build
    /// without Keychain access groups cannot hold. Nothing signs in.
    static let showsExpiredSessionPreview =
        ProcessInfo.processInfo.arguments.contains(expiredSessionPreviewFlag)
    static let expiredSessionPreviewFlag = "-AtumExpiredSessionPreview"
}

enum S6ScriptedScenario: String, CaseIterable {
    case systemGallery = "system.gallery"
    case welcome
    case welcomeCancelled = "welcome.cancelled"
    case welcomeExpired = "welcome.expired"
    case welcomeBusy = "welcome.busy"
    case statusCannotConnect = "status.cant-connect"
    case statusDomain = "status.domain"
    case bootSlow = "boot.slow"
    case storeCatalog = "store.catalog"
    case storeFirstLoad = "store.first-load"
    case storeEmpty = "store.empty"
    case storeUnavailable = "store.unavailable"
    case storeStale = "store.stale"
    case storePartial = "store.partial"
    case storeOpenApp = "store.open-app"
    case accountDefault = "account.default"
    case accountRestore = "account.restore"
    case recoveryRejected = "recovery.rejected"
    case recoveryDone = "recovery.done"
    case accountKey = "account.key"
    case signOutPlain = "signout.plain"
    case signOutSaveKey = "signout.save-key"
    case accountLegal = "account.legal"
}

/// The preview host for `-AtumExpiredSessionPreview`: the same S6 welcome
/// state and design as the live app; the button and legal links do nothing.
struct ExpiredSessionPreviewHost: View {
    private let design = try! LiveDesign()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            design.color("ground", scheme: scheme).ignoresSafeArea()
            S6WelcomeScreen(design: design, presentation: .expired,
                            onContinue: {}, onOpenLegal: { _ in })
        }
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
    }
}
#endif
