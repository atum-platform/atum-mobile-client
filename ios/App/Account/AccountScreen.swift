import AtumChat
import AtumDesign
import SwiftUI

/// The Account sheet remains the phone's top-left entry point. Its first screen
/// is the stable Settings index; there is intentionally no Account tab.
struct AccountScreen: View {
    let design: LiveDesign
    let presentation: AccountPresentation
    let actions: AccountActions
    var store: LiveProductStoreRead
    var storeCommerce: LiveStoreCommerce?
    var refreshStore: @MainActor () async -> Void
    var openStoreRoom: (String) -> Void
    var setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)?
    /// The owner's activity switch (`io.atum.desktop.share_activity`), on by
    /// default: public receipts and typing.
    var shareActivity: Bool
    var setShareActivity: @MainActor (Bool) async -> Bool
    /// The two reporting switches are app preferences, not account data.
    var crashReportsEnabled: Bool
    var setCrashReportsEnabled: @MainActor (Bool) -> Void
    var usageDataEnabled: Bool
    var setUsageDataEnabled: @MainActor (Bool) -> Void
    var founderContactAvailable: Bool
    var founderContactTitle: String
    /// The Founder draft, when the roster offers one: Contact us opens it and makes nothing;
    /// its first message makes the room.
    var founderDraft: FounderDraftActions?
    var contactFounder: @MainActor () async -> String?
    var openFounderRoom: (String) -> Void
    /// The assistant's existing card, for Settings > Assistants.
    var assistantCard: ((AccountAssistantSummary) -> AnyView)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsState: AccountSettingsState
    @State private var notificationState = AccountNotificationState.unknown
    @State private var showsLegal = false
    @State private var showsStore = false
    @State private var recoverySheet: RecoverySheet?
    @State private var founderDraftPresented = false
    @State private var confirmsSignOut = false
    @State private var signOutError = false

    init(design: LiveDesign,
         presentation: AccountPresentation,
         actions: AccountActions,
         store: LiveProductStoreRead = .unavailable,
         storeCommerce: LiveStoreCommerce? = nil,
         refreshStore: @escaping @MainActor () async -> Void = {},
         openStoreRoom: @escaping (String) -> Void = { _ in },
         setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)? = nil,
         shareActivity: Bool = true,
         setShareActivity: @escaping @MainActor (Bool) async -> Bool = { _ in true },
         crashReportsEnabled: Bool = true,
         setCrashReportsEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
         usageDataEnabled: Bool = true,
         setUsageDataEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
         founderContactAvailable: Bool = false,
         founderContactTitle: String = "Contact us",
         founderDraft: FounderDraftActions? = nil,
         contactFounder: @escaping @MainActor () async -> String? = { nil },
         openFounderRoom: @escaping (String) -> Void = { _ in },
         assistantCard: ((AccountAssistantSummary) -> AnyView)? = nil) {
        self.design = design
        self.presentation = presentation
        self.actions = actions
        self.store = store
        self.storeCommerce = storeCommerce
        self.refreshStore = refreshStore
        self.openStoreRoom = openStoreRoom
        self.setAppShortcutVisibility = setAppShortcutVisibility
        self.shareActivity = shareActivity
        self.setShareActivity = setShareActivity
        self.crashReportsEnabled = crashReportsEnabled
        self.setCrashReportsEnabled = setCrashReportsEnabled
        self.usageDataEnabled = usageDataEnabled
        self.setUsageDataEnabled = setUsageDataEnabled
        self.founderContactAvailable = founderContactAvailable
        self.founderContactTitle = founderContactTitle
        self.founderDraft = founderDraft
        self.contactFounder = contactFounder
        self.openFounderRoom = openFounderRoom
        self.assistantCard = assistantCard
        _settingsState = State(initialValue: AccountSettingsState(
            accountID: presentation.matrixUserID,
            capabilities: presentation.settingsCapabilities
        ))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        List {
            identityHeader
            // Three quiet groups, separated only by space, as on the desktop.
            ForEach(settingsState.groups) { group in
                Section {
                    // Account is the profile card above (FlowPhone2).
                    ForEach(group.sections.filter { $0 != .account }) { section in
                        AtumSettingsRow(
                            glyph: sectionGlyph(section),
                            title: AccountSettingsCopy.sectionTitle(section, design: design),
                            value: nil,
                            indicator: .push,
                            identifier: "account.settings.index." + section.rawValue
                        ) {
                            settingsState.select(section)
                        }
                    }
                } header: {
                    groupName(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ConnectionGlyph(design: design) }
        }
        .task { await refreshNotifications() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotifications() } }
        }
        .onChange(of: presentation.matrixUserID) { _, accountID in
            settingsState.reconcile(accountID: accountID,
                                    capabilities: presentation.settingsCapabilities)
        }
        .onChange(of: presentation.settingsCapabilities) { _, capabilities in
            settingsState.reconcile(accountID: presentation.matrixUserID,
                                    capabilities: capabilities)
        }
        .onChange(of: presentation.signOutFailureToken) { _, _ in signOutError = true }
        .navigationDestination(item: selectedSection) { section in
            AccountSettingsDetail(
                section: section,
                design: design,
                presentation: presentation,
                actions: actions,
                store: store,
                notificationState: notificationState,
                shareActivity: shareActivity,
                setShareActivity: setShareActivity,
                crashReportsEnabled: crashReportsEnabled,
                setCrashReportsEnabled: setCrashReportsEnabled,
                usageDataEnabled: usageDataEnabled,
                setUsageDataEnabled: setUsageDataEnabled,
                callbacks: AccountSettingsDetailCallbacks(
                    openSection: { settingsState.select($0) },
                    openStore: { showsStore = true },
                    openLegal: { showsLegal = true },
                    openRecoveryKey: { recoverySheet = .show },
                    restoreMessages: { recoverySheet = .restore },
                    beginSignOut: beginSignOut,
                    notificationTapped: { Task { await notificationTapped() } },
                    founderContactAvailable: founderContactAvailable,
                    founderContactTitle: founderContactTitle,
                    founderDraftAvailable: founderDraft != nil,
                    openFounderDraft: { founderDraftPresented = true },
                    contactFounder: contactFounder,
                    openFounderRoom: openFounderRoom,
                    assistantCard: assistantCard
                )
            )
            .alert(copy("src.matrix.mobile-copy.mobilePhoneCopy.signOutTitle"),
                   isPresented: $confirmsSignOut) {
                Button(copy("desktop.dm.signOut"), role: .destructive) {
                    Task {
                        let result = await actions.signOut(false)
                        if result {
                            AccessibilityNotification.Announcement(copy("desktop.dm.signOut")).post()
                        } else { signOutError = true }
                    }
                }
                Button(copy("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
            } message: {
                Text(copy("src.matrix.mobile-copy.mobilePhoneCopy.signOutBody"))
            }
        }
        .navigationDestination(isPresented: $showsLegal) {
            LegalScreen(design: design, openWebPage: actions.openWebPage)
        }
        .navigationDestination(isPresented: $showsStore) {
            StoreScreen(design: design, store: store, onRefresh: refreshStore,
                        onOpenRoom: { roomID in
                            showsStore = false
                            openStoreRoom(roomID)
                        },
                        setAppShortcutVisibility: setAppShortcutVisibility,
                        commerce: storeCommerce)
        }
        .sheet(isPresented: $founderDraftPresented) {
            if let draft = founderDraft {
                FounderDraftSheet(design: design, draft: draft) {
                    founderDraftPresented = false
                }
            } else {
                Color.clear.onAppear { founderDraftPresented = false }
            }
        }
        .sheet(item: $recoverySheet) { sheet in
            switch sheet {
            case .show:
                RecoveryKeySheet(design: design, mode: .show,
                                 load: actions.loadRecoveryKey) {
                    actions.markRecoveryKeySaved()
                    return true
                }
            case .saveBeforeSignOut:
                RecoveryKeySheet(design: design, mode: .saveBeforeSignOut,
                                 load: actions.loadRecoveryKey) {
                    actions.markRecoveryKeySaved()
                    let result = await actions.signOut(true)
                    if !result { signOutError = true }
                    return result
                }
            case .restore:
                RestoreMessagesSheet(design: design,
                                     restore: actions.restoreMessages,
                                     onDone: { recoverySheet = nil })
            }
        }
        .alert(copy("src.matrix.chat-copy.copies.errorGeneric"), isPresented: $signOutError) {
            Button(copy("src.matrix.chat-copy.copies.retry")) { beginSignOut() }
            Button(copy("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
        }
        .accessibilityIdentifier("account.screen")
    }

    /// A group's name is for assistive technology only: a heading VoiceOver
    /// reads and the rotor reaches, drawn at a size and colour the eye never
    /// meets, because the groups are told apart by space alone.
    private func groupName(_ group: AccountSettingsGroupID) -> some View {
        Color.clear
            .frame(height: 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccountSettingsCopy.text(group.accessibilityName, design: design))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("account.settings.group." + group.rawValue)
    }

    private var selectedSection: Binding<AccountSettingsSectionID?> {
        Binding(
            get: { settingsState.selectedSection },
            set: { settingsState.select($0) }
        )
    }

    /// FlowPhone2 › Settings: the profile card. A 56 pt round face, the
    /// name in body semibold and one ink-3 line, with a caret; it opens
    /// Account, where the name and photo are edited. The board's line
    /// ("Account, Protons, devices") has no exported copy yet (atum-app gap
    /// F5), so the card shows the public handle there.
    private var identityHeader: some View {
        Section {
            Button { settingsState.select(.account) } label: {
                HStack(spacing: 12) {
                    AccountProfileHeader(design: design, presentation: presentation, actions: actions,
                                         identifierPrefix: "account.profile", background: .cell,
                                         editable: false, avatarSize: 56)
                    Image(atum.symbol(.chevronRight))
                        .font(.system(size: 14))
                        .foregroundStyle(atum.kitColor(.ink4, scheme: scheme))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(atum.kitColor(.surface, scheme: scheme))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("account.settings.index.account")
        }
    }

    private func sectionGlyph(_ section: AccountSettingsSectionID) -> AtumGlyph {
        switch section {
        case .account: .userCircle
        case .assistants: .sparkles
        case .protons: .compass
        case .general: .settings
        // "What Atum knows" (FlowPhone2): an eye, not a link.
        case .connections: .eye
        case .devices: .deviceMobile
        case .privacy: .shield
        case .help: .helpCircle
        case .advanced: .slidersHorizontal
        }
    }

    private func beginSignOut() {
        switch AccountSettingsState.signOutPrompt(
            holdsRecoveryKey: presentation.holdsRecoveryKey,
            recoveryKeySavedOnThisPhone: presentation.recoveryKeySavedOnThisPhone
        ) {
        case .confirmation: confirmsSignOut = true
        case .saveRecoveryKey: recoverySheet = .saveBeforeSignOut
        }
    }

    private func refreshNotifications() async {
        notificationState = await actions.readNotificationState()
    }

    private func notificationTapped() async {
        if notificationState == .notDetermined {
            notificationState = await actions.requestNotifications()
        } else {
            actions.openNotificationSettings()
        }
    }

    private func copy(_ key: String,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }

    private enum RecoverySheet: String, Identifiable {
        case show
        case saveBeforeSignOut
        case restore
        var id: String { rawValue }
    }
}
