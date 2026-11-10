import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI
import UIKit

struct AccountSettingsDetailCallbacks {
    var openSection: (AccountSettingsSectionID) -> Void
    var openStore: () -> Void
    var openLegal: () -> Void
    var openRecoveryKey: () -> Void
    var restoreMessages: () -> Void
    var beginSignOut: () -> Void
    var notificationTapped: () -> Void
    /// Account › How Atum answers › Protons: desktop's "Top up". Nil draws no
    /// button. This is the Store stream's slot (plan v2 ST-5): it passes the
    /// pack sheet here and Settings draws the button beside the balance.
    var openTopUp: (() -> Void)? = nil
    var founderContactAvailable: Bool = false
    /// The roster's local draft is the only Founder chat on offer: opening it makes nothing.
    var founderDraftAvailable: Bool = false
    var openFounderDraft: () -> Void = {}
    var contactFounder: @MainActor () async -> String? = { nil }
    var openFounderRoom: (String) -> Void = { _ in }
    /// The assistant's existing card (name, photo, instructions, model,
    /// routines), built by the app root from the chat's own assistant actions.
    /// Settings never implements a second editor. Nil: no card to open.
    var assistantCard: ((AccountAssistantSummary) -> AnyView)? = nil
}

struct AccountSettingsDetail: View {
    let section: AccountSettingsSectionID
    let design: LiveDesign
    let presentation: AccountPresentation
    let actions: AccountActions
    let store: LiveProductStoreRead
    let notificationState: AccountNotificationState
    let shareActivity: Bool
    let setShareActivity: @MainActor (Bool) async -> Bool
    let crashReportsEnabled: Bool
    let setCrashReportsEnabled: @MainActor (Bool) -> Void
    let usageDataEnabled: Bool
    let setUsageDataEnabled: @MainActor (Bool) -> Void
    let callbacks: AccountSettingsDetailCallbacks

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var openedAssistant: AccountAssistantSummary?
    @State private var deletesAccount = false

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    @AppStorage(AtumAppearance.storageKey) private var appearance = AtumAppearance.system.rawValue

    var body: some View {
        List {
            // A folded destination draws its page, as the desktop's `settingsPageOf`.
            switch section.page {
            case .account:
                accountContent
                ForEach(AccountPageSection.order(restoresFirst: restoresFirst), id: \.self) { part in
                    accountSection(part)
                }
                // Desktop: Sign out, then Delete account… beside it, both neutral,
                // below every section folded into Account.
                Section {
                    signOutButton
                    deleteAccountButton
                }
            case .assistants: assistantsContent
            case .general: generalContent
            case .connections: connectionsContent
            case .help: helpContent
            case .protons, .devices, .privacy, .advanced: EmptyView()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(AccountSettingsCopy.sectionTitle(section.page, design: design))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedAssistant) { assistant in
            if let card = callbacks.assistantCard {
                card(assistant)
            }
        }
        .sheet(isPresented: $deletesAccount) {
            DeleteAccountRequestSheet(design: design, accountID: presentation.matrixUserID) {
                deletesAccount = false
            }
        }
        .accessibilityIdentifier("account.settings." + section.page.rawValue)
    }

    // MARK: Account

    /// Who you are: name and photo (edited in place) and the public handle.
    @ViewBuilder private var accountContent: some View {
        Section {
            AccountProfileHeader(design: design, presentation: presentation, actions: actions,
                                 identifierPrefix: "account.settings.account.profile",
                                 background: .cell, showsHandle: false)
        }

        // Only the directory's @handle, never the Matrix ID's localpart: with
        // no handle read yet (plan SV-4) the row is left out.
        if let handle = presentation.publicHandle {
            Section {
                statusRow(glyph: .userCircle,
                          title: copy("shared.matrix-alias-copy.copy.title"),
                          value: handle,
                          identifier: "account.settings.account.handle")
                    .textSelection(.enabled)
            }
        }
    }

    /// The desktop recovery key comes last unless this phone must restore
    /// messages before anything else (desktop `recovery_required`).
    private var restoresFirst: Bool {
        AccountRecoverySlot.decide(
            offersHistoryRecovery: presentation.offersHistoryRecovery,
            holdsRecoveryKey: presentation.holdsRecoveryKey
        ) == .restoreMessages
    }

    @ViewBuilder private func accountSection(_ part: AccountPageSection) -> some View {
        switch part {
        case .howAtumAnswers: howAtumAnswersContent
        case .recovery:
            Section {
                recoveryRows
            } header: {
                Text(copy("src.matrix.settings-copy.copy.encryptedMessages"))
            }
        case .devices: devicesContent
        case .chats: chatsContent
        case .memory: memoryContent
        case .activity: activityContent
        case .ignored: ignoredContent
        }
    }

    /// Desktop's "How Atum answers": one Protons row with the whole-Proton
    /// balance and what it pays for (never a paid/bonus split or a rate), and
    /// Top up when the Store stream provides it.
    @ViewBuilder private var howAtumAnswersContent: some View {
        Section {
            HStack(spacing: 12) {
                ProtonMark(.regular)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy("desktop.atum.protons.title"))
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    Text(protonsHelp)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.settings.protons.balance")
                // ST-5 slot: the Top up button, drawn when a pack sheet is passed in.
                if let openTopUp = callbacks.openTopUp {
                    Button(text(.topUp), action: openTopUp)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(atum.color(.ink, scheme: scheme))
                        .accessibilityIdentifier("account.settings.protons.top-up")
                }
            }
            .frame(minHeight: 52)
            settingsRow(glyph: .compass,
                        title: copy("src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore"),
                        indicator: .push,
                        identifier: "account.settings.protons.store",
                        action: callbacks.openStore)
        } header: {
            header(.howAtumAnswers)
        }
    }

