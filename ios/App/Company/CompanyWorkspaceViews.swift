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
    @State private var showsMembers = false
    @State private var showsSwitcher = false
    @State private var showsCreate = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

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
        .navigationDestination(isPresented: $showsMembers) {
            CompanyMembersView(design: design,
                               members: presentation.workspace?.members ?? [],
                               isLoading: presentation.workspace?.membersLoading ?? false,
                               loadMatrixThumbnail: actions.loadMatrixThumbnail)
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
                                  onCreated: { showsCreate = false })
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

    // MARK: List

    private var list: some View {
        List {
            if let workspace = presentation.workspace {
                notices(workspace)
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
                Section {
                    if workspace.channelsLoading {
                        note(copy.text(CompanyCopyKey("loadingChannels")))
                    } else if workspace.channels.isEmpty {
                        note(copy.text(CompanyCopyKey("noChannels")))
                    } else {
                        ForEach(workspace.channels) { channel in
                            channelRow(channel)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    sectionHeader(copy.channelsTitle, id: "company.section")
                }
                .listSectionSeparator(.hidden)
                // Direct messages is always there for a loaded company (desktop
                // `company-workspace.tsx:2996`): You and the Chief of Staff come first;
                // only the conversation rows and "+" wait for the conversations family.
                ConversationSectionView(design: design, companyID: workspace.id,
                                        directMessages: workspace.directMessages,
                                        actions: actions.conversations,
                                        rowActions: actions.directMessages,
                                        loadMatrixThumbnail: actions.loadMatrixThumbnail)
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
        .refreshable { await actions.refresh() }
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showsMembers = true } label: {
                        Label { Text(verbatim: copy.membersTitle) } icon: {
                            Image(atum.symbol(.users))
                        }
                    }
                    .accessibilityIdentifier("company.members")
                    Button(role: .destructive) { confirmsLeave = true } label: {
                        Label { Text(verbatim: copy.leaveAction) } icon: {
                            Image(atum.symbol(.logOut))
                        }
                    }
                    .accessibilityIdentifier("company.leave")
                } label: {
                    atum.barIcon(.moreHorizontal)
                }
                .accessibilityIdentifier("company.menu")
            }
        }
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
                                              onCreated: { dismiss() })
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
