import AtumChat
import SwiftUI

/// The signed-in shell: Personal chats, Drive, Store and Workplace remain
/// distinct destinations; Account stays behind Home's top-left avatar.
/// Each root keeps its own navigation path on `Router`, so changing tabs never
/// rebuilds or resets a different tab's navigation state.
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
        VStack(spacing: 0) {
            Group {
                switch router.selectedTab {
                case .home:
                    NavigationStack(path: $router.homePath) { home() }
                case .drive:
                    NavigationStack(path: $router.drivePath) { drive() }
                case .store:
                    NavigationStack(path: $router.storePath) { store() }
                case .teamSpace:
                    NavigationStack(path: $router.teamSpacePath) { teamSpace() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Reserve the bar's actual layout height outside NavigationStack.
            // An inset on the outer navigation container did not constrain the
            // nested List's scrollable tail, leaving its final row underneath.
            if router.activeRoomID == nil {
                bottomBar
            }
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

    @Environment(\.colorScheme) private var scheme

    private var accountPresentation: Binding<Bool> {
        Binding(get: { router.isAccountPresented },
                set: { if !$0 { router.dismissAccount() } })
    }
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// top field): one glass capsule of four icon tabs. Kit sizes for an
    /// icon-only bar: 24 pt glyphs (`icon.xl`), 44 pt tabs (the regular touch
    /// height) inside a 4 pt inset, so the capsule is 52 pt tall; the selected
    /// tab sits on a `fill-selected` capsule with its glyph filled. Titles stay
    /// as accessibility labels. An unavailable tab is never dimmed (STYLE: no
    /// silent gates); it opens its coming-soon destination and says so.
    private var bottomBar: some View {
        let kit = design.kit
        return HStack(spacing: 0) {
            tabButton(.home)
            tabButton(.drive)
            tabButton(.store)
            tabButton(.teamSpace)
        }
        .padding(kit.space(.s1))
        .modifier(LiveGlass(design: design,
                            radius: (kit.phoneControlHeight(.regular) + kit.space(.s1) * 2) / 2))
        .padding(.horizontal, kit.space(.s4))
        .padding(.top, kit.space(.s1))
        .padding(.bottom, 2)
    }

    private func tabButton(_ kind: Router.Tab) -> some View {
        let title = PhoneTabCopy.title(for: kind, design: design)
        let selected = router.selectedTab == kind
        let available = isAvailable(kind)
        let atum = AtumVisualSystem(design: design)
        let kit = design.kit
        return Button { router.select(tab: kind) } label: {
            Image(atum.symbol(glyph(for: kind, selected: selected)))
                .font(.system(size: CGFloat(kit.tokens.icon["xl"] ?? 24), weight: .light))
                .overlay(alignment: .topTrailing) {
                    // Only mentions earn a mark on a tab (gap spec §2).
                    let mark = badge(for: kind)
                    if case .mention = mark {
                        HomeBadgeView(design: design, badge: mark, pinned: false)
                            .offset(x: 12, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: kit.phoneControlHeight(.regular))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .background {
                    if selected {
                        Capsule().fill(atum.kitColor(.fillSelected, scheme: scheme))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: available ? badgeDescription(for: kind)
                                            : design.text("desktop.atum.discover.comingSoon")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("phone.tab." + kind.identifier)
        // A long press shows the tab's name large, as for any icon-only control.
        .accessibilityShowsLargeContentViewer {
            Image(atum.symbol(glyph(for: kind, selected: selected)))
            Text(verbatim: title)
        }
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
/// real tab destination, never a dead tap; the tab itself is subdued by
/// `RootTabs`.
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

private extension Router.Tab {
    var identifier: String {
        switch self {
        case .home: PhoneTab.chats.rawValue
        case .drive: PhoneTab.drive.rawValue
        case .store: "store"
        case .teamSpace: PhoneTab.teamSpace.rawValue
        }
    }
}
