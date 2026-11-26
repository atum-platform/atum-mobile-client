import AtumChat
import AtumDesign
import AtumNativeAPI
import PhotosUI
import SwiftUI
import UIKit

struct ChatInfoMember: Identifiable, Equatable {
    let userID: String
    let name: String
    let matrixAvatarURI: String?
    let isAssistant: Bool
    let isCurrentUser: Bool
    /// A catalog app's bot (Moon, Andy): its face is a squircle, in a group too.
    var isApp = false

    var id: String { userID }

    /// Who they are, for Report (`ReportPolicy.mayReportPerson`).
    var reportMember: ReportPolicy.Member {
        if isApp { return .app }
        return isAssistant ? .assistant : .person
    }
}

/// Report person, asked from the panel or a Members row (HC-2).
struct ReportPersonRequest: Identifiable, Equatable {
    let userID: String
    var id: String { userID }
}

enum ChatInfoAppTier {
    static func presentation(_ value: LiveProductAppVerification?) -> AppVerificationTier? {
        switch value {
        case .official?: .official
        case .verified?: .verified
        case nil: nil
        }
    }
}

struct CompanyChatInfo: Equatable {
    let companyID: String
    let companyName: String
    let channelName: String
    let members: [CompanyMemberRow]
    let membersLoading: Bool
    let leavePending: Bool
    let notice: String
    /// The platform's member count for the channel (TS-9 capsule and details).
    var memberCount: Int? = nil
    /// The company's seeded default channel, whose purpose is the desktop's localized line.
    var isDefaultChannel = false
}

struct ChatInfoPresentation {
    enum Kind: Equatable {
        case assistant
        case app(AppVerificationTier?)
        case person
        case group(memberCount: Int)
    }

    let roomID: String
    let title: String
    let subtitle: String?
    let kind: Kind
    let avatar: LiveProductAvatar?
    let matrixAvatarURI: String?
    let avatarSHA256: String?
    let avatarCandidates: [LiveProductRemoteArt]
    let accent: Color?
    let isPinned: Bool
    let isMuted: Bool
    let roomIsEncrypted: Bool
    let pinLimitReached: Bool
    let members: [ChatInfoMember]
    let actionFailureToken: UInt64
    /// Present only while this chat is a company channel: the company roster
    /// replaces the Matrix member list and the leave path lives here.
    let company: CompanyChatInfo?
    /// The platform-named Founder's ordinary human chat. Only the exact
    /// account-marked room gets the filled official-account mark and handle.
    let isFounder: Bool
    let founderHandle: String?
    /// The account's default assistant. The card is the same one as any
    /// assistant's; the flag only selects the Atum face and the name rules.
    let isPrimaryAssistant: Bool
    /// The platform's bot-handle stem when `/agents` advertises one. The phone
    /// has no alias editor yet, so nil is an honest "not visible here".
    let botHandle: String?
    /// A group's `m.room.topic`, shown under its name.
    let topic: String?
    /// The room's `m.lowpriority` tag, and whether this chat offers the switch
    /// (`RosterProjection.offersLowPriority`).
    let isLowPriority: Bool
    let offersLowPriority: Bool

    init(roomID: String, title: String, subtitle: String? = nil, kind: Kind,
         avatar: LiveProductAvatar? = nil, matrixAvatarURI: String? = nil,
         avatarSHA256: String? = nil, avatarCandidates: [LiveProductRemoteArt] = [],
         accent: Color? = nil,
         isPinned: Bool = false, isMuted: Bool = false,
         roomIsEncrypted: Bool = false,
         pinLimitReached: Bool = false, members: [ChatInfoMember] = [],
         actionFailureToken: UInt64 = 0, company: CompanyChatInfo? = nil,
         isFounder: Bool = false, founderHandle: String? = nil,
         isPrimaryAssistant: Bool = false, botHandle: String? = nil,
         topic: String? = nil, isLowPriority: Bool = false, offersLowPriority: Bool = false) {
        self.topic = topic
        self.isLowPriority = isLowPriority
        self.offersLowPriority = offersLowPriority
        self.roomID = roomID
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.avatar = avatar
        self.matrixAvatarURI = matrixAvatarURI
        self.avatarSHA256 = avatarSHA256
        self.avatarCandidates = avatarCandidates
        self.accent = accent
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.roomIsEncrypted = roomIsEncrypted
        self.pinLimitReached = pinLimitReached
        self.members = members
        self.actionFailureToken = actionFailureToken
        self.company = company
        self.isFounder = isFounder
        self.founderHandle = founderHandle
        self.isPrimaryAssistant = isPrimaryAssistant
        self.botHandle = botHandle
    }

