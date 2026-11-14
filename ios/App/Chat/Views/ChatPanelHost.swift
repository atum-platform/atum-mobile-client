import AtumChat
import AtumDesign
import SwiftUI
import UIKit

/// The chat's side panel (M1): one panel per chat,
/// opened by the chat's title or its "…". `ChatScreen` presents it as a sheet
/// with a medium and a large height (the iPad inspector column is deferred:
/// see `ChatScreen`). Pages (a
/// group's Members, a shared section's See all and an app's page) push
/// inside it; the chat stays where it is.
struct ChatPanelHost: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let actions: ChatInfoActions
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let close: () -> Void

    @State private var path: [ChatPanelPolicy.Page] = []
    @State private var height: PresentationDetent
    @State private var details: ChatInfoDetails?
    @State private var detailsGeneration = 0
    /// The Shared section's scope, owned here so its See all pages share it
    /// and it closes with the panel (`SharedCollectionsController`).
    @State private var shared = SharedCollectionsController()

    init(design: LiveDesign, info: ChatInfoPresentation, actions: ChatInfoActions,
         loadMatrixThumbnail: ((String, Int) async -> Data?)?, close: @escaping () -> Void) {
        self.design = design
        self.info = info
        self.actions = actions
        self.loadMatrixThumbnail = loadMatrixThumbnail
        self.close = close
        _height = State(initialValue: Self.detent(ChatPanelPolicy.openingHeight(for: info.panelSurface)))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack(path: $path) {
            ChatInfoHome(design: design, info: info, actions: actions,
                         loadMatrixThumbnail: loadMatrixThumbnail, details: details,
                         close: close, open: { path.append($0) },
                         reload: { detailsGeneration &+= 1 },
                         sharedCollections: actions.sharedCollections == nil ? nil : shared)
                .navigationDestination(for: ChatPanelPolicy.Page.self) { page in
                    switch page {
                    case .members:
                        ChatMembersPage(design: design, info: info, actions: actions,
                                        details: details, loadMatrixThumbnail: loadMatrixThumbnail,
                                        close: close, reload: { detailsGeneration &+= 1 })
                    case let .shared(section):
                        SharedCollectionPage(design: design, info: info, controller: shared,
                                             section: section.collection, close: close)
                    case let .appPage(routeID):
                        if let appPanel = actions.appPanel {
                            AppPanelPageView(design: design, actions: appPanel, routeID: routeID,
                                             close: close)
                        }
                    }
                }
        }
        .atumDesign(visual: atum)
        .presentationDetents([.medium, .large], selection: $height)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("info.sheet")
        .onChange(of: path) { old, new in
            guard new.count > old.count, let page = new.last else { return }
            height = Self.detent(ChatPanelPolicy.height(afterPushing: page, from: Self.height(height)))
        }
        .task(id: DetailsRequest(roomID: info.roomID, generation: detailsGeneration)) {
            guard let load = actions.loadDetails else { return }
            let loaded = await load(info.roomID)
            guard !Task.isCancelled else { return }
            if let loaded { details = loaded }
        }
    }

    private struct DetailsRequest: Hashable {
        let roomID: String
        let generation: Int
    }

    static func detent(_ height: ChatPanelPolicy.Height) -> PresentationDetent {
        height == .large ? .large : .medium
    }

    static func height(_ detent: PresentationDetent) -> ChatPanelPolicy.Height {
        detent == .large ? .large : .medium
    }
}

/// The panel's close control: the bar's X, and Escape on an iPad keyboard (the
/// desktop's Esc rule).
struct ChatPanelCloseButton: View {
    let design: LiveDesign
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            AtumVisualSystem(design: design).barIcon(.close)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(design.text(PersonInfoKey.closeInfo))
        .accessibilityIdentifier("info.close")
    }
}

