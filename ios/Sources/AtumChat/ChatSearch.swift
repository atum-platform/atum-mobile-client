import Foundation

public enum GlobalChatSearchScope: Equatable, Sendable {
    case plain, deviceOnly
}

/// Search selection survives duplicate message bodies and unloaded history.
/// A threaded hit opens the thread and focuses the reply ID, never the root ID.
public struct ChatSearchEventTarget: Hashable, Sendable {
    public let roomID: String
    public let eventID: String
    public let threadRootID: String?

    public init(roomID: String, eventID: String, threadRootID: String? = nil) {
        self.roomID = roomID
        self.eventID = eventID
        self.threadRootID = threadRootID
    }
}

public struct GlobalChatSearchHit: Identifiable, Equatable, Sendable {
    public let id: ChatSearchEventTarget
    public let roomName: String?
    public let senderID: String
    public let senderName: String?
    public let snippet: String
    /// Milliseconds since 1970.
    public let timestamp: Int64

    public init(target: ChatSearchEventTarget, roomName: String?, senderID: String,
                senderName: String? = nil, snippet: String, timestamp: Int64) {
        id = target
        self.roomName = roomName
        self.senderID = senderID
        self.senderName = senderName
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// One Home search per signed-in session. Submit keystrokes with the input
/// token bound to the field. Selecting a scope invalidates the old binding,
/// clears the field and results, and cancels debounce and all source work.
@MainActor
public final class GlobalChatSearch<Plain, Device> {
    public struct Input: Equatable, Sendable {
        public let scope: GlobalChatSearchScope
        fileprivate let id: UUID
    }

    public enum Result {
        case idle, pending
        case plain(Plain)
        case device(Device)
    }

    public typealias IsCurrent = @MainActor () -> Bool
    public typealias Search<Value> = @MainActor (String, IsCurrent) async -> Value

    public private(set) var input = Input(scope: .plain, id: UUID())
    public private(set) var query = ""
    public private(set) var result: Result = .idle
    /// Capture for selection, then recheck after any async validation.
    public private(set) var generation = UUID()
    public var onChange: (@MainActor () -> Void)?

    private let debounce: Duration
    private let plain: Search<Plain>
    private let device: Search<Device>
    private var searchTask: Task<Void, Never>?

    /// Run all remote sources inside `plain` as structured children. The
    /// device closure must only have access to the SDK's local search source.
    public init(debounce: Duration = ChatHistorySearch.debounce,
                plain: @escaping Search<Plain>, device: @escaping Search<Device>) {
        self.debounce = debounce
        self.plain = plain
        self.device = device
    }

    deinit { searchTask?.cancel() }

    /// Also reset on dismiss, account replacement or deletion of local data,
    /// even when the chosen scope was already plain.
    public func reset(to scope: GlobalChatSearchScope = .plain) {
        cancel()
        input = Input(scope: scope, id: UUID())
        query = ""
        result = .idle
        onChange?()
    }

    public func submit(_ text: String, for input: Input) {
        guard input == self.input, text != query else { return }
        query = text
        refresh()
    }

    /// Revalidate and rerun the active query when the roster or history
    /// changes. The same query must never start in another scope.
    public func refresh() {
        cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...200).contains(term.unicodeScalars.count) else {
            result = .idle
            onChange?()
            return
        }
        let generation = generation
        let scope = input.scope
        result = .pending
        searchTask = Task { [weak self, debounce, plain, device] in
            do { try await Task.sleep(for: debounce) } catch { return }
            let isCurrent: IsCurrent = { [weak self] in
                !Task.isCancelled && self?.generation == generation
            }
            guard isCurrent() else { return }
            let next: Result
            switch scope {
            case .plain: next = .plain(await plain(term, isCurrent))
            case .deviceOnly: next = .device(await device(term, isCurrent))
            }
            guard isCurrent(), let self else { return }
            self.result = next
            self.searchTask = nil
            self.onChange?()
        }
        onChange?()
    }

    private func cancel() {
        generation = UUID()
        searchTask?.cancel()
        searchTask = nil
    }
}

// HC-6 (parity plan v2, lane 1 S6): search in the open chat, ported from
// desktop `m/chat-search-matches.ts`, `m/history-search.ts` and
// `m/history-message-text.ts`. Pure values only: the chat screen owns the
// field, the transcript owns the scrolling.

/// How search compares text: case and Vietnamese marks fold away ("da lat"
/// finds "Đà Lạt"), đ reads as d, any run of space as one, and a match never
/// crosses a line break (desktop `foldSearchChar`, `textMatchesChatSearch`).
public enum ChatSearchText {
    /// One character as search compares it, as Unicode scalars: no marks,
    /// lower case, đ as d, any space as one space, a line break as "\n".
    public static func fold(_ character: Character) -> [Unicode.Scalar] {
        if character.isNewline { return ["\n"] }
        if character.isWhitespace { return [" "] }
        // Plain ASCII, most of any chat: lower case is all there is to do.
        if let ascii = character.asciiValue {
            let lower = ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii
            return [Unicode.Scalar(lower)]
        }
        let stripped = String(character).decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !Self.isMark($0) }
        let lowered = String(String.UnicodeScalarView(stripped)).lowercased()
        return lowered.unicodeScalars.map { $0 == "đ" ? "d" : $0 }
    }

