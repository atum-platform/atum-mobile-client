import AtumNativeAPI
import SwiftUI
import UIKit

// Wave 3 TS-11 and TS-13 surfaces (docs/ports/w3-team-space.md):
// - "Add people to {company}" (desktop `invite-sheet.tsx`): one field, the typed
//   @handle as a row with its face and one Add, what became of it, then the
//   share link (desktop `invite-links.tsx`) where this person may make one.
// - "Join a company" (desktop `invite-join-dialog.tsx`): paste a link, preview
//   the company, Join.
// - "Create a channel" (desktop flat-mode create, `channel-create-dialog.tsx`
//   words): one name field.
// Every async answer is fenced on the sheet's own @State generation, never on
// the view's captured properties after an await.

struct CompanyInviteActions {
    let standing: (_ companyID: String, _ handle: String?) -> CompanyInviteStanding
    let invite: (_ companyID: String, _ handle: String) async -> CompanyInviteOutcome
    let loadLinks: (_ companyID: String) async -> [CompanyInviteLinkSummary]?
    let createLink: (_ companyID: String) async -> CompanyInviteLinkCreateResult
    let revokeLink: (_ companyID: String, _ linkID: NativeID) async -> CompanyInviteRevokeFailure?
    let preview: (CompanyInviteLinkToken) async -> CompanyInviteJoinState
    let redeem: (CompanyInviteLinkToken, NativeID, CompanyInviteLinkPreview) async -> CompanyInviteJoinState
    let createChannel: (_ companyID: String, _ name: String) async -> CompanyChannelCreateResult
}

/// The words for a refused company call, shared by the sheets below.
@MainActor
enum CompanyInviteText {
    static func failure(_ outcome: CompanyInviteOutcome, method: CompanyInviteMethod,
                        team: TeamSpaceCopy, copy: CompanyCopy) -> String {
        guard case let .refused(refusal, reason) = outcome else { return copy.text(CompanyCopyKey("unavailable")) }
        // The 1.1 invitation by handle answers 404 for a handle no one holds.
        if method == .legacy, refusal == .missing, let text = team.refusal("invite_target_unavailable") {
            return text
        }
        if reason == "invitation_unavailable" || reason == "invite_target_unavailable" { return team.inviteCantInvite }
        if let reason, let text = team.refusal(reason) { return text }
        switch refusal {
        case .denied: return team.inviteNotAllowed
        case .missing: return team.inviteCantInvite
        case .limit: return team.refusal("invite_lookup_limited") ?? copy.text(CompanyCopyKey("limit"))
        default: return error(.refused(refusal, reason: nil, retryAfter: nil), team: team, copy: copy)
        }
    }

    static func error(_ error: CompanyAPIError?, team: TeamSpaceCopy, copy: CompanyCopy) -> String {
        guard case let .refused(refusal, reason, _) = error else { return copy.text(CompanyCopyKey("unavailable")) }
        if let reason, let text = team.refusal(reason) { return text }
        switch refusal {
        case .denied: return copy.text(CompanyCopyKey("denied"))
        case .conflict: return copy.text(CompanyCopyKey("conflict"))
        case .limit: return copy.text(CompanyCopyKey("limit"))
        case .invalid: return copy.text(CompanyCopyKey("invalid"))
        case .missing: return copy.text(CompanyCopyKey("missing"))
        case .authentication: return copy.text(CompanyCopyKey("authentication"))
        default: return copy.text(CompanyCopyKey("unavailable"))
        }
    }
}

// MARK: Add people

struct CompanyInviteSheet: View {
    let design: LiveDesign
    let companyID: String
    let companyName: String
    let abilities: CompanyInviteAbilities
    let actions: CompanyInviteActions
    var loadMatrixThumbnail: ((String, Int) async -> Data?)?

    private enum RowState: Equatable { case sending, invited, failed }

