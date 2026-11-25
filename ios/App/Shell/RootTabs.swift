import AtumChat
import SwiftUI
import UIKit

/// The signed-in shell: Personal chats, Drive, Store and Workplace remain
/// distinct destinations in the system tab bar; Account stays behind Home's
/// top-left avatar. Each root keeps its own navigation path on `Router` and
/// its own live view tree inside `TabView`, so changing tabs never rebuilds or
/// resets a different tab's navigation or view state.
struct RootTabs<HomeContent: View, DriveContent: View, StoreContent: View, TeamSpaceContent: View,
               AccountContent: View>: View {
    @Bindable var router: Router
    let design: LiveDesign
    let availability: PhoneTabAvailability
    let badges: PhoneTabBadges
    private let home: () -> HomeContent
    private let drive: () -> DriveContent
    private let store: () -> StoreContent
    private let teamSpace: () -> TeamSpaceContent
    private let account: () -> AccountContent

    init(router: Router, design: LiveDesign,
         availability: PhoneTabAvailability = .none,
         badges: PhoneTabBadges = .none,
         @ViewBuilder home: @escaping () -> HomeContent,
         @ViewBuilder drive: @escaping () -> DriveContent,
         @ViewBuilder store: @escaping () -> StoreContent,
         @ViewBuilder teamSpace: @escaping () -> TeamSpaceContent,
         @ViewBuilder account: @escaping () -> AccountContent) {
        self.router = router
        self.design = design
        self.availability = availability
        self.badges = badges
        self.home = home
        self.drive = drive
        self.store = store
        self.teamSpace = teamSpace
        self.account = account
    }

    var body: some View {
        // The system tab bar (P1, UX polish audit issue 1). Every root keeps
        // its own live `NavigationStack`, so a tab switch no longer destroys
        // another tab's scroll position, search text or `@State`. A chat
        // destination hides the bar with `.toolbarVisibility(.hidden, for:
        // .tabBar)`, which UIKit animates as part of the push and the pop
        // (interactive swipe-back included). The bar sits behind the
        // keyboard, and content scrolls beneath its Liquid Glass.
        TabView(selection: selection) {
            tab(.home) { NavigationStack(path: $router.homePath) { home() } }
            tab(.drive) { NavigationStack(path: $router.drivePath) { drive() } }
            tab(.store) { NavigationStack(path: $router.storePath) { store() } }
            tab(.teamSpace) { NavigationStack(path: $router.teamSpacePath) { teamSpace() } }
        }
        .atumDesign(design)
        .sheet(isPresented: accountPresentation) {
            NavigationStack {
                // The sheet is Settings; Account is its first destination, as
                // on the desktop (2026-10-25 reorg).
                // FlowPhone2 › Settings: a large title and a trailing glass
                // check (Done), not a leading X over an inline title.
                account()
                    .navigationTitle(design.text("desktop.atum.settings.title"))
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { router.dismissAccount() } label: {
                                AtumVisualSystem(design: design).barIcon(.check)
                            }
                            .accessibilityLabel(design.text("desktop.common.close"))
                            .accessibilityIdentifier("account.close")
                        }
                    }
            }
            .atumDesign(design)
        }
    }

    private var accountPresentation: Binding<Bool> {
        Binding(get: { router.isAccountPresented },
                set: { if !$0 { router.dismissAccount() } })
    }

    /// The bar writes through `Router.select(tab:)`, never `selectedTab`
    /// directly, so a user's tab choice still cancels an in-flight room open
    /// (`onUserSelectedTab`) and a re-tap of the selected tab still pops it
    /// or, on Home's root, scrolls the roster to its top. Programmatic routing
    /// (notifications, `open(roomId:)`) changes `selectedTab` and the bar
    /// follows through the getter.
    private var selection: Binding<Router.Tab> {
        Binding(get: { router.selectedTab }, set: { router.select(tab: $0) })
    }

    /// One icon-only system tab. The Kit's Phosphor glyphs stay the images
    /// (Light at rest, Fill when selected) and the exported title stays the
    /// accessibility label and the large-content-viewer title, as before.
    /// The system draws the selection (the tint is the app's ink) and the
    /// Liquid Glass. Only a mention earns a mark (gap spec §2), drawn by the
    /// system badge with the same "99+" cap as a Home row. An unavailable tab
    /// is never dimmed (STYLE: no silent gates); it opens its coming-soon
    /// destination and says so in its value.
    private func tab<Content: View>(_ kind: Router.Tab,
                                    @ViewBuilder content: () -> Content) -> some TabContent<Router.Tab> {
        let title = PhoneTabCopy.title(for: kind, design: design)
        let atum = AtumVisualSystem(design: design)
        let selected = router.selectedTab == kind
        let destination = content()
            // The bar's bottom scroll edge is the system hard edge, not the
            // default soft one. iOS 26's soft edge fades and dims list rows
            // about 65 pt above the bar's top (a 148 pt pocket over an 83 pt
            // bar on a 390 x 844 iPhone). Resting rows above the bar lost
            // contrast there (CI fix, `testRosterAccessibilityAudit`). The
            // hard edge stops at the bar. Rows still scroll beneath the glass,
            // and the system inset still rests the last row above it. Views
            // that set their own edge style, such as the chat transcript's
            // soft edge over its composer, keep it.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .background(TabBarItemIdentifiers(identifiers: Router.Tab.barOrder.map { "phone.tab." + $0.identifier }))
        return Tab(value: kind) {
            destination
        } label: {
            // No title text in the bar: FlowPhone2's phone shell is four icon
            // tabs. A `.fill` custom symbol must not be picked up by the bar's
            // automatic fill variant, so variants are pinned off.
            tabIcon(atum.symbol(glyph(for: kind, selected: selected)))
                .environment(\.symbolVariants, .none)
        }
        .badge(badgeText(for: kind))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: isAvailable(kind) ? badgeDescription(for: kind)
                                                 : design.text("desktop.atum.discover.comingSoon")))
        .accessibilityIdentifier("phone.tab." + kind.identifier)
    }

    /// The tab glyph at the Kit's `icon.xl` (24 pt), the size the pre-P1 bar
    /// drew. The system bar draws a bare custom symbol at its own default
    /// (about 17 pt) and ignores `.font`, and `.imageScale(.large)` blanks it.
    /// A symbol image that already carries a point size keeps it, and stays a
    /// vector template symbol, so the system selection tint and dark mode
    /// still apply and the large-content viewer can still scale it
    /// (docs/ports/tabbar-icon-size.md).
    /// The Phosphor symbols are Regular-M only, so `.light` matches the old
    /// bar's font without changing the stroke.
    private func tabIcon(_ name: String) -> Image {
        let size = CGFloat(design.kit.tokens.icon["xl"] ?? 24)
        guard let image = UIImage(named: name)?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .light)) else {
            return Image(name)
        }
        return Image(uiImage: image)
    }

    private func badgeText(for tab: Router.Tab) -> Text? {
        guard case let .mention(count) = badge(for: tab) else { return nil }
        return Text(verbatim: Badge.pillText(count))
    }

    private func badge(for tab: Router.Tab) -> Badge {
        tab == .teamSpace ? badges.teamSpace : .none
    }

    /// The mark in words, with its numbers, from the exported copy
    /// (`CompanyCopy.tabMarkDescription`).
    private func badgeDescription(for tab: Router.Tab) -> String {
        CompanyCopy(design: design).tabMarkDescription(badge(for: tab))
    }

    /// The Kit's Phosphor chat-circle, folder-simple, compass and briefcase:
    /// Light at rest, Fill for the selected tab (STYLE §8).
    private func glyph(for tab: Router.Tab, selected: Bool) -> AtumGlyph {
        switch tab {
        case .home: selected ? .messageCircleFilled : .messageCircle
        case .drive: selected ? .folderFilled : .folder
        case .store: selected ? .compassFilled : .compass
        case .teamSpace: selected ? .briefcaseFilled : .briefcase
        }
    }

    private func isAvailable(_ tab: Router.Tab) -> Bool {
        switch tab {
        case .home, .store: true
        case .drive: availability.state(for: .drive) == .available
        case .teamSpace: availability.state(for: .teamSpace) == .available
        }
    }
}

