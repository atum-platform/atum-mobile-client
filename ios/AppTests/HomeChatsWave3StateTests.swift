@testable import AtumMobile
import XCTest
import AtumNativeAPI
import AtumChat

/// HC-6: the chat header's line under the name (desktop
/// `data-matrix-agent-title` and the group header topic).
@MainActor
final class HomeChatsWave3StateTests: XCTestCase {
    func testSubtitleIsTheAssistantsTitleOrTheGroupsTopic() {
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!a", title: "Lan", subtitle: "Trợ lý viết",
                                                       kind: .assistant)), "Trợ lý viết")
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!g", title: "Nhóm", kind: .group(memberCount: 3),
                                                       topic: "  Đi\nĐà Lạt ")), "Đi Đà Lạt")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!g", title: "Nhóm", kind: .group(memberCount: 3),
                                                     topic: "   ")), "an empty topic draws nothing")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!p", title: "Hoa", subtitle: "x", kind: .person)),
                     "a person chat has none")
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!f", title: "Founder", subtitle: "Atum",
                                                       kind: .person, isFounder: true)), "Atum")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!m", title: "Moon", subtitle: "x", kind: .app(nil))))
    }

    func testSearchIsOfferedInPersonalChatsOnly() {
        let personal = ChatInfoPresentation(roomID: "!p", title: "Hoa", kind: .person)
        XCTAssertTrue(ChatScreen.offersSearch(info: personal, conversation: nil))
        XCTAssertTrue(ChatScreen.offersSearch(info: nil, conversation: nil))
    }

    func testSearchSessionCountsStepsAndCloses() {
        let session = ChatSearchSession()
        session.open()
        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(session.searching)
        session.close()
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.highlights.isEmpty)
    }

    /// The page call returns before its ordered diff/status stream is consumed.
    /// A loading row changes snapshot.rows.count, but is not the older page.
    func testSearchWaitsForThePagePublicationBeforeDeclaringNoResults() async throws {
        let source = GatedSearchSource()
        let store = searchStore()
        defer { store.close() }
        await store.attach(source: source)
        for _ in 0..<200 where store.snapshot.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ChatHistorySearch.searched(store.snapshot.rows), 70)
        var result: ChatHistorySearch.Progress?
        let walk = Task {
            result = await ChatHistorySearch.run(query: "da lat", rows: { store.snapshot.rows },
                                                loadPage: { await store.loadOlderPageForSearch() })
        }
        await source.waitForRequest()
        // Exceeds the old 1 s row-count fallback. Release is explicitly gated,
        // so runner speed cannot make the real page win this race.
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNil(result, "must not finish at 70 while the page's rows are still withheld")
        await source.releasePage()
        await walk.value
        XCTAssertEqual(result?.phase, .found)
        XCTAssertEqual(result?.searched, 71)
    }

    func testReplacingAQueryDoesNotCancelOrOverlapItsUnpublishedPage() async throws {
        let source = GatedSearchSource()
        let store = searchStore()
        let session = ChatSearchSession()
        defer { session.close(); store.close() }
        await store.attach(source: source)
        for _ in 0..<200 where store.snapshot.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        session.open()
        session.setQuery("missing", store: store)
        await source.waitForRequest()
        session.setQuery("da lat", store: store)
        try await Task.sleep(for: .milliseconds(1200))
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "the new query must join the page, not issue another request")
        await source.releasePage()
        for _ in 0..<200 where session.progress?.phase != .found { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.progress?.phase, .found)
        XCTAssertEqual(session.matches.first?.rowID, "older-match")
        XCTAssertEqual(session.focus?.rowID, "older-match")
    }

    func testDetachingReleasesAnUnpublishedSearchPage() async throws {
        let source = GatedSearchSource()
        let store = searchStore()
        defer { store.close() }
        await store.attach(source: source)
        for _ in 0..<200 where store.snapshot.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let page = Task { await store.loadOlderPageForSearch() }
        await source.waitForRequest()
        store.detach()
        let result = await page.value
        XCTAssertEqual(result, .failed)
    }

    private func searchStore() -> LiveConversationStore {
        LiveConversationStore(info: ConversationRoomInfo(
            roomID: "!search:example.test", title: "Search",
            context: RoomContext(kind: .person, ownUserID: "@me:example.test"),
            knownNames: [:], catalogBotUserIDs: [], languageCode: "en"))
    }

}

