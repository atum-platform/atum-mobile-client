import AtumNativeAPI
import SwiftUI

// Team Space revamp pass 1 on the phone (W4-E7, atum-desktop #114 at `fef8286c`):
// header search's "Search “…”" row and its results, a failed channel open with
// Try again, and the Board page's Board · List and Mine controls. Desktop's one
// right pane is a sheet or a pushed screen here, as every other detail already is.
// docs/ports/w4-e7-team-space.md has the inventory and the reasons.

/// Company message search for the open company, asked from the header box.
struct TeamSpaceMessageSearchActions {
    /// One company's Messages tab (desktop `bridge.search`, `tab: 'messages'`). The phone's
    /// search service answers a failure with nothing, as Home search does.
    var search: @MainActor (_ companyID: String, _ query: String) async -> [CompanySearchResult]
    /// The message is checked again and its room opened (desktop `onOpenSearchResult`).
    var open: @MainActor (CompanySearchResult) async -> Bool
}

// MARK: Header search

/// The row under the box (desktop `TeamSpaceSidebarRow` with `SearchIcon`):
/// "Search “launch”", spoken as "Search messages for “launch”".
struct TeamSpaceSearchMessagesRow: View {
    let design: LiveDesign
    let query: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(atum.symbol(.search))
                    .font(.system(size: 17))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(verbatim: copy.searchFor(query))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: copy.searchMessagesFor(query)))
        .accessibilityIdentifier("company.search.messages")
    }
}

/// The search results (desktop `data-matrix-company-search-pane`): titled Search, the
/// query searched straight away, its own field to refine it, and each result opening
/// its message. Messages only: the Files tab's words are not in the pin yet.
struct TeamSpaceMessageSearchSheet: View {
    let design: LiveDesign
    let companyID: String
    let initialQuery: String
    let actions: TeamSpaceMessageSearchActions
    let opened: () -> Void

    @State private var query: String
    @State private var searched: String?
    @State private var results: [CompanySearchResult] = []
    @State private var searching = false
    @State private var generation: UInt64 = 0
    @State private var openFailed = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    init(design: LiveDesign, companyID: String, initialQuery: String,
         actions: TeamSpaceMessageSearchActions, opened: @escaping () -> Void) {
        self.design = design
        self.companyID = companyID
        self.initialQuery = initialQuery
        self.actions = actions
        self.opened = opened
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel(Text(verbatim: design.text("shared.matrix-company-copy.copy.searchMessages")))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("company.search.loading")
                } else if searched != nil, results.isEmpty {
                    note(design.text("shared.matrix-company-copy.copy.searchNoResults"))
                        .accessibilityIdentifier("company.search.empty")
                } else {
                    ForEach(results) { result in
                        Button { open(result) } label: {
                            HomeSearchEventRow(design: design, result: result, section: .messages)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("company.search.result." + result.eventID)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(verbatim: design.text("shared.matrix-company-copy.copy.searchPlaceholder")))
            .onSubmit(of: .search) { run(query) }
            .navigationTitle(copy.search)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.search.close")
                }
            }
        }
        .task { run(initialQuery) }
        .sensoryFeedback(.error, trigger: openFailed)
        .accessibilityIdentifier("company.search.sheet")
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Desktop asks once the query has two characters; only the latest answer lands.
    private func run(_ raw: String) {
        guard let term = TeamSpaceHeaderSearch.messageQuery(raw) else { return }
        generation &+= 1
        let current = generation
        searching = true
        Task { @MainActor in
            let answer = await actions.search(companyID, term)
            guard current == generation else { return }
            searching = false
            searched = term
            results = answer
        }
    }

    private func open(_ result: CompanySearchResult) {
        Task { @MainActor in
            if await actions.open(result) {
                opened()
            } else {
                openFailed += 1
            }
        }
    }
}

// MARK: Channel opening

/// "Couldn’t open this channel." with Try again, under the channel that failed: one
/// line and one action (desktop `data-matrix-company-channel-pane="failed"`). The
/// phone's channel list is where the open was asked for, so the line sits there.
struct CompanyChannelFailedRow: View {
    let design: LiveDesign
    let retry: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { line; Spacer(minLength: 0); button }
            VStack(alignment: .leading, spacing: 8) { line; button }
        }
        .padding(.leading, 36)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("company.channel.failed")
    }

    private var line: some View {
        Text(verbatim: copy.channelFailed)
            .font(.subheadline)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .accessibilityAddTraits(.isStaticText)
    }

    private var button: some View {
        Button(action: retry) {
            Text(verbatim: copy.tryAgain)
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("company.channel.retry")
    }
}

// MARK: Board views

/// Board · List and Mine over the Board page (desktop `company-board.tsx` header:
/// `ak-seg` with Board and List, then the Mine toggle once the viewer's member is
/// known). Drawn whether or not the board could be read, as the desktop draws it.
struct CompanyBoardControls: View {
    let design: LiveDesign
    /// The viewer's own member (desktop `viewerMemberRef`); nil leaves Mine off the bar.
    let viewer: String?
    @Binding var preference: CompanyBoardPreference

    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    var body: some View {
        HStack(spacing: 12) {
            Picker(selection: Binding(get: { preference.view },
                                      set: { preference = preference.selecting($0) })) {
                ForEach(CompanyBoardView.allCases, id: \.self) { view in
                    Text(verbatim: copy.boardView(view)).tag(view)
                        .accessibilityIdentifier("company.board.view." + view.rawValue)
                }
            } label: {
                Text(verbatim: copy.boardViews)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("company.board.views")
            if viewer != nil {
                Toggle(isOn: Binding(get: { preference.mineOn(viewer: viewer) },
                                     set: { _ in preference = preference.togglingMine(viewer: viewer) })) {
                    Text(verbatim: copy.mine)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("company.board.mine")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