/// The simple one-line placeholder an unavailable destination opens. It is a
/// real tab destination, never a dead tap; the tab itself is never dimmed.
struct PhoneComingSoonView: View {
    let design: LiveDesign
    let tab: PhoneTab

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 12) {
            if let atum {
                // Kit state: one light glyph in ink-4, one line.
                Image(atum.symbol(tab == .drive ? .folder : .briefcase))
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(atum.kitColor(.ink4, scheme: scheme))
                Text(design.text("desktop.atum.discover.comingSoon"))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if let atum {
                atum.color(.ground, scheme: scheme).ignoresSafeArea()
            }
        }
        .navigationTitle(Text(verbatim: PhoneTabCopy.title(for: tab, design: design)))
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("phone.comingSoon." + tab.rawValue)
    }
}

/// Tab titles come only from the committed design export.
@MainActor
enum PhoneTabCopy {
    static func title(for tab: Router.Tab, design: LiveDesign) -> String {
        switch tab {
        case .home: design.text("desktop.atum.roster.title")
        case .drive: design.text("src.matrix.drive-copy.matrixDriveCopy.title")
        case .store: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore")
        case .teamSpace: teamTitle(design)
        }
    }

    /// "Team space" (`teamSpaceTitle`). The board's short "Team" has no exported
    /// key yet (gap F12); "Nơi làm việc" is the retired Workplace name.
    private static func teamTitle(_ design: LiveDesign) -> String {
        design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.teamSpaceTitle")
    }

    static func title(for tab: PhoneTab, design: LiveDesign) -> String {
        switch tab {
        case .chats: design.text("desktop.atum.roster.title")
        case .drive: design.text("src.matrix.drive-copy.matrixDriveCopy.title")
        case .teamSpace: teamTitle(design)
        }
    }
}

/// Pins the `phone.tab.*` accessibility identifiers on the UIKit tab bar
/// items. `TabContent.accessibilityIdentifier` reaches the bar's buttons, but
/// iOS 26 rebuilds those buttons (for example once content scrolls beneath
/// the glass) and the rebuilt ones carried the label and value without the
/// identifier. The item's own identifier survives a rebuild. Any loaded tab
/// can pin all four, so tabs that were never opened are identified too.
private struct TabBarItemIdentifiers: UIViewControllerRepresentable {
    let identifiers: [String]

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.identifiers = identifiers
        // After SwiftUI has applied this pass's tab item changes.
        DispatchQueue.main.async { controller.apply() }
    }

    final class Controller: UIViewController {
        var identifiers: [String] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        func apply() {
            guard let items = tabBarController?.tabBar.items, items.count == identifiers.count else { return }
            for (item, identifier) in zip(items, identifiers) where item.accessibilityIdentifier != identifier {
                item.accessibilityIdentifier = identifier
            }
        }
    }
}

private extension Router.Tab {
    /// The bar's left-to-right order, as declared in `RootTabs.body`.
    static let barOrder: [Router.Tab] = [.home, .drive, .store, .teamSpace]

    var identifier: String {
        switch self {
        case .home: PhoneTab.chats.rawValue
        case .drive: PhoneTab.drive.rawValue
        case .store: "store"
        case .teamSpace: PhoneTab.teamSpace.rawValue
        }
    }
}
