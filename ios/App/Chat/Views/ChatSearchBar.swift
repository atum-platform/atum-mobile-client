import AtumChat
import Observation
import SwiftUI

/// HC-6: the open chat's search (desktop `MatrixChatSearch`, `m/chat-search.tsx`),
/// one per chat screen. It finds the words of the loaded messages, newest
/// first, highlights them in the transcript and steps older and newer. When
/// nothing loaded matches it walks older history one bounded page at a time
/// (`ChatHistorySearch`, desktop `searchOlderMatrixHistory`).
///
/// The transcript scrolls only when the person asks (typing, stepping, a
/// walk that found something), never because rows changed under them.
@MainActor
@Observable
final class ChatSearchSession {
    struct Focus: Equatable {
        var rowID: String
        var sequence: UInt64
    }

    private(set) var isOpen = false
    private(set) var query = ""
    private(set) var matches = [ChatSearchMatch]()
    private(set) var current = 0
    private(set) var progress: ChatHistorySearch.Progress?
    private(set) var highlights = [String: ChatSearchHighlight]()
    /// The row the transcript brings to its middle; the sequence grows with
    /// every request.
    private(set) var focus: Focus?

    @ObservationIgnored private var index = ChatSearchIndex()
    @ObservationIgnored private var walk: Task<Void, Never>?
    @ObservationIgnored private var focusSequence: UInt64 = 0

    var searching: Bool { isOpen && ChatSearchText.needle(query) != nil }

    var readout: ChatSearchReadout {
        ChatSearchReadout(matches: matches.count, current: current, progress: progress)
    }

    func open() { isOpen = true }

    func close() {
        walk?.cancel()
        walk = nil
        isOpen = false
        query = ""
        matches = []
        current = 0
        progress = nil
        highlights = [:]
        focus = nil
        index = ChatSearchIndex()
    }

    /// The field changed: a new query starts at the newest match, and walks
    /// older history when nothing loaded matches.
    func setQuery(_ value: String, store: LiveConversationStore) {
        guard value != query else { return }
        query = value
        matches = index.matches(in: store.snapshot.rows, query: value)
        current = 0
        progress = nil
        publishHighlights()
        requestFocus()
        walk?.cancel()
        walk = nil
        guard searching, matches.isEmpty else { return }
        walk = Task { [weak self, weak store] in
            try? await Task.sleep(for: ChatHistorySearch.debounce)
            guard !Task.isCancelled, let store else { return }
            let result = await ChatHistorySearch.run(
                query: value,
                rows: { store.snapshot.rows },
                loadPage: { await store.loadOlderPageForSearch() },
                progress: { [weak self] value in
                    guard !Task.isCancelled else { return }
                    self?.progress = value
                    #if DEBUG
                    UITestProbe.append("search.walk phase=\(value.phase) pages=\(value.pages) searched=\(value.searched)",
                                       to: "search-placement.txt")
                    #endif
                })
            guard !Task.isCancelled, let self, self.query == value else { return }
            self.progress = result
            if result.phase == .found {
                self.rowsChanged(store.snapshot.rows)
                self.current = 0
                self.publishHighlights()
                self.requestFocus()
            }
        }
    }

    /// New rows (a page, a message, an edit) while searching: the counts
    /// follow and the match you are on stays the one you are on. Nothing
    /// scrolls.
    func rowsChanged(_ rows: [ChatRow]) {
        guard searching else { return }
        let next = index.matches(in: rows, query: query)
        guard next != matches else { return }
        let previous = matches.indices.contains(current) ? matches[current] : nil
        current = ChatSearch.keptIndex(next, previous: previous, previousIndex: current)
        matches = next
        publishHighlights()
    }

    func step(_ direction: ChatSearch.Direction) {
        guard !matches.isEmpty else { return }
        current = ChatSearch.step(current, count: matches.count, direction)
        publishHighlights()
        requestFocus()
    }

    private func publishHighlights() {
        let next = ChatSearch.highlights(matches, current: current, query: query)
        if next != highlights { highlights = next }
    }

    private func requestFocus() {
        guard matches.indices.contains(current) else { focus = nil; return }
        focusSequence &+= 1
        focus = Focus(rowID: matches[current].rowID, sequence: focusSequence)
    }
}

/// The search bar, where the composer sits while a search is open: the field
/// and Close, then the count and the older/newer steps (desktop's header
/// field, laid out as iOS find bars are: above the keyboard).
struct ChatSearchBar: View {
    let session: ChatSearchSession
    let store: LiveConversationStore
    let design: LiveDesign

