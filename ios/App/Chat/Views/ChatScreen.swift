import AtumChat
import QuickLook
import SwiftUI
import UIKit

/// App-drawn words for the exact account-marked Founder room. The resolver is
/// deliberately room-ID based: a copied name, handle or avatar cannot produce
/// the card or its official mark.
struct FounderIntroPresentation: Equatable, Sendable {
    let name: String
    let subtitle: String
    let intro: String

    static func exactRoom(roomID: String, founderRoomID: String?,
                          isFounderAccount: Bool, name: String,
                          subtitle: String, intro: String) -> Self? {
        guard !isFounderAccount, roomID == founderRoomID else { return nil }
        return Self(name: name, subtitle: subtitle, intro: intro)
    }
}

/// The chat (plan §3.3), pushed from Home in a `NavigationStack` (B31): the
/// system back button and edge swipe, a title capsule with avatar and name,
/// the connection glyph (B30), the transcript, the jump pill floating above
/// the composer in one glass container (one bottom glass layer, §3.9), and the
/// empty-chat greeting.
///
/// It reads the store only through the frozen `ConversationStore` surface.
/// The rows' one `ChatActions` value is the store's, with the reaction tick
/// (`ChatHaptics`, B26) and every link tap routed to `ChatLinkRouter` (B17).
/// The long-press menu's and the failed-send mark's presentations (the
/// select-text sheet, the delete confirmation, the failed-send sheet) hang
/// here once, driven by one `MessageActionsPresenter` (B8, B20).
struct ChatScreen: View {
    let store: LiveConversationStore
    let design: LiveDesign
    /// The chat's avatar as Home shows it (§3.3, §3.9, §4.6): Atum's eclipse,
    /// the agent's photo, the catalog bot's avatar; nil for a monogram.
    var avatar: LiveProductAvatar? = nil
    var info: ChatInfoPresentation? = nil
    /// A team space chat outside a company channel's info (scripted
    /// captures): it reads as flat runs too.
    var teamSpaceChat = false
    var infoActions = ChatInfoActions()
    var appBot: AppBotPresentation? = nil
    var appBotCatalog = AppBotCatalogPresentation.empty
    var onOpenAppBot: @MainActor @Sendable (String) -> Void = { _ in }
    var onBeginAppBotSetup: @MainActor @Sendable (AppBotPresentation) -> Bool = { _ in false }
    var onOpenAppBotRoute: @MainActor @Sendable (AppBotPresentation, String) -> Bool = { _, _ in false }
    var onOpenAppBotTerms: @MainActor @Sendable (URL) -> Void = { _ in }
    var appOnboardingPresented = false
    var mediaAccess = ChatMediaAccess()
    var loadMatrixThumbnail: ((String, Int) async -> Data?)? = nil
    /// The account's first-run greeting, only for the default assistant's open
    /// chat while the account-wide marker is unseen.
    var firstRunContext: FirstRunContext? = nil
    /// The empty exact Founder chat's local card. This is presentation, never
    /// a Matrix event or a message sent on the Founder's behalf.
    var founderIntro: FounderIntroPresentation? = nil
    /// The company channel's non-E2EE line, shown above the composer until
    /// the person's first message in this chat.
    var companyNotice: String? = nil
    /// A company DM or group DM: its own header menu (Add people, Hide), the privacy note, and
    /// on a read-only one a banner in place of the composer. Files are closed for now.
    var conversationChat: ConversationChatPresentation? = nil
    var conversationActions = ConversationChatActions()
    var dismissPresentationRequest: UInt64 = 0
    var onPresentationChanged: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.showsConnectionGlyph) private var showsConnectionGlyph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var links = ChatLinkRouter()
    @State private var chrome = ChatChrome()
    @State private var haptics = ChatHaptics()
    @State private var presenter = MessageActionsPresenter()
    @State private var appBotPresenter = AppBotPresenter()
    @State private var mediaPresenter = ChatMediaPresenter()
    @State private var appBotNoticeDisplays = [String: AppBotNoticeDisplay]()
    @Namespace private var mediaNamespace
    @State private var infoPresented = false
    @State private var composerModelPresented = false
    @State private var composerModelRefreshToken: UInt64 = 0
    @State private var confirmsCompanyLeave = false
    @State private var addPeoplePresented = false
    /// Today, for the day dividers (B14): updated at midnight and when the
    /// app comes back, so a chat left open overnight relabels its days.
    @State private var today = Calendar.current.startOfDay(for: Date())

    var body: some View {
        let theme = ChatTheme(design: design)
        let actions = links.actions(for: store, base: haptics.actions(of: store))
        // B13: nothing is read while something covers the chat: the in-app
        // Safari page, the held-link line, a sheet or the delete confirmation.
        let covered = links.presented != nil || links.showsHeld || presenter.covers || infoPresented
            || composerModelPresented
            || appBotPresenter.covers || appOnboardingPresented || mediaPresenter.covers
        let appBotProjection = AppBotNoticeProjectionInput(rows: store.snapshot.rows,
                                                           catalog: appBotCatalog,
                                                           roomID: store.roomID,
                                                           roomIsEncrypted: store.roomIsEncrypted)
        let members = Dictionary(uniqueKeysWithValues: (info?.members ?? []).map { ($0.userID, $0) })
        let roomFace = ChatFace.room(avatar, matrixURI: info?.matrixAvatarURI,
                                     sha256: info?.avatarSHA256,
                                     candidates: info?.avatarCandidates ?? [],
                                     name: info?.title ?? store.title,
                                     kind: Self.avatarKind(store.kind))
        TranscriptView(store: store, chrome: chrome, covered: covered)
            .overlay {
                if Self.isEmptyChat(rows: store.snapshot.rows, pagination: store.pagination) {
                    if let founderIntro {
                        FounderIntroCard(presentation: founderIntro, design: design)
                    } else if let firstRunContext {
                        // The binding is read-only on purpose: typing in the
                        // real composer dismisses onboarding, but this view
                        // never writes, replaces or sends the draft.
                        FirstRunGreetingView(
                            design: design,
                            context: firstRunContext,
                            composerDraft: Binding(get: { store.draft }, set: { _ in })
                        )
                    } else if let appBot {
                        AppBotHero(app: appBot, design: design)
                    } else {
                        EmptyChatGreeting()
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                GlassEffectContainer(spacing: 12) {
                    // The composer pads itself (its people typing line sits
                    // above the pill); the pill sits above both.
                    VStack(spacing: 4) {
                        if let companyNotice {
                            Text(verbatim: companyNotice)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(theme.quiet(scheme))
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .accessibilityIdentifier("chat.company.notice")
                        }
                        if let note = conversationChat?.note {
                            Text(verbatim: note)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(theme.quiet(scheme))
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .accessibilityIdentifier("chat.conversation.note")
                        }
                        JumpPillHost(store: store, chrome: chrome)
                        // ST-5 (lane 4 W7): out of Protons, the same top-up as the Store.
                        if store.kind == .assistant, conversationChat?.banner == nil {
                            ProtonTopUpChatNotice(design: design)
                        }
                        if let banner = conversationChat?.banner {
                            // Read-only is the platform's word: no composer, only the banner.
                            ConversationReadOnlyBanner(text: banner, design: design)
                        } else {
                            ChatComposer(store: store, design: design, haptics: haptics,
                                         modelActions: infoActions.assistantModels,
                                         modelDestinations: infoActions.assistantModelDestinations,
                                         modelRefreshToken: composerModelRefreshToken,
                                         modelPickerPresented: $composerModelPresented,
                                         turnStopActions: store.kind == .assistant
                                             ? infoActions.assistantTurnStop : nil)
                        }
                    }
                }
            }
            .background(design.color("ground", scheme: scheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let info {
                        ChatTitleCapsule(info: info, design: design,
                                         loadMatrixThumbnail: loadMatrixThumbnail) {
                            openPanel()
                        }
                    } else {
                        Text(verbatim: store.title)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                // Offline only: the mark is its own item, split from the "…"
                // button by a fixed spacer, so iOS 26 does not fold it into
                // that button's glass group (where it lost its identity).
                if showsConnectionGlyph {
                    ToolbarItem(placement: .topBarTrailing) {
                        ConnectionGlyph(design: design)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                // FlowPhone: a glass "…" on the trailing side opens the chat's
                // info and actions. Company and conversation chats keep their
                // own "…" menu below.
                if info != nil, info?.company == nil, conversationChat == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { openPanel() } label: {
                            AtumVisualSystem(design: design).barIcon(.moreHorizontal)
                        }
                        .accessibilityLabel(ChatCopy.text(design, .infoOpen))
                        .accessibilityIdentifier("chat.more")
                    }
                }
                if let conversation = conversationChat, conversation.canAddPeople || conversation.canHide {
                    ToolbarItem(placement: .topBarTrailing) {
                        conversationMenu(conversation)
                    }
                }
                if let company = info?.company {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { openPanel() } label: {
                                Label { Text(verbatim: CompanyCopy(design: design).membersTitle) } icon: {
                                    Image(AtumVisualSystem(design: design).symbol(.users))
                                }
                            }
                            .accessibilityIdentifier("chat.company.members")
                            Button(role: .destructive) { confirmsCompanyLeave = true } label: {
                                Label { Text(verbatim: CompanyCopy(design: design).leaveAction) } icon: {
                                    Image(AtumVisualSystem(design: design).symbol(.logOut))
                                }
                            }
                            .accessibilityIdentifier("chat.company.leave")
                        } label: {
                            AtumVisualSystem(design: design).barIcon(.moreHorizontal)
                        }
                        .accessibilityIdentifier("chat.company.menu")
                        .disabled(company.leavePending)
                    }
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .environment(\.chatTheme, theme)
            .atumDesign(design)
            .environment(\.chatActions, actions)
            .environment(\.messageActions, presenter)
            .environment(\.chatOwnUserID, store.ownUserID)
            .environment(\.chatRoomAvatar, avatar)
            .environment(\.chatRoomFace, roomFace)
            .environment(\.chatMembers, members)
            .environment(\.chatNonPersonSenders, Self.nonPersonSenders(store.nonPersonSenders, members: members))
            .environment(\.chatLoadMatrixThumbnail, loadMatrixThumbnail)
            .environment(\.appBotPresentation, appBot)
            .environment(\.appBotPresenter, appBotPresenter)
            .environment(\.appBotNoticeDisplays, appBotNoticeDisplays)
            .environment(\.chatMediaAccess, mediaAccess)
            .environment(\.chatAttachmentsClosedReason,
                         conversationChat == nil ? nil : ConversationCopy(design: design).attachments)
            .environment(\.chatMediaPresenter, mediaPresenter)
            .environment(\.chatLocalMediaFiles, store.localMediaFiles)
            .environment(\.chatMediaRetryGeneration, store.mediaRetryGeneration)
            .environment(\.chatMediaNamespace, mediaNamespace)
            .environment(\.chatToday, today)
            .environment(\.chatReducesMotion, reduceMotion || ChatMotion.disabledForUITests)
            .environment(\.chatFlatRuns, info?.company != nil || conversationChat != nil || teamSpaceChat)
            .messageActionSheets(presenter, design: design, actions: actions)
            .sheet(isPresented: $addPeoplePresented) {
                if let conversation = conversationChat {
                    let kept = conversation.kept
                    ConversationPickerSheet(
                        design: design, mode: .add(kept, sourceID: conversation.conversationID),
                        people: conversationActions.people(conversation.companyID, Set(kept.refs)),
                        start: { picked in
                            // The whole larger set: the people already in, plus the new ones.
                            await conversationActions.addPeople(conversation.companyID,
                                                                conversation.conversationID,
                                                                kept.refs + picked)
                        },
                        routeToRoom: { conversationActions.routeToRoom(conversation.companyID, $0) })
                        .atumDesign(design)
                }
            }
            // The chat's side panel: a sheet with a medium and a large height
            // (M1). Not `.inspector`: attached here, on a screen pushed
            // inside the app's NavigationStack, it left the whole chat blank on
            // iPhone (CI 2026-11-06, every scripted chat). The iPad column waits
            // for an inspector placed outside the stack (M1 follow-up).
            .sheet(isPresented: $infoPresented) {
                if let info {
                    ChatPanelHost(design: design, info: info, actions: panelActions,
                                  loadMatrixThumbnail: loadMatrixThumbnail) {
                        infoPresented = false
                    }
                    // No `.id` here: the panel closes on a room change
                    // (`panelScope`), and `.id` on a view whose body is a
                    // NavigationStack crashes on iOS 26 (M1 presentation fix).
                }
            }
            .onChange(of: panelScope) { old, new in
                // A panel never outlives its chat or its account.
                if !ChatPanelPolicy.staysOpen(from: old, to: new) { infoPresented = false }
            }
            .sheet(item: $appBotPresenter.continueRequest) { request in
                ContinueOnMacSheet(request: request, design: design) {
                    appBotPresenter.continueRequest = nil
                }
                .atumDesign(design)
            }
            .task(id: appBotProjection) {
                let projected = await Task.detached(priority: .userInitiated) {
                    AppBotNoticeProjection.displays(appBotProjection)
                }.value
                guard !Task.isCancelled else { return }
                appBotNoticeDisplays = projected
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                refreshToday()
            }
            .onAppear {
                appBotPresenter.openApp = onOpenAppBot
                appBotPresenter.beginSetup = onBeginAppBotSetup
                appBotPresenter.openRoute = onOpenAppBotRoute
                appBotPresenter.openTerms = onOpenAppBotTerms
            }
            .confirmationDialog(CompanyCopy(design: design).leaveTitle(company: info?.company?.companyName ?? ""),
                                isPresented: $confirmsCompanyLeave,
                                titleVisibility: .visible) {
                Button(CompanyCopy(design: design).leaveConfirm, role: .destructive) {
                    if let companyID = info?.company?.companyID {
                        infoActions.leaveCompany?(companyID)
                    }
                }
                Button(design.text("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
            } message: {
                Text(verbatim: CompanyCopy(design: design).leaveMessage)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshToday() }
            }
            .onChange(of: covered, initial: true) { _, isCovered in
                onPresentationChanged(isCovered)
            }
            .onChange(of: infoPresented) { wasPresented, isPresented in
                if wasPresented, !isPresented { composerModelRefreshToken &+= 1 }
            }
            .onChange(of: dismissPresentationRequest) { _, _ in
                dismissPresentations()
            }
            .onDisappear { onPresentationChanged(false) }
            .fullScreenCover(item: $links.presented) { page in
                SafariView(url: page.url).ignoresSafeArea()
            }
            .fullScreenCover(item: $mediaPresenter.viewer) { request in
                MediaViewer(request: request, design: design, access: mediaAccess,
                            namespace: mediaNamespace) {
                    mediaPresenter.viewer = nil
                }
            }
            .quickLookPreview(Binding(
                get: { mediaPresenter.quickLookFile?.url },
                set: { if $0 == nil { mediaPresenter.quickLookFile = nil } }
            ))
            .alert(theme.copy.text(.linkHeld), isPresented: $links.showsHeld) {
                Button(theme.copy.text(.dismiss), role: .cancel) {}
            }
    }

    /// Add people (a new conversation with the larger group; not on a read-only
    /// one) and Hide (the person's own view). No leave, delete or remove: who is in
    /// a conversation is the platform's.
    private func conversationMenu(_ conversation: ConversationChatPresentation) -> some View {
        let copy = ConversationCopy(design: design)
        return Menu {
            if conversation.canAddPeople {
                Button { addPeoplePresented = true } label: {
                    Label { Text(verbatim: copy.addPeople) } icon: {
                        Image(AtumVisualSystem(design: design).symbol(.users))
                    }
                }
                .accessibilityIdentifier("chat.conversation.addPeople")
            }
            if conversation.canHide {
                Button {
                    Task { await conversationActions.hide(conversation.companyID, conversation.conversationID) }
                } label: {
                    Label { Text(verbatim: copy.hide) } icon: { Image(AtumVisualSystem(design: design).symbol(.eyeOff)) }
                }
                .accessibilityIdentifier("chat.conversation.hide")
            }
        } label: {
            AtumVisualSystem(design: design).barIcon(.moreHorizontal)
        }
        .accessibilityLabel(copy.menu)
        .accessibilityIdentifier("chat.conversation.menu")
    }

    /// The panel's actions, with Report person from this chat's store (it
    /// knows the messages the person can be reported by) unless the host
    /// gave its own.
    private var panelActions: ChatInfoActions {
        var actions = infoActions
        if actions.reportPerson == nil {
            let store = store
            actions.reportPerson = { userID, reason in await store.reportPerson(userID, reason: reason) }
        }
        return actions
    }

    /// Who gets no Report in this chat: the store's assistants and app bots,
    /// and every member the panel marks as one.
    static func nonPersonSenders(_ known: Set<String>, members: [String: ChatInfoMember]) -> Set<String> {
        known.union(members.values.filter { $0.isAssistant || $0.isApp }.map(\.userID))
    }

    static func avatarKind(_ kind: RoomKind) -> AtumAvatarKind {
        switch kind {
        case .assistant: .assistant
        case .appBot: .app
        case .person: .person
        case .group: .group
        }
    }

    private var panelScope: ChatPanelPolicy.Scope? {
        info.map { ChatPanelPolicy.Scope(accountID: store.ownUserID, roomID: $0.roomID) }
    }

    /// Opens the side panel at its home. The composer's keyboard goes down
    /// first, so it never rides up with the sheet.
    private func openPanel() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        infoPresented = true
    }

    private func refreshToday() {
        let now = Calendar.current.startOfDay(for: Date())
        if now != today { today = now }
    }

    private func dismissPresentations() {
        infoPresented = false
        composerModelPresented = false
        links.presented = nil
        links.showsHeld = false
        presenter.selectText = nil
        presenter.deleteRequest = nil
        presenter.failedSend = nil
        presenter.linkAfterSelectText = nil
        presenter.actionsOverlay = nil
        appBotPresenter.dismissAll()
        mediaPresenter.dismissAll()
    }

    /// B2, §3.3, U10: the greeting shows in an empty chat once the start of
    /// the room is reached (coordinator decision 6: in every room kind).
    static func isEmptyChat(rows: [ChatRow], pagination: PaginationState) -> Bool {
        guard !rows.contains(where: { $0.item.kind.isEventContent }) else { return false }
        return pagination == .idle(hitTimelineStart: true) || rows.contains { $0.item.kind == .timelineStart }
    }
}

/// Desktop parity for the empty Founder chat: raven, exact official account
/// mark, localized identity, and the owner's five-locale intro copy. It gives
/// way to the transcript as soon as any event content exists.
private struct FounderIntroCard: View {
    let presentation: FounderIntroPresentation
    let design: LiveDesign

    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        VStack(spacing: 0) {
            FounderRavenAvatar(size: 56, fallbackName: presentation.name)
            HStack(spacing: 6) {
                Text(verbatim: presentation.name)
                    .font(.body.weight(.semibold))
                AppSeal(tier: .official, placement: .chatTitle, label: .officialAccount)
            }
            .padding(.top, 16)
            Text(verbatim: presentation.subtitle)
                .font(.subheadline)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .padding(.top, 2)
            Text(verbatim: presentation.intro)
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 16)
                .accessibilityIdentifier("chat.founderIntro.text")
        }
        .frame(maxWidth: 416)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.founderIntro")
    }
}
/// The pill, from the transcript's mirror (never from the store's
/// per-frame follow state).
private struct JumpPillHost: View {
    let store: LiveConversationStore
    let chrome: ChatChrome

    var body: some View {
        JumpPillButton(pill: chrome.pill) { store.handle(.jumpTapped) }
    }
}
/// §3.3: the title capsule: avatar (32 pt) and name. From S2 it opens the
/// chat info sheet.
struct ChatTitleCapsule: View {
    let info: ChatInfoPresentation
    let design: LiveDesign
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                ChatInfoAvatar(info: info, size: 32, loadMatrixThumbnail: loadMatrixThumbnail)
                HStack(spacing: 4) {
                    Text(verbatim: info.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if case let .app(verification) = info.kind {
                        AppSeal(tier: verification, placement: .chatTitle)
                    } else if info.isFounder {
                        AppSeal(tier: .official, placement: .chatTitle, label: .officialAccount)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(info.title)
        .accessibilityHint(ChatCopy.text(design, .infoOpen))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat.title")
        // The navigation bar caps its text size; a long press shows the name
        // large instead, as system bar titles do.
        .accessibilityShowsLargeContentViewer()
    }
}