    private var protonsHelp: String {
        if let value = store.walletValue {
            return AccountSettingsCopy.text(.protonsLeft, argument: value, design: design)
        }
        if store.availability == .loading { return copy("desktop.common.loading") }
        return text(.walletUnavailableHelp)
    }

    /// Your devices come first under how Atum answers (desktop `PrivacyPane`).
    @ViewBuilder private var devicesContent: some View {
        Section {
            statusRow(glyph: .deviceMobile,
                      title: UIDevice.current.name,
                      value: AccountSettingsCopy.sectionTitle(.devices, design: design)
                          + " · " + connectionText,
                      identifier: "account.settings.privacy.devices.current")
            capabilityRow(capability: presentation.settingsCapabilities.pairedDevices,
                          glyph: .users,
                          title: text(.otherDevices),
                          identifier: "account.settings.privacy.devices.others")
        } header: {
            Text(copy("src.matrix.security-copy.copies.devicesTitle"))
        }
    }

    /// The fact that is true for every chat, as on the desktop: where chats are
    /// kept, that end-to-end encryption is per chat, and what it does to memory.
    @ViewBuilder private var chatsContent: some View {
        Section {
            helpRow(glyph: .keyRound,
                    title: text(.chatsStored),
                    help: text(.chatsStoredHelp),
                    value: nil,
                    identifier: "account.settings.privacy.chats")
        } header: {
            header(.chats)
        } footer: {
            footer(text(.encryptionDetail))
        }
    }

    /// Memory is not a setting yet: one honest row and the disclosure.
    @ViewBuilder private var memoryContent: some View {
        Section {
            helpRow(glyph: .history,
                    title: text(.remembers),
                    help: text(.remembersHelp),
                    value: capabilityMessage(presentation.settingsCapabilities.memory),
                    identifier: "account.settings.privacy.memory")
        } header: {
            header(.memory)
        } footer: {
            footer(text(.memoryDisclosure))
        }
    }

