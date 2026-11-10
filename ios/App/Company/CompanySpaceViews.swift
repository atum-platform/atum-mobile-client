import AtumChat
import AtumNativeAPI
import SwiftUI

// Wave 2 Team Space structure: the company pages (Chat · Board), the Board's
// honest state, the Company overview sheet, the Activity inbox and Saved.

// MARK: Pages (TS-10)

/// Chat · Board (then Marketplace while the company Store answers): a segmented
/// control under the company header, the phone's form of the desktop's title-bar
/// tabs (`company-space-tabs.tsx`).
struct CompanyPagesBar: View {
    let design: LiveDesign
    let tabs: [CompanySpaceTab]
    @Binding var selection: CompanySpaceTab

    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(tabs, id: \.self) { tab in
                Text(verbatim: copy.page(tab)).tag(tab)
                    .accessibilityIdentifier("company.page." + tab.rawValue)
            }
        } label: {
            Text(verbatim: copy.pagesLabel)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("company.pages")
    }
}

/// The Board page. The phone has no board read yet (the platform's `board-*`
/// native routes, TS later), so it shows the desktop board's own unavailable
/// state rather than an empty board that would look real.
struct CompanyBoardPage: View {
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ContentUnavailableView {
            Text(verbatim: TeamSpaceCopy(design: design).boardUnavailable)
                .font(.body)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        }
        .accessibilityIdentifier("company.board.unavailable")
    }
}

// MARK: Company overview (TS-8)

