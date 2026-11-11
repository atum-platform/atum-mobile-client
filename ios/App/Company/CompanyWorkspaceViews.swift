import AtumChat
import AtumNativeAPI
import SwiftUI

// The phone's Team Space surfaces (B19 S4, daily-use slice U1/U4). The
// Workplace root is the last-used company's channel list, Slack-style: a
// company header that always opens the switcher sheet (every company with its
// mark and a check on the current one, invitations, "Create company"),
// invitations on top, then "Channels" with unread and mention marks and a mute
// action, then "Direct messages" (You, the Chief of Staff, the company's DMs).
// A channel pushes the existing chat and Back returns to the list. With no
// company and no invitation the root is a "Create your company" empty state.
// Every company mark is a circle (owner ruling 2).
//
// Wave 2 (TS-6..TS-10, docs/ports/team-space-structure.md): Chat · Board pages
// under the header, a "Search {company}" field over channels and DMs, the
// Saved row once something is saved, the Activity icon beside the "…" company
// menu (Company overview, Add company, Leave company; entries the phone cannot
// open yet are not drawn), and the Invite teammates footer once an invite
// sheet exists.
//
// Wave 3 (TS-11, TS-13, docs/ports/w3-team-space.md): Invite teammates and
// Invite people open "Add people to {company}" (with the share link where the
// server has links on), "Join with invite link" sits in the empty state and the
// create form, and the channel list has Favorites, Channels with "+" (Create a
// channel, for admins) and a collapsed Archived.

struct TeamSpacePresentation: Equatable {
    var isLoading: Bool
    var isUnavailable: Bool
    var invitations: [CompanyHomeRow] = []
    /// The active company; nil with no company (only invitations, or none).
    var workspace: CompanyWorkspacePresentation?
    /// Every company with its mark and the active one flagged, even when there
    /// is only one: the switcher sheet is also where a person creates another.
    var switcher: [CompanySwitcherEntry] = []
    /// The platform says this person may create a company (advisory; a refused
    /// create is still handled).
    var canCreate = false
    /// The app-icon count (Home rows plus company channels), kept current while
    /// Workplace is the screen, because Home is not mounted then.
    var appIconCount = 0
    /// Company ID → its logo's MXC URI (`CompanyWorkspaceModel.logoURIs`).
    var logos: [String: String] = [:]
    /// The company menu's entries for the open company (desktop `menuAllowed`).
    var menu = CompanyMenuAllowed()
    /// The viewer's role in the open company, for the overview.
    var viewerRole: String?
    /// The company Store answers with something to get (Marketplace page). The
    /// phone has no company Store read yet, so this stays false.
    var marketplaceAvailable = false
    /// What the invite sheet may do in the open company (TS-11).
    var inviteAbilities = CompanyInviteAbilities.none
    /// The viewer may create a channel in the open company (TS-13).
    var canCreateChannel = false
    /// Favorites / Channels / Archived sections: only in the desktop's C2
    /// channels mode (`CompanyTeamSpaceProfile.channels`); a flat list before it.
    var sectionsChannels = false
}

struct TeamSpaceActions {
    let refresh: () async -> Void
    let selectCompany: (String) -> Void
    let openRoom: (String) -> Void
    let acceptInvitation: (String) async -> Bool
    let declineInvitation: (String) -> Void
    let leave: (String) async -> Void
    let setMuted: (String, Bool) -> Void
    /// Creates a company; nil when it was created and shown, else why not.
    let createCompany: (String) async -> CompanyCreateFailure?
    /// The person edited the name after a failed try, so the next try is a new
    /// request instead of a replay of the old one.
    var createNameEdited: (() -> Void)?
    var setAppIconBadge: ((Int) async -> Void)?
    /// Direct messages; nil keeps the section off whatever the presentation says.
    var conversations: ConversationListActions?
    /// Authenticated Matrix media, for company logos and people's photos.
    var loadMatrixThumbnail: ((String, Int) async -> Data?)?
    /// "You" and the Chief of Staff rows of Direct messages.
    var directMessages = DirectMessagesActions()
    /// The open company's Activity inbox (TS-7); nil when it could not be read.
    var loadActivity: ((String) async -> [CompanyActivityRow]?)?
    /// The account's Saved pointers (TS-6); nil when unreadable.
    var loadSavedPointers: (() async -> [CompanySavedMessagePointer]?)?
    var loadSavedRows: (([CompanySavedMessagePointer]) async -> [CompanySavedRow])?
    /// The invite sheet, invite links, join with a link and channel create (TS-11, TS-13).
    /// Nil keeps all of them undrawn.
    var invites: CompanyInviteActions?
    /// The Threads row and its company list (TS-6b); nil keeps the row undrawn.
    var threads: CompanyThreadsActions?
}

/// Workplace is a separate mode from Personal Home. It reuses the existing
/// owner-bound company reads/actions; it creates no second company authority
/// and never projects company rooms into Home.
struct TeamSpaceScreen: View {
    let design: LiveDesign
    let presentation: TeamSpacePresentation
    let actions: TeamSpaceActions