    @ViewBuilder private var activityContent: some View {
        Section {
            Toggle(isOn: Binding(
                get: { shareActivity },
                set: { value in Task { _ = await setShareActivity(value) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text(.shareActivity))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    Text(text(.shareActivityHelp))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
            .tint(atum.color(.ink, scheme: scheme))
            .frame(minHeight: 52)
            .accessibilityIdentifier("account.share-activity")
        } header: {
            header(.activity)
        }
    }

    /// Always drawn, as on the desktop; the list explains how ignoring works
    /// when it is empty.
    @ViewBuilder private var ignoredContent: some View {
        Section {
            NavigationLink {
                IgnoredPeopleList(design: design, actions: actions)
            } label: {
                HStack(spacing: 12) {
                    Image(atum.symbol(.eyeOff))
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(copy("src.matrix.moderation-copy.copies.ignoredPeople"))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                }
                .frame(minHeight: 52)
            }
            .accessibilityIdentifier("account.settings.privacy.ignored")
        } footer: {
            footer(copy("src.matrix.moderation-copy.copies.ignoredHow"))
        }
    }

    // MARK: Assistants

    /// The one index of assistants, as on the desktop: a lead line, then each
    /// assistant with what it is for and whether it is ready. A ready assistant
    /// opens its own card, where everything about it lives.
    @ViewBuilder private var assistantsContent: some View {
        Section {
            if presentation.assistants.isEmpty {
                Text(text(.assistantPrepared))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("account.settings.assistants.empty")
            } else {
                ForEach(presentation.assistants) { assistant in
                    assistantRow(assistant)
                }
            }
        } header: {
            Text(text(.assistantsLead))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.settings.assistants.lead")
        }
    }

    // MARK: General

    /// Desktop's General: Look (appearance, text size, language), then
    /// Notifications. Startup is a macOS login item and stays on the Mac.
    @ViewBuilder private var generalContent: some View {
        Section {
            appearanceRow
            disabledRow(glyph: .fileText,
                        title: copy("desktop.atum.settings.textSize"),
                        value: text(.usesIOSSettings),
                        identifier: "account.settings.general.text-size")
            settingsRow(glyph: .globe,
                        title: copy("desktop.atum.account.language"),
                        value: languageName,
                        indicator: .external,
                        identifier: "account.settings.general.language",
                        action: actions.openAppSettings)
        } header: {
            Text(copy("src.matrix.settings-copy.copy.display"))
        }

        Section {
            settingsRow(glyph: .bell,
                        title: copy("src.matrix.settings-copy.copy.notifications"),
                        value: notificationValue,
                        indicator: .external,
                        identifier: "account.settings.general.notifications",
                        action: callbacks.notificationTapped)
        } header: {
            Text(copy("src.matrix.settings-copy.copy.notifications"))
        } footer: {
            footer(text(.opensIOSSettings))
        }
    }

    // MARK: Connections

    /// Desktop's Connections: the account's subscription first, then Google
    /// and the apps used in your chats. Browser logins read Chrome on a Mac
    /// and stay there. Each row says "Not available yet" until its phone
    /// adapter exists (plan v2 AC-5, wave 3 S8).
    @ViewBuilder private var connectionsContent: some View {
        Section {
            helpRow(glyph: .sparkles,
                    title: text(.yourSubscription),
                    help: text(.subscriptionHelp),
                    value: text(.notAvailableYet),
                    identifier: "account.settings.connections.subscription")
        } header: {
            Text(copy("src.matrix.model-picker-copy.COPY.subscriptions"))
        }

        Section {
            statusRow(glyph: .globe,
                      title: capabilityMessage(presentation.settingsCapabilities.google)
                          ?? text(.google),
                      value: nil,
                      identifier: "account.settings.connections.google")
        } header: {
            header(.google)
        }

        Section {
            statusRow(glyph: .compass,
                      title: text(.notAvailableYet),
                      value: nil,
                      identifier: "account.settings.connections.apps")
        } header: {
            header(.apps)
        }
    }

    // MARK: Help

    /// Desktop's Help: the version, Help improve Atum (the reports), reaching
    /// a person, then the fine print. Software updates belong to the App Store.
    @ViewBuilder private var helpContent: some View {
        Section {
            statusRow(glyph: .fileText,
                      title: copy("src.matrix.updates.copy.copy.currentVersion",
                                  [.text(presentation.version)]),
                      value: nil,
                      identifier: "account.version")
                .textSelection(.enabled)
        } header: {
            Text(copy("desktop.atum.settings.about"))
        }

        Section {
            reportingToggle(glyph: .alertCircle,
                            title: .shareCrashReports,
                            detail: .shareCrashReportsHelp,
                            isOn: crashReportsEnabled,
                            identifier: "account.share-crash-reports",
                            set: setCrashReportsEnabled)
            reportingToggle(glyph: .globe,
                            title: .shareUsageData,
                            detail: .shareUsageDataHelp,
                            isOn: usageDataEnabled,
                            identifier: "account.share-usage-data",
                            set: setUsageDataEnabled)
        } header: {
            Text(copy("src.matrix.settings-copy.copy.improve"))
        } footer: {
            footer(text(.reportingFooter))
        }

        Section {
            if callbacks.founderContactAvailable {
                settingsRow(glyph: .mail,
                            // Desktop: "Founder" under the section's "Contact us".
                            title: copy("src.matrix.founder.founder-copy.FOUNDER_COPY.name"),
                            indicator: .push,
                            identifier: "account.settings.help.contact") {
                    Task { @MainActor in
                        switch MobileFounderPolicy.contactAction(
                            founderDraftAvailable: callbacks.founderDraftAvailable
                        ) {
                        case .openDraft:
                            // Nothing exists yet: the draft opens, and its first message
                            // makes the room and its one invitation.
                            callbacks.openFounderDraft()
                        case .contactFounder:
                            guard let roomID = await callbacks.contactFounder() else { return }
                            callbacks.openFounderRoom(roomID)
                        }
                    }
                }
            } else {
                // Desktop: "Email support" when no Founder is reachable.
                settingsRow(glyph: .mail,
                            title: copy("src.matrix.founder.founder-copy.FOUNDER_COPY.emailSupport"),
                            value: AccountSupportMail.mailbox,
                            indicator: .external,
                            identifier: "account.settings.help.contact") {
                    let subject = copy("src.matrix.founder.founder-copy.FOUNDER_COPY.emailSubject")
                    if let url = AccountSupportMail.url(subject: subject) { openURL(url) }
                }
            }
        } header: {
            Text(copy("src.matrix.founder.founder-copy.FOUNDER_COPY.contactTitle"))
        }

        Section {
            settingsRow(glyph: .fileText,
                        title: copy("src.matrix.legal-copy.copy.legal"),
                        indicator: .push,
                        identifier: "account.settings.help.legal",
                        action: callbacks.openLegal)
        }
    }

    @ViewBuilder private var recoveryRows: some View {
        switch AccountRecoverySlot.decide(
            offersHistoryRecovery: presentation.offersHistoryRecovery,
            holdsRecoveryKey: presentation.holdsRecoveryKey
        ) {
        case .restoreMessages:
            settingsRow(glyph: .history,
                        title: copy("src.matrix.chat-copy.copies.restoreMessages"),
                        indicator: .push,
                        identifier: "account.settings.privacy.restore",
                        action: callbacks.restoreMessages)
        case .recoveryKey:
            settingsRow(glyph: .keyRound,
                        title: copy("src.matrix.security-copy.copies.recoveryTitle"),
                        indicator: .push,
                        identifier: "account.settings.privacy.recovery-key",
                        action: callbacks.openRecoveryKey)
        case nil:
            disabledRow(glyph: .keyRound,
                        title: copy("src.matrix.security-copy.copies.recoveryTitle"),
                        value: text(.notAvailableYet),
                        identifier: "account.settings.privacy.recovery-unavailable")
        }
    }

    private var signOutButton: some View {
        Button(action: callbacks.beginSignOut) {
            HStack(spacing: 12) {
                Image(atum.symbol(.logOut))
                    .font(.body)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(copy("desktop.dm.signOut"))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Spacer()
                if presentation.signOutInProgress {
                    AtomWait().frame(width: 20, height: 20)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation.signOutInProgress)
        .accessibilityIdentifier("account.sign-out")
    }

    /// Desktop `MatrixDeleteAccount`: a neutral action that asks first, then
    /// drafts the deletion request to Atum's privacy mailbox.
    private var deleteAccountButton: some View {
        Button { deletesAccount = true } label: {
            HStack(spacing: 12) {
                Image(atum.symbol(.trash))
                    .font(.body)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(copy("src.matrix.legal-copy.copy.deleteAccountAction"))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Spacer()
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("account.delete-account")
    }

    @ViewBuilder private func assistantRow(_ assistant: AccountAssistantSummary) -> some View {
        // Desktop: the role, then a state only while the assistant is not ready.
        let state = assistant.isReady ? nil : text(.assistantPreparing)
        let detail = [assistant.title, state].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let opens = assistant.isReady && callbacks.assistantCard != nil
        let content = HStack(spacing: 12) {
            HomeAvatar(row: assistant.homeRow, size: 36, loadMatrixThumbnail: thumbnailLoader)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: assistant.name)
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(atum.symbol(.chevronRight))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        if opens {
            Button { openedAssistant = assistant } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(text(.openAssistant) + ": " + assistant.name)
                .accessibilityValue(detail)
                .accessibilityIdentifier("account.settings.assistant." + assistant.roomID)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(assistant.name)
                .accessibilityValue(detail)
                .accessibilityIdentifier("account.settings.assistant." + assistant.roomID)
        }
    }

    /// Home's own thumbnail loader, so an assistant wears the same photo here.
    private var thumbnailLoader: ((String, Int) async -> Data?)? {
        actions.loadAvatarThumbnail.map { load in { uri, side in await load(uri, side) } }
    }

    private func capabilityRow(capability: AccountSettingsCapability,
                               glyph: AtumGlyph,
                               title: String,
                               identifier: String) -> some View {
        statusRow(glyph: glyph, title: title,
                  value: capabilityMessage(capability), identifier: identifier)
    }

    /// Nil once the capability is live: the row then says nothing about it.
    private func capabilityMessage(_ capability: AccountSettingsCapability) -> String? {
        switch AccountSettingsCapabilityStatus(capability) {
        case .loading: copy("desktop.common.loading")
        case .notAvailableYet: text(.notAvailableYet)
        case .live: nil
        }
    }

    /// How this phone is connected right now, in the desktop's own words for
    /// the same states (connected, connecting, offline, not connected).
    private var connectionText: String {
        switch presentation.connection {
        case .ready: copy("src.matrix.copy.copies.ready")
        case .connecting: copy("src.matrix.copy.copies.connecting")
        case .offline: copy("src.matrix.copy.copies.offline")
        case .error: copy("src.matrix.copy.copies.enrollmentAbsent")
        }
    }

    private var notificationValue: String? {
        switch notificationState {
        case .unknown, .notDetermined: nil
        case .on: copy("src.matrix.mobile-copy.mobilePhoneCopy.notificationsOn")
        case .off: copy("src.matrix.mobile-copy.mobilePhoneCopy.notificationsOff")
        }
    }

    private var languageName: String {
        let locale = Locale(identifier: design.locale)
        return locale.localizedString(forIdentifier: design.locale)
            ?? locale.localizedString(forLanguageCode: design.locale)
            ?? design.locale
    }

    /// Desktop's General › Look › Appearance: System, Light or Dark, as one
    /// segmented control under the title. It applies at once, to the whole
    /// app (`LiveAppearanceApplier`), and is kept on this phone.
    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(atum.symbol(.sun))
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(copy(AtumAppearance.titleKey))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
            }
            Picker(copy(AtumAppearance.titleKey), selection: $appearance) {
                ForEach(AtumAppearance.allCases) { mode in
                    Text(copy(mode.copyKey))
                        .tag(mode.rawValue)
                        .accessibilityIdentifier("account.settings.general.appearance." + mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("account.settings.general.appearance")
        }
        .padding(.vertical, 8)
        .listRowBackground(atum.kitColor(.surface, scheme: scheme))
    }

    private func reportingToggle(glyph: AtumGlyph,
                                 title: AccountSettingsText,
                                 detail: AccountSettingsText,
                                 isOn: Bool,
                                 identifier: String,
                                 set: @escaping @MainActor (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            HStack(alignment: .top, spacing: 12) {
                Image(atum.symbol(glyph))
                    .font(.body)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(text(title))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    Text(text(detail))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(atum.color(.ink, scheme: scheme))
        .frame(minHeight: 52)
        .accessibilityIdentifier(identifier)
    }

    private func settingsRow(glyph: AtumGlyph,
                             title: String,
                             value: String? = nil,
                             indicator: AtumSettingsRow.Indicator? = nil,
                             identifier: String,
                             action: @escaping () -> Void) -> some View {
        AtumSettingsRow(glyph: glyph, title: title, value: value,
                        indicator: indicator, identifier: identifier, action: action)
    }

    private func statusRow(glyph: AtumGlyph,
                           title: String,
                           value: String?,
                           identifier: String) -> some View {
        HStack(spacing: 12) {
            Image(atum.symbol(glyph))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                stackedStatus(title, value)
            } else {
                // One line when title and value both fit; otherwise the value
                // goes under the title instead of truncating either of them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statusTitle(title).fixedSize()
                        Spacer(minLength: 8)
                        if let value, !value.isEmpty {
                            Text(value)
                                .font(.body)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    stackedStatus(title, value)
                }
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier(identifier)
    }

    private func disabledRow(glyph: AtumGlyph,
                             title: String,
                             value: String,
                             identifier: String) -> some View {
        statusRow(glyph: glyph, title: title, value: value, identifier: identifier)
    }

    /// A row with a quiet second line under its title, and an optional status
    /// at the end (desktop `SettingsRow` with `help` and a status control).
    private func helpRow(glyph: AtumGlyph,
                         title: String,
                         help: String,
                         value: String?,
                         identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(atum.symbol(glyph))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                statusTitle(title)
                Text(help)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let value, !value.isEmpty, dynamicTypeSize.isAccessibilitySize {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value, !value.isEmpty, !dynamicTypeSize.isAccessibilitySize {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, help, value].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier(identifier)
    }

    private func stackedStatus(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            statusTitle(title)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func statusTitle(_ value: String) -> some View {
        Text(value)
            .font(.body)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private func header(_ value: AccountSettingsText) -> some View {
        Text(text(value))
    }

    private func footer(_ value: String) -> some View {
        Text(value)
            .font(.footnote)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .textCase(nil)
    }

    private func text(_ key: AccountSettingsText) -> String {
        AccountSettingsCopy.text(key, design: design)
    }

    private func copy(_ key: String,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}

extension AccountAssistantSummary {
    /// The row Home would draw for this assistant, so the avatar is Home's.
    var homeRow: HomeRow {
        HomeRow(id: roomID, kind: isAtum ? .atum : .assistant, name: name,
                avatarURL: avatarURL, matrixAvatarURL: matrixAvatarURL,
                avatarSHA256: avatarSHA256)
    }
}

@MainActor
enum AccountSettingsCopy {
    static func text(_ key: AccountSettingsText, design: LiveDesign) -> String {
        key.resolved(locale: design.locale) { exportKey in
            design.copy.contains(exportKey) ? design.text(exportKey) : nil
        }
    }

    /// A key whose words carry one value (`%1$@`), such as the balance line.
    static func text(_ key: AccountSettingsText, argument: String,
                     design: LiveDesign) -> String {
        if !AccountSettingsText.staleInPinnedExport.contains(key),
           design.copy.contains(key.exportKey) {
            return design.text(key.exportKey, arguments: [.text(argument)])
        }
        return key.fallback(locale: design.locale)
            .replacingOccurrences(of: "%1$@", with: argument)
    }

    static func sectionTitle(_ section: AccountSettingsSectionID,
                             design: LiveDesign) -> String {
        switch section.title(isPad: UIDevice.current.userInterfaceIdiom == .pad) {
        case let .exported(key): design.text(key)
        case let .owed(key): text(key, design: design)
        }
    }
}