    var avatarKind: AtumAvatarKind {
        if avatar == .eclipse { return .atum }
        return switch kind {
        case .assistant: .assistant
        case .app: .app
        case .person: .person
        case .group: .group
        }
    }

    func sortedMembers(locale: Locale) -> [ChatInfoMember] {
        members.sorted { left, right in
            if left.isCurrentUser != right.isCurrentUser { return left.isCurrentUser }
            let order = left.name.compare(right.name, options: [.caseInsensitive, .diacriticInsensitive],
                                          range: nil, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            return left.userID < right.userID
        }
    }

    /// Which panel this chat gets (`ChatPanelPolicy`).
    var panelSurface: ChatPanelPolicy.Surface {
        if company != nil { return .teamSpace }
        return switch kind {
        case .assistant: .assistant
        case .app: .app
        case .person: .person
        case .group: .group
        }
    }

    var assistantAccessCopyKey: ChatCopyKey {
        roomIsEncrypted ? .infoAssistantAccessEncrypted : .infoAssistantAccessPlain
    }
}

struct ChatInfoActions {
    var setPinned: ((String, Bool) -> Void)?
    var setMuted: ((String, Bool) -> Void)?
    var deleteAppRoom: ((String) -> Void)?
    /// Leave company. No longer offered from a channel (lane 2 D6): on the 1.1
    /// wire desktop's channel menu has no exit; Leave company lives in the
    /// company menu. Kept for hosts that still pass it.
    var leaveCompany: ((String) -> Void)?
    var assistantDefinition: AssistantDefinitionActions?
    var assistantModels: AssistantModelActions?
    var assistantModelDestinations: AssistantModelDestinationActions?
    var assistantHome: AssistantHomeActions?
    var assistantAvatar: AssistantAvatarActions?
    var assistantPresentation: AssistantPresentationActions?
    var assistantRoutines: AssistantRoutineActions?
    /// The card's bot handle editor (AS-5); nil keeps the read-only line.
    var assistantHandles: AssistantHandleActions?
    /// "Delete {name}…" for a non-primary assistant (AS-4).
    var assistantRetire: AssistantRetireActions?
    /// After a confirmed retirement: the host leaves the chat.
    var onAssistantRetired: (() -> Void)?
    /// Opens the Store on the shelf the card's Pet and Skills rows lead to
    /// (desktop's `openShelf`). Nil in hosts without a Store.
    var openStore: ((StoreSectionKind) -> Void)?
    /// "Delete chat" / "Leave group" (`ChatExitPolicy`), confirmed first.
    var exitRoom: ((String, ChatExitAction) -> Void)?
    /// Matrix ignore for a person in this chat's people.
    var setIgnored: ((String, Bool) async -> Bool)?
    /// Report person (user ID, optional reason), beside Block; true once
    /// sent. Nil hides Report (the chat screen supplies it from its store).
    var reportPerson: ((String, String?) async -> Bool)?
    /// The signed-in account is the Founder: the Founder chat is kept.
    var viewerIsFounder = false
    /// Matrix `m.lowpriority` for a person or group chat.
    var setLowPriority: ((String, Bool) -> Void)?
    /// The panel's facts that need a read of their own (the room's start, its
    /// people's power levels, the Team Spaces you share): read when the panel
    /// opens, never on the chat's own path. Nil where the host has none.
    var loadDetails: ((String) async -> ChatInfoDetails?)?
    /// Remove, ban or unban someone in a group (Matrix kick, ban, unban).
    var moderateMember: ((String, String, ChatMemberAction) async -> Bool)?
    /// Stop for my assistant's turn in progress (review C1). Nil in every
    /// host that cannot reach the platform's stop route, and then the
    /// composer offers no Stop at all (never a dead button).
    var assistantTurnStop: AssistantTurnStopActions?
    /// Opens the Shared section's photos, files and links; nil hides it.
    var sharedCollections: SharedCollectionsOpener?
    /// A company channel's own reads (intro facts, pinned messages; TS-9).
    var companyChannel: CompanyChannelActions?
    /// An app chat's declared pages (AS-11, `AppPanelPagesSection`); nil hides them.
    var appPanel: AppPanelActions?
    /// The agent's own page in its 1:1 chat (W4-E3, desktop #51); nil hides it.
    var agentDesk: AgentDeskActions?
    /// HC-7: Rename a person or group chat (desktop conversation menu).
    var rename: ChatRenameActions?
    /// Members' verified @handles, on the line under each name (desktop
    /// `MatrixMembers`). Nil shows none.
    var handles: PersonHandleLookup?
}

/// What the panel reads when it opens. Every field may be unknown; an unknown
/// one is left out of the panel, never guessed.
struct ChatInfoDetails: Equatable {
    struct Member: Equatable, Identifiable {
        let userID: String
        let name: String
        let matrixAvatarURI: String?
        let power: Int64
        let membership: ChatMemberModeration.Membership
        var id: String { userID }
    }