/// The company at a glance (desktop `CompanyOverviewFrame`, company-workspace.tsx:3165–3403):
/// its logo and name, the viewer's role, the members, and the Chief of Staff's
/// state. The parts the platform gates (search, logo and policy settings,
/// projects, funding) are not drawn until the phone speaks their wire.
struct CompanyOverviewSheet: View {
    let design: LiveDesign
    let workspace: CompanyWorkspacePresentation
    let logoURI: String?
    let viewerRole: String?
    let menu: CompanyMenuAllowed
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let leave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    private var activeMembers: Int {
        workspace.members.filter { $0.state == nil }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        CompanyLogo(name: workspace.title, logoURI: logoURI, size: 56,
                                    loadMatrixThumbnail: loadMatrixThumbnail)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: workspace.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(atum.color(.ink, scheme: scheme))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                if let viewerRole {
                                    CompanyRolePill(design: design, role: viewerRole,
                                                    isAdmin: workspace.members.first(where: \.isSelf)?.isAdmin ?? false)
                                }
                                if !workspace.members.isEmpty {
                                    Text(verbatim: copy.memberCount(activeMembers))
                                        .font(.footnote)
                                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("company.overview.header")
                }

                if menu.members {
                    Section {
                        NavigationLink {
                            CompanyMembersView(design: design, members: workspace.members,
                                               isLoading: workspace.membersLoading,
                                               loadMatrixThumbnail: loadMatrixThumbnail)
                        } label: {
                            HStack(spacing: 12) {
                                Image(atum.symbol(.users)).accessibilityHidden(true)
                                Text(verbatim: copy.membersTitle)
                                Spacer()
                                MemberFacesStack(members: Array(workspace.members.prefix(3)),
                                                 loadMatrixThumbnail: loadMatrixThumbnail)
                            }
                            .frame(minHeight: 44)
                        }
                        .listRowBackground(atum.color(.cell, scheme: scheme))
                        .accessibilityIdentifier("company.overview.members")
                    }
                }

                if let chief = workspace.directMessages.chief {
                    Section {
                        HStack(spacing: 12) {
                            MatrixFace(kind: .assistant, name: team.chiefOfStaff, matrixURI: nil, size: 28,
                                       loadMatrixThumbnail: nil)
                            Text(verbatim: DirectMessagesCopy(design: design).chiefOfStaff(platformName: chief.platformName))
                            Spacer()
                            Text(verbatim: DirectMessagesCopy(design: design).line(chief.status)
                                 ?? design.text("shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosCopy.ready"))
                                .font(.footnote)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                        .frame(minHeight: 44)
                        .listRowBackground(atum.color(.cell, scheme: scheme))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("company.overview.chief")
                    }
                }

                if menu.leave {
                    Section {
                        Button(role: .destructive) {
                            dismiss()
                            leave()
                        } label: {
                            Label { Text(verbatim: copy.leaveAction) } icon: { Image(atum.symbol(.logOut)) }
                                .foregroundStyle(atum.color(.danger, scheme: scheme))
                                .frame(minHeight: 44)
                        }
                        .disabled(workspace.leavePending)
                        .listRowBackground(atum.color(.cell, scheme: scheme))
                        .accessibilityIdentifier("company.overview.leave")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationTitle(team.companyOverview)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.overview.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("company.overview")
    }
}

/// Up to three round member faces, overlapping (desktop `atum-member-stack`).
struct MemberFacesStack: View {
    let members: [CompanyMemberRow]
    var size: CGFloat = 22
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(members) { member in
                MatrixFace(kind: .person, name: member.name, matrixURI: member.avatarURI, size: size,
                           loadMatrixThumbnail: loadMatrixThumbnail)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Sidebar utility row (TS-6)

/// Threads, Saved or Drafts: an icon, the name, and its mark (desktop `TeamSpaceSidebarRow`).
struct TeamSpaceUtilityRow: View {
    let design: LiveDesign
    let glyph: AtumGlyph
    let title: String
    var badge: Badge = .none
    let identifier: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(atum.symbol(glyph))
                    .font(.system(size: 17))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.body.weight(TeamSpaceBadges.isBold(badge) ? .semibold : .regular))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Spacer(minLength: 8)
                HomeBadgeView(design: design, badge: badge, pinned: false)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Activity (TS-7)

/// The company's Activity inbox (desktop `team-space/activity.tsx`): All or
/// Mentions, 25 at a time, each row opening its room.
struct TeamSpaceActivitySheet: View {
    let design: LiveDesign
    let rows: [CompanyActivityRow]?
    let isLoading: Bool
    let reload: () async -> Void
    let open: (CompanyActivityRow) -> Void

    @State private var filter = CompanyActivityFilter.all
    @State private var visible = CompanyActivityFeed.pageSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    private var filtered: [CompanyActivityRow] {
        (rows ?? []).filter { filter == .all || $0.item.kind == .mention }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker(selection: $filter) {
                    Text(verbatim: copy.activityAll).tag(CompanyActivityFilter.all)
                    Text(verbatim: copy.activityMentions).tag(CompanyActivityFilter.mentions)
                } label: {
                    Text(verbatim: copy.activityFilterLabel)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("company.activity.filter")

                if rows == nil && !isLoading {
                    Text(verbatim: copy.activityFailed)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("company.activity.failed")
                } else if rows == nil {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    emptyState.listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    ForEach(filtered.prefix(visible)) { row in
                        activityRow(row)
                    }
                    if filtered.count > visible {
                        Button(copy.activityLoadMore) { visible += CompanyActivityFeed.pageSize }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("company.activity.more")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .refreshable { await reload() }
            .onChange(of: filter) { _, _ in visible = CompanyActivityFeed.pageSize }
            .navigationTitle(copy.activityTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.activity.close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("company.activity")
    }

    private var emptyState: some View {
        let mentions = filter == .mentions
        return VStack(spacing: 6) {
            Text(verbatim: mentions ? copy.activityEmptyMentionsTitle : copy.activityEmptyAllTitle)
                .font(.headline)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Text(verbatim: mentions ? copy.activityEmptyMentionsBody : copy.activityEmptyAllBody)
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("company.activity.empty")
    }

    private func activityRow(_ row: CompanyActivityRow) -> some View {
        Button {
            open(row)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: row.item.kind == .mention ? copy.activityMention : copy.activityThreadReply)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                    Text(verbatim: "· " + row.roomName)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Date(timeIntervalSince1970: TimeInterval(row.item.sentAt) / 1000),
                         format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                    if row.item.unread {
                        Circle().fill(atum.color(.actionStrong, scheme: scheme)).frame(width: 8, height: 8)
                            .accessibilityLabel(Text(verbatim: copy.activityUnread))
                    }
                }
                Text(verbatim: row.senderName ?? copy.activitySomeone)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Text(verbatim: row.item.body)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityHint(Text(verbatim: copy.activityOpen(room: row.roomName)))
        .accessibilityIdentifier("company.activity.row." + row.item.eventID)
    }
}

// MARK: Saved (TS-6)

/// The account's Saved messages (desktop `team-space/saved-messages.tsx`):
/// newest first; one that is gone or out of reach says so.
struct TeamSpaceSavedSheet: View {
    let design: LiveDesign
    let pointers: [CompanySavedMessagePointer]
    let load: ([CompanySavedMessagePointer]) async -> [CompanySavedRow]
    let open: (CompanySavedRow) -> Void

    @State private var rows: [CompanySavedRow]?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        NavigationStack {
            List {
                if let rows {
                    if rows.isEmpty {
                        VStack(spacing: 6) {
                            Text(verbatim: copy.savedEmptyTitle).font(.headline)
                            Text(verbatim: copy.savedEmptyBody)
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(rows) { row in savedRow(row) }
                } else {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationTitle(copy.savedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.saved.close")
                }
            }
            .task(id: pointers) { rows = await load(pointers) }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("company.saved")
    }

    @ViewBuilder private func savedRow(_ row: CompanySavedRow) -> some View {
        if let summary = row.summary, let room = row.roomName {
            Button { open(row) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: row.isOwn ? copy.savedYou : (summary.senderName ?? copy.activitySomeone))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                        Text(verbatim: "· " + [room, row.companyName].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .lineLimit(1)
                    }
                    Text(verbatim: summary.body)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .lineLimit(4)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("company.saved.row." + row.pointer.eventID)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: copy.savedUnavailable).font(.subheadline.weight(.semibold))
                Text(verbatim: copy.savedUnavailableBody)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("company.saved.unavailable." + row.pointer.eventID)
        }
    }
}
