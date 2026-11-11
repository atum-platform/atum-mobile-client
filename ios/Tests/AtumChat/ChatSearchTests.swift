import XCTest
@testable import AtumChat

/// HC-6: in-chat search, against desktop `chat-search-matches.ts` and
/// `history-search.ts`.
final class ChatSearchTests: XCTestCase {
    private func rows(_ items: [ChatItem]) -> [ChatRow] { items.map { ChatRow(item: $0) } }

    // MARK: Folding (desktop `foldSearchChar`)

    func testFoldingIgnoresCaseMarksAndReadsĐAsD() {
        XCTAssertTrue(ChatSearchText.matches("Hẹn gặp ở Đà Lạt nhé", query: "da lat"))
        XCTAssertTrue(ChatSearchText.matches("Hẹn gặp ở Đà Lạt nhé", query: "ĐÀ  LẠT"))
        XCTAssertTrue(ChatSearchText.matches("ĐƯỜNG", query: "duong"))
        XCTAssertFalse(ChatSearchText.matches("Hà Nội", query: "da lat"))
    }

    func testAnEmptyOrSpaceOnlyQueryFindsNothing() {
        XCTAssertNil(ChatSearchText.needle(""))
        XCTAssertNil(ChatSearchText.needle("   \n "))
        XCTAssertEqual(ChatSearch.matches(in: rows([F.text("a", from: F.agent, "x")]), query: " "), [])
    }

    func testRunsOfSpaceReadAsOneButAMatchNeverCrossesALine() {
        XCTAssertTrue(ChatSearchText.matches("cà   phê sáng", query: "ca phe"))
        XCTAssertFalse(ChatSearchText.matches("cà\nphê", query: "ca phe"))
    }

    func testOccurrencesAreCharacterOffsetsIntoTheOriginalText() {
        let text = "Đà Lạt, rồi lại Đà Lạt"
        let needle = try! XCTUnwrap(ChatSearchText.needle("đà lạt"))
        let ranges = ChatSearchText.occurrences(of: needle, in: text)
        XCTAssertEqual(ranges, [0..<6, 16..<22])
        let characters = Array(text)
        XCTAssertEqual(String(characters[ranges[1]]), "Đà Lạt")
    }

    func testAnswersAreSearchedAsTheirWordsAndMineAsTyped() {
        // Desktop `historyMessageText`: no link destination, no marks.
        XCTAssertEqual(ChatSearchText.markdownWords("**Đà** [Lạt](https://x.test/lat) `code`"), "Đà Lạt code")
        XCTAssertFalse(ChatSearch.matches(in: rows([F.text("a", from: F.agent, "[here](https://x.test/secret)")]),
                                          query: "secret").count > 0, "a link destination is not a word")
        XCTAssertEqual(ChatSearch.matches(in: rows([F.mine("m", "**bold**")]), query: "**bold").count, 1,
                       "my own message shows (and is searched) literally")
    }

    // MARK: Matches (desktop `findChatMatches`)

    func testMatchesAreNewestFirstAcrossAndWithinMessages() {
        let items = [
            F.text("old", from: F.agent, "trà sữa và trà đá", minute: 1),
            F.notice("note", from: F.agent, "trà"),
            F.mine("new", "thêm trà nữa", minute: 3)
        ]
        XCTAssertEqual(ChatSearch.matches(in: rows(items), query: "tra"), [
            ChatSearchMatch(rowID: "new", occurrence: 0),
            ChatSearchMatch(rowID: "old", occurrence: 1),
            ChatSearchMatch(rowID: "old", occurrence: 0)
        ], "notices are not messages; the later word in one message is the newer match")
    }

    func testStepsWrapBothWays() {
        XCTAssertEqual(ChatSearch.step(0, count: 3, .older), 1)
        XCTAssertEqual(ChatSearch.step(2, count: 3, .older), 0)
        XCTAssertEqual(ChatSearch.step(0, count: 3, .newer), 2)
        XCTAssertEqual(ChatSearch.step(0, count: 0, .older), -1)
    }

    func testTheMatchYouAreOnStaysWhenRowsChange() {
        let a = ChatSearchMatch(rowID: "a", occurrence: 0)
        let b = ChatSearchMatch(rowID: "b", occurrence: 0)
        let c = ChatSearchMatch(rowID: "c", occurrence: 0)
        XCTAssertEqual(ChatSearch.keptIndex([c, a, b], previous: a, previousIndex: 0), 1,
                       "a newer match arrived below: the one you are on moved down a place")
        XCTAssertEqual(ChatSearch.keptIndex([c], previous: a, previousIndex: 2), 0, "gone: the nearest that exists")
    }

    func testHighlightsMarkEveryMatchedRowAndTheCurrentOccurrence() {
        let items = [F.text("a", from: F.agent, "mèo và mèo"), F.mine("b", "con mèo")]
        let matches = ChatSearch.matches(in: rows(items), query: "meo")
        let highlights = ChatSearch.highlights(matches, current: 1, query: "meo")
        XCTAssertEqual(highlights["b"]?.current, nil)
        XCTAssertEqual(highlights["a"]?.current, 1, "the second result is a's later word")
        XCTAssertEqual(Set(highlights.keys), ["a", "b"])
    }