    /// When the chat began: its `m.room.create` event's time.
    var startedAt: Date?
    /// The Team Spaces whose rooms both of you are joined to, by name.
    var teamSpaces: [String] = []
    /// The account's ignore list (`m.ignored_user_list`).
    var ignoredUserIDs: Set<String> = []
    /// The room's power levels as they apply to you; nil leaves only Block.
    var moderation: ChatMemberModeration?
    /// Everyone the Members page lists with their power: joined, invited and banned.
    var members: [Member] = []
}

enum AssistantDefinitionLoadResult {
    case value(AgentDefinitionSnapshot)
    case failed
}

enum AssistantDefinitionSaveResult {
    case saved(AgentDefinitionSnapshot)
    case conflict(AgentDefinitionSnapshot?)
    case failed
}

struct AssistantDefinitionActions {
    let read: () async -> AssistantDefinitionLoadResult
    let save: (AgentDefinitionSnapshot, PortableAssistantDefinition) async -> AssistantDefinitionSaveResult
    /// The platform's own rename, fenced by the same revisions as the other
    /// definition writes. Nil where the host cannot rename.
    var rename: ((AgentDefinitionSnapshot, String) async -> AssistantRenameResult)?
    /// The card's Pet row value (AS-2). Nil where the host has no pet read.
    var pet: AssistantPetActions?
}

enum AssistantRenameResult {
    case renamed(AgentDefinitionSnapshot)
    case refused(AssistantNameRefusal)
    case conflict(AgentDefinitionSnapshot?)
    case failed
}

typealias AssistantModelLoadResult = PhoneModelPickerReadResult<ManagedModelSnapshot>

enum AssistantModelSaveResult {
    case saved(ManagedModelSnapshot)
    case conflict(ManagedModelSnapshot?)
    case failed
}

struct AssistantModelActions {
    let matrixAccountID: String
    let read: () async -> AssistantModelLoadResult
    let save: (ManagedModelSnapshot, String, ManagedModelEffort, NativeID) async -> AssistantModelSaveResult
}

typealias AssistantModelDestinationLoadResult = PhoneModelPickerReadResult<ManagedModelDestinationSnapshot>

enum AssistantModelDestinationSaveResult {
    case cancelled
    case saved(ManagedModelDestinationSnapshot)
    /// A conflict may carry the latest authoritative snapshot. Transport,
    /// old-provider and flag-off refusals carry nil; none is ever "saved".
    case refused(ManagedModelDestinationSnapshot?)
    /// A ChatGPT write whose consent no longer held when re-checked (a
    /// revision-conflict retry or a refusal): nothing was retried, and the
    /// picker returns to the training-off card with this fresh status.
    case consentRequired(ChatGPTTrainingStatus, latest: ManagedModelDestinationSnapshot?)
}

struct AssistantModelDestinationActions {
    let matrixAccountID: String
    let isCurrent: @MainActor () -> Bool
    let read: () async -> AssistantModelDestinationLoadResult
    let readOffer: () async -> AssistantModelLoadResult
    let save: (ManagedModelDestinationSnapshot, ManagedModelDestinationID, String, NativeID) async
        -> AssistantModelDestinationSaveResult
    /// The cloud's subscription models (`PhoneModelPicker.swift`). Nil where the host has none.
    var subscriptions: AssistantSubscriptionActions?
}

enum AssistantAvatarSaveResult { case saved, failed }

struct AssistantAvatarActions {
    let save: (AgentAvatarImage?) async -> AssistantAvatarSaveResult
}

enum AssistantPresentationLoadResult {
    case value(AgentPresentationSnapshot)
    case failed
}

enum AssistantPresentationSaveResult {
    case saved(AgentPresentationSnapshot)
    case conflict(AgentPresentationSnapshot?)
    case failed
}

struct AssistantPresentationActions {
    let read: () async -> AssistantPresentationLoadResult
    let save: (AgentPresentationSnapshot, String?, AgentMark) async -> AssistantPresentationSaveResult
}

/// The panel's home page (`ChatPanelHost`): who the chat is with, the chat's
/// own settings, then its actions. Person and group chats follow the desktop's
/// conversation info panel; the assistant's home *is* its card; app and
/// Team Space chats keep their own sections.
struct ChatInfoHome: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let actions: ChatInfoActions
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    var details: ChatInfoDetails?
    let close: () -> Void
    let open: (ChatPanelPolicy.Page) -> Void
    /// Reads the panel's details again after a change they show (Block).
    var reload: () -> Void = {}
    /// The panel's Shared scope owner (`ChatPanelHost`); nil hides the section.
    var sharedCollections: SharedCollectionsController? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmation: SheetConfirmation?
    @State private var reporting: ReportPersonRequest?
    @State private var renameRequest: ChatRenameRequest?

