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
    var founderContactAvailable: Bool = false
    var founderContactTitle: String = "Contact us"
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
    @State private var openedAssistant: AccountAssistantSummary?
    @State private var deletesAccount = false

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    @AppStorage(AtumAppearance.storageKey) private var appearance = AtumAppearance.system.rawValue

    var body: some View {
        List {
            switch section {
            case .account:
                // Desktop's Account page: you, your Protons, Privacy & security,
                // then signing out last.
                accountContent
                protonsContent
                privacyContent
                // Desktop: Sign out, then Delete account… beside it, both neutral.
                Section {
                    signOutButton
                    deleteAccountButton
                }
            case .assistants: assistantsContent
            case .protons: protonsContent
            case .general: generalContent
            case .connections:
                // Desktop's Connections page holds "This Mac"; here, this phone.
                connectionsContent
                devicesContent
            case .devices: devicesContent
            case .privacy: privacyContent
            case .help: helpContent
            case .advanced: advancedContent
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(AccountSettingsCopy.sectionTitle(section, design: design))
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
        .accessibilityIdentifier("account.settings." + section.rawValue)
    }

    // MARK: You

    /// Who you are: name and photo (edited in place), the public handle, and
    /// signing out. Assistants, the Store and contact moved to their own pages.
    @ViewBuilder private var accountContent: some View {
        Section {
            AccountProfileHeader(design: design, presentation: presentation, actions: actions,
                                 identifierPrefix: "account.settings.account.profile",
                                 background: .cell, showsHandle: false)
        } header: {
            header(.profile)
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

    @ViewBuilder private var protonsContent: some View {
        Section {
            if let value = store.walletValue {
                HStack(spacing: 8) {
                    ProtonMark(.regular)
                    Text(verbatim: value)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(minHeight: 52)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(copy("desktop.atum.discover.protons", [.text(value)]))
                .accessibilityIdentifier("account.settings.protons.balance")
            } else {
                statusRow(glyph: .compass,
                          title: text(.protonBalance),
                          value: storeStatus,
                          identifier: "account.settings.protons.balance")
            }
            settingsRow(glyph: .compass,
                        title: copy("src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore"),
                        indicator: .push,
                        identifier: "account.settings.protons.store",
                        action: callbacks.openStore)
        } header: {
            Text(copy("desktop.atum.protons.title"))
        } footer: {
            footer(text(.noStoreKitPurchase))
        }
    }

    // MARK: The app

    @ViewBuilder private var generalContent: some View {
        Section {
            appearanceRow
            settingsRow(glyph: .globe,
                        title: copy("desktop.atum.account.language"),
                        value: languageName,
                        indicator: .external,
                        identifier: "account.settings.general.language",
                        action: actions.openAppSettings)
            disabledRow(glyph: .fileText,
                        title: text(.textSize),
                        value: text(.usesIOSSettings),
                        identifier: "account.settings.general.text-size")
        } header: {
            header(.display)
        }

        Section {
            settingsRow(glyph: .bell,
                        title: copy("src.matrix.settings-copy.copy.notifications"),
                        value: notificationValue,
                        indicator: .external,
                        identifier: "account.settings.general.notifications",
                        action: callbacks.notificationTapped)
        } header: {
            header(.notifications)
        } footer: {
            footer(text(.opensIOSSettings))
        }
    }

    @ViewBuilder private var connectionsContent: some View {
        Section {
            capabilityRow(capability: presentation.settingsCapabilities.google,
                          glyph: .globe,
                          title: "Google",
                          identifier: "account.settings.connections.google")
        }

        Section {
            if store.apps.isEmpty {
                disabledRow(glyph: .compass,
                            title: text(.apps),
                            value: storeStatus,
                            identifier: "account.settings.connections.apps")
            } else {
                ForEach(store.apps) { app in
                    statusRow(glyph: .compass,
                              title: app.title,
                              value: app.subtitle,
                              identifier: "account.settings.connections.app." + app.id)
                }
            }
        } header: {
            header(.apps)
        }
    }

    /// This phone's own page, the sibling of the desktop's "This Mac": its
    /// status, and where the things an assistant may do on a computer are set.
    @ViewBuilder private var devicesContent: some View {
        Section {
            statusRow(glyph: .deviceMobile,
                      title: UIDevice.current.name,
                      value: connectionText,
                      identifier: "account.settings.devices.current")
        } header: {
            Text(AccountSettingsCopy.sectionTitle(.devices, design: design))
        }

        Section {
            disabledRow(glyph: .clock,
                        title: text(.availability),
                        value: text(.manageOnMac),
                        identifier: "account.settings.devices.availability")
            disabledRow(glyph: .keyRound,
                        title: text(.macAccess),
                        value: text(.manageOnMac),
                        identifier: "account.settings.devices.access")
        } header: {
            header(.onYourMac)
        } footer: {
            footer(text(.macAccessHelp))
        }
    }

    /// Most protective first, as on the desktop: the recovery key, your
    /// devices, memory, chat encryption, then activity and the two reports.
    @ViewBuilder private var privacyContent: some View {
        Section {
            recoveryRows
        } header: {
            Text(copy("src.matrix.settings-copy.copy.encryptedMessages"))
        }

        Section {
            statusRow(glyph: .deviceMobile,
                      title: UIDevice.current.name,
                      value: text(.thisDevice) + " · " + connectionText,
                      identifier: "account.settings.privacy.devices.current")
            capabilityRow(capability: presentation.settingsCapabilities.pairedDevices,
                          glyph: .users,
                          title: text(.otherDevices),
                          identifier: "account.settings.privacy.devices.others")
        } header: {
            Text(copy("src.matrix.security-copy.copies.devicesTitle"))
        }

        if actions.setIgnored != nil {
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

        Section {
            statusRow(glyph: .history,
                      title: text(.remembers),
                      value: capabilityMessage(presentation.settingsCapabilities.memory),
                      identifier: "account.settings.privacy.memory")
        } header: {
            header(.memory)
        } footer: {
            footer(text(.memoryDisclosure))
        }

        Section {
            disabledRow(glyph: .keyRound,
                        title: text(.chatEncryption),
                        value: text(.notAvailable),
                        identifier: "account.settings.privacy.encryption")
        } header: {
            header(.chats)
        }

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
            header(.reportingData)
        } footer: {
            footer(text(.reportingFooter))
        }
    }

    // MARK: Help and the expert corner

    /// Reaching a person, the fine print and the version.
    @ViewBuilder private var helpContent: some View {
        Section {
            if callbacks.founderContactAvailable {
                settingsRow(glyph: .mail,
                            title: callbacks.founderContactTitle,
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
                disabledRow(glyph: .mail,
                            title: text(.contactAtum),
                            value: text(.contactUnavailable),
                            identifier: "account.settings.help.contact")
            }
        }

        Section {
            settingsRow(glyph: .fileText,
                        title: copy("src.matrix.legal-copy.copy.legal"),
                        indicator: .push,
                        identifier: "account.settings.help.legal",
                        action: callbacks.openLegal)
            statusRow(glyph: .fileText,
                      title: copy("src.matrix.updates.copy.copy.currentVersion",
                                  [.text(presentation.version)]),
                      value: nil,
                      identifier: "account.version")
                .textSelection(.enabled)
        } header: {
            Text(copy("desktop.atum.settings.about"))
        }
    }

    @ViewBuilder private var advancedContent: some View {
        Section {
            capabilityRow(capability: presentation.settingsCapabilities.advanced,
                          glyph: .globe,
                          title: text(.providersAndChatGPT),
                          identifier: "account.settings.advanced.providers")
        } header: {
            header(.providersAndRepair)
        }

        Section {
            disabledRow(glyph: .keyRound,
                        title: text(.expertTools),
                        value: text(.manageOnMac),
                        identifier: "account.settings.advanced.tools")
            disabledRow(glyph: .fileText,
                        title: text(.technicalDetails),
                        value: text(.manageOnMac),
                        identifier: "account.settings.advanced.details")
        } header: {
            header(.expertTools)
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
                        value: text(.notAvailable),
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
        disabledRow(glyph: glyph, title: title,
                    value: capabilityMessage(capability), identifier: identifier)
    }

    private func capabilityMessage(_ capability: AccountSettingsCapability) -> String {
        switch capability {
        case .unknown: text(.loadingSettings)
        case .unavailable, .available: text(.notAvailable)
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

    private var storeStatus: String {
        switch store.availability {
        case .loading: return text(.loadingSettings)
        case .ready, .empty: return text(.connected)
        case .offline, .unavailable: return text(.notAvailable)
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

    static func sectionTitle(_ section: AccountSettingsSectionID,
                             design: LiveDesign) -> String {
        switch section.title(isPad: UIDevice.current.userInterfaceIdiom == .pad) {
        case let .exported(key): design.text(key)
        case let .owed(key): text(key, design: design)
        }
    }
}