    /// The query as search compares it; nil when there is nothing to look for.
    public static func needle(_ query: String) -> [Unicode.Scalar]? {
        var folded = [Unicode.Scalar]()
        for character in query {
            for unit in fold(character) {
                let unit: Unicode.Scalar = unit == "\n" ? " " : unit
                if unit == " ", folded.last == " " || folded.isEmpty { continue }
                folded.append(unit)
            }
        }
        while folded.last == " " { folded.removeLast() }
        return folded.isEmpty ? nil : folded
    }

    /// Every place `needle` matches in `text`, as character offsets into
    /// `text`, first to last. Matches never overlap and never cross a line.
    public static func occurrences(of needle: [Unicode.Scalar], in text: String) -> [Range<Int>] {
        Folded(text).occurrences(of: needle)
    }

    /// A text folded once, each folded unit pointing at the character it
    /// came from (-1 for a line break), so a query can be matched again and
    /// again without folding the text again.
    public struct Folded: Equatable, Sendable {
        public private(set) var units: [Unicode.Scalar] = []
        private var sources: [Int] = []

        public init(_ text: String) {
            for (offset, character) in text.enumerated() {
                for unit in ChatSearchText.fold(character) {
                    if unit == "\n" {
                        units.append("\n")
                        sources.append(-1)
                        continue
                    }
                    // Runs of space read as one, as the query's do.
                    if unit == " ", units.isEmpty || units.last == " " || units.last == "\n" { continue }
                    units.append(unit)
                    sources.append(offset)
                }
            }
        }

        public func occurrences(of needle: [Unicode.Scalar]) -> [Range<Int>] {
            guard let first = needle.first else { return [] }
            var ranges = [Range<Int>]()
            let count = needle.count
            var index = 0
            while index + count <= units.count {
                if units[index] == first, units[index..<(index + count)].elementsEqual(needle),
                   sources[index] >= 0, sources[index + count - 1] >= 0 {
                    ranges.append(sources[index]..<(sources[index + count - 1] + 1))
                    index += count
                } else {
                    index += 1
                }
            }
            return ranges
        }
    }

    /// Whether `query` matches anywhere in `text`.
    public static func matches(_ text: String, query: String) -> Bool {
        guard let needle = needle(query) else { return false }
        return !occurrences(of: needle, in: text).isEmpty
    }

    /// What a message shows as words: an answer's Markdown without link
    /// destinations or formatting marks, my own text as typed (desktop
    /// `historyMessageText`; mine show literally on the phone, B6).
    public static func words(of item: ChatItem) -> String? {
        guard item.kind == .message, !item.body.isEmpty else { return nil }
        return item.isOwn ? item.body : markdownWords(item.body)
    }