    private enum SheetConfirmation: Equatable {
        case deleteApp
        case exit(ChatExitAction)
        case ignore(userID: String, name: String)
    }

    /// What `ChatExitPolicy` calls this chat.
    private var exitRoom: ChatExitPolicy.Room {
        if info.company != nil { return .teamSpace }
        switch info.kind {
        case .assistant: return .assistant
        case .app: return .appBot
        case .person: return info.isFounder ? .founder : .person
        case .group: return .group
        }
    }

    private var exitAction: ChatExitAction? {
        guard actions.exitRoom != nil else { return nil }
        return ChatExitPolicy.action(for: exitRoom, viewerIsFounder: actions.viewerIsFounder)
    }

    private func mayIgnore(_ member: ChatInfoMember) -> Bool {
        actions.setIgnored != nil
            && ChatExitPolicy.mayIgnore(memberIsAssistant: member.isAssistant,
                                        memberIsSelf: member.isCurrentUser,
                                        in: exitRoom, viewerIsFounder: actions.viewerIsFounder)
    }

    /// A person chat's other person, when they may be ignored.
    private var ignorablePeer: ChatInfoMember? {
        guard exitRoom == .person || exitRoom == .founder else { return nil }
        return info.members.first { mayIgnore($0) }
    }

    /// A person chat's other person, when they may be reported (desktop
    /// `person-info-panel.tsx`: Report sits above Block). A group's people are
    /// reported from its Members page.
    private var reportablePeer: ChatInfoMember? {
        guard actions.reportPerson != nil, exitRoom == .person || exitRoom == .founder else { return nil }
        return info.members.first {
            ReportPolicy.mayReportPerson($0.reportMember, isSelf: $0.isCurrentUser, in: exitRoom,
                                         viewerIsFounder: actions.viewerIsFounder)
        }
    }