    @State private var joiningID: String?
    @State private var actionFailure = 0
    @State private var confirmsLeave = false
    @State private var showsSwitcher = false
    @State private var showsCreate = false
    @State private var showsOverview = false
    @State private var showsActivity = false
    @State private var showsSaved = false
    @State private var showsThreads = false
    /// The open company's threads (TS-6b): rows read for another company are never shown.
    @State private var threadsRead: (companyID: String, rows: [CompanyThreadListRow]?)?
    @State private var threadsLoading = false
    @State private var threadsGeneration: UInt64 = 0
    @State private var showsInvite = false
    @State private var showsJoin = false
    @State private var showsCreateChannel = false
    @State private var archivedExpanded = false
    /// The page per company (desktop keeps it in the company's space preferences).
    @State private var pages = [String: CompanySpaceTab]()
    @State private var query = ""
    /// Activity for one company: rows read for another company are never shown.
    @State private var activityRead: (companyID: String, rows: [CompanyActivityRow]?)?
    @State private var activityLoading = false
    /// Bumped by every Activity read; only the latest read may land.
    @State private var activityGeneration: UInt64 = 0

    private var activity: [CompanyActivityRow]? {
        guard let activityRead, activityRead.companyID == presentation.workspace?.id else { return nil }
        return activityRead.rows
    }
    @State private var savedPointers: [CompanySavedMessagePointer] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var locale: Locale { Locale(identifier: design.locale) }
    private var needle: String? { TeamSpaceSearch.needle(query, locale: locale) }

    private var pageTabs: [CompanySpaceTab] {
        CompanySpaceTabs.ids(marketplaceAvailable: presentation.marketplaceAvailable)
    }

    private var page: Binding<CompanySpaceTab> {
        Binding(
            get: {
                CompanySpaceTabs.effective(presentation.workspace.flatMap { pages[$0.id] },
                                           marketplaceAvailable: presentation.marketplaceAvailable)
            },
            set: { tab in
                guard let id = presentation.workspace?.id else { return }
                pages[id] = tab
            })
    }

    private var threadRows: [CompanyThreadListRow]? {
        guard let threadsRead, threadsRead.companyID == presentation.workspace?.id else { return nil }
        return threadsRead.rows
    }

    private var sidebarEntries: TeamSpaceSidebarEntries {
        // Drafts have no phone projection yet (their desktop record is the per-target
        // `com.atum.draft.v2.*` account data), so the row stays hidden, as the desktop
        // hides a row with nothing to open. Threads (TS-6b) shows once the company has one.
        TeamSpaceSidebarEntries(threads: threadRows?.count ?? 0, saved: savedPointers.count, drafts: 0)
    }

    /// Desktop `threadsBadge`: unread thread mentions as a count, else a dot.
    private var threadsBadge: Badge {
        CompanyThreads.badge((threadRows ?? []).map(\.thread))
    }

    private var activityBadge: Badge {
        CompanyActivityFeed.badge((activity ?? []).map(\.item))
    }

