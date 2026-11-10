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
    /// Leaving a company channel leaves the company (the channel's roster is
    /// the company roster).
    var leaveCompany: ((String) -> Void)?
    var assistantDefinition: AssistantDefinitionActions?
    var assistantModels: AssistantModelActions?
    var assistantModelDestinations: AssistantModelDestinationActions?
    var assistantHome: AssistantHomeActions?
    var assistantAvatar: AssistantAvatarActions?
    var assistantPresentation: AssistantPresentationActions?
    var assistantRoutines: AssistantRoutineActions?
    /// Opens the Store, where the card's Pet and Skills rows lead (desktop
    /// opens the same shelves). Nil in hosts without a Store.
    var openStore: (() -> Void)?
    /// "Delete chat" / "Leave group" (`ChatExitPolicy`), confirmed first.
    var exitRoom: ((String, ChatExitAction) -> Void)?
    /// Matrix ignore for a person in this chat's people.
    var setIgnored: ((String, Bool) async -> Bool)?
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
}

enum AssistantRenameResult {
    case renamed(AgentDefinitionSnapshot)
    case refused(AssistantNameRefusal)
    case conflict(AgentDefinitionSnapshot?)
    case failed
}

enum AssistantModelLoadResult {
    case value(ManagedModelSnapshot)
    case unavailable
    case failed
}

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

struct AssistantModelDestinationValue: Equatable {
    var snapshot: ManagedModelDestinationSnapshot
    /// The cloud aliases the provider says are usable now. Mac destinations
    /// use the locally supported Atum lineup and do not inherit this set.
    let cloudEligibleAliases: Set<String>
}

enum AssistantModelDestinationLoadResult {
    case value(AssistantModelDestinationValue)
    case unavailable
    case failed
}

enum AssistantModelDestinationSaveResult {
    case saved(ManagedModelDestinationSnapshot)
    /// A conflict may carry the latest authoritative snapshot. Transport,
    /// old-provider and flag-off refusals carry nil; none is ever "saved".
    case refused(ManagedModelDestinationSnapshot?)
}

struct AssistantModelDestinationActions {
    let matrixAccountID: String
    let read: () async -> AssistantModelDestinationLoadResult
    let save: (ManagedModelDestinationSnapshot, ManagedModelDestinationID, String, NativeID) async
        -> AssistantModelDestinationSaveResult
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

    private enum SheetConfirmation: Equatable {
        case leaveCompany
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

    var body: some View {
        Group {
            if isAssistantInfo {
                // The assistant's info sheet *is* the assistant card: one
                // screen, every field edited where it stands. No profile
                // summary and no "Edit assistant" step.
                assistantSection
            } else if isPersonal {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        if case .group = info.kind { membersRow.padding(.top, 20) }
                        if case .person = info.kind, let spaces = details?.teamSpaces, !spaces.isEmpty {
                            teamSpacesSection(spaces).padding(.top, 24)
                        }
                        conversationSection.padding(.top, 24)
                        if let sharedCollections {
                            SharedCollectionsSection(design: design, info: info, open: actions.sharedCollections,
                                                     controller: sharedCollections, seeAll: { open(.shared($0)) })
                        }
                        assistantAccessSection.padding(.top, 24)
                        exitSection.padding(.top, 24)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        actionTiles
                            .padding(.top, 20)
                        assistantAccessSection.padding(.top, 24)
                        if let company = info.company {
                            companySection(company).padding(.top, 24)
                        }
                        if case .app = info.kind { deleteSection.padding(.top, 24) }
                        exitSection.padding(.top, 24)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
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
            case .leaveCompany:
                Button(companyCopy.leaveConfirm, role: .destructive) {
                    if let company = info.company { actions.leaveCompany?(company.companyID) }
                    close()
                }
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
            case .leaveCompany:
                Text(verbatim: companyCopy.leaveMessage)
            case .deleteApp:
                Text(copy(.deleteBotChatBody, [.text(info.title)]))
            case let .exit(action):
                Text(design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChatBody"
                                                       : "src.matrix.chat-copy.copies.leaveBody"))
            case .ignore:
                Text(design.text("src.matrix.chat-copy.copies.blockPersonBody"))
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

    // MARK: Personal chats (desktop)

    /// "N members" opens the group's Members page inside the panel.
    private var membersRow: some View {
        let count: Int = if case let .group(memberCount) = info.kind { memberCount } else { 0 }
        return Button { open(.members) } label: {
            HStack(spacing: 12) {
                Image(atum.symbol(.users))
                Text(design.text(PersonInfoKey.members, arguments: [.number(Int64(count))]))
                Spacer()
                Image(atum.symbol(.chevronRight))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
            }
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("info.members.open")
    }

    private func teamSpacesSection(_ spaces: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(design.text(PersonInfoKey.teamSpaces))
            VStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 12) {
                        Image(atum.symbol(.briefcase))
                        Text(verbatim: name)
                        Spacer()
                    }
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    if index < spaces.count - 1 { Divider().padding(.leading, 48) }
                }
            }
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.team-spaces")
    }

