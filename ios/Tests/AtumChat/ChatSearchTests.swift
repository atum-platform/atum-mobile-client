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
    func testRoutedSearchMatchesTheEventIDEvenWhenTheTextIsIdentical() async {
        var loaded = [F.text("new", from: F.agent, "launch")]
        let result = await ChatHistorySearch.find(eventID: "$old", snapshot: {
            Snapshot(rows: self.rows(loaded), change: .inPlace, generation: 1)
        }, loadPage: {
            loaded.insert(F.text("old", from: F.agent, "launch", threadRoot: "$thread"), at: 0)
            return .loaded(hasMore: true)
        }, placeMatch: { _ in
            try await ChatHistorySearch.waitForRoutedPlacement { completion in
                completion.yield(())
                completion.finish()
            }
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 1)
    }

    @MainActor
    func testRoutedSearchContinuesOnTheReplacementTimeline() async {
        var loaded = [F.text("new", from: F.agent, "launch")]
        var calls = 0
        let result = await ChatHistorySearch.find(eventID: "$old", snapshot: {
            Snapshot(rows: self.rows(loaded), change: .inPlace, generation: calls == 0 ? 1 : 2)
        }, loadPage: {
            calls += 1
            if calls == 1 {
                loaded = [F.text("replacement", from: F.agent, "launch")]
                return .timelineReplaced
            }
            loaded.insert(F.text("old", from: F.agent, "launch", threadRoot: "$thread"), at: 0)
            return .loaded(hasMore: true)
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testRoutedSearchIgnoresAReplyPublishedByTheReplacedTimeline() async {
        let recent = F.text("recent", from: F.agent, "launch")
        let oldReply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var newReply = oldReply
        newReply.id = "replacement-reply"
        var snapshot = Snapshot(rows: rows([recent]), change: .reset, generation: 1)
        var calls = 0
        var focused = [String]()
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot }, loadPage: {
            calls += 1
            switch calls {
            case 1:
                // The old page published just before the binding refresh cancelled it.
                snapshot.rows = self.rows([oldReply, recent])
                return .timelineReplaced
            case 2:
                XCTAssertTrue(focused.isEmpty, "the retained old row cannot consume the route")
                snapshot = Snapshot(rows: self.rows([recent]), change: .reset, generation: 2)
                return .loaded(hasMore: true)
            default:
                snapshot.rows = self.rows([newReply, recent])
                return .loaded(hasMore: true)
            }
        }, placeMatch: {
            focused.append($0.rowID)
            return true
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(focused, [newReply.id])
    }

    @MainActor
    func testRoutedSearchWaitsForTheNewBindingWhenTheFirstProjectionArrivesDuringTheOldPage() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let binding = CompanyTurnBinding(companyID: "company", agentPrincipal: "agent", agentUserID: F.agent,
                                         roomID: "!channel:example.test", audience: .channel(id: "channel"))
        var context = RoomContext(kind: .group, ownUserID: F.me)
        context.companyTurnScope = .channel(threadRoot: "$thread", binding: nil)
        var core = ConversationCore(context: context)
        _ = core.attached(now: now)
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")

        var calls = 0
        var focused: String?
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { core.snapshot }, loadPage: {
            calls += 1
            let projection = ProjectedTimeline(snapshot: Snapshot(rows: self.rows([reply]), change: .reset,
                                                                  generation: UInt64(calls)),
                                               nextNoAnswerChange: nil, sequence: 1)
            if calls == 1 {
                _ = core.receive(projection, now: now)
                core.detached()
                context.companyTurnScope = .channel(threadRoot: "$thread", binding: binding)
                core.updateContext(context)
                XCTAssertEqual(core.snapshot.rows.map(\.id), [reply.id], "the old row stays visible")
                return .timelineReplaced
            }
            XCTAssertNil(focused)
            _ = core.attached(now: now)
            _ = core.receive(projection, now: now)
            return .loaded(hasMore: true)
        }, placeMatch: {
            focused = $0.rowID
            return true
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(focused, reply.id)
    }

    @MainActor
    func testRoutedSearchIgnoresEndOfHistoryWhenBindingChangesDuringTheGracePeriod() async {
        let recent = F.text("recent", from: F.agent, "launch")
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var snapshot = Snapshot(rows: rows([recent]), change: .reset, generation: 1)
        var timelineGeneration: UInt64 = 1
        var calls = 0
        var refresh: Task<Void, Never>?
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot },
                                                  timelineGeneration: { timelineGeneration }, loadPage: {
            calls += 1
            if calls == 1 {
                // Reattach after the old final page returns and the walk yields.
                refresh = Task { @MainActor in
                    timelineGeneration = 2
                    try? await Task.sleep(for: .milliseconds(400))
                    snapshot = Snapshot(rows: self.rows([recent]), change: .reset, generation: 2)
                }
                return .loaded(hasMore: false)
            }
            XCTAssertEqual(timelineGeneration, 2)
            XCTAssertEqual(snapshot.generation, 2, "the replacement must project before paging")
            snapshot.rows = self.rows([reply, recent])
            return .loaded(hasMore: true)
        })
        await refresh?.value
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testRoutedSearchResumesWhenTheReplyDisappearsBeforePlacement() async {
        let recent = F.text("recent", from: F.agent, "launch")
        let oldReply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var newReply = oldReply
        newReply.id = "replacement-reply"
        var snapshot = Snapshot(rows: rows([recent]), change: .reset, generation: 1)
        var calls = 0
        var attempted = [String]()
        var selectedEvent: String? = "$reply"
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot }, loadPage: {
            calls += 1
            XCTAssertEqual(selectedEvent, "$reply", "discovery and a failed placement leave the route pending")
            snapshot.rows = self.rows([calls == 1 ? oldReply : newReply, recent])
            return .loaded(hasMore: true)
        }, placeMatch: { match in
            attempted.append(match.rowID)
            XCTAssertEqual(selectedEvent, match.eventID)
            if match.rowID == oldReply.id {
                // The view sees the row, then loses it before layout places it.
                XCTAssertTrue(match.isCurrent(in: snapshot))
                await Task.yield()
                snapshot = Snapshot(rows: self.rows([recent]), change: .reset, generation: 2)
            }
            guard match.isCurrent(in: snapshot) else { return false }
            selectedEvent = nil
            return true
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 2, "placement retry shares the original walk's page count")
        XCTAssertEqual(attempted, [oldReply.id, newReply.id])
        XCTAssertNil(selectedEvent)
    }

    @MainActor
    func testRoutedSearchFailsWhenLayoutNeverConfirmsPlacement() async {
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        let snapshot = Snapshot(rows: rows([reply]), change: .reset, generation: 1)
        let returned = expectation(description: "placement timeout releases the walk")
        let walk = Task {
            let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot }, loadPage: {
                XCTFail("a placement timeout should end the walk without loading another page")
                return .failed
            }, placeMatch: { _ in
                try await ChatHistorySearch.waitForRoutedPlacement(timeout: .milliseconds(20)) { _ in
                    // No layout callback arrives to complete the placement.
                }
            })
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 2)
        walk.cancel()
        let result = await walk.value
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.pages, 0)
    }

    @MainActor
    func testRoutedSearchRetriesAfterAStalePlacementTimesOutBeforeReplacementProjects() async {
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var replacement = reply
        replacement.id = "replacement-reply"
        let replacementRows = rows([replacement])
        var snapshot = Snapshot(rows: rows([reply]), change: .reset, generation: 1)
        var liveGeneration: UInt64 = 1
        var refresh: Task<Void, Never>?
        var attempted = [String]()
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot },
                                                  timelineGeneration: { liveGeneration }, loadPage: {
            XCTFail("the replacement already contains the reply")
            return .failed
        }, placeMatch: { match in
            attempted.append(match.rowID)
            guard match.rowID == reply.id else { return match.isCurrent(in: snapshot) }
            return try await ChatHistorySearch.waitForRoutedPlacement(timeout: .milliseconds(20)) { _ in
                liveGeneration = 2
                refresh = Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    snapshot = Snapshot(rows: replacementRows, change: .reset, generation: 2)
                }
            }
        })
        await refresh?.value
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 0)
        XCTAssertEqual(attempted, [reply.id, replacement.id])
    }

    @MainActor
    func testRoutedSearchSurvivesAReattachSlowerThanThePageSlotDeadline() async {
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var replacement = reply
        replacement.id = "replacement-reply"
        let replacementRows = rows([replacement])
        var snapshot = Snapshot(rows: rows([reply]), change: .reset, generation: 1)
        var liveGeneration: UInt64 = 1
        var refresh: Task<Void, Never>?
        var attempted = [String]()
        var pagesRequested = 0

        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot },
                                                  timelineGeneration: { liveGeneration }, loadPage: {
            pagesRequested += 1
            // A detached store cannot claim a page slot and fails after four seconds.
            try? await Task.sleep(for: .seconds(4))
            return .failed
        }, placeMatch: { match in
            attempted.append(match.rowID)
            guard match.rowID == reply.id else { return match.isCurrent(in: snapshot) }
            return try await ChatHistorySearch.waitForRoutedPlacement { completion in
                liveGeneration = 2
                completion.finish()
                refresh = Task {
                    try? await Task.sleep(for: .seconds(5))
                    snapshot = Snapshot(rows: replacementRows, change: .reset, generation: 2)
                }
            }
        })
        await refresh?.value
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 0)
        XCTAssertEqual(pagesRequested, 0)
        XCTAssertEqual(attempted, [reply.id, replacement.id])
    }

    @MainActor
    func testRoutedSearchTriesTheReplacementProjectionBeforeLoadingAnotherPage() async {
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        var replacement = reply
        replacement.id = "replacement-reply"
        var snapshot = Snapshot(rows: rows([reply]), change: .reset, generation: 1)
        var attempted = [String]()
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: { snapshot }, loadPage: {
            XCTFail("the replacement already contains the event")
            return .failed
        }, placeMatch: { match in
            attempted.append(match.rowID)
            guard match.rowID == reply.id else { return true }
            return try await ChatHistorySearch.waitForRoutedPlacement(timeout: .milliseconds(20)) { _ in
                snapshot = Snapshot(rows: self.rows([replacement]), change: .reset, generation: 2)
            }
        })
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 0)
        XCTAssertEqual(attempted, [reply.id, replacement.id])
    }

    @MainActor
    func testRoutedSearchBoundsPlacementRetriesEvenWhenNoPageIsNeeded() async {
        let reply = F.text("reply", from: F.agent, "launch", threadRoot: "$thread")
        let replyRows = rows([reply])
        var generation: UInt64 = 1
        var attempts = 0
        let result = await ChatHistorySearch.find(eventID: "$reply", snapshot: {
            Snapshot(rows: replyRows, change: .reset, generation: generation)
        }, loadPage: {
            XCTFail("every generation already contains the event")
            return .failed
        }, placeMatch: { _ in
            attempts += 1
            guard attempts <= ChatHistorySearch.maximumPages + 1 else { return true }
            return try await ChatHistorySearch.waitForRoutedPlacement { completion in
                generation += 1
                completion.finish()
            }
        })
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.pages, 0)
        XCTAssertEqual(attempts, ChatHistorySearch.maximumPages + 1)
    }

    @MainActor
    func testTimelineReplacementDoesNotResetTheRoutedSearchBudget() async {
        var calls = 0
        let result = await ChatHistorySearch.find(eventID: "$missing", snapshot: { .empty }, loadPage: {
            calls += 1
            return calls.isMultiple(of: 2) ? .timelineReplaced : .loaded(hasMore: true)
        })
        XCTAssertEqual(result.phase, .capped)
        XCTAssertEqual(result.pages, 40)
        XCTAssertEqual(calls, 40)
    }

    @MainActor
    func testFinalPageIdleBeforeDiffsStillFindsOldestMatch() async {
        var loaded = [F.text("new", from: F.agent, "nothing")]
        var publication: Task<Void, Never>?
        let result = await ChatHistorySearch.run(query: "da lat", rows: { self.rows(loaded) }, loadPage: {
            // The idle/start status arrives before the independent diff listener.
            publication = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                loaded.insert(F.text("oldest", from: F.agent, "Đi Đà Lạt"), at: 0)
            }
            return .loaded(hasMore: false)
        })
        await publication?.value
        XCTAssertEqual(result.phase, .found)
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.searched, 2)
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

    func testSearchWaitsForAScrollPageAndCanClaimAfterItsCompletion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var core = ConversationCore(context: F.assistantRoom())
        _ = core.attached(now: now)
        let rows = Projection.rows((0..<30).map { F.text("m\($0)", from: F.agent, minute: $0) },
                                   context: F.assistantRoom(), options: .s1)
        _ = core.receive(ProjectedTimeline(snapshot: Snapshot(rows: rows, change: .reset, generation: 1),
                                           nextNoAnswerChange: nil, sequence: 1, touchedItemIDs: []), now: now)
        let effects = core.handle(.geometry(distanceFromBottom: 400, distanceFromTop: 0, viewportHeight: 800,
                                            motion: .user), now: now)
        XCTAssertTrue(effects.contains { if case .paginateBackwards = $0 { true } else { false } })
        XCTAssertFalse(core.startSearchPage(now: now), "search must not steal scrolling's page slot")
        // The reader moves away from the trigger, so completion does not
        // immediately claim another scroll page.
        _ = core.handle(.geometry(distanceFromBottom: 400, distanceFromTop: 3000, viewportHeight: 800,
                                   motion: .user), now: now)
        _ = core.paginationFinished(hitTimelineStart: false, now: now)
        XCTAssertTrue(core.startSearchPage(now: now), "the completed scroll request leaves a usable search slot")
    }

}