@MainActor
final class PeopleHandleSearchTests: XCTestCase {
    private let own = "@fake_owner:example.test"
    private let target = "@fake_person:example.test"
    private var row: HomeGroupCandidate {
        HomeGroupCandidate(id: target, name: "Fake Person", kind: .person, avatarURL: "mxc://example.test/fake")
    }
    private func assignment(kind: String = "human", user: String? = nil) throws -> AliasLookupResponse {
        let json = """
        {"state":"assigned","handle":"fake_person","principal":"00000000-0000-4000-8000-000000000001","kind":"\(kind)","generation":1,"matrixUser":"\(user ?? target)"}
        """
        // Contract types read integers through the raw-JSON userInfo, so a
        // plain JSONDecoder throws `invalidValue`: decode as the client does.
        return try NativeAPI.decode(AliasLookupResponse.self, from: Data(json.utf8))
    }
    func testHitIsFirst() async throws {
        let hit = try assignment()
        let other = HomeGroupCandidate(id: "@fake_other:example.test", name: "Other", kind: .person)
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [other] })
        XCTAssertEqual(result?.map(\.id), [target, other.id])
        XCTAssertEqual(result?.first?.name, "@fake_person")
    }
    func testMatchingRowKeepsProfileAndHasNoDuplicate() async throws {
        let hit = try assignment()
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [self.row] })
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.name, row.name)
        XCTAssertEqual(result?.first?.avatarURL, row.avatarURL)
        XCTAssertEqual(result?.first?.handle, "fake_person")
    }
    func testLookupFailurePreservesDirectory() async {
        struct Failure: Error {}
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in throw Failure() }, directory: { _ in [self.row] })
        XCTAssertEqual(result, [row])
    }
    func testDirectoryFailureReturnsHit() async throws {
        let hit = try assignment()
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in nil })
        XCTAssertEqual(result?.map(\.id), [target])
    }
    func testLeadingAtIsStripped() async {
        var lookups: [String] = []
        var terms: [String] = []
        let result = await HomePeopleSearch.search(" @fake_person ", ownUserID: own, excluded: [],
            lookup: { handle in lookups.append(handle.rawValue); return nil },
            directory: { term in terms.append(term); return [self.row] })
        XCTAssertEqual(lookups, ["fake_person"])
        XCTAssertEqual(terms, ["fake_person"])
        XCTAssertEqual(result, [row])
    }
    func testOwnUserExcludedFromBothSources() async throws {
        let hit = try assignment(user: own)
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [HomeGroupCandidate(id: self.own, name: "Owner", kind: .person)] })
        XCTAssertEqual(result, [])
    }
    func testNonHumanAssignmentIgnored() async throws {
        for kind in ["agent", "app", "organization"] {
            let hit = try assignment(kind: kind)
            let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
                lookup: { _ in hit }, directory: { _ in [] })
            XCTAssertEqual(result, [])
        }
    }
    func testMinimumAvoidsTransport() async {
        let result = await HomePeopleSearch.search("@f", ownUserID: own, excluded: [],
            lookup: { _ in XCTFail("short query"); return nil },
            directory: { _ in XCTFail("short query"); return [] })
        XCTAssertEqual(result, [])
    }
}


