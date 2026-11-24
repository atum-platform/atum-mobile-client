import AtumNativeAPI
import SwiftUI

// Team Space revamp pass 1 on the phone (W4-E7, atum-desktop #114 at `fef8286c`):
// header search's "Search “…”" row and its results, a failed channel open with
// Try again, and the Board page's Board · List and Mine controls. Desktop's one
// right pane is a sheet or a pushed screen here, as every other detail already is.
// docs/ports/w4-e7-team-space.md has the inventory and the reasons.

/// Company message search for the open company, asked from the header box.
struct TeamSpaceMessageSearchActions {
    var search: @MainActor (_ companyID: String, _ query: String, _ nextBatch: String?) async -> CompanySearchPage?
    /// The message is checked again and its room opened (desktop `onOpenSearchResult`).
    var open: @MainActor (CompanySearchResult) async -> RoomOpenResult
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
    let actions: TeamSpaceMessageSearchActions
    let opened: () -> Void

    @State private var query: String
    @State private var searchState: TeamSpaceMessageSearchState
    /// Tied to the sheet so dismissing it also cancels the open.
    @State private var opening: CompanySearchResult?
    @State private var openFailed = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }

    init(design: LiveDesign, companyID: String, initialQuery: String,
         actions: TeamSpaceMessageSearchActions, opened: @escaping () -> Void) {
        self.design = design
        self.companyID = companyID
        self.actions = actions
        self.opened = opened
        _query = State(initialValue: initialQuery)
        var state = TeamSpaceMessageSearchState()
        state.submit(initialQuery)
        _searchState = State(initialValue: state)
    }

    var body: some View {
        let request = searchState.request
        let openingResult = opening
        NavigationStack {
            List {
                if let page = searchState.page {
                    ForEach(page.results) { result in
                        Button { if opening == nil { opening = result } } label: {
                            HomeSearchEventRow(design: design, result: result, section: .messages)
                        }
                        .buttonStyle(.plain)
                        .disabled(opening != nil)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("company.search.result." + result.eventID)
                    }
                    if page.results.isEmpty, page.nextBatch == nil, !searchState.failed {
                        note(design.text("shared.matrix-company-copy.copy.searchNoResults"))
                            .accessibilityIdentifier("company.search.empty")
                    }
                }
                if searchState.failed {
                    note(design.text("shared.matrix-company-copy.copy.unavailable"))
                        .accessibilityIdentifier("company.search.failed")
                }
                if request != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel(Text(verbatim: design.text("shared.matrix-company-copy.copy.searchMessages")))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("company.search.loading")
                } else if searchState.page?.nextBatch != nil {
                    Button {
                        searchState.loadMore()
                    } label: {
                        Text(verbatim: searchState.failed ? copy.tryAgain : loadMore)
                            .frame(minHeight: 44)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("company.search.more")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(verbatim: design.text("shared.matrix-company-copy.copy.searchPlaceholder")))
            .onSubmit(of: .search) { searchState.submit(query) }
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
        .task(id: request) { await search(request) }
        .task(id: openingResult) { await open(openingResult) }
        .sensoryFeedback(.error, trigger: openFailed)
        .accessibilityIdentifier("company.search.sheet")
    }

    private var loadMore: String {
        let key = "shared.matrix-company-copy.copy.searchLoadMore"
        return design.copy.contains(key) ? design.text(key)
            : design.text("src.matrix.mobile-copy.mobileScreensCopy.teamSpace.activity.loadMore")
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func search(_ request: TeamSpaceMessageSearchState.Request?) async {
        guard let request, !Task.isCancelled else { return }
        let answer = await actions.search(companyID, request.term, request.nextBatch)
        guard !Task.isCancelled else { return }
        searchState.finish(request, answer: answer)
    }

    private func open(_ result: CompanySearchResult?) async {
        guard let result, !Task.isCancelled else { return }
        let outcome = await actions.open(result)
        guard !Task.isCancelled else { return }
        opening = nil
        switch outcome {
        case .opened: opened()
        case .failed: openFailed += 1
        case .superseded: break
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

    @Environment(\.colorScheme) private var scheme
    private var copy: TeamSpaceCopy { TeamSpaceCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { views; mine }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                views
                mine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var views: some View {
        HStack(spacing: 2) {
            ForEach(CompanyBoardView.allCases, id: \.self) { view in
                let selected = preference.view == view
                Button {
                    preference = preference.selecting(view)
                } label: {
                    Text(verbatim: copy.boardView(view))
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(minWidth: 44, minHeight: 44)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8).fill(atum.color(.ground, scheme: scheme))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("company.board.view." + view.rawValue)
            }
        }
        .padding(2)
        .background(atum.color(.cell, scheme: scheme), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: copy.boardViews))
    }

    @ViewBuilder private var mine: some View {
        if viewer != nil {
            Toggle(isOn: Binding(get: { preference.mineOn(viewer: viewer) },
                                 set: { _ in preference = preference.togglingMine(viewer: viewer) })) {
                Text(verbatim: copy.mine)
                    .font(.subheadline)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("company.board.mine")
            .toggleStyle(.button)
            .buttonStyle(.bordered)
        }
    }
}
