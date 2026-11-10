import AtumChat
import AtumNativeAPI
import SwiftUI

// A company channel's chrome (TS-9), the phone's form of desktop's channel
// header, "…" menu, Channel details, intro and pinned panel
// (`company-channel-menu.tsx`, `team-space/channel-chrome.tsx`,
// `team-space/channel-intro.tsx`, `team-space/pinned-panel.tsx`).
//
// The phone speaks the 1.1 channel wire, which is the desktop's legacy
// (no channel admission) profile. There the desktop menu offers Threads,
// Channel details, Favorite and Notifications, and **no** exit: the channel
// follows the company roster, so there is nothing to leave from a room, and
// Leave company lives only in the company menu. Leave channel, channel
// members, add people, edit, archive and restore need wire 1.4 admission; they
// are not drawn until the phone speaks it.

/// The reads a channel's chrome makes beyond the chat's own.
struct CompanyChannelActions {
    /// The room's create time and pinned count, for the intro and the details.
    var loadFacts: ((String) async -> CompanyChannelFacts?)?
    /// The room's pinned messages, in the room's order.
    var loadPinned: ((String) async -> [CompanyPinnedRow]?)?
}

/// The channel's name with its "#", and the topic under it when the room has one.
struct CompanyChannelTitle: View {
    let design: LiveDesign
    let title: String
    let topic: String?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    private var topicLine: String? {
        topic.flatMap { value in
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    Text(verbatim: "#")
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                if let topicLine {
                    Text(verbatim: topicLine)
                        .font(.caption)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .lineLimit(1)
                        .accessibilityIdentifier("chat.company.topic")
                }
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: TeamSpaceCopy(design: design).channelDetails))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat.title")
        .accessibilityShowsLargeContentViewer()
    }
}

/// Up to three round faces and the channel's count, in one quiet capsule
/// (desktop `MatrixCompanyMembersButton`). On the 1.1 wire a channel's people
/// are the company roster, so it opens the channel's info, where they are.
struct CompanyChannelMembersCapsule: View {
    let design: LiveDesign
    let company: CompanyChatInfo
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    private var active: [CompanyMemberRow] { company.members.filter { $0.state == nil } }
    private var count: Int { company.memberCount ?? active.count }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                if active.isEmpty {
                    Image(atum.symbol(.users)).font(.footnote)
                } else {
                    MemberFacesStack(members: Array(active.prefix(3)), size: 20,
                                     loadMatrixThumbnail: loadMatrixThumbnail)
                }
                Text(verbatim: count.formatted())
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: CompanyCopy(design: design).memberCount(count)))
        .accessibilityIdentifier("chat.company.members.capsule")
    }
}

/// The channel's "…" menu on the legacy wire: Channel details, Favorite,
/// Notifications (the phone's mute), never Leave.
struct CompanyChannelMenu: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let setPinned: ((String, Bool) -> Void)?
    let setMuted: ((String, Bool) -> Void)?
    let openDetails: () -> Void

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var company: CompanyCopy { CompanyCopy(design: design) }

    var body: some View {
        Menu {
            Button(action: openDetails) {
                Label { Text(verbatim: team.channelDetails) } icon: { Image(atum.symbol(.hash)) }
            }
            .accessibilityIdentifier("chat.company.details")
            Divider()
            if let setPinned {
                Button { setPinned(info.roomID, !info.isPinned) } label: {
                    Label { Text(verbatim: info.isPinned ? team.unfavoriteChannel : team.favoriteChannel) } icon: {
                        Image(atum.symbol(info.isPinned ? .starFilled : .star))
                    }
                }
                .accessibilityIdentifier("chat.company.favorite")
            }
            if let setMuted {
                Button { setMuted(info.roomID, !info.isMuted) } label: {
                    Label { Text(verbatim: company.muteTitle(isMuted: info.isMuted)) } icon: {
                        Image(atum.symbol(info.isMuted ? .bell : .bellOff))
                    }
                }
                .accessibilityIdentifier("chat.company.mute")
            }
        } label: {
            atum.barIcon(.moreHorizontal)
        }
        .accessibilityLabel(Text(verbatim: ChatCopy.text(design, .infoOpen)))
        .accessibilityIdentifier("chat.company.menu")
    }
}

/// "This is the start of #general": the channel's name, what it is for, and
/// when it was made (desktop `ChannelIntro`). Shown while the channel is empty.
struct CompanyChannelIntro: View {
    let design: LiveDesign
    let roomID: String
    let company: CompanyChatInfo
    let actions: CompanyChannelActions?