    /// A personal chat (a person or a group of people, not a Team Space room):
    /// the desktop's conversation info layout.
    private var isPersonal: Bool {
        guard info.company == nil else { return false }
        switch info.kind {
        case .person, .group: return true
        case .assistant, .app: return false
        }
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    private var kit: AtumKit { design.kit }
    private var ink: Color { atum.color(.ink, scheme: scheme) }
    /// The panel's grouped rows keep the panel's own cell colour on the sheet.
    private var rowBackground: Color { atum.color(.cell, scheme: scheme) }

    var body: some View {
        Group {
            if isAssistantInfo {
                // The assistant's info sheet *is* the assistant card: one
                // screen, every field edited where it stands. No profile
                // summary and no "Edit assistant" step.
                assistantSection
            } else {
                // One system inset-grouped list, as Settings draws its pages
                // (UX polish P2, audit issue 6): section headers, footers and
                // row highlights are the system's, not hand-drawn cards.
                List {
                    headerSection
                    if isPersonal {
                        personalSections
                    } else {
                        channelSections
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
                // One side margin for the list's groups and the full-width
                // sections it hosts (`panelEmbeddedRow`), so their edges line up.
                .contentMargins(.horizontal, kit.space(.s4), for: .scrollContent)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(atum.color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(panelTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                ChatPanelCloseButton(design: design, close: close)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming,
                            titleVisibility: .visible, presenting: confirmation) { confirmation in
            switch confirmation {
            case .deleteApp:
                Button(copy(.deleteChat), role: .destructive) {
                    actions.deleteAppRoom?(info.roomID)
                    close()
                }
            case let .exit(action):
                Button(exitTitle(action), role: .destructive) {
                    actions.exitRoom?(info.roomID, action)
                    close()
                }
            case let .ignore(userID, _):
                Button(design.text(Self.blockKey), role: .destructive) {
                    Task {
                        _ = await actions.setIgnored?(userID, true)
                        reload()
                    }
                }
            }
            Button(copy(.cancel), role: .cancel) {}
        } message: { confirmation in
            switch confirmation {
            case .deleteApp:
                Text(copy(.deleteBotChatBody, [.text(info.title)]))
            case let .exit(action):
                Text(design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChatBody"
                                                       : "src.matrix.chat-copy.copies.leaveBody"))
            case .ignore:
                Text(design.text("src.matrix.chat-copy.copies.blockPersonBody"))
            }
        }
        .sheet(item: $reporting) { request in
            ReportSheet(design: design, subject: .person) { reason in
                await actions.reportPerson?(request.userID, reason) ?? false
            }
        }

        .sensoryFeedback(.error, trigger: info.actionFailureToken)
        .onChange(of: info.actionFailureToken) { old, new in
            guard old != new else { return }
            AccessibilityNotification.Announcement(copy(.errorGeneric)).post()
        }
    }

    /// The bar's title: "Conversation info" / "Group info" in a personal chat,
    /// as on the desktop; none elsewhere (the header names the chat).
    private var panelTitle: String {
        guard isPersonal else { return "" }
        if case .group = info.kind { return design.text(PersonInfoKey.groupInfo) }
        return design.text(PersonInfoKey.conversationInfo)
    }

    // MARK: Sections

    /// Who the chat is with, centred on the panel's ground above the groups
    /// (the Settings profile header pattern).
    private var headerSection: some View {
        Section {
            header
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: kit.space(.s6), bottom: 0, trailing: kit.space(.s6)))
        }
    }

    /// Person and group chats: the desktop's conversation info panel order.
    @ViewBuilder private var personalSections: some View {
        if case let .group(memberCount) = info.kind {
            Section { membersRow(count: memberCount) }
                .listRowBackground(rowBackground)
        }
        if case .person = info.kind, let spaces = details?.teamSpaces, !spaces.isEmpty {
            teamSpacesSection(spaces)
        }
        conversationSection
        if let sharedCollections, actions.sharedCollections != nil, SharedCollectionsSection.applies(to: info) {
            Section {
                SharedCollectionsSection(design: design, info: info, open: actions.sharedCollections,
                                         controller: sharedCollections, seeAll: { open(.shared($0)) })
                    .panelEmbeddedRow(bleed: kit.space(.s4))
            }
        }
        assistantAccessSection
        exitSection
    }

    /// App and Team Space chats keep their own sections between the header
    /// and the chat's controls.
    @ViewBuilder private var channelSections: some View {
        if case .app = info.kind, let appPanel = actions.appPanel {
            Section {
                AppPanelPagesSection(design: design, appName: info.title, actions: appPanel,
                                     open: open, backToChat: close)
                    .panelEmbeddedRow(bleed: kit.space(.s4))
            }
        }
        Section {
            actionTiles
                .panelEmbeddedRow(bleed: kit.space(.s4))
        }
        assistantAccessSection
        if let company = info.company {
            Section {
                CompanyChannelInfoSection(design: design, info: info, company: company,
                                          startedAt: details?.startedAt,
                                          actions: actions.companyChannel,
                                          loadMatrixThumbnail: loadMatrixThumbnail)
                    .panelEmbeddedRow(bleed: kit.space(.s4))
            }
        }
        if case .app = info.kind { deleteSection }
        exitSection
    }

    // MARK: Personal chats (desktop)

    /// "N members" opens the group's Members page inside the panel.
    private func membersRow(count: Int) -> some View {
        NavigationLink(value: ChatPanelPolicy.Page.members) {
            HStack(spacing: kit.space(.s3)) {
                Image(atum.symbol(.users))
                Text(design.text(PersonInfoKey.members, arguments: [.number(Int64(count))]))
            }
            .foregroundStyle(ink)
        }
        .accessibilityIdentifier("info.members.open")
    }

    private func teamSpacesSection(_ spaces: [String]) -> some View {
        Section {
            ForEach(Array(spaces.enumerated()), id: \.offset) { _, name in
                HStack(spacing: kit.space(.s3)) {
                    Image(atum.symbol(.briefcase))
                    Text(verbatim: name)
                }
                .foregroundStyle(ink)
                // A container per row, so the name stays its own text.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("info.team-spaces")
            }
        } header: {
            Text(verbatim: design.text(PersonInfoKey.teamSpaces))
        }
        .listRowBackground(rowBackground)
    }

    /// The conversation's own facts and switches: encryption, when it began,
    /// pin, mute and (for an ordinary chat) low priority.
    private var conversationSection: some View {
        Section {
            factRow(glyph: .shield,
                    text: design.text(info.roomIsEncrypted ? PersonInfoKey.encrypted : PersonInfoKey.notEncrypted),
                    id: "info.encryption")
            if let startedAt = details?.startedAt {
                factRow(glyph: .clock,
                        text: design.text(PersonInfoKey.started, arguments: [.text(startedDate(startedAt))]),
                        id: "info.started")
            }
            switchRow(glyph: info.isPinned ? .pinFilled : .pin, title: copy(.pin),
                      isOn: info.isPinned, isEnabled: info.isPinned || !info.pinLimitReached,
                      id: "info.pin") { actions.setPinned?(info.roomID, $0) }
            switchRow(glyph: info.isMuted ? .bellOff : .bell, title: design.text(PersonInfoKey.muteNotifications),
                      isOn: info.isMuted, isEnabled: actions.setMuted != nil,
                      id: "info.mute") { actions.setMuted?(info.roomID, $0) }
            if info.offersLowPriority, actions.setLowPriority != nil {
                switchRow(glyph: .chevronDown, title: design.text(PersonInfoKey.lowPriority),
                          isOn: info.isLowPriority, isEnabled: true,
                          id: "info.low-priority") { actions.setLowPriority?(info.roomID, $0) }
            }
            if let rename = actions.rename, !info.isFounder {
                renameRow(rename)
            }
        } header: {
            Text(verbatim: design.text(PersonInfoKey.conversation))
                .accessibilityIdentifier("info.conversation")
        } footer: {
            if !info.isPinned, info.pinLimitReached {
                Text(copy(.pinLimit))
            }
        }
        .listRowBackground(rowBackground)
    }

    /// HC-7: Rename (desktop conversation menu): your own name for the chat,
    /// or the group's name for everyone when you may name it.
    private func renameRow(_ rename: ChatRenameActions) -> some View {
        Button {
            let roomID = info.roomID
            Task {
                guard let request = await rename.request(roomID) else { return }
                renameRequest = request
            }
        } label: {
            HStack(spacing: kit.space(.s3)) {
                Image(atum.symbol(.pencil))
                Text(copy(.rename))
            }
            .foregroundStyle(ink)
        }
        .accessibilityIdentifier("info.rename")
        // On the row, so the panel's own dialogs (Block, Delete) keep their
        // presentation host to themselves.
        .chatRenameAlert($renameRequest, design: design) { request, name in
            await rename.save(request, name)
        }
    }

    private func factRow(glyph: AtumGlyph, text: String, id: String) -> some View {
        HStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(glyph))
            Text(verbatim: text)
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func switchRow(glyph: AtumGlyph, title: String, isOn: Bool, isEnabled: Bool,
                           id: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            HStack(spacing: kit.space(.s3)) {
                Image(atum.symbol(glyph))
                Text(verbatim: title)
            }
        }
        .tint(atum.color(.actionStrong, scheme: scheme))
        .foregroundStyle(ink)
        .disabled(!isEnabled)
        .accessibilityIdentifier(id)
    }

    private func startedDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted)
            .locale(Locale(identifier: design.locale)))
    }

    private var header: some View {
        VStack(spacing: kit.space(.s2)) {
            ChatInfoAvatar(info: info, size: 72, loadMatrixThumbnail: loadMatrixThumbnail)
            HStack(spacing: kit.space(.s2)) {
                Text(verbatim: info.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if case let .app(verification) = info.kind {
                    AppSeal(tier: verification, placement: .chatTitle)
                } else if info.isFounder {
                    AppSeal(tier: .official, placement: .chatTitle, label: .officialAccount)
                }
            }
            if let subtitle = info.subtitle {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
            if info.isFounder, let handle = info.founderHandle {
                Text(verbatim: "@" + handle)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityIdentifier("chat.info.founder.handle")
            }
            if isPersonal, case .group = info.kind, let topic = info.topic, !topic.isEmpty {
                Text(verbatim: topic)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .accessibilityIdentifier("info.topic")
            }
            if let kindLine {
                Text(kindLine)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pin and Mute for app and Team Space chats: two tiles under the header
    /// (desktop's quick actions), side by side or stacked at accessibility sizes.
    @ViewBuilder private var actionTiles: some View {
        let tiles = Group {
            infoAction(isEnabled: info.isPinned || !info.pinLimitReached,
                       glyph: info.isPinned ? .pinOff : .pin,
                       label: info.isPinned ? .unpin : .pin,
                       id: "info.pin") {
                actions.setPinned?(info.roomID, !info.isPinned)
            }
            infoAction(isEnabled: true,
                       glyph: info.isMuted ? .bell : .bellOff,
                       label: info.isMuted ? .unmute : .mute,
                       id: "info.mute") {
                actions.setMuted?(info.roomID, !info.isMuted)
            }
        }
        VStack(spacing: kit.space(.s2)) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: kit.space(.s3)) { tiles }
            } else {
                HStack(spacing: kit.space(.s3)) { tiles }
            }
            if !info.isPinned, info.pinLimitReached {
                Text(copy(.pinLimit))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, kit.space(.s4))
    }

    private func infoAction(isEnabled: Bool, glyph: AtumGlyph, label: ChatCopyKey,
                            id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: kit.space(.s2)) {
                Image(atum.symbol(glyph)).font(.title3)
                Text(copy(label)).font(.footnote)
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(rowBackground,
                        in: RoundedRectangle(cornerRadius: kit.phoneRadius(.sm), style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }

    private var assistantAccessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: kit.space(.s2)) {
                HStack(spacing: kit.space(.s3)) {
                    Image(atum.symbol(.keyRound))
                    Text(copy(.infoAssistantAccessTitle))
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(ink)

                Text(copy(info.assistantAccessCopyKey))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, kit.space(.s1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("info.assistant-access")
        }
        .listRowBackground(rowBackground)
    }

    private var isAssistantInfo: Bool {
        if case .assistant = info.kind { return true }
        return false
    }

    private var assistantSection: some View {
        AssistantCard(
            design: design,
            identity: AssistantCardIdentity(
                roomID: info.roomID,
                name: info.title,
                title: info.subtitle,
                botHandle: info.botHandle,
                isPrimary: info.isPrimaryAssistant,
                avatar: info.avatar,
                matrixAvatarURI: info.matrixAvatarURI,
                avatarSHA256: info.avatarSHA256,
                avatarCandidates: info.avatarCandidates
            ),
            entry: .chatInfo,
            definition: actions.assistantDefinition,
            models: actions.assistantModels,
            home: actions.assistantHome,
            modelDestinations: actions.assistantModelDestinations,
            avatar: actions.assistantAvatar,
            routines: actions.assistantRoutines,
            loadMatrixThumbnail: loadMatrixThumbnail,
            onMessage: { close() },
            onOpenStore: actions.openStore.map { openStore in { shelf in close(); openStore(shelf) } },
            handles: actions.assistantHandles,
            retire: actions.assistantRetire,
            onRetired: {
                close()
                actions.onAssistantRetired?()
            }
        )
    }


    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } })
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .deleteApp: copy(.deleteChatTitle)
        case let .exit(action):
            design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChatTitle"
                                              : "src.matrix.chat-copy.copies.leaveTitle")
        case .ignore:
            design.text("src.matrix.chat-copy.copies.blockPersonTitle")
        case nil: ""
        }
    }

    /// Block and Unblock (Matrix `m.ignored_user_list`), with the desktop's words.
    static let blockKey = "src.matrix.chat-copy.copies.blockPerson"
    static let unblockKey = "src.matrix.chat-copy.copies.unblockPerson"

    private func exitTitle(_ action: ChatExitAction) -> String {
        design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChat" : "desktop.dm.group.leave")
    }

    /// Report and Block the other person (person chats) and Delete chat /
    /// Leave group, in one quiet group at the end, as on the desktop. Block is
    /// undone in place.
    @ViewBuilder private var exitSection: some View {
        if reportablePeer != nil || ignorablePeer != nil || exitAction != nil {
            Section {
                if let peer = reportablePeer {
                    // PENDING-COPY:src.matrix.chat-copy.copies.reportPerson
                    actionRow(glyph: .alertCircle, title: ReportCopy.text(design, .reportPerson),
                              tone: .ink, id: "info.report") {
                        reporting = ReportPersonRequest(userID: peer.userID)
                    }
                }
                if let peer = ignorablePeer {
                    let blocked = details?.ignoredUserIDs.contains(peer.userID) == true
                    actionRow(glyph: .eyeOff, title: design.text(blocked ? Self.unblockKey : Self.blockKey),
                              tone: .ink, id: blocked ? "info.unblock" : "info.block") {
                        if blocked {
                            Task {
                                _ = await actions.setIgnored?(peer.userID, false)
                                reload()
                            }
                        } else {
                            confirmation = .ignore(userID: peer.userID, name: peer.name)
                        }
                    }
                }
                if let exitAction {
                    actionRow(glyph: exitAction == .deleteChat ? .trash : .logOut,
                              title: exitTitle(exitAction), tone: .danger,
                              id: "info.exit." + exitAction.rawValue) {
                        confirmation = .exit(exitAction)
                    }
                }
            }
            .listRowBackground(rowBackground)
        }
    }

    private func actionRow(glyph: AtumGlyph, title: String, tone: AtumColorRole, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(role: tone == .danger ? .destructive : nil, action: action) {
            HStack(spacing: kit.space(.s3)) {
                Image(atum.symbol(glyph))
                Text(verbatim: title)
            }
            .foregroundStyle(atum.color(tone, scheme: scheme))
        }
        .accessibilityIdentifier(id)
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) { confirmation = .deleteApp } label: {
                HStack(spacing: kit.space(.s3)) {
                    Image(atum.symbol(.trash))
                    Text(copy(.deleteChat))
                }
                .foregroundStyle(atum.color(.danger, scheme: scheme))
            }
            .accessibilityIdentifier("info.delete")
        }
        .listRowBackground(rowBackground)
    }

    private var kindLine: String? {
        switch info.kind {
        case .assistant: copy(.infoKindAssistant)
        case let .app(verification?): copy(verification == .verified ? .partnerApp : .firstPartyApp)
        case .app(nil): nil
        case .person: nil
        case let .group(memberCount):
            // A personal group says its count on the Members row instead.
            isPersonal ? nil : copy(.infoMemberCount, [.number(Int64(memberCount))])
        }
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        ChatCopy.text(design, key, arguments)
    }

}