    /// The conversation's own facts and switches: encryption, when it began,
    /// pin, mute and (for an ordinary chat) low priority.
    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(design.text(PersonInfoKey.conversation))
            VStack(spacing: 0) {
                factRow(glyph: .shield,
                        text: design.text(info.roomIsEncrypted ? PersonInfoKey.encrypted : PersonInfoKey.notEncrypted),
                        id: "info.encryption")
                if let startedAt = details?.startedAt {
                    Divider().padding(.leading, 48)
                    factRow(glyph: .clock,
                            text: design.text(PersonInfoKey.started, arguments: [.text(startedDate(startedAt))]),
                            id: "info.started")
                }
                Divider().padding(.leading, 48)
                switchRow(glyph: info.isPinned ? .pinFilled : .pin, title: copy(.pin),
                          isOn: info.isPinned, isEnabled: info.isPinned || !info.pinLimitReached,
                          id: "info.pin") { actions.setPinned?(info.roomID, $0) }
                Divider().padding(.leading, 48)
                switchRow(glyph: info.isMuted ? .bellOff : .bell, title: design.text(PersonInfoKey.muteNotifications),
                          isOn: info.isMuted, isEnabled: actions.setMuted != nil,
                          id: "info.mute") { actions.setMuted?(info.roomID, $0) }
                if info.offersLowPriority, actions.setLowPriority != nil {
                    Divider().padding(.leading, 48)
                    switchRow(glyph: .chevronDown, title: design.text(PersonInfoKey.lowPriority),
                              isOn: info.isLowPriority, isEnabled: true,
                              id: "info.low-priority") { actions.setLowPriority?(info.roomID, $0) }
                }
            }
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            if !info.isPinned, info.pinLimitReached {
                Text(copy(.pinLimit))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .padding(.horizontal, 32)
            }
        }
        // A container of its own, so its rows keep their identifiers (on a
        // plain stack the identifier is handed down and replaces theirs).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.conversation")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .padding(.horizontal, 32)
            .accessibilityAddTraits(.isHeader)
    }

    private func factRow(glyph: AtumGlyph, text: String, id: String) -> some View {
        HStack(spacing: 12) {
            Image(atum.symbol(glyph))
            Text(verbatim: text)
            Spacer()
        }
        .foregroundStyle(atum.color(.ink, scheme: scheme))
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func switchRow(glyph: AtumGlyph, title: String, isOn: Bool, isEnabled: Bool,
                           id: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            HStack(spacing: 12) {
                Image(atum.symbol(glyph))
                Text(verbatim: title)
            }
        }
        .tint(atum.color(.actionStrong, scheme: scheme))
        .foregroundStyle(atum.color(.ink, scheme: scheme))
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .disabled(!isEnabled)
        .accessibilityIdentifier(id)
    }

    private func startedDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted)
            .locale(Locale(identifier: design.locale)))
    }

    private var header: some View {
        VStack(spacing: 8) {
            ChatInfoAvatar(info: info, size: 72, loadMatrixThumbnail: loadMatrixThumbnail)
            HStack(spacing: 6) {
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
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

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
        VStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) { tiles }
            } else {
                HStack(spacing: 12) { tiles }
            }
            if !info.isPinned, info.pinLimitReached {
                Text(copy(.pinLimit))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
    }

    private func infoAction(isEnabled: Bool, glyph: AtumGlyph, label: ChatCopyKey,
                            id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(atum.symbol(glyph)).font(.title3)
                Text(copy(label)).font(.footnote)
            }
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier(id)
    }

    private var assistantAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(copy(.infoAssistantAccessTitle))
                    .font(.footnote.weight(.semibold))
            } icon: {
                Image(atum.symbol(.keyRound))
            }
            .foregroundStyle(atum.color(.ink, scheme: scheme))

            Text(copy(info.assistantAccessCopyKey))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("info.assistant-access")
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
            onOpenStore: actions.openStore.map { openStore in { close(); openStore() } }
        )
    }

    private var companyCopy: CompanyCopy { CompanyCopy(design: design) }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } })
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .leaveCompany: companyCopy.leaveTitle(company: info.company?.companyName ?? "")
        case .deleteApp: copy(.deleteChatTitle)
        case let .exit(action):
            design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChatTitle"
                                              : "src.matrix.chat-copy.copies.leaveTitle")
        case .ignore:
            design.text("src.matrix.chat-copy.copies.blockPersonTitle")
        case nil: ""
        }
    }

    @ViewBuilder private func companySection(_ company: CompanyChatInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: company.notice)
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("info.company.notice")
            Text(companyCopy.membersTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: 0) {
                if company.membersLoading && company.members.isEmpty {
                    Text(verbatim: companyCopy.text(CompanyCopyKey("loading")))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 44)
                }
                ForEach(company.members) { member in
                    HStack(spacing: 12) {
                        Image(atum.symbol(.userCircle))
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: member.name).font(.body)
                            HStack(spacing: 4) {
                                if let handle = member.handle { Text(verbatim: "@" + handle) }
                                Text(verbatim: member.role)
                                if let state = member.state { Text(verbatim: "· " + state) }
                            }
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                        Spacer()
                        if member.isSelf {
                            Text(copy(.you))
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("info.company.member." + member.id)
                    if member.id != company.members.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .accessibilityIdentifier("info.company.members")

            Button(role: .destructive) {
                guard !company.leavePending else { return }
                confirmation = .leaveCompany
            } label: {
                HStack(spacing: 12) {
                    Image(atum.symbol(.logOut))
                    Text(verbatim: company.leavePending
                         ? companyCopy.leavePending
                         : companyCopy.leaveAction)
                    Spacer()
                }
                .foregroundStyle(atum.color(.danger, scheme: scheme))
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(atum.color(.cell, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(company.leavePending)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("info.company.leave")
        }
    }

    /// Block and Unblock (Matrix `m.ignored_user_list`), with the desktop's words.
    static let blockKey = "src.matrix.chat-copy.copies.blockPerson"
    static let unblockKey = "src.matrix.chat-copy.copies.unblockPerson"

    private func exitTitle(_ action: ChatExitAction) -> String {
        design.text(action == .deleteChat ? "src.matrix.chat-copy.copies.deleteChat" : "desktop.dm.group.leave")
    }

    /// Block the other person (person chats) and Delete chat / Leave group, in
    /// one quiet group at the end, as on the desktop. Block is undone in place.
    @ViewBuilder private var exitSection: some View {
        if ignorablePeer != nil || exitAction != nil {
            VStack(spacing: 0) {
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
                    if exitAction != nil { Divider().padding(.leading, 48) }
                }
                if let exitAction {
                    actionRow(glyph: exitAction == .deleteChat ? .trash : .logOut,
                              title: exitTitle(exitAction), tone: .danger,
                              id: "info.exit." + exitAction.rawValue) {
                        confirmation = .exit(exitAction)
                    }
                }
            }
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func actionRow(glyph: AtumGlyph, title: String, tone: AtumColorRole, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(role: tone == .danger ? .destructive : nil, action: action) {
            HStack(spacing: 12) {
                Image(atum.symbol(glyph))
                Text(verbatim: title)
                Spacer()
            }
            .foregroundStyle(atum.color(tone, scheme: scheme))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var deleteSection: some View {
        Button(role: .destructive) { confirmation = .deleteApp } label: {
            HStack(spacing: 12) {
                Image(atum.symbol(.trash))
                Text(copy(.deleteChat))
                Spacer()
            }
            .foregroundStyle(atum.color(.danger, scheme: scheme))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("info.delete")
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

    @State private var art: AtumAvatarArt?

    var body: some View {
        Group {
            if info.isFounder {
                FounderRavenAvatar(size: size, fallbackName: info.title)
            } else {
                AtumAvatar(kind: info.avatarKind, name: info.title, art: art, size: size)
                    .task(id: Request(avatar: info.avatar, matrixURI: info.matrixAvatarURI,
                                      sha256: info.avatarSHA256,
                                      candidates: info.avatarCandidates, size: size)) {
                        art = nil
                        let pixelSide = AtumAvatar.thumbnailPixelSide(for: size)
                        art = await AtumAvatarCandidateLoader.load(
                            matrixURI: info.matrixAvatarURI,
                            pixelSide: pixelSide,
                            loadMatrixThumbnail: loadMatrixThumbnail,
                            remoteCandidates: AtumAvatarCandidateLoader.candidates(
                                avatar: info.avatar,
                                sha256: info.avatarSHA256,
                                declared: info.avatarCandidates
                            )
                        )
                    }
            }
        }
    }

    private struct Request: Hashable {
        let avatarDescription: String
        let matrixURI: String?
        let sha256: String?
        let candidates: [LiveProductRemoteArt]
        let size: CGFloat

        init(avatar: LiveProductAvatar?, matrixURI: String?, sha256: String?,
             candidates: [LiveProductRemoteArt], size: CGFloat) {
            avatarDescription = String(describing: avatar)
            self.matrixURI = matrixURI
            self.sha256 = sha256
            self.candidates = candidates
            self.size = size
        }
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