    @Environment(\.colorScheme) private var scheme
    @FocusState private var fieldFocused: Bool

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: ChatCopy { ChatCopy(design: design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                field
                Button {
                    session.close()
                } label: {
                    Image(atum.symbol(.close))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityLabel(copy.text(.searchClose))
                .accessibilityIdentifier("chat.search.close")
            }
            HStack(alignment: .center, spacing: 4) {
                Text(verbatim: readoutText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(announcement)
                    .accessibilityIdentifier("chat.search.count")
                stepButton(.older)
                stepButton(.newer)
            }
            .opacity(session.searching ? 1 : 0)
            .accessibilityHidden(!session.searching)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // Solid, so the transcript never reads through the field or the count.
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea(edges: .bottom))
        // Focus set while the bar is first appearing can be dropped: ask
        // again once it is on screen.
        .task {
            fieldFocused = true
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled, !fieldFocused { fieldFocused = true }
        }
        .onChange(of: announcement) { _, text in
            guard !text.isEmpty else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.search")
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(atum.symbol(.search))
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
            // Vertical, so the prompt wraps instead of clipping at large text
            // sizes; Return steps to the older match and never adds a line.
            TextField(text: Binding(get: { session.query },
                                    set: { value in
                                        if value.contains("\n") {
                                            session.setQuery(value.replacingOccurrences(of: "\n", with: ""),
                                                             store: store)
                                            session.step(.older)
                                        } else {
                                            session.setQuery(value, store: store)
                                        }
                                    }),
                      prompt: Text(verbatim: copy.text(.searchChat))
                          .foregroundStyle(atum.color(.muted, scheme: scheme)),
                      axis: .vertical) {
                EmptyView()
            }
            .lineLimit(1...3)
            .focused($fieldFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .accessibilityLabel(copy.text(.searchChat))
            .accessibilityIdentifier("chat.search.field")
        }
        .font(.body)
        .foregroundStyle(atum.color(.ink, scheme: scheme))
        .padding(.horizontal, atum.kit.space(.s3))
        .frame(maxWidth: .infinity, minHeight: atum.kit.phoneControlHeight(.regular))
        .background(atum.kitColor(.fillQuiet, scheme: scheme), in: Capsule())
    }

    private func stepButton(_ direction: ChatSearch.Direction) -> some View {
        Button {
            session.step(direction)
        } label: {
            Image(atum.symbol(.chevronDown))
                .rotationEffect(direction == .older ? .degrees(180) : .zero)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(atum.color(session.matches.isEmpty ? .muted : .ink, scheme: scheme))
        .disabled(session.matches.isEmpty)
        .accessibilityLabel(copy.text(direction == .older ? .searchOlder : .searchNewer))
        .accessibilityIdentifier(direction == .older ? "chat.search.older" : "chat.search.newer")
    }

    /// "2/5", or "No results", then " · Searched n of N" while or after a
    /// walk (desktop's long counter; the bar has room for its words).
    private var readoutText: String {
        guard session.searching else { return "" }
        let readout = session.readout
        let position = readout.position.map { "\($0.index)/\($0.count)" } ?? copy.text(.searchNoResults)
        guard let history = historyLine(readout.history) else { return position }
        return position + " · " + history
    }

    /// Desktop's live announcement: "Result 2 of 5", or "No results", then
    /// the history line.
    private var announcement: String {
        guard session.searching else { return "" }
        let readout = session.readout
        let position = readout.position.map {
            copy.text(.searchResult, .number(Int64($0.index)), .number(Int64($0.count)))
        } ?? copy.text(.searchNoResults)
        return [position, historyLine(readout.history)].compactMap { $0 }.joined(separator: ". ")
    }

    private func historyLine(_ history: ChatSearchReadout.History?) -> String? {
        switch history {
        case let .searching(searched, bound)?:
            copy.text(.searchSearching, .number(Int64(searched)), .number(Int64(bound)))
        case let .searched(searched, bound)?:
            copy.text(.searchSearched, .number(Int64(searched)), .number(Int64(bound)))
        case nil:
            nil
        }
    }
}

/// Paints a search's matches into a message's text: every match a soft ink
/// wash, the one you are on in ink (desktop `::highlight(atum-chat-search)`),
/// in the bubble's own colours.
enum ChatSearchPaint {
    static func paint(_ text: AttributedString, highlight: ChatSearchHighlight,
                      wash: Color, current: Color, onCurrent: Color) -> AttributedString {
        let plain = String(text.characters)
        let ranges = ChatSearchText.occurrences(of: highlight.needle, in: plain)
        guard !ranges.isEmpty else { return text }
        var result = text
        for (number, range) in ranges.enumerated() {
            let start = result.characters.index(result.startIndex, offsetBy: range.lowerBound)
            let end = result.characters.index(result.startIndex, offsetBy: range.upperBound)
            if number == highlight.current {
                result[start..<end].backgroundColor = current
                result[start..<end].foregroundColor = onCurrent
            } else {
                result[start..<end].backgroundColor = wash
            }
        }
        return result
    }
}