/// Delivers SDK outputs in order, but only publishes the older page when the
/// test releases it. The call's Bool is deliberately ahead of the stream.
private actor GatedSearchSource: ChatTimelineSource {
    nonisolated let outputs: AsyncStream<ChatTimelineOutput>
    private let continuation: AsyncStream<ChatTimelineOutput>.Continuation
    private var requested: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    init() { (outputs, continuation) = AsyncStream.makeStream(of: ChatTimelineOutput.self) }
    func start() {
        let items = (0..<70).map { ChatItem(id: "cached-\($0)", kind: .message,
                                          sender: "@me:example.test", isOwn: true, body: "cached words") }
        continuation.yield(.batch(ChatTimelineBatch(diffs: [.reset(items)])))
    }
    func stop() { continuation.finish() }
    func markOutputBoundary(_ id: UUID) -> Bool {
        continuation.yield(.outputBoundary(id))
        return true
    }
    func paginateBackwards(numEvents: UInt16) -> Bool {
        calls += 1
        continuation.yield(.pagination(.paginating))
        requested?.resume(); requested = nil
        return true
    }
    func waitForRequest() async {
        if calls > 0 { return }
        await withCheckedContinuation { requested = $0 }
    }
    func releasePage() {
        let match = ChatItem(id: "older-match", kind: .message, sender: "@me:example.test",
                             isOwn: true, body: "Đi Đà Lạt")
        continuation.yield(.batch(ChatTimelineBatch(diffs: [.pushFront(match)])))
        continuation.yield(.pagination(.idle(hitTimelineStart: true)))
    }
    func send(text: String, replyTo eventID: String?) {}
    func edit(_ item: ChatEventRef, text: String) {}
    func redact(_ item: ChatEventRef) {}
    func toggleReaction(_ item: ChatEventRef, key: String) {}
    func isSendQueueEnabled() -> Bool { true }
    func enableSendQueue() {}
    func retrySend(_ item: ChatEventRef) {}
    func abortSend(_ item: ChatEventRef) {}
    func sendReceipt(_ receipt: ChatReceipt) {}
    func fetchReplyDetails(eventID: String) {}
}


@MainActor
final class TimelinePaginationPublicationTests: XCTestCase {
    private func controller(_ source: PaginationStatusSource, timeout: Duration = .seconds(5)) -> TimelineController {
        TimelineController(source: source, roomID: "!pages:example.test",
                           context: RoomContext(kind: .person, ownUserID: "@me:example.test"),
                           generation: 1, clock: { Date() }, pagePublicationTimeout: timeout)
    }