    func testTheIndexRefoldsOnlyAnEditedMessage() {
        var index = ChatSearchIndex()
        var items = [F.text("a", from: F.agent, "một con mèo")]
        XCTAssertEqual(index.matches(in: rows(items), query: "meo").count, 1)
        items[0].body = "một con chó"
        XCTAssertEqual(index.matches(in: rows(items), query: "meo").count, 0, "an edit is searched as edited")
    }

    // MARK: History (desktop `searchOlderMatrixHistory`)

    @MainActor
    func testHistoryWalksOlderPagesUntilAMatchArrives() async {
        var loaded = [F.text("new", from: F.agent, "không có gì")]
        var pages = 0
        var seen = [ChatHistorySearch.Phase]()
        let result = await ChatHistorySearch.run(
            query: "da lat",
            rows: { self.rows(loaded) },
            loadPage: {
                pages += 1
                loaded.insert(F.text("p\(pages)", from: F.agent, pages == 3 ? "Đi Đà Lạt" : "khác"), at: 0)
                return .loaded(hasMore: true)
            },
            progress: { seen.append($0.phase) })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 3, "three pages back, as the slice's acceptance asks")
        XCTAssertEqual(result.searched, 4)
        XCTAssertEqual(result.bound, ChatHistorySearch.eventBound)
        XCTAssertEqual(seen, [.searching, .searching, .searching, .found])
    }

    @MainActor
    func testHistoryStopsAtTheStartTheCapOrAFailure() async {
        let start = await ChatHistorySearch.run(query: "x", rows: { [] }, loadPage: { .loaded(hasMore: false) })
        XCTAssertEqual(start.phase, .complete)
        var calls = 0
        let capped = await ChatHistorySearch.run(query: "x", maximumPages: 2, rows: { [] },
                                                 loadPage: { calls += 1; return .loaded(hasMore: true) })
        XCTAssertEqual(capped.phase, .capped)
        XCTAssertEqual(calls, 2)
        let failed = await ChatHistorySearch.run(query: "x", rows: { [] }, loadPage: { .failed })
        XCTAssertEqual(failed.phase, .failed)
        let tooMany = await ChatHistorySearch.run(query: "x", maximumPages: 99, rows: { [] },
                                                  loadPage: { .loaded(hasMore: true) })
        XCTAssertEqual(tooMany.pages, ChatHistorySearch.maximumPages, "never past the product bound")
    }

    @MainActor
    func testALoadedMatchNeedsNoPage() async {
        let result = await ChatHistorySearch.run(query: "mèo", rows: { self.rows([F.mine("a", "mèo")]) },
                                                 loadPage: { XCTFail("no page"); return .failed })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 0)
    }

    func testReadoutFollowsDesktopsCounter() {
        XCTAssertNil(ChatSearchReadout(matches: 0, current: 0, progress: nil).position)
        XCTAssertEqual(ChatSearchReadout(matches: 5, current: 1, progress: nil).position?.index, 2)
        let walking = ChatSearchReadout(matches: 0, current: 0,
                                        progress: .init(phase: .searching, pages: 1, searched: 250))
        XCTAssertEqual(walking.history, .searching(searched: 250, bound: 2_200))
        let found = ChatSearchReadout(matches: 1, current: 0, progress: .init(phase: .found, pages: 0, searched: 40))
        XCTAssertNil(found.history, "found in what was loaded: no history line")
        let done = ChatSearchReadout(matches: 0, current: 0, progress: .init(phase: .complete, pages: 4, searched: 120))
        XCTAssertEqual(done.history, .searched(searched: 120, bound: 2_200))
        XCTAssertNil(ChatSearchReadout(matches: 0, current: 0,
                                       progress: .init(phase: .failed, pages: 1, searched: 1)).history)
    }

    // MARK: The core's search page

    func testASearchPageIsTheOnlyPageInFlight() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var core = ConversationCore(context: F.assistantRoom())
        XCTAssertFalse(core.startSearchPage(now: now), "no timeline yet")
        _ = core.attached(now: now)
        let items = (0..<30).map { F.text("m\($0)", from: F.agent, minute: $0) }
        let rows = Projection.rows(items, context: F.assistantRoom(), options: .s1)
        _ = core.receive(ProjectedTimeline(snapshot: Snapshot(rows: rows, change: .reset, generation: 1),
                                           nextNoAnswerChange: nil, sequence: 1, touchedItemIDs: []), now: now)
        XCTAssertTrue(core.startSearchPage(now: now))
        XCTAssertFalse(core.startSearchPage(now: now), "one page at a time")
        XCTAssertEqual(core.handle(.geometry(distanceFromBottom: 400, distanceFromTop: 0, viewportHeight: 800,
                                             motion: .user), now: now).filter {
            if case .paginateBackwards = $0 { true } else { false }
        }, [], "scrolling waits for the search's page")
        _ = core.paginationFinished(hitTimelineStart: true, now: now)
        XCTAssertTrue(core.reachedTimelineStart)
        XCTAssertFalse(core.startSearchPage(now: now), "nothing older than the start")
    }
}