enum AssistantAvatarPhoto {
    enum Failure: Error { case unreadable, tooLarge }

    /// Bakes orientation, crops a square and re-encodes without source
    /// metadata. The provider's hard boundary is 2 MiB; progressively smaller
    /// renders avoid uploading an image it will necessarily reject.
    @MainActor static func prepare(_ data: Data) throws -> AgentAvatarImage {
        guard !data.isEmpty, let source = UIImage(data: data),
              source.size.width > 0, source.size.height > 0 else { throw Failure.unreadable }
        let maximum = max(source.size.width, source.size.height)
        let first = max(64, min(1_024, Int(maximum.rounded(.up))))
        let sides = Array(Set([first, min(first, 768), min(first, 512)])).sorted(by: >)
        for side in sides {
            let size = CGFloat(side)
            let scale = max(size / source.size.width, size / source.size.height)
            let draw = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = CGPoint(x: (size - draw.width) / 2, y: (size - draw.height) / 2)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = true
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
                .image { context in
                    UIColor.black.setFill()
                    context.cgContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
                    source.draw(in: CGRect(origin: origin, size: draw))
                }
            for quality in [0.86, 0.72, 0.56] {
                guard let encoded = rendered.jpegData(compressionQuality: quality) else { continue }
                if encoded.count <= 2 * 1_024 * 1_024 {
                    return try AgentAvatarImage(type: .jpeg, data: encoded)
                }
            }
        }
        throw Failure.tooLarge
    }
}