    func testNoStatusReturnsPromptlyAndFlushesQueuedRows() async throws {
        let source = PaginationStatusSource(.noStatus)
        let controller = controller(source)
        defer { controller.close() }
        var ids = [String]()
        controller.onPublication = { ids = $0.projected.snapshot.rows.map(\.id) }
        await controller.start()
        let started = ContinuousClock.now
        let hitStart = try await controller.paginateBackwards(events: 50)
        XCTAssertFalse(hitStart)
        XCTAssertEqual(ids, ["page-match"], "the output marker must flush the queued batch without status events")
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testAlreadyAtStartWithoutAStatusReturnsPromptly() async throws {
        let source = PaginationStatusSource(.atStart)
        let controller = controller(source)
        defer { controller.close() }
        await controller.start()
        let started = ContinuousClock.now
        let hitStart = try await controller.paginateBackwards(events: 50)
        XCTAssertTrue(hitStart)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testStatusConsumedBeforeSDKReturnIsNotLost() async throws {
        let source = PaginationStatusSource(.beforeReturn)
        let controller = controller(source)
        defer { controller.close() }
        var states = [PaginationState]()
        var ids = [String]()
        controller.onPaginationStatus = { state in
            states.append(state)
            if state == .paginating { Task { await source.allowReturn() } }
        }
        controller.onPublication = { ids = $0.projected.snapshot.rows.map(\.id) }
        await controller.start()
        let hitStart = try await controller.paginateBackwards(events: 50)
        XCTAssertFalse(hitStart)
        XCTAssertEqual(states, [.paginating, .idle(hitTimelineStart: false)])
        XCTAssertEqual(ids, ["page-match"])
    }

    func testStatusQueuedAfterSDKReturnIsFlushedBeforeDecidingToWait() async throws {
        let source = PaginationStatusSource(.afterReturn)
        let controller = controller(source)
        defer { controller.close() }
        var states = [PaginationState]()
        var ids = [String]()
        controller.onPaginationStatus = { states.append($0) }
        controller.onPublication = { ids = $0.projected.snapshot.rows.map(\.id) }
        await controller.start()
        let hitStart = try await controller.paginateBackwards(events: 50)
        XCTAssertFalse(hitStart)
        XCTAssertEqual(states, [.paginating, .idle(hitTimelineStart: false)])
        XCTAssertEqual(ids, ["page-match"])
    }

    func testPaginatingWithoutIdleReturnsAtTheBoundAndAllowsAnotherPage() async throws {
        let source = PaginationStatusSource(.missingIdle)
        let controller = controller(source, timeout: .milliseconds(100))
        defer { controller.close() }
        var states = [PaginationState]()
        controller.onPaginationStatus = { states.append($0) }
        await controller.start()
        let started = ContinuousClock.now
        let first = try await controller.paginateBackwards(events: 50)
        XCTAssertFalse(first)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(100))
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertEqual(states.last, .idle(hitTimelineStart: false), "timeout must also release the core's loading status")
        let second = try await controller.paginateBackwards(events: 20)
        XCTAssertFalse(second)
        let calls = await source.calls
        XCTAssertEqual(calls, 2, "the shared request must be cleared after a timeout")
    }

    func testEndedSubscriptionDoesNotKeepThePagePending() async throws {
        let source = PaginationStatusSource(.ended)
        let controller = controller(source)
        defer { controller.close() }
        await controller.start()
        let started = ContinuousClock.now
        let hitStart = try await controller.paginateBackwards(events: 20)
        XCTAssertFalse(hitStart)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testConcurrentScrollAndSearchCallersJoinOneRequest() async throws {
        let source = PaginationStatusSource(.heldIdle)
        let controller = controller(source)
        defer { controller.close() }
        await controller.start()
        let search = Task { try await controller.paginateBackwards(events: 50) }
        await source.waitForBoundary()
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let scroll = Task {
            signal.yield(()); signal.finish()
            return try await controller.paginateBackwards(events: 20)
        }
        for await _ in started { break }
        await source.releasePage()
        let searchResult = try await search.value
        let scrollResult = try await scroll.value
        XCTAssertFalse(searchResult)
        XCTAssertEqual(scrollResult, searchResult)
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "a concurrent scroll load must join rather than silently fail")
    }
}

private actor PaginationStatusSource: ChatTimelineSource {
    enum Mode { case noStatus, atStart, beforeReturn, afterReturn, missingIdle, ended, heldIdle }
    nonisolated let outputs: AsyncStream<ChatTimelineOutput>
    private let continuation: AsyncStream<ChatTimelineOutput>.Continuation
    private let mode: Mode
    private var returnGate: CheckedContinuation<Void, Never>?
    private var boundaryGate: CheckedContinuation<Void, Never>?
    private var boundarySent = false
    private(set) var calls = 0

    init(_ mode: Mode) {
        self.mode = mode
        (outputs, continuation) = AsyncStream.makeStream(of: ChatTimelineOutput.self)
    }
    func start() { continuation.yield(.batch(ChatTimelineBatch(diffs: [.reset([])]))) }
    func stop() { continuation.finish() }
    func paginateBackwards(numEvents: UInt16) async -> Bool {
        calls += 1
        switch mode {
        case .noStatus: emitMatch()
        case .atStart, .afterReturn: break
        case .beforeReturn:
            continuation.yield(.pagination(.paginating))
            await withCheckedContinuation { returnGate = $0 }
            releasePage()
        case .missingIdle, .heldIdle: continuation.yield(.pagination(.paginating))
        case .ended:
            continuation.yield(.pagination(.paginating))
            continuation.finish()
        }
        return mode == .atStart
    }
    func allowReturn() { returnGate?.resume(); returnGate = nil }
    func markOutputBoundary(_ id: UUID) -> Bool {
        if mode == .afterReturn {
            continuation.yield(.pagination(.paginating))
            releasePage()
        }
        if case .terminated = continuation.yield(.outputBoundary(id)) { return false }
        boundarySent = true
        boundaryGate?.resume(); boundaryGate = nil
        return true
    }
    func waitForBoundary() async {
        if boundarySent { return }
        await withCheckedContinuation { boundaryGate = $0 }
    }
    func releasePage() {
        emitMatch()
        continuation.yield(.pagination(.idle(hitTimelineStart: false)))
    }
    private func emitMatch() {
        continuation.yield(.batch(ChatTimelineBatch(diffs: [.pushFront(ChatItem(
            id: "page-match", kind: .message, sender: "@me:example.test", isOwn: true, body: "Đà Lạt"))])))
    }
    func send(text: String, replyTo eventID: String?) {}
    func edit(_ item: ChatEventRef, text: String) {}
    func redact(_ item: ChatEventRef) {}
    func toggleReaction(_ item: ChatEventRef, key: String) {}
    func isSendQueueEnabled() -> Bool { true }
    func enableSendQueue() {}
    func retrySend(_ item: ChatEventRef) {}
    func abortSend(_ item: ChatEventRef) {}
    func sendReceipt(_ receipt: ChatReceipt) {}
    func fetchReplyDetails(eventID: String) {}
}
