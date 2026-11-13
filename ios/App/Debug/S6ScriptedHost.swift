#if DEBUG
import AtumChat
import SwiftUI

/// A plain reference count: changing it is not a SwiftUI state change.
final class ScriptedReadCounter {
    var count = 0
}

struct S6ScriptedHost: View {
    let scenario: S6ScriptedScenario
    private let design = try! LiveDesign()
    @State private var router = Router()
    @State private var signedOut = false
    @State private var recoveryRestored = false
    @State private var legalLinks = ChatLinkRouter()
    @State private var storePath = NavigationPath()
    /// Counted without redrawing the host: a redraw would rebuild the page
    /// and read the list again, hiding the failed first read.
    @State private var deviceReads = ScriptedReadCounter()
    @State private var openedDeviceSignOut: URL?

    var body: some View {
        Group {
            switch scenario {
            case .systemGallery: S6SystemGallery(design: design)
            case .welcome: welcome(.idle)
            case .welcomeCancelled: welcome(.cancelled)
            case .welcomeExpired: welcome(.expired)
            case .welcomeBusy: welcome(.busy)
            case .statusCannotConnect:
                if signedOut {
                    welcome(.idle)
                } else {
                    S6StatusScreen(design: design, kind: .cannotConnect, busy: false,
                                   retry: {}, signOut: { signedOut = true })
                }
            case .statusDomain:
                S6StatusScreen(design: design, kind: .domain(.domainUnavailable), busy: false,
                               retry: {}, signOut: nil)
            case .bootSlow: S6BootWait(design: design, revealAfter: AtumDebugLaunch.s6ClockZero)
            case .storeCatalog, .storeFirstLoad, .storeEmpty, .storeUnavailable,
                 .storeStale, .storePartial, .storeOpenApp:
                storeHost
            case .storeAcquire: StoreCommerceScriptedHost(design: design, mode: .acquire)
            case .storeInsufficient: StoreCommerceScriptedHost(design: design, mode: .insufficient)
            case .storeUncertain: StoreCommerceScriptedHost(design: design, mode: .uncertain)
            case .storeOwned: StoreCommerceScriptedHost(design: design, mode: .owned)
            case .storeClosed: StoreCommerceScriptedHost(design: design, mode: .closed)
            case .storeCheckoutSlow: StoreCommerceScriptedHost(design: design, mode: .slowCheckout)
            case .accountDefault, .accountRestore, .recoveryRejected, .recoveryDone,
                 .accountKey, .signOutPlain, .signOutSaveKey, .accountLegal,
                 .accountDevices, .accountDevicesFailed:
                accountHost
            }
        }
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
        .atumDesign(design)
        .fullScreenCover(item: $legalLinks.presented) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }

    @Environment(\.colorScheme) private var scheme

    private func welcome(_ presentation: WelcomePresentation) -> some View {
        S6WelcomeScreen(design: design, presentation: presentation,
                        onContinue: {}, onOpenLegal: { _ in })
    }

    private var storeHost: some View {
        NavigationStack(path: $storePath) {
            StoreScreen(design: design, store: storePresentation,
                        onRefresh: {},
                        onOpenRoom: { roomID in storePath = NavigationPath([roomID]) },
                        loadingRevealAfter: AtumDebugLaunch.s6ClockZero)
            .navigationDestination(for: String.self) { _ in
                Text(verbatim: "Moon").accessibilityIdentifier("scripted.moon-chat")
            }
        }
    }

    private var accountHost: some View {
        Group {
            if signedOut {
                welcome(.idle)
            } else {
                NavigationStack {
                    AccountScreen(design: design,
                                  presentation: accountPresentation,
                                  actions: scriptedAccountActions)
                }
                // The browser page a device sign-out opens is only recorded here.
                .environment(\.openURL, OpenURLAction { url in
                    guard url.host == "account.atum.invalid" else { return .systemAction }
                    openedDeviceSignOut = url
                    return .handled
                })
                .overlay(alignment: .bottom) {
                    if openedDeviceSignOut != nil {
                        Text(verbatim: "device-sign-out-opened")
                            .font(.caption2)
                            .opacity(0.01)
                            .accessibilityIdentifier("scripted.device-sign-out-opened")
                    }
                }
            }
        }
    }

    private var scriptedDevices: Bool {
        scenario == .accountDevices || scenario == .accountDevicesFailed
    }