    @State private var query = ""
    @State private var rows = [String: RowState]()
    @State private var status: (text: String, isError: Bool)?
    @FocusState private var searchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }
    private var handle: String? { CompanyInviteQuery.handle(query) }
    private var standing: CompanyInviteStanding { actions.standing(companyID, handle) }

    /// What the field says when no row can be drawn for it.
    private var emptyLine: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard handle == nil, text.count >= 2 else { return nil }
        // An address, where email invitations are off: the link is the way in.
        if CompanyInviteQuery.isEmail(text), abilities.inviteLink { return team.inviteEmailOff }
        return team.peopleNoMatch
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(text: $query, prompt: Text(verbatim: team.inviteSearch)) {
                        Text(verbatim: team.inviteSearch)
                    }
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.default)
                    .submitLabel(.send)
                    .onSubmit { if let handle, standing == .none, rows[handle] == nil { add(handle) } }
                    .onChange(of: query) { _, _ in status = nil }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("company.invite.search")
                } header: {
                    Text(verbatim: team.inviteSheetTitle(company: companyName))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("company.invite.title")
                }

                if let handle {
                    Section { candidate(handle) }
                } else if let emptyLine {
                    Section {
                        Text(verbatim: emptyLine)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("company.invite.empty")
                    }
                }

                if let status {
                    Section {
                        Text(verbatim: status.text)
                            .font(.subheadline)
                            .foregroundStyle(atum.color(status.isError ? .danger : .ink, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("company.invite.status")
                    }
                }

                if abilities.inviteLink {
                    CompanyInviteLinksSection(design: design, companyID: companyID,
                                              canRevoke: abilities.revokeInviteLink, actions: actions)
                }
            }
            .scrollContentBackground(.hidden)
            // At large text the keyboard covers the row and the link: scrolling puts it away.
            .scrollDismissesKeyboard(.immediately)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.invite.close")
                }
            }
        }
        .task { searchFocused = true }
        .accessibilityIdentifier("company.invite.sheet")
    }

    private func candidate(_ handle: String) -> some View {
        let state = rows[handle]
        let person = HStack(spacing: 12) {
            MatrixFace(kind: .person, name: handle, matrixURI: nil, size: 36,
                       loadMatrixThumbnail: loadMatrixThumbnail)
            Text(verbatim: "@" + handle)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        // At the accessibility sizes the action goes under the name, so neither is cut.
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    person
                    trailing(handle, state: state)
                }
            } else {
                HStack(spacing: 12) {
                    person
                    Spacer(minLength: 8)
                    trailing(handle, state: state)
                }
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("company.invite.row." + handle)
    }

    @ViewBuilder
    private func trailing(_ handle: String, state: RowState?) -> some View {
        if state == .sending {
            ProgressView()
                .accessibilityLabel(Text(verbatim: team.working))
        } else if state == .invited || standing == .invited {
            Label {
                Text(verbatim: team.inviteAlreadyInvited).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(atum.symbol(.check)) }
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .accessibilityIdentifier("company.invite.invited." + handle)
        } else if standing == .member {
            Text(verbatim: team.inviteAlreadyMember)
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("company.invite.member." + handle)
        } else {
            Button { add(handle) } label: {
                Text(verbatim: team.inviteAdd)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(atum.color(.onInk, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(atum.color(.actionStrong, scheme: scheme))
            .accessibilityIdentifier("company.invite.add." + handle)
        }
    }

    private func add(_ handle: String) {
        guard rows[handle] != .sending else { return }
        rows[handle] = .sending
        status = nil
        Task { @MainActor in
            let outcome = await actions.invite(companyID, handle)
            // The row is keyed by its handle: a newer press for another handle keeps its own.
            switch outcome {
            case .invited:
                rows[handle] = .invited
                status = (team.inviteInvited("@" + handle), false)
            default:
                rows[handle] = .failed
                status = (CompanyInviteText.failure(outcome, method: abilities.method, team: team, copy: copy), true)
            }
        }
    }
}

// MARK: Share link

/// "Or share a link": one press makes a member link and copies it. The link's
/// text is shown once, here, and held only by this section (one company, one
/// opening of the sheet); it is never logged and goes when the sheet closes.
struct CompanyInviteLinksSection: View {
    let design: LiveDesign
    let companyID: String
    let canRevoke: Bool
    let actions: CompanyInviteActions

    private enum Status: Equatable { case idle, working, copied, revoked }

    @State private var links: [CompanyInviteLinkSummary] = []
    @State private var secret: CompanyInviteLinkSecret?
    @State private var replayed = Set<NativeID>()
    @State private var status = Status.idle
    @State private var error: String?
    /// Every read and press bumps this; only the latest answer may land.
    @State private var generation: UInt64 = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }
    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        Section {
            Button(action: create) {
                HStack(spacing: 10) {
                    if status == .working { ProgressView() } else { Image(atum.symbol(.copy)).accessibilityHidden(true) }
                    Text(verbatim: status == .working ? team.inviteLinkCreating : team.copyInviteLink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .frame(minHeight: 44)
            }
            .disabled(status == .working)
            .accessibilityIdentifier("company.invite.link.create")

            if status == .copied || status == .revoked {
                Text(verbatim: status == .copied ? team.inviteLinkCopied : team.inviteLinkRevoked)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityIdentifier("company.invite.link.status")
            }

            if let secret {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: secret.url)
                        .font(.footnote.monospaced())
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("company.invite.link.url")
                    Text(verbatim: team.inviteLinkDuration(days: max(1, CompanyInviteDays.left(
                        expiresAt: secret.summary.expiresAt, now: now)))
                        + " " + team.inviteLinkCapacity(uses: secret.summary.maxUses))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: team.inviteLinkAudience)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error {
                Text(verbatim: error)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("company.invite.link.error")
            }

            ForEach(links) { link in
                VStack(alignment: .leading, spacing: 4) {
                    // At the accessibility sizes Revoke goes under the line, so neither is cut.
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Text(verbatim: team.inviteLinkUsage(used: link.uses, max: link.maxUses) + " · "
                             + team.inviteLinkExpires(days: CompanyInviteDays.left(expiresAt: link.expiresAt, now: now)))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        if canRevoke {
                            Button(role: .destructive) { revoke(link) } label: {
                                Text(verbatim: team.inviteLinkRevoke)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("company.invite.link.revoke." + link.id.rawValue)
                        }
                    }
                    if replayed.contains(link.id) {
                        Text(verbatim: team.inviteLinkReplayed)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("company.invite.link." + link.id.rawValue)
            }
        } header: {
            Text(verbatim: team.inviteLinkSection)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("company.invite.links")
        } footer: {
            if !links.isEmpty {
                Text(verbatim: team.inviteLinksActive)
            }
        }
        .task(id: companyID) {
            secret = nil
            await load()
        }
        .onDisappear { secret = nil }
    }

    private func load() async {
        generation &+= 1
        let mine = generation
        let read = await actions.loadLinks(companyID)
        guard mine == generation, !Task.isCancelled, let read else { return }
        links = read
    }

    private func create() {
        generation &+= 1
        let mine = generation
        status = .working
        error = nil
        secret = nil
        Task { @MainActor in
            let result = await actions.createLink(companyID)
            guard mine == generation else { return }
            switch result {
            case let .created(link):
                secret = link
                UIPasteboard.general.string = link.url
                status = .copied
            case let .replayed(id):
                replayed.insert(id)
                status = .idle
            case let .failed(failure):
                status = .idle
                error = CompanyInviteText.error(failure, team: team, copy: copy)
            }
            await load()
        }
    }

    private func revoke(_ link: CompanyInviteLinkSummary) {
        generation &+= 1
        let mine = generation
        error = nil
        Task { @MainActor in
            let failure = await actions.revokeLink(companyID, link.id)
            guard mine == generation else { return }
            if let failure {
                error = CompanyInviteText.error(failure.error, team: team, copy: copy)
                return
            }
            status = .revoked
            if secret?.summary.id == link.id { secret = nil }
            await load()
        }
    }
}

// MARK: Join with an invite link

struct CompanyInviteJoinSheet: View {
    let design: LiveDesign
    let actions: CompanyInviteActions
    /// The company joined (already selected by the model): the host closes what it opened.
    let onJoined: (String) -> Void

    @State private var input = ""
    @State private var stage = CompanyInviteJoinState.paste
    /// The pasted link's bearer, in memory only, for this one flow.
    @State private var token: CompanyInviteLinkToken?
    /// One redeem request per flow, so a retry after a lost answer replays it.
    @State private var requestID = try? NativeID(UUID().uuidString.lowercased())
    @State private var generation: UInt64 = 0
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var locale: Locale { Locale(identifier: design.locale) }

    private var isEditing: Bool {
        switch stage {
        case .paste: true
        case let .failure(failure, preview): preview == nil && failure == .invalid || preview == nil && failure == .unavailable
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isEditing {
                        TextField(text: $input, prompt: Text(verbatim: team.inviteLinkLabel), axis: .vertical) {
                            Text(verbatim: team.inviteLinkLabel)
                        }
                        .focused($inputFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...4)
                        .onChange(of: input) { _, _ in if case .failure = stage { stage = .paste } }
                        .accessibilityIdentifier("company.join.input")
                        PasteButton(payloadType: String.self) { strings in
                            guard let first = strings.first else { return }
                            Task { @MainActor in input = first }
                        }
                        .accessibilityIdentifier("company.join.paste")
                    }
                } header: {
                    Text(verbatim: team.joinInviteTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .textCase(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    if isEditing {
                        Text(verbatim: team.inviteLinkHint)
                    }
                }

                if case .previewing = stage {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(verbatim: team.previewingInvite)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("company.join.previewing")
                    }
                }

                if let preview = stage.previewValue {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: team.invitedTo(preview.companyName))
                                .font(.body.weight(.medium))
                                .foregroundStyle(atum.color(.ink, scheme: scheme))
                            if let inviter = preview.inviterLabel {
                                Text(verbatim: team.inviteFrom(inviter))
                                    .font(.subheadline)
                                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                            }
                            Text(verbatim: team.inviteExpires(Date(timeIntervalSince1970: TimeInterval(preview.expiresAt))
                                .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))))
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("company.join.preview")
                    }
                }

                if case let .failure(failure, _) = stage {
                    Section {
                        Text(verbatim: team.joinFailure(failure))
                            .foregroundStyle(atum.color(.danger, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("company.join.failure")
                    }
                }

                if case let .complete(_, completion, _) = stage {
                    Section {
                        Text(verbatim: team.joinCompletion(completion))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("company.join.complete")
                    }
                }

                Section { primaryButton }
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(design.text("src.matrix.chat-copy.copies.cancel")) { close() }
                        .accessibilityIdentifier("company.join.cancel")
                }
            }
        }
        .task { inputFocused = true }
        .onDisappear { token = nil }
        .accessibilityIdentifier("company.join.sheet")
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch stage {
        case .preview, .redeeming:
            let busy = { if case .redeeming = stage { return true } else { return false } }()
            Button(action: join) {
                HStack(spacing: 8) {
                    if busy { ProgressView() }
                    Text(verbatim: busy ? team.joiningInvite : team.joinInvite)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(busy)
            .accessibilityIdentifier("company.join.submit")
        case .complete:
            EmptyView()
        default:
            Button(action: preview) {
                Text(verbatim: team.previewInvite)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!isEditing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("company.join.previewButton")
        }
    }

    private func preview() {
        guard let parsed = CompanyInviteLinkToken.parse(paste: input) else {
            stage = .failure(.invalid, preview: nil)
            return
        }
        // A different link is a different flow: a new redeem request with it.
        if parsed != token { requestID = try? NativeID(UUID().uuidString.lowercased()) }
        token = parsed
        generation &+= 1
        let mine = generation
        stage = .previewing
        Task { @MainActor in
            let next = await actions.preview(parsed)
            guard mine == generation else { return }
            stage = next
        }
    }

    private func join() {
        guard case let .preview(value) = stage, let token, let requestID else { return }
        generation &+= 1
        let mine = generation
        stage = .redeeming(value)
        Task { @MainActor in
            let next = await actions.redeem(token, requestID, value)
            guard mine == generation else { return }
            stage = next
            if case let .complete(_, _, companyID) = next {
                self.token = nil
                onJoined(companyID)
            }
        }
    }

    private func close() {
        generation &+= 1
        token = nil
        dismiss()
    }
}

// MARK: Create a channel

struct CompanyChannelCreateSheet: View {
    let design: LiveDesign
    let companyID: String
    let create: (_ companyID: String, _ name: String) async -> CompanyChannelCreateResult
    /// The new channel's room, when the platform has made it already.
    let onCreated: (String?) -> Void

    @State private var name = ""
    @State private var attempted = false
    @State private var isCreating = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var team: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var copy: CompanyCopy { CompanyCopy(design: design) }

    private var problem: String? {
        switch CompanyChannelName.problem(name) {
        case .required: attempted ? team.channelNameRequired : nil
        case .tooLong: team.channelNameTooLong
        case nil: nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name, prompt: Text(verbatim: team.channelNamePlaceholder)) {
                        Text(verbatim: team.channelNameLabel)
                    }
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .disabled(isCreating)
                    .onSubmit(submit)
                    .onChange(of: name) { _, _ in failure = nil }
                    .accessibilityLabel(Text(verbatim: team.channelNameLabel))
                    .accessibilityIdentifier("company.channel.create.name")
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: team.createChannelTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: team.createChannelBody)
                            .font(.subheadline)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                    }
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                } footer: {
                    if let text = problem ?? failure {
                        Text(verbatim: text)
                            .foregroundStyle(atum.color(.danger, scheme: scheme))
                            .accessibilityIdentifier("company.channel.create.error")
                    }
                }
                Section {
                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if isCreating { ProgressView() }
                            Text(verbatim: isCreating ? team.creatingChannel : team.createChannelSubmit)
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(isCreating || CompanyChannelName.normalized(name) == nil)
                    .accessibilityIdentifier("company.channel.create.submit")
                }
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(design.text("src.matrix.chat-copy.copies.cancel")) { dismiss() }
                        .accessibilityIdentifier("company.channel.create.cancel")
                }
            }
        }
        .task { nameFocused = true }
        .accessibilityIdentifier("company.channel.create")
    }

    private func submit() {
        attempted = true
        guard !isCreating, CompanyChannelName.normalized(name) != nil else { return }
        isCreating = true
        failure = nil
        let typed = name
        Task { @MainActor in
            let result = await create(companyID, typed)
            isCreating = false
            switch result {
            case let .created(roomID):
                onCreated(roomID)
                dismiss()
            case let .failed(error):
                failure = CompanyInviteText.error(error, team: team, copy: copy)
            }
        }
    }
}