    var body: some View {
        Group {
            if presentation.isLoading && presentation.workspace == nil && presentation.invitations.isEmpty {
                ProgressView(copy.text(CompanyCopyKey("loading")))
            } else if presentation.isUnavailable && presentation.workspace == nil
                        && presentation.invitations.isEmpty {
                ContentUnavailableView(
                    copy.text(CompanyCopyKey("unavailable")),
                    image: atum.symbol(.briefcase)
                )
            } else if presentation.workspace == nil && presentation.invitations.isEmpty {
                emptyState
            } else if presentation.workspace != nil, page.wrappedValue == .board {
                CompanyBoardPage(design: design)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        CompanyPagesBar(design: design, tabs: pageTabs, selection: page)
                    }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        // FlowPhone › Team: a large title under the switcher. The board's short
        // "Team" has no exported key (gap F12); "Team space" is the current name.
        .navigationTitle(design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.teamSpaceTitle"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbar }
        .sheet(isPresented: $showsOverview) {
            if let workspace = presentation.workspace {
                CompanyOverviewSheet(design: design, workspace: workspace,
                                     logoURI: presentation.logos[workspace.id],
                                     viewerRole: presentation.viewerRole, menu: presentation.menu,
                                     loadMatrixThumbnail: actions.loadMatrixThumbnail,
                                     leave: { confirmsLeave = true })
                    .atumDesign(visual: atum)
            }
        }
        .sheet(isPresented: $showsActivity) {
            TeamSpaceActivitySheet(design: design, rows: activity, isLoading: activityLoading,
                                   reload: { await reloadActivity() },
                                   open: { row in
                                       showsActivity = false
                                       actions.openRoom(row.item.roomID)
                                   })
                .atumDesign(visual: atum)
        }
        .sheet(isPresented: $showsThreads) {
            if let threads = actions.threads {
                TeamSpaceThreadsSheet(design: design, rows: threadRows, isLoading: threadsLoading,
                                      reload: { await reloadThreads() },
                                      follow: threads.follow, markRead: threads.markRead,
                                      open: { row in
                                          showsThreads = false
                                          threads.open(row.thread.roomID, row.thread.root.eventID)
                                      },
                                      loadMatrixThumbnail: actions.loadMatrixThumbnail)
                    .atumDesign(visual: atum)
            }
        }
        .onChange(of: showsThreads) { _, shown in
            // A thread read or followed in the list changes the row's mark.
            if !shown { Task { await reloadThreads() } }
        }
        .sheet(isPresented: $showsSaved) {
            TeamSpaceSavedSheet(design: design, pointers: savedPointers,
                                load: { await actions.loadSavedRows?($0) ?? [] },
                                open: { row in
                                    showsSaved = false
                                    actions.openRoom(row.pointer.roomID)
                                })
                .atumDesign(visual: atum)
        }
        .task(id: presentation.workspace?.id) {
            query = ""
            await reloadStructure()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reloadStructure() } }
        }
        .sheet(isPresented: $showsSwitcher) {
            CompanySwitcherSheet(design: design, presentation: presentation, actions: actions,
                                 joiningID: joiningID,
                                 join: { row, finished in join(row, finished: finished) })
                .atumDesign(visual: atum)
        }
        .sheet(isPresented: $showsCreate) {
            NavigationStack {
                CompanyCreateForm(design: design, canCreate: presentation.canCreate,
                                  create: actions.createCompany,
                                  nameEdited: { actions.createNameEdited?() },
                                  onCreated: { showsCreate = false },
                                  invites: actions.invites)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(design.text("src.matrix.chat-copy.copies.cancel")) { showsCreate = false }
                                .accessibilityIdentifier("company.create.cancel")
                        }
                    }
            }
            .atumDesign(visual: atum)
            .presentationDetents([.medium, .large])
        }
        // The right to create can be taken away while the form is open.
        .onChange(of: presentation.canCreate) { _, canCreate in
            if !canCreate { showsCreate = false }
        }
        .sheet(isPresented: $showsInvite) {
            if let workspace = presentation.workspace, let invites = actions.invites {
                CompanyInviteSheet(design: design, companyID: workspace.id, companyName: workspace.title,
                                   abilities: presentation.inviteAbilities, actions: invites,
                                   loadMatrixThumbnail: actions.loadMatrixThumbnail)
                    .id(workspace.id)
                    .atumDesign(visual: atum)
            }
        }
        // An invite sheet for a company the viewer may no longer invite to closes.
        .onChange(of: presentation.inviteAbilities.invite) { _, allowed in
            if !allowed { showsInvite = false }
        }
        .onChange(of: presentation.workspace?.id) { _, _ in
            showsInvite = false
            showsCreateChannel = false
        }
        .sheet(isPresented: $showsJoin) {
            if let invites = actions.invites {
                CompanyInviteJoinSheet(design: design, actions: invites,
                                       onJoined: { _ in showsJoin = false })
                    .atumDesign(visual: atum)
            }
        }
        .sheet(isPresented: $showsCreateChannel) {
            if let workspace = presentation.workspace, let invites = actions.invites {
                CompanyChannelCreateSheet(design: design, companyID: workspace.id,
                                          create: invites.createChannel,
                                          onCreated: { roomID in
                                              if let roomID { actions.openRoom(roomID) }
                                          })
                    .id(workspace.id)
                    .atumDesign(visual: atum)
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: presentation.canCreateChannel) { _, allowed in
            if !allowed { showsCreateChannel = false }
        }
        .confirmationDialog(copy.leaveTitle(company: presentation.workspace?.title ?? ""),
                            isPresented: $confirmsLeave, titleVisibility: .visible) {
            Button(copy.leaveConfirm, role: .destructive) {
                guard let companyID = presentation.workspace?.id else { return }
                Task { await actions.leave(companyID) }
            }
            .accessibilityIdentifier("company.confirm.leave")
            Button(design.text("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: copy.leaveMessage)
        }
        .task { await actions.refresh() }
        .task(id: AppIconUpdate(count: presentation.appIconCount, isActive: scenePhase == .active)) {
            guard scenePhase == .active, !presentation.isLoading,
                  let setAppIconBadge = actions.setAppIconBadge else { return }
            await setAppIconBadge(presentation.appIconCount)
        }
        .sensoryFeedback(.error, trigger: actionFailure)
        .accessibilityIdentifier("teamSpace.screen")
    }

    private struct AppIconUpdate: Equatable {
        let count: Int
        let isActive: Bool
    }

    /// Activity and Saved, read again for the open company.
    private func reloadStructure() async {
        await reloadSaved()
        await reloadActivity()
        await reloadThreads()
    }

    private func reloadThreads() async {
        threadsGeneration &+= 1
        let generation = threadsGeneration
        guard let companyID = presentation.workspace?.id, let load = actions.threads?.load else {
            threadsRead = nil
            threadsLoading = false
            return
        }
        if threadsRead?.companyID != companyID { threadsRead = nil }
        threadsLoading = true
        let rows = await load(companyID)
        guard generation == threadsGeneration, !Task.isCancelled else { return }
        threadsLoading = false
        // A failed read keeps the rows already shown rather than hiding the row.
        if rows != nil || threadsRead?.companyID != companyID { threadsRead = (companyID, rows) }
    }

    private func reloadActivity() async {
        activityGeneration &+= 1
        let generation = activityGeneration
        guard let companyID = presentation.workspace?.id, let load = actions.loadActivity else {
            activityRead = nil
            activityLoading = false
            return
        }
        if activityRead?.companyID != companyID { activityRead = nil }
        activityLoading = true
        let rows = await load(companyID)
        // `presentation` here is this view's copy from before the await, so
        // the fence is the shared generation: a newer read (a company switch
        // starts one) or a cancelled task drops this answer.
        guard generation == activityGeneration, !Task.isCancelled else { return }
        activityLoading = false
        activityRead = (companyID, rows)
    }

    private func reloadSaved() async {
        guard let load = actions.loadSavedPointers else { return }
        if let pointers = await load() { savedPointers = pointers }
    }

    // MARK: List

    private var list: some View {
        List {
            if let workspace = presentation.workspace {
                notices(workspace)
            }
            if presentation.workspace != nil, sidebarEntries.threads || sidebarEntries.saved {
                Section {
                    // Desktop order: Threads, then Saved (`company-workspace.tsx:2865–2900`).
                    if sidebarEntries.threads, actions.threads != nil {
                        TeamSpaceUtilityRow(design: design, glyph: .messageCircle,
                                            title: CompanyThreadsCopy(design: design).companyTitle,
                                            badge: threadsBadge,
                                            identifier: "company.threads.entry") { showsThreads = true }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    if sidebarEntries.saved {
                        TeamSpaceUtilityRow(design: design, glyph: .star, title: team.savedTitle,
                                            identifier: "company.saved.entry") { showsSaved = true }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listSectionSeparator(.hidden)
            }
            if !presentation.invitations.isEmpty {
                Section {
                    ForEach(presentation.invitations) { row in
                        CompanyInvitationCard(design: design, row: row, joiningID: joiningID,
                                              join: { join(row) },
                                              later: { actions.declineInvitation(row.invitationID) })
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader(copy.invitationsTitle, id: "company.invitations")
                }
                .listSectionSeparator(.hidden)
            }
            if let workspace = presentation.workspace {
                let plan = channelPlan(workspace)
                if !plan.favorites.isEmpty {
                    Section {
                        ForEach(plan.favorites) { channel in channelListRow(channel) }
                    } header: {
                        sectionHeader(team.favorites, id: "company.channels.favorites")
                    }
                    .listSectionSeparator(.hidden)
                }
                Section {
                    if workspace.channelsLoading {
                        note(copy.text(CompanyCopyKey("loadingChannels")))
                    } else if workspace.channels.isEmpty {
                        note(copy.text(CompanyCopyKey("noChannels")))
                    } else {
                        ForEach(plan.channels) { channel in channelListRow(channel) }
                    }
                } header: {
                    channelsHeader
                }
                .listSectionSeparator(.hidden)
                if !plan.archived.isEmpty {
                    Section {
                        if archivedExpanded {
                            ForEach(plan.archived) { channel in channelListRow(channel) }
                        }
                    } header: {
                        archivedHeader(count: plan.archived.count)
                    }
                    .listSectionSeparator(.hidden)
                }
                // Direct messages is always there for a loaded company (desktop
                // `company-workspace.tsx:2996`): You and the Chief of Staff come first;
                // only the conversation rows and "+" wait for the conversations family.
                ConversationSectionView(design: design, companyID: workspace.id,
                                        directMessages: workspace.directMessages,
                                        actions: actions.conversations,
                                        rowActions: actions.directMessages,
                                        loadMatrixThumbnail: actions.loadMatrixThumbnail,
                                        needle: needle)
                if presentation.menu.invite, actions.invites != nil {
                    Section {
                        Button { showsInvite = true } label: {
                            Label { Text(verbatim: team.inviteTeammates) } icon: { Image(atum.symbol(.plus)) }
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("company.invite.teammates")
                    }
                    .listSectionSeparator(.hidden)
                }
            } else if presentation.canCreate {
                Section {
                    createCompanyButton
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await actions.refresh()
            await reloadStructure()
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text(verbatim: team.sidebarSearch(company: presentation.workspace?.title ?? "")))
        .safeAreaInset(edge: .top, spacing: 0) {
            if presentation.workspace != nil {
                CompanyPagesBar(design: design, tabs: pageTabs, selection: page)
            }
        }
        .accessibilityIdentifier("company.channels")
    }

    // MARK: Empty state

    /// No company and no invitation. Where the platform admits this person to
    /// create one, the screen says so and offers it; otherwise it says plainly
    /// that creating companies is not open yet.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(atum.symbol(.briefcase))
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
            if presentation.canCreate {
                Text(verbatim: copy.emptyTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .multilineTextAlignment(.center)
                Text(verbatim: copy.emptyBody)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
                createCompanyButton
                    .padding(.top, 6)
            } else {
                Text(verbatim: copy.noCompanies)
                    .font(.headline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .multilineTextAlignment(.center)
                Text(verbatim: copy.creationClosed)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
            // A person with no company joins one with a link, whether or not they may create.
            if actions.invites != nil {
                Button { showsJoin = true } label: {
                    Text(verbatim: team.joinWithInviteLink)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("company.join.open")
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("company.empty")
    }

    private var createCompanyButton: some View {
        Button { showsCreate = true } label: {
            HStack(spacing: 8) {
                Image(atum.symbol(.plus))
                    .accessibilityHidden(true)
                Text(verbatim: copy.createAction)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(atum.color(.actionStrong, scheme: scheme))
        .accessibilityIdentifier("company.create.open")
    }

    @ViewBuilder
    private func notices(_ workspace: CompanyWorkspacePresentation) -> some View {
        if workspace.leavePending {
            note(copy.leavePending).accessibilityIdentifier("company.leave.pending")
        }
        if let notice = workspace.notice {
            note(notice).accessibilityIdentifier("company.converge.notice")
        }
        if let error = workspace.error {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(atum.color(.danger, scheme: scheme))
                .accessibilityIdentifier("company.error")
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
    }

    private func sectionHeader(_ title: String, id: String) -> some View {
        Text(verbatim: title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .textCase(nil)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(id)
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let workspace = presentation.workspace {
            // FlowPhone: the company switcher is a leading glass capsule.
            ToolbarItem(placement: .topBarLeading) { header(workspace) }
            // Desktop: Activity is an icon at the end of the switcher's row, always there
            // while a company is open (`activity-button.tsx`).
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsActivity = true } label: {
                    atum.barIcon(.bell)
                        .overlay(alignment: .topTrailing) {
                            if activityBadge != .none {
                                HomeBadgeView(design: design, badge: activityBadge, pinned: false)
                                    .scaleEffect(0.8)
                                    .offset(x: 8, y: -8)
                                    .accessibilityIdentifier("company.activity.badge")
                            }
                        }
                }
                .accessibilityLabel(Text(verbatim: team.activityTitle))
                .accessibilityValue(Text(verbatim: copy.markDescription(activityBadge).joined(separator: ", ")))
                .accessibilityIdentifier("company.activity.open")
            }
            if presentation.menu.inCompany || presentation.menu.exits {
                ToolbarItem(placement: .topBarTrailing) { companyMenu(workspace) }
            }
        }
    }

    /// The company menu (desktop `company-menu.tsx`): Company overview, then what
    /// the viewer may do in the company, then Add company and Leave company. An
    /// entry the viewer may not use is not drawn. The companies themselves stay
    /// in the header's switcher sheet, the phone's form of the menu's radio list.
    private func companyMenu(_ workspace: CompanyWorkspacePresentation) -> some View {
        let allowed = presentation.menu
        return Menu {
            Section {
                if allowed.overview {
                    Button { showsOverview = true } label: {
                        Label { Text(verbatim: team.companyOverview) } icon: { Image(atum.symbol(.briefcase)) }
                    }
                    .accessibilityIdentifier("company.overview.open")
                }
                if allowed.invite, actions.invites != nil {
                    Button { showsInvite = true } label: {
                        Label { Text(verbatim: team.invitePeople) } icon: { Image(atum.symbol(.mail)) }
                    }
                    .accessibilityIdentifier("company.invite")
                }
                if allowed.settings {
                    Button { showsOverview = true } label: {
                        Label { Text(verbatim: team.companySettings) } icon: { Image(atum.symbol(.settings)) }
                    }
                    .accessibilityIdentifier("company.settings")
                }
            }
            Section {
                if allowed.create {
                    Button { showsCreate = true } label: {
                        Label { Text(verbatim: team.addCompany) } icon: { Image(atum.symbol(.plus)) }
                    }
                    .accessibilityIdentifier("company.add")
                }
                if allowed.leave {
                    Button(role: .destructive) { confirmsLeave = true } label: {
                        Label { Text(verbatim: copy.leaveAction) } icon: { Image(atum.symbol(.logOut)) }
                    }
                    .accessibilityIdentifier("company.leave")
                }
            }
        } label: {
            atum.barIcon(.moreHorizontal)
        }
        .accessibilityIdentifier("company.menu")
    }

    /// The current company: its logo (or initial) in a circle, its name and a
    /// chevron. It is always the switcher (one company or many), and a mark
    /// beside it says another company has something waiting.
    /// The tile in the bar's 44 pt glass capsule (FlowPhone › Team draws it at
    /// about 26 pt). A capsule drawn by the view itself lost its name and caret
    /// to the bar's vibrancy on iOS 26, so the bar's own glass is kept.
    static let headerLogo: CGFloat = 28

    private func header(_ workspace: CompanyWorkspacePresentation) -> some View {
        let others = TeamSpaceBadges.tab(
            companies: presentation.switcher.filter { !$0.isActive }.map(\.badge),
            pendingInvitations: 0)
        return Button { showsSwitcher = true } label: {
            // Its own view type: iOS 26 bars lift plain Text and Image out of a
            // button's label (they drew the tile and the badge, not the name or
            // the caret); a custom view is hosted whole, as the chat title is.
            CompanyHeaderLabel(design: design, title: workspace.title,
                               logoURI: presentation.logos[workspace.id],
                               logoSize: Self.headerLogo, others: others,
                               loadMatrixThumbnail: actions.loadMatrixThumbnail)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: workspace.title))
        .accessibilityValue(Text(verbatim: copy.markDescription(others).joined(separator: ", ")))
        .accessibilityHint(Text(verbatim: copy.companiesTitle))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("company.header")
    }

    // MARK: Channel sections (TS-13)

    private func channelPlan(_ workspace: CompanyWorkspacePresentation) -> CompanyChannelSectionPlan<CompanyChannelRow> {
        .split(workspace.channels, isFavourite: \.isFavourite, isArchived: \.isArchived,
               matches: { TeamSpaceSearch.matches([$0.title], needle: needle, locale: locale) },
               sectioned: presentation.sectionsChannels)
    }

    private func channelListRow(_ channel: CompanyChannelRow) -> some View {
        channelRow(channel)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// "Channels" and, for those who may create one, the desktop's "+" Add channels menu.
    private var channelsHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            sectionHeader(copy.channelsTitle, id: "company.section")
            Spacer(minLength: 8)
            if presentation.canCreateChannel, actions.invites != nil {
                Menu {
                    Button { showsCreateChannel = true } label: {
                        Label { Text(verbatim: team.createChannelItem) } icon: { Image(atum.symbol(.plus)) }
                    }
                    .accessibilityIdentifier("company.channel.create.open")
                } label: {
                    Image(atum.symbol(.plus))
                        .font(.body)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(verbatim: team.addChannels))
                .accessibilityIdentifier("company.channel.add")
            }
        }
    }

    /// "Archived", collapsed until opened (desktop `defaultOpen={false}`).
    private func archivedHeader(count: Int) -> some View {
        Button { archivedExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(atum.symbol(archivedExpanded ? .chevronDown : .chevronRight))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: team.archivedSection)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .textCase(nil)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(Text(verbatim: count.formatted()))
        .accessibilityIdentifier("company.channels.archived")
    }

    // MARK: Channel row

    private func channelRow(_ channel: CompanyChannelRow) -> some View {
        Button {
            guard let roomID = channel.roomID, channel.canOpen else { return }
            actions.openRoom(roomID)
        } label: {
            HStack(spacing: 8) {
                // FlowPhone › Team: "#" in a 28 pt ink-3 column, the name in
                // ink, semibold while unread.
                Text(verbatim: "#")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(verbatim: channel.title)
                    .font(.body.weight(channel.isBold ? .semibold : .regular))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(1)
                if channel.isMuted {
                    Image(atum.symbol(.bellOff))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                if !channel.canOpen {
                    Text(verbatim: channel.state)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                }
                HomeBadgeView(design: design, badge: channel.badge, pinned: false)
                    .accessibilityIdentifier("company.channel.badge." + channel.id)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!channel.canOpen)
        .opacity(channel.canOpen ? 1 : 0.5)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            muteButton(channel)
        }
        .contextMenu { muteButton(channel) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.channelLabel(channel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(verbatim: copy.muteTitle(isMuted: channel.isMuted))) {
            toggleMute(channel)
        }
        .accessibilityIdentifier("company.channel." + channel.id)
    }

    @ViewBuilder
    private func muteButton(_ channel: CompanyChannelRow) -> some View {
        if channel.roomID != nil, channel.canOpen {
            Button { toggleMute(channel) } label: {
                Label(copy.muteTitle(isMuted: channel.isMuted),
                      image: atum.symbol(channel.isMuted ? .bell : .bellOff))
            }
            .tint(atum.color(.muted, scheme: scheme))
            .accessibilityIdentifier("company.channel.mute." + channel.id)
        }
    }

    private func toggleMute(_ channel: CompanyChannelRow) {
        guard let roomID = channel.roomID else { return }
        actions.setMuted(roomID, !channel.isMuted)
    }

    // MARK: Invitation

    private func join(_ row: CompanyHomeRow, finished: ((Bool) -> Void)? = nil) {
        guard joiningID == nil else { return }
        joiningID = row.id
        Task { @MainActor in
            let accepted = await actions.acceptInvitation(row.invitationID)
            joiningID = nil
            if !accepted { actionFailure &+= 1 }
            finished?(accepted)
        }
    }
}

/// One waiting invitation, on the Workplace list and in the switcher sheet.
/// "Not now" is the phone's own hide (the platform has no decline in this
/// wire), so it is not worded as a refusal.
struct CompanyInvitationCard: View {
    let design: LiveDesign
    let row: CompanyHomeRow
    /// The invitation being accepted right now, if any; one at a time.
    let joiningID: String?
    let join: () -> Void
    let later: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Text(verbatim: row.subtitle ?? copy.invitationsTitle)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(action: join) {
                    // On ink: the screen's ink foreground otherwise drew the
                    // label ink on ink (blank).
                    Text(verbatim: copy.joinAction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(atum.color(.onInk, scheme: scheme))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(atum.color(.actionStrong, scheme: scheme))
                .disabled(joiningID != nil)
                .accessibilityIdentifier("company.join." + row.companyID)

                Button(action: later) {
                    Text(verbatim: copy.laterAction)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(joiningID != nil)
                .accessibilityIdentifier("company.later." + row.companyID)
            }
            if joiningID == row.id {
                Text(verbatim: copy.text(CompanyCopyKey("loading")))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
        }
        .padding(14)
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("company.invitation." + row.companyID)
    }
}

/// The company switcher: every company with its mark and a check on the
/// current one, the invitations waiting, and "Create company". Picking a
/// company makes it the one Workplace opens to next time (the model persists
/// the choice), then closes the sheet.
struct CompanySwitcherSheet: View {
    let design: LiveDesign
    let presentation: TeamSpacePresentation
    let actions: TeamSpaceActions
    let joiningID: String?
    let join: (CompanyHomeRow, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presentation.switcher) { entry in
                        companyRow(entry)
                            .listRowBackground(atum.color(.cell, scheme: scheme))
                    }
                }

                if !presentation.invitations.isEmpty {
                    Section {
                        ForEach(presentation.invitations) { row in
                            CompanyInvitationCard(
                                design: design, row: row, joiningID: joiningID,
                                join: { join(row) { accepted in if accepted { dismiss() } } },
                                later: { actions.declineInvitation(row.invitationID) })
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(verbatim: copy.invitationsTitle)
                            .accessibilityIdentifier("company.switcher.invitations")
                    }
                }

                switch footer {
                case .create:
                    Section {
                        NavigationLink {
                            CompanyCreateForm(design: design, canCreate: presentation.canCreate,
                                              create: actions.createCompany,
                                              nameEdited: { actions.createNameEdited?() },
                                              onCreated: { dismiss() },
                                              invites: actions.invites)
                        } label: {
                            HStack(spacing: 12) {
                                Image(atum.symbol(.plus))
                                    .accessibilityHidden(true)
                                Text(verbatim: copy.createAction)
                            }
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                            .frame(minHeight: 44)
                        }
                        .listRowBackground(atum.color(.cell, scheme: scheme))
                        .accessibilityIdentifier("company.create.open")
                    }
                case .closedNote:
                    Section {
                        Text(verbatim: copy.creationClosed)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("company.create.closed")
                    }
                case .nothing:
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationTitle(copy.companiesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.switcher.close")
                }
            }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("company.switcher")
    }

    private var footer: CompanySwitcherFooter {
        .resolve(canCreate: presentation.canCreate, companyCount: presentation.switcher.count)
    }

    /// Up to three companies and no invitation fit the medium sheet; anything
    /// longer opens full height so "Create company" is never below the fold.
    private var detents: Set<PresentationDetent> {
        presentation.invitations.isEmpty && presentation.switcher.count <= 3 ? [.medium, .large] : [.large]
    }

    private func companyRow(_ entry: CompanySwitcherEntry) -> some View {
        Button {
            actions.selectCompany(entry.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                CompanyLogo(name: entry.title, logoURI: presentation.logos[entry.id], size: 36,
                            loadMatrixThumbnail: actions.loadMatrixThumbnail)
                Text(verbatim: entry.title)
                    .font(.body.weight(entry.badge == .none ? .regular : .semibold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                Spacer(minLength: 8)
                HomeBadgeView(design: design, badge: entry.badge, pinned: false)
                    .accessibilityIdentifier("company.switch.badge." + entry.id)
                if entry.isActive {
                    Image(atum.symbol(.check))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .accessibilityIdentifier("company.switch.current." + entry.id)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([entry.title] + copy.markDescription(entry.badge))
            .joined(separator: ", ")))
        .accessibilityAddTraits(entry.isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("company.switch." + entry.id)
    }
}

/// "New company": one name field and Create. The platform decides who may
/// create; a refusal, or a lost answer, is said under the field and the name
/// stays, so the same name can be tried again (a lost answer replays the same
/// request, so it cannot make two companies).
struct CompanyCreateForm: View {
    let design: LiveDesign
    /// The platform's current say-so. When it is lost the form says so and
    /// cannot be submitted; the model also refuses at submit.
    let canCreate: Bool
    /// Nil when the company was created and shown, else why not.
    let create: (String) async -> CompanyCreateFailure?
    let nameEdited: () -> Void
    let onCreated: () -> Void
    /// "Join with invite link" (desktop create dialog step 1); nil hides it.
    var invites: CompanyInviteActions? = nil

    @State private var showsJoin = false
    @State private var name = ""
    /// The shaped name of the last try, so an edit of it can be told from the
    /// first typing.
    @State private var submittedName: String?
    @State private var isCreating = false
    @State private var failure: CompanyCreateFailure?
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }
    private var canSubmit: Bool { canCreate && CompanyName.normalized(name) != nil && !isCreating }

    var body: some View {
        Form {
            Section {
                TextField(copy.companyNameLabel, text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .disabled(isCreating)
                    .onSubmit { submit() }
                    .onChange(of: name) { _, value in
                        // The platform refuses a longer name; stop typing at the limit.
                        if CompanyName.isAtLimit(value), value.utf16.count > CompanyName.maximumLength {
                            name = Self.limited(value)
                        }
                        failure = nil
                        if let submitted = submittedName, CompanyName.normalized(value) != submitted {
                            submittedName = nil
                            nameEdited()
                        }
                    }
                    .accessibilityLabel(copy.companyNameLabel)
                    .accessibilityIdentifier("company.create.name")
            } footer: {
                if !canCreate {
                    Text(verbatim: copy.creationClosed)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .accessibilityIdentifier("company.create.closed")
                } else if let failure {
                    Text(verbatim: copy.createFailure(failure))
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .accessibilityIdentifier("company.create.error")
                }
            }
            Section {
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if isCreating { ProgressView() }
                        Text(verbatim: copy.createSubmit)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("company.create.submit")
            }
            if invites != nil {
                Section {
                    Button { showsJoin = true } label: {
                        Label { Text(verbatim: TeamSpaceCopy(design: design).joinWithInviteLink) }
                            icon: { Image(atum.symbol(.link)) }
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("company.join.open")
                }
            }
        }
        .sheet(isPresented: $showsJoin) {
            if let invites {
                CompanyInviteJoinSheet(design: design, actions: invites, onJoined: { _ in
                    showsJoin = false
                    onCreated()
                })
                .atumDesign(visual: AtumVisualSystem(design: design))
            }
        }
        .navigationTitle(copy.newCompanyTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.error, trigger: failure)
        .task { nameFocused = true }
        .accessibilityIdentifier("company.create")
    }

    private func submit() {
        guard canSubmit else { return }
        isCreating = true
        failure = nil
        let typed = name
        submittedName = CompanyName.normalized(typed)
        Task { @MainActor in
            let result = await create(typed)
            isCreating = false
            if let result { failure = result } else { onCreated() }
        }
    }

    /// The longest prefix of `value` the platform accepts, never splitting a
    /// character.
    static func limited(_ value: String) -> String {
        var result = value
        while result.utf16.count > CompanyName.maximumLength { result.removeLast() }
        return result
    }
}

struct CompanyMembersView: View {
    let design: LiveDesign
    let members: [CompanyMemberRow]
    let isLoading: Bool
    var loadMatrixThumbnail: ((String, Int) async -> Data?)? = nil

    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

    var body: some View {
        List {
            if isLoading && members.isEmpty {
                Text(verbatim: copy.text(CompanyCopyKey("loading")))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            } else {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        MatrixFace(kind: .person, name: member.name, matrixURI: member.avatarURI, size: 36,
                                   loadMatrixThumbnail: loadMatrixThumbnail)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: member.name)
                                    .font(.body)
                                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                                    .lineLimit(1)
                                CompanyRolePill(design: design, role: member.role, isAdmin: member.isAdmin)
                            }
                            HStack(spacing: 6) {
                                if let handle = member.handle {
                                    Text(verbatim: "@" + handle)
                                }
                                if let state = member.state {
                                    Text(verbatim: "· " + state)
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                        Spacer()
                        if member.isSelf {
                            Text(verbatim: design.text("desktop.dm.you"))
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("company.member." + member.id)
                }
            }
        }
        .navigationTitle(copy.membersTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("company.members.list")
    }
}

/// A member's role as a pill (desktop `RoleBadge`): admins a shade stronger.
struct CompanyRolePill: View {
    let design: LiveDesign
    let role: String
    let isAdmin: Bool

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Text(verbatim: role)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(atum.color(isAdmin ? .ink : .soft, scheme: scheme))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(atum.color(isAdmin ? .actionQuiet : .cell, scheme: scheme)))
            .overlay(Capsule().strokeBorder(atum.color(.frame, scheme: scheme), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize()
    }
}

/// FlowPhone › Team: the company's logo circle, its name in subheadline semibold
/// and the up/down caret, plus a mark when another company has something
/// waiting; drawn inside the bar's glass capsule.
private struct CompanyHeaderLabel: View {
    let design: LiveDesign
    let title: String
    let logoURI: String?
    let logoSize: CGFloat
    let others: Badge
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(spacing: 8) {
            CompanyLogo(name: title, logoURI: logoURI, size: logoSize,
                        loadMatrixThumbnail: loadMatrixThumbnail)
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .lineLimit(1)
            // A bar draws no custom symbol, even inside a custom view.
            AtumBarIcon.image(atum.symbol(.chevronUpDown), pointSize: 14)
                .foregroundStyle(atum.kitColor(.ink3, scheme: scheme))
                .accessibilityHidden(true)
            if others != .none {
                HomeBadgeView(design: design, badge: others, pinned: false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("company.header.badge")
            }
        }
        .fixedSize()
    }
}