struct ChatInfoAvatar: View {
    let info: ChatInfoPresentation
    let size: CGFloat
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    var body: some View {
        if info.isFounder {
            FounderRavenAvatar(size: size, fallbackName: info.title)
        } else {
            // Seeded from the memo: the Home row's photo is on the title's
            // first frame (before 25 Nov 2026 it started blank every time the
            // view was made, so the face blinked as the chat opened).
            AtumSourcedAvatar(kind: info.avatarKind, name: info.title, mark: info.avatar?.agentMark,
                              size: size, source: info.avatarSource, identity: info.roomID,
                              loadMatrixThumbnail: loadMatrixThumbnail)
        }
    }
}

extension ChatInfoPresentation {
    @MainActor var avatarSource: AtumAvatarSource {
        AtumAvatarSource(matrixURI: matrixAvatarURI, avatar: avatar, sha256: avatarSHA256,
                         declared: avatarCandidates)
    }
}

/// A member's face: circles for people and assistants, a squircle for an
/// app's bot (STYLE.md §5).
struct ChatInfoMemberAvatar: View {
    let member: ChatInfoMember
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    @State private var art: AtumAvatarArt?

    var body: some View {
        AtumAvatar(kind: .member(isApp: member.isApp, isAssistant: member.isAssistant),
                   name: member.name, art: art, size: 32)
            .task(id: member.matrixAvatarURI) {
                art = nil
                guard let uri = member.matrixAvatarURI, let loadMatrixThumbnail,
                      let data = await loadMatrixThumbnail(uri, AtumAvatar.thumbnailPixelSide(for: 32)),
                      !Task.isCancelled else { return }
                let loaded = await AtumAvatarArt.load(data: data, pixelSide: AtumAvatar.thumbnailPixelSide(for: 32))
                guard !Task.isCancelled else { return }
                art = loaded
            }
    }
}