    @State private var createdAt: Date?
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    /// On the 1.1 wire only the default channel has words of its own (desktop
    /// `channelDescription`: its localized purpose).
    private var purpose: String? { company.isDefaultChannel ? team.defaultChannelPurpose : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(verbatim: "#").foregroundStyle(atum.color(.muted, scheme: scheme))
                Text(verbatim: company.channelName).foregroundStyle(atum.color(.ink, scheme: scheme))
            }
            .font(.title2.weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: team.channelStartTitle(company.channelName)))
            .accessibilityAddTraits(.isHeader)
            if let purpose {
                Text(verbatim: purpose)
                    .font(.body)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
            if let createdAt {
                Text(verbatim: team.channelCreatedOn(createdAt.formatted(date: .long, time: .omitted)))
                    .font(.callout)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityIdentifier("chat.company.intro.made")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .task(id: roomID) { createdAt = await actions?.loadFacts?(roomID)?.createdAt }
        .accessibilityIdentifier("chat.company.intro")
    }
}

/// The channel's part of its info sheet: Channel details (name, topic, the
/// company and its member count, when it was made), Pinned messages, then the
/// company roster. Favorite and Notifications are the sheet's own Pin and Mute
/// tiles above. There is no Leave here (see the file header).
struct CompanyChannelInfoSection: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let company: CompanyChatInfo
    let startedAt: Date?
    let actions: CompanyChannelActions?
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @State private var pinnedCount: Int?
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

    private var topic: String? {
        info.topic.flatMap { value in
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        } ?? (company.isDefaultChannel ? team.defaultChannelPurpose : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group(title: team.channelDetails, id: "info.company.details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "# " + company.channelName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    if let topic {
                        Text(verbatim: topic)
                            .font(.subheadline)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(verbatim: team.channelTopicLabel + ", " + topic))
                    }
                    Text(verbatim: [company.companyName,
                                    copy.memberCount(company.memberCount ?? company.members.count)]
                        .joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                    if let startedAt {
                        Text(verbatim: team.channelCreatedOn(startedAt.formatted(date: .long, time: .omitted)))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
                NavigationLink {
                    CompanyPinnedMessagesView(design: design, roomID: info.roomID, actions: actions)
                } label: {
                    row(glyph: .pin, title: team.pinnedMessages,
                        trailing: pinnedCount.map { $0.formatted() })
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("info.company.pinned")
            }
            .background(atum.color(.cell, scheme: scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)

            Text(verbatim: company.notice)
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("info.company.notice")

            group(title: copy.membersTitle, id: "info.company.members") {
                LazyVStack(spacing: 0) {
                    if company.membersLoading && company.members.isEmpty {
                        Text(verbatim: copy.text(CompanyCopyKey("loading")))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 44)
                    }
                    ForEach(company.members) { member in
                        memberRow(member)
                        if member.id != company.members.last?.id {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .task(id: info.roomID) { pinnedCount = await actions?.loadFacts?(info.roomID)?.pinnedCount }
    }

    private func group(title: String, id: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            content()
                .background(atum.color(.cell, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
        }
        .accessibilityIdentifier(id)
    }

    private func row(glyph: AtumGlyph, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(atum.symbol(glyph))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(verbatim: title).foregroundStyle(atum.color(.ink, scheme: scheme))
            Spacer()
            if let trailing {
                Text(verbatim: trailing).foregroundStyle(atum.color(.soft, scheme: scheme))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func memberRow(_ member: CompanyMemberRow) -> some View {
        HStack(spacing: 12) {
            MatrixFace(kind: .person, name: member.name, matrixURI: member.avatarURI, size: 32,
                       loadMatrixThumbnail: loadMatrixThumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: member.name).font(.body).lineLimit(1)
                    CompanyRolePill(design: design, role: member.role, isAdmin: member.isAdmin)
                }
                HStack(spacing: 4) {
                    if let handle = member.handle { Text(verbatim: "@" + handle) }
                    if let state = member.state { Text(verbatim: "· " + state) }
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
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("info.company.member." + member.id)
    }
}

/// The channel's pinned messages (desktop `PinnedPanel`), oldest pin first as the room lists them.
struct CompanyPinnedMessagesView: View {
    let design: LiveDesign
    let roomID: String
    let actions: CompanyChannelActions?

    @State private var rows: [CompanyPinnedRow]?
    @State private var loaded = false
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        List {
            if let rows {
                if rows.isEmpty {
                    Text(verbatim: team.noPinnedMessages)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("info.company.pinned.empty")
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        if let summary = row.summary {
                            Text(verbatim: row.isOwn ? TeamSpaceCopy(design: design).savedYou
                                 : (summary.senderName ?? team.activitySomeone))
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: summary.body)
                                .font(.subheadline)
                                .lineLimit(6)
                        } else {
                            Text(verbatim: team.pinnedMessageUnavailable)
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("info.company.pinned." + row.eventID)
                }
            } else if loaded {
                Text(verbatim: team.pinnedMessageUnavailable)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(rows.map { team.pinnedMessageCount($0.count) } ?? team.pinnedMessages)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: roomID) {
            rows = await actions?.loadPinned?(roomID)
            loaded = true
        }
        .accessibilityIdentifier("info.company.pinned.list")
    }
}