    /// Two synthetic sessions: a named Mac seen two hours ago and an unnamed
    /// one seen three days ago. The device IDs are never drawn.
    private func scriptedDeviceList() -> [AccountDevice]? {
        deviceReads.count += 1
        if scenario == .accountDevicesFailed && deviceReads.count == 1 { return nil }
        let now = Date()
        return [
            AccountDevice(id: "SCRIPTEDMAC", name: "MacBook Pro", lastSeen: now.addingTimeInterval(-2 * 3_600)),
            AccountDevice(id: "SCRIPTEDOLD", name: nil, lastSeen: now.addingTimeInterval(-3 * 86_400)),
        ]
    }

    private var storePresentation: LiveProductStoreRead {
        switch scenario {
        case .storeFirstLoad:
            return .init(availability: .loading)
        case .storeUnavailable:
            return .init(availability: .unavailable)
        case .storeEmpty:
            return .init(availability: .empty, walletMicroProtons: 12_400_000_000)
        default:
            let featured = LiveProductStoreItem(
                id: "featured", kind: .skill,
                title: design.text("desktop.atum.discover.featuredSection"),
                summary: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                glyph: "◉", featured: true, price: scenario == .storePartial ? nil : "24"
            )
            let assistant = LiveProductStoreItem(
                id: "assistant", kind: .agent, title: "Atum",
                summary: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                glyph: "A", featured: false, price: "0"
            )
            let skill = LiveProductStoreItem(
                id: "skill", kind: .skill,
                title: design.text("desktop.atum.discover.skillsSection"),
                summary: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                glyph: "✦", featured: false, price: "12"
            )
            let pet = LiveProductStoreItem(
                id: "pet", kind: .pet,
                title: design.text("desktop.atum.discover.petsSection"),
                summary: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                glyph: "◌", featured: false, price: nil
            )
            let moon = LiveProductStoreApp(
                id: "moon", title: "Moon",
                subtitle: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                avatarCandidates: [], accent: scriptedMoon.brandAccentColor,
                isAvailable: true, isVerified: true, verification: .official,
                roomID: scenario == .storeOpenApp || scenario == .storeCatalog ? "moon-room" : nil
            )
            let andy = LiveProductStoreApp(
                id: "andy", title: "Andy",
                subtitle: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                avatarCandidates: [], accent: nil,
                isAvailable: true, isVerified: true, verification: .official,
                roomID: nil
            )
            return .init(availability: .ready,
                         walletMicroProtons: scenario == .storePartial ? nil : 12_400_000_000,
                         items: scenario == .storePartial ? [featured] : [featured, assistant, skill, pet],
                         apps: scenario == .storePartial ? [] : [moon, andy],
                         staleAvailability: scenario == .storeStale ? .offline
                            : (scenario == .storePartial ? .unavailable : nil))
        }
    }

    private var accountPresentation: AccountPresentation {
        let restore = !recoveryRestored && (scenario == .accountRestore
            || scenario == .recoveryRejected || scenario == .recoveryDone)
        let key = scenario == .accountKey || scenario == .signOutSaveKey
        return AccountPresentation(
            matrixUserID: "@an:atum.invalid", displayName: "An",
            offersHistoryRecovery: restore, holdsRecoveryKey: key,
            recoveryKeySavedOnThisPhone: false, signOutInProgress: false,
            signOutFailureToken: 0, version: "1.0.0 (202610130001)",
            directoryHandle: "annguyen",
            recoveryStatus: scriptedDevices ? .off : .unknown
        )
    }

    private var scriptedAccountActions: AccountActions {
        var actions = AccountActions(
            readNotificationState: { .on }, requestNotifications: { .on },
            openNotificationSettings: {}, openAppSettings: {},
            loadRecoveryKey: { .value("SYNTH ETIC RECO VERY KEY1") },
            markRecoveryKeySaved: {},
            restoreMessages: { _ in
                if scenario == .recoveryRejected { return .rejected }
                recoveryRestored = true
                return .restored
            },
            signOut: { _ in signedOut = true; return true },
            openWebPage: { legalLinks.open($0.absoluteString) },
            saveProfileName: { _ in .saved }
        )
        if scriptedDevices {
            actions.loadDevices = { scriptedDeviceList() }
            actions.deviceSignOutURL = { deviceID in
                URL(string: "https://account.atum.invalid/account/?action=org.matrix.device_delete&device_id="
                    + deviceID)
            }
        }
        return actions
    }

    private var scriptedMoon: AppBotPresentation {
        AppBotPresentation(
            appID: "00000000-0000-4000-8000-893af8437b12", slug: "moon",
            botUserID: "@app-moon:atum.invalid", name: "Moon", subtitle: nil,
            avatarURL: URL(string: "https://atum.invalid/moon.png")!,
            avatarSHA256: String(repeating: "0", count: 64), accentHex: "#F4D35E",
            verification: .official, purchaseRouteID: "purchase", setupComplete: false
        )
    }
}
#endif