/// The conversation info panel's words, exported from the desktop's
/// `person-info-copy.ts`.
enum PersonInfoKey {
    private static let prefix = "src.matrix.person-info-copy.copy."
    static let conversationInfo = prefix + "conversationInfo"
    static let groupInfo = prefix + "groupInfo"
    static let showInfo = prefix + "showInfo"
    static let closeInfo = prefix + "closeInfo"
    static let teamSpaces = prefix + "teamSpaces"
    static let conversation = prefix + "conversation"
    static let encrypted = prefix + "encrypted"
    static let notEncrypted = prefix + "notEncrypted"
    static let started = prefix + "started"
    static let members = prefix + "members"
    static let muteNotifications = prefix + "muteNotifications"
    static let lowPriority = prefix + "lowPriority"
    static let back = prefix + "back"
    static let loading = prefix + "loading"
    static let failed = prefix + "failed"
    static let tryAgain = prefix + "tryAgain"
}

extension View {
    /// A section another view draws in full (Shared, an app's pages, a Team
    /// Space channel's details) inside the panel's grouped list: no row
    /// background or insets, and widened by the list's side margin so its own
    /// 16 pt edges line up with the list's groups. Its buttons stay where they
    /// are drawn, so a tap never runs every button in the row.
    func panelEmbeddedRow(bleed: CGFloat) -> some View {
        buttonStyle(.borderless)
            .padding(.horizontal, -bleed)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}