/// A group's people, pushed inside the panel: one row each, and what can be
/// done about them behind the row's menu, each confirmed first (desktop
/// `MatrixMembers`). Remove, ban and unban follow the room's power levels
/// (`ChatMemberModeration`); without them the page offers Block only.
struct ChatMembersPage: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let actions: ChatInfoActions
    let details: ChatInfoDetails?
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let close: () -> Void
    let reload: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var confirming: Confirmation?
    @State private var failureToken: UInt64 = 0
    @State private var pending: String?
    @State private var reporting: ReportPersonRequest?

    private struct Confirmation: Equatable {
        let userID: String
        let name: String
        let action: ChatMemberAction
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    /// The list the page shows: the room's members with their power when the
    /// panel read them, otherwise the chat's joined members.
    private var rows: [Row] {
        let own = info.members.first(where: \.isCurrentUser)?.userID
        let assistants = Set(info.members.filter(\.isAssistant).map(\.userID))
        let apps = Set(info.members.filter(\.isApp).map(\.userID))
        if let members = details?.members, !members.isEmpty {
            return members.map { member in
                Row(member: ChatInfoMember(userID: member.userID, name: member.name,
                                           matrixAvatarURI: member.matrixAvatarURI,
                                           isAssistant: assistants.contains(member.userID),
                                           isCurrentUser: member.userID == own,
                                           isApp: apps.contains(member.userID)),
                    power: member.power, membership: member.membership)
            }.sorted(by: Row.order)
        }
        return info.members.map { Row(member: $0, power: 0, membership: .joined) }.sorted(by: Row.order)
    }

    private struct Row: Identifiable {
        let member: ChatInfoMember
        let power: Int64
        let membership: ChatMemberModeration.Membership
        var id: String { member.userID }

        static func order(_ lhs: Row, _ rhs: Row) -> Bool {
            if lhs.member.isCurrentUser != rhs.member.isCurrentUser { return lhs.member.isCurrentUser }
            if (lhs.membership == .banned) != (rhs.membership == .banned) { return rhs.membership == .banned }
            let order = lhs.member.name.localizedCaseInsensitiveCompare(rhs.member.name)
            return order == .orderedSame ? lhs.member.userID < rhs.member.userID : order == .orderedAscending
        }
    }

    private func memberActions(_ row: Row) -> [ChatMemberAction] {
        let mayBlock = actions.setIgnored != nil
            && ChatExitPolicy.mayIgnore(memberIsAssistant: row.member.isAssistant,
                                        memberIsSelf: row.member.isCurrentUser,
                                        in: .group, viewerIsFounder: actions.viewerIsFounder)
        let blocked = details?.ignoredUserIDs.contains(row.member.userID) == true
        // Desktop `conversation-controls.tsx`: Report sits after Ignore, for a person only.
        let mayReport = actions.reportPerson != nil
            && ReportPolicy.mayReportPerson(row.member.reportMember, isSelf: row.member.isCurrentUser,
                                            in: .group, viewerIsFounder: actions.viewerIsFounder)
        guard let moderation = details?.moderation, actions.moderateMember != nil else {
            return ChatMemberModeration.personalActions(isSelf: row.member.isCurrentUser, mayBlock: mayBlock,
                                                        isBlocked: blocked, mayReport: mayReport)
        }
        return moderation.actions(targetPower: row.power, membership: row.membership,
                                  isSelf: row.member.isCurrentUser, mayBlock: mayBlock, isBlocked: blocked,
                                  mayReport: mayReport)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    memberRow(row)
                    if row.id != rows.last?.id { Divider().padding(.leading, 60) }
                }
            }
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .accessibilityIdentifier("info.members")
        }
        .background(atum.color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(design.text("src.matrix.chat-copy.copies.members"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ChatPanelCloseButton(design: design, close: close)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), titleVisibility: .visible, presenting: confirming) { confirmation in
            Button(actionLabel(confirmation.action), role: .destructive) { run(confirmation) }
            Button(design.text("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
        } message: { confirmation in
            if let body = confirmationBody(confirmation.action) { Text(verbatim: body) }
        }
        .sheet(item: $reporting) { request in
            ReportSheet(design: design, subject: .person) { reason in
                await actions.reportPerson?(request.userID, reason) ?? false
            }
        }
        .sensoryFeedback(.error, trigger: failureToken)
    }

    private func memberRow(_ row: Row) -> some View {
        let available = memberActions(row)
        let label = memberLabel(row.member)
        return HStack(spacing: 12) {
            ChatInfoMemberAvatar(member: row.member, loadMatrixThumbnail: loadMatrixThumbnail)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label.name).font(.body)
                // Their @handle on the quiet line under the name (desktop
                // `conversation-controls.tsx`, `data-person-handle`).
                if let handle = label.line {
                    Text(verbatim: handle)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .lineLimit(1)
                        .accessibilityIdentifier("info.member.handle." + row.member.userID)
                }
                if row.membership != .joined {
                    Text(verbatim: design.text(row.membership == .banned
                                               ? "src.matrix.moderation-copy.copies.banned"
                                               : "src.matrix.conversation-copy.copies.invited"))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
            Spacer()
            if row.member.isCurrentUser {
                Text(ChatCopy.text(design, .you))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            } else if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.self) { action in
                        Button(role: action == .unblock || action == .unban || action == .report
                               ? nil : .destructive) {
                            if action == .report {
                                // The report sheet asks for its own reason; no confirmation first.
                                reporting = ReportPersonRequest(userID: row.member.userID)
                            } else if action == .unblock {
                                run(Confirmation(userID: row.member.userID, name: label.name, action: action))
                            } else {
                                confirming = Confirmation(userID: row.member.userID, name: label.name,
                                                          action: action)
                            }
                        } label: {
                            Label(actionLabel(action), image: atum.symbol(glyph(action)))
                        }
                        .accessibilityIdentifier("info.member.action." + action.rawValue)
                    }
                } label: {
                    Image(atum.symbol(.moreHorizontal))
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(pending == row.member.userID)
                .accessibilityLabel(design.text("src.matrix.chat-copy.copies.memberOptions",
                                                arguments: [.text(label.name)]))
                .accessibilityIdentifier("info.member.options." + row.member.userID)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.member." + row.member.userID)
        .requestingHandles([row.member.userID], from: actions.handles)
    }

    /// A member's name and @handle line (desktop `matrixMemberLabel`, which
    /// reads the verified cache for every member).
    private func memberLabel(_ member: ChatInfoMember) -> (name: String, line: String?) {
        guard let handles = actions.handles else { return (member.name, nil) }
        return PersonHandleText.member(name: member.name, handle: handles.handle(member.userID),
                                       unnamed: PeopleNameWords.unnamed)
    }

    private func run(_ confirmation: Confirmation) {
        pending = confirmation.userID
        Task {
            let succeeded: Bool
            switch confirmation.action {
            case .block: succeeded = await actions.setIgnored?(confirmation.userID, true) ?? false
            case .unblock: succeeded = await actions.setIgnored?(confirmation.userID, false) ?? false
            case .remove, .ban, .unban:
                succeeded = await actions.moderateMember?(info.roomID, confirmation.userID, confirmation.action) ?? false
            case .report:
                // Reported through its sheet (`reporting`), never confirmed here.
                succeeded = true
            }
            pending = nil
            if !succeeded {
                failureToken &+= 1
                AccessibilityNotification.Announcement(ChatCopy.text(design, .errorGeneric)).post()
            }
            reload()
        }
    }

    private func glyph(_ action: ChatMemberAction) -> AtumGlyph {
        switch action {
        case .block, .unblock: .eyeOff
        case .report: .alertCircle
        case .remove: .logOut
        case .ban, .unban: .shield
        }
    }

    private func actionLabel(_ action: ChatMemberAction) -> String {
        switch action {
        case .block: design.text(ChatInfoHome.blockKey)
        case .unblock: design.text(ChatInfoHome.unblockKey)
        // PENDING-COPY:src.matrix.chat-copy.copies.reportPerson
        case .report: ReportCopy.text(design, .reportPerson)
        case .remove: design.text("src.matrix.conversation-copy.copies.remove")
        case .ban: design.text("src.matrix.moderation-copy.copies.ban")
        case .unban: design.text("src.matrix.moderation-copy.copies.unban")
        }
    }

    private var confirmationTitle: String {
        guard let confirming else { return "" }
        let name: [AtumCopy.Argument] = [.text(confirming.name)]
        return switch confirming.action {
        case .block, .unblock: design.text("src.matrix.chat-copy.copies.memberIgnoreTitle", arguments: name)
        // Never confirmed here: the report sheet has its own title.
        case .report: ""
        case .remove: design.text("src.matrix.chat-copy.copies.memberRemoveTitle", arguments: name)
        case .ban: design.text("src.matrix.chat-copy.copies.memberBanTitle", arguments: name)
        case .unban: design.text("src.matrix.chat-copy.copies.memberUnbanTitle", arguments: name)
        }
    }

    private func confirmationBody(_ action: ChatMemberAction) -> String? {
        switch action {
        case .block, .unblock: design.text("src.matrix.moderation-copy.copies.notice")
        case .remove: design.text("src.matrix.chat-copy.copies.memberRemoveBody")
        case .report: nil
        case .ban: design.text("src.matrix.moderation-copy.copies.banNotice")
        case .unban: nil
        }
    }
}