    /// Desktop `historyMessageText`.
    public static func markdownWords(_ body: String) -> String {
        var text = body
        text = replacing(#"!\[([^\]]*)\]\([^\n)]*\)"#, in: text, with: "$1")
        text = replacing(#"\[([^\]]+)\]\([^\n)]*\)"#, in: text, with: "$1")
        text = replacing(#"<[^>\n]+>"#, in: text, with: " ")
        text = replacing(#"[*_~`]"#, in: text, with: "")
        return text
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}

/// One match: the `occurrence`-th place the query matches in a row's words.
public struct ChatSearchMatch: Equatable, Hashable, Sendable {
    public var rowID: String
    public var occurrence: Int

    public init(rowID: String, occurrence: Int) {
        self.rowID = rowID
        self.occurrence = occurrence
    }
}

/// What one row draws while a search is open: every place the needle matches,
/// and which of them is the match you are on.
public struct ChatSearchHighlight: Equatable, Hashable, Sendable {
    public var needle: [Unicode.Scalar]
    public var current: Int?

    public init(needle: [Unicode.Scalar], current: Int?) {
        self.needle = needle
        self.current = current
    }
}

/// The loaded transcript's matches (desktop `findChatMatches`, `stepMatch`,
/// `sameMatchIndex`).
public enum ChatSearch {
    public enum Direction: Sendable {
        /// Up the transcript (a higher number). Return and ↑ on desktop.
        case older
        /// Down the transcript. Shift-Return and ↓ on desktop.
        case newer
    }

    /// Every match among the rows' messages, newest first: the one nearest
    /// the composer is the first result.
    public static func matches(in rows: [ChatRow], query: String) -> [ChatSearchMatch] {
        var index = ChatSearchIndex()
        return index.matches(in: rows, query: query)
    }

    /// Where a step lands; both directions wrap around. -1 with no matches.
    public static func step(_ current: Int, count: Int, _ direction: Direction) -> Int {
        guard count > 0 else { return -1 }
        switch direction {
        case .older: return (current + 1) % count
        case .newer: return (current - 1 + count) % count
        }
    }

    /// After the transcript changed: the match you were on stays the one you
    /// are on; if it is gone, the nearest index that still exists.
    public static func keptIndex(_ matches: [ChatSearchMatch], previous: ChatSearchMatch?,
                                 previousIndex: Int) -> Int {
        if let previous, let same = matches.firstIndex(of: previous) { return same }
        return max(0, min(previousIndex, matches.count - 1))
    }

    /// Each matched row's highlight, by row ID.
    public static func highlights(_ matches: [ChatSearchMatch], current: Int,
                                  query: String) -> [String: ChatSearchHighlight] {
        guard let needle = ChatSearchText.needle(query) else { return [:] }
        var result = [String: ChatSearchHighlight]()
        for match in matches where result[match.rowID] == nil {
            result[match.rowID] = ChatSearchHighlight(needle: needle, current: nil)
        }
        if matches.indices.contains(current) {
            let focused = matches[current]
            result[focused.rowID]?.current = focused.occurrence
        }
        return result
    }
}

/// The rows' folded words, kept by row while a search is open, so each new
/// snapshot (a page, a message, an edit) folds only what changed.
public struct ChatSearchIndex: Sendable {
    private var folded = [String: (body: String, isOwn: Bool, text: ChatSearchText.Folded)]()

    public init() {}

    public mutating func matches(in rows: [ChatRow], query: String) -> [ChatSearchMatch] {
        guard let needle = ChatSearchText.needle(query) else { return [] }
        var found = [ChatSearchMatch]()
        var seen = Set<String>()
        for row in rows.reversed() {
            guard row.item.kind == .message, !row.item.body.isEmpty else { continue }
            seen.insert(row.id)
            let text: ChatSearchText.Folded
            if let cached = folded[row.id], cached.body == row.item.body, cached.isOwn == row.item.isOwn {
                text = cached.text
            } else if let words = ChatSearchText.words(of: row.item) {
                text = ChatSearchText.Folded(words)
                folded[row.id] = (row.item.body, row.item.isOwn, text)
            } else {
                continue
            }
            let count = text.occurrences(of: needle).count
            // Within one message the later words are newer too.
            for occurrence in stride(from: count - 1, through: 0, by: -1) {
                found.append(ChatSearchMatch(rowID: row.id, occurrence: occurrence))
            }
        }
        if folded.count > seen.count { folded = folded.filter { seen.contains($0.key) } }
        return found
    }
}

/// Searching older history (desktop `searchOlderMatrixHistory`): when the
/// loaded rows hold no match, older pages are loaded one at a time until a
/// match arrives, the room's start, or the hard cap.
public enum ChatHistorySearch {
    /// Desktop `MATRIX_TIMELINE_PAGE_EVENTS`.
    public static let pageEvents: UInt16 = 50
    /// Desktop `MATRIX_TIMELINE_SEARCH_PAGES`.
    public static let maximumPages = 40
    /// Desktop `MATRIX_TIMELINE_EVENT_BOUND` (200 + 50 × 40): the "of N" in
    /// "Searched n of N".
    public static let eventBound = 2_200
    /// Desktop waits this long after a keystroke before asking the homeserver.
    public static let debounce: Duration = .milliseconds(180)

    public enum Phase: Equatable, Sendable {
        case searching, found, complete, capped, cancelled
        /// A page could not load or routed placement failed.
        case failed
    }

    public struct Progress: Equatable, Sendable {
        public var phase: Phase
        public var pages: Int
        public var searched: Int
        public var bound: Int

        public init(phase: Phase, pages: Int, searched: Int, bound: Int = ChatHistorySearch.eventBound) {
            self.phase = phase
            self.pages = pages
            self.searched = searched
            self.bound = bound
        }
    }

    /// What one older page did.
    public enum Page: Equatable, Sendable {
        case loaded(hasMore: Bool)
        /// The store dropped this page when it replaced the timeline.
        case timelineReplaced
        case failed
    }

    /// The events loaded so far, as the "searched" count.
    public static func searched(_ rows: [ChatRow]) -> Int {
        min(rows.lazy.filter { $0.item.kind.isEventContent }.count, eventBound)
    }

    /// The bounded walk. `rows` is read after every page; `progress` hears
    /// each step. Stops early when the task is cancelled.
    @MainActor
    public static func run(query: String, maximumPages: Int = ChatHistorySearch.maximumPages,
                           rows: @MainActor () -> [ChatRow],
                           loadPage: @MainActor () async -> Page,
                           progress: @MainActor (Progress) -> Void = { _ in }) async -> Progress {
        var index = ChatSearchIndex()
        return await run(maximumPages: maximumPages, rows: rows,
                         acceptMatch: { index.matches(in: rows(), query: query).isEmpty ? nil : .found },
                         loadPage: loadPage, progress: progress)
    }

    public struct RoutedMatch: Equatable, Sendable {
        public let rowID: String
        public let eventID: String
        fileprivate let generation: UInt64

        public func isCurrent(in snapshot: Snapshot) -> Bool {
            snapshot.generation == generation
                && snapshot.rows.contains { $0.id == rowID && $0.item.eventID == eventID }
        }
    }

    /// Wait for layout to confirm placement. Finishing the stream without a
    /// value lets the walk retry. A timeout fails a placement that is still current.
    @MainActor
    public static func waitForRoutedPlacement(
        timeout: Duration = .seconds(3),
        start: (AsyncThrowingStream<Void, Error>.Continuation) -> Void
    ) async throws -> Bool {
        let (result, completion) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let deadline = ContinuousClock.now + timeout
        start(completion)
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            completion.finish(throwing: PlacementTimedOut())
        }
        defer { timer.cancel() }
        var iterator = result.makeAsyncIterator()
        return try await iterator.next() != nil
    }

    private struct PlacementTimedOut: Error {}

    /// A routed result names a Matrix event. The same walk keeps its page
    /// budget while the transcript tries to place a match in the current projection.
    @MainActor
    public static func find(eventID: String, snapshot: @MainActor () -> Snapshot,
                            timelineGeneration: (@MainActor () -> UInt64)? = nil,
                            loadPage: @MainActor () async -> Page,
                            placeMatch: @MainActor (RoutedMatch) async throws -> Bool = { _ in true }) async -> Progress {
        var replacedGeneration: UInt64?
        var placementAttempts = 0
        var projectionWaitRemaining: Duration = .seconds(10)
        func projectionIsPending() -> Bool {
            guard let timelineGeneration else { return false }
            let projectedGeneration = snapshot().generation
            return projectedGeneration == Snapshot.empty.generation || projectedGeneration != timelineGeneration()
        }
        func waitForProjection() async -> Phase? {
            guard projectionIsPending() else { return nil }
            // Share the wait budget across reattachments in this walk.
            let deadline = ContinuousClock.now + projectionWaitRemaining
            defer { projectionWaitRemaining = max(.zero, ContinuousClock.now.duration(to: deadline)) }
            while projectionIsPending() {
                let now = ContinuousClock.now
                guard now < deadline else { return .failed }
                do { try await Task.sleep(until: min(now + .milliseconds(100), deadline), clock: .continuous) }
                catch { return .cancelled }
            }
            return nil
        }
        func currentProjection() -> Snapshot {
            let current = snapshot()
            // The transcript keeps drawing the old rows until the replacement
            // projects. Those rows cannot complete the routed search.
            guard current.generation != Snapshot.empty.generation,
                  current.generation == (timelineGeneration?() ?? current.generation),
                  current.generation != replacedGeneration else { return .empty }
            return current
        }
        return await run(maximumPages: maximumPages,
                         rows: { currentProjection().rows },
                         generation: { timelineGeneration?() ?? snapshot().generation },
                         acceptMatch: {
                             while !Task.isCancelled {
                                 if let phase = await waitForProjection() { return phase }
                                 let current = currentProjection()
                                 guard current.generation != Snapshot.empty.generation,
                                       let row = current.rows.first(where: { $0.item.eventID == eventID })
                                 else { return nil }
                                 // Timeline churn can retry without loading a page.
                                 // Bound placements across the walk as well.
                                 guard placementAttempts <= maximumPages else { return .failed }
                                 placementAttempts += 1
                                 let match = RoutedMatch(rowID: row.id, eventID: eventID,
                                                         generation: current.generation)
                                 do {
                                     if try await placeMatch(match) { return .found }
                                 } catch is PlacementTimedOut {
                                     if Task.isCancelled { return .cancelled }
                                     if match.isCurrent(in: currentProjection()) { return .failed }
                                     continue
                                 } catch {
                                     return Task.isCancelled ? .cancelled : .failed
                                 }
                                 // Give the live projection a chance to publish the
                                 // reply before spending another page.
                                 if match.isCurrent(in: currentProjection()) { return nil }
                             }
                             return nil
                         }, loadPage: {
                             // A swap can invalidate the page slot while the walk
                             // is starting a page or awaiting its result.
                             guard !projectionIsPending() else { return .timelineReplaced }
                             let generation = snapshot().generation
                             let page = await loadPage()
                             if page == .timelineReplaced { replacedGeneration = generation }
                             if page == .failed, let timelineGeneration, timelineGeneration() != generation {
                                 return .timelineReplaced
                             }
                             return page
                         })
    }

    @MainActor
    private static func run(maximumPages: Int, rows: @MainActor () -> [ChatRow],
                            generation: @MainActor () -> UInt64 = { 0 },
                            acceptMatch: @MainActor () async -> Phase?,
                            loadPage: @MainActor () async -> Page,
                            progress: @MainActor (Progress) -> Void = { _ in }) async -> Progress {
        let limit = max(0, min(maximumPages, Self.maximumPages))
        func report(_ phase: Phase, _ pages: Int) -> Progress {
            let value = Progress(phase: phase, pages: pages, searched: searched(rows()))
            progress(value)
            return value
        }
        if Task.isCancelled { return report(.cancelled, 0) }
        if let phase = await acceptMatch() { return report(phase, 0) }
        if Task.isCancelled { return report(.cancelled, 0) }
        guard limit > 0 else { return report(.capped, 0) }
        for pages in 1...limit {
            _ = report(.searching, pages - 1)
            let page = await loadPage()
            let pageGeneration = generation()
            if Task.isCancelled { return report(.cancelled, pages) }
            if let phase = await acceptMatch() { return report(phase, pages) }
            if Task.isCancelled { return report(.cancelled, pages) }
            if generation() != pageGeneration { continue }
            switch page {
            case .failed: return report(.failed, pages)
            case .loaded(hasMore: false):
                // SDK status and diffs have separate listeners. Give the final
                // projection a short grace period before declaring no results.
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return report(.cancelled, pages) }
                if let phase = await acceptMatch() { return report(phase, pages) }
                if Task.isCancelled { return report(.cancelled, pages) }
                if generation() != pageGeneration { continue }
                return report(.complete, pages)
            case .loaded(hasMore: true), .timelineReplaced: continue
            }
        }
        return report(.capped, limit)
    }
}

/// What the search bar's count says (desktop `MatrixChatSearch` counter and
/// announcement), as values the screen turns into copy.
public struct ChatSearchReadout: Equatable, Sendable {
    /// "2/5": the match you are on (1-based) and the count; nil for none.
    public var position: (index: Int, count: Int)?
    /// "Searching n of N messages…" or "Searched n of N"; nil for no line.
    public var history: History?

    public enum History: Equatable, Sendable {
        case searching(searched: Int, bound: Int)
        case searched(searched: Int, bound: Int)
    }

    public init(matches: Int, current: Int, progress: ChatHistorySearch.Progress?) {
        position = matches > 0 ? (index: min(max(current, 0), matches - 1) + 1, count: matches) : nil
        switch progress?.phase {
        case .searching?:
            history = .searching(searched: progress!.searched, bound: progress!.bound)
        case .found?, .complete?, .capped?:
            // "Found" in the loaded rows needs no line (desktop shows none
            // before a walk starts); after a walk it says how far it went.
            history = (progress!.pages > 0 || progress!.phase != .found)
                ? .searched(searched: progress!.searched, bound: progress!.bound) : nil
        case .cancelled?, .failed?, nil:
            history = nil
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position?.index == rhs.position?.index && lhs.position?.count == rhs.position?.count
            && lhs.history == rhs.history
    }
}
