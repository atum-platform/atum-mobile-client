import XCTest
@testable import AtumChat

/// Behaviour of one open chat's decisions (the store's pure core): instant
/// plain sends, replies and edits, sends held across a session renewal, the
/// failure mapping, one pagination in flight, the read rule gated on the
/// bottom being visible, `.fullyRead` on leaving, and reply-detail fetches.
/// The read and pagination rules are WS3's real `ReadPolicy` and
/// `PaginationPolicy`, run by the core on an injected clock.
final class ConversationCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func core(_ kind: RoomKind = .assistant, history: HistoryLoading = .onScroll) -> ConversationCore {
        let context: RoomContext = switch kind {
        case .person: F.personRoom()
        case .appBot: F.botRoom()
        case .group: RoomContext(kind: .group, ownUserID: F.me)
        case .assistant: F.assistantRoom()
        }
        return ConversationCore(context: context, history: history)
    }

    private func projection(_ items: [ChatItem], change: SnapshotChange = .reset,
                            context: RoomContext = F.assistantRoom(),
                            replyDetails: [String: ChatReplyDetails] = [:],
                            touched: Set<String> = []) -> ProjectedTimeline {
        let rows = Projection.rows(items, context: context, replyDetails: replyDetails, options: .s1)
        return ProjectedTimeline(snapshot: Snapshot(rows: rows, change: change, generation: 1),
                                 nextNoAnswerChange: nil, sequence: 1, touchedItemIDs: touched)
    }

    private func mark(_ core: ConversationCore, _ id: String) -> DeliveryMark? {
        core.snapshot.rows.first { $0.id == id }?.delivery
    }

    private func attachedCore(_ items: [ChatItem], kind: RoomKind = .assistant,
                              context: RoomContext = F.assistantRoom(),
                              history: HistoryLoading = .onScroll) -> ConversationCore {
        var core = core(kind, history: history)
        _ = core.attached(now: now)
        _ = core.receive(projection(items, context: context), now: now)
        return core
    }

    private func geometry(top: Double, bottom: Double = 0) -> FollowInput {
        .geometry(distanceFromBottom: bottom, distanceFromTop: top, viewportHeight: 800, motion: .idle)
    }

    // MARK: Send (B6, B21, B20)

    func testSendClearsTheDraftAtOnceAndSendsTheTrimmedTextAsTyped() {
        var core = attachedCore([F.mine("q")])
        core.draft = "  *hi* 1. a_b_ \n"
        XCTAssertEqual(core.send(), [.send(text: "*hi* 1. a_b_", replyToEventID: nil)])
        XCTAssertEqual(core.draft, "")
        core.draft = "   "
        XCTAssertEqual(core.send(), [], "nothing to send")
    }

    func testAReplyTargetBecomesAReplyAndClears() {
        var core = attachedCore([F.text("a", from: F.agent)])
        XCTAssertTrue(core.reply(to: "a"))
        XCTAssertEqual(core.replyTarget, "$a")
        core.draft = "ok"
        XCTAssertEqual(core.send(), [.send(text: "ok", replyToEventID: "$a")])
        XCTAssertNil(core.replyTarget)
        XCTAssertFalse(core.reply(to: "missing"))
    }

    func testMediaConsumesCaptionAndReplyWithoutCreatingATextEffect() {
        var core = attachedCore([F.text("a", from: F.agent)])
        XCTAssertTrue(core.reply(to: "a"))
        core.draft = "  chú thích  "
        let payload = core.takeMediaCaption()
        XCTAssertEqual(payload?.caption, "chú thích")
        XCTAssertEqual(payload?.replyToEventID, "$a")
        XCTAssertEqual(core.draft, "")
        XCTAssertNil(core.replyTarget)
    }

    func testOnlyEventsOnTheServerCanBeRepliedTo() {
        var core = attachedCore([F.echo("e"), F.echo("s", delivery: .sent(eventID: "$s"))])
        XCTAssertFalse(core.reply(to: "e"), "a pending echo has no event ID yet")
        XCTAssertTrue(core.reply(to: "s"))
        XCTAssertEqual(core.replyTarget, "$s")
    }

    func testEditingMyMessageInAPeopleChatSendsAnEdit() {
        var core = attachedCore([F.mine("m", "hello")], kind: .person, context: F.personRoom())
        XCTAssertTrue(core.beginEdit("m"))
        XCTAssertEqual(core.draft, "hello", "the message loads into the composer")
        core.draft = "hello there"
        XCTAssertEqual(core.send(), [.edit(.event("$m"), text: "hello there")])
        XCTAssertNil(core.editTarget)
    }

    func testEditIsRefusedInAgentRoomsOnOtherPeoplesMessagesAndOnFailedSends() {
        var assistant = attachedCore([F.mine("m")])
        XCTAssertFalse(assistant.beginEdit("m"), "editing a prompt does not re-run an agent")
        var person = attachedCore([F.text("t", from: F.friend), F.echo("f", delivery: .failed(isRecoverable: true))],
                                  kind: .person, context: F.personRoom())
        XCTAssertFalse(person.beginEdit("t"))
        XCTAssertFalse(person.beginEdit("f"))
    }

    func testCancellingAnEditClearsTheDraftAndAReplyReplacesAnEdit() {
        var core = attachedCore([F.mine("m", "hello"), F.text("t", from: F.friend)], kind: .person,
                                context: F.personRoom())
        XCTAssertTrue(core.beginEdit("m"))
        core.cancelEdit()
        XCTAssertEqual(core.draft, "")
        XCTAssertTrue(core.beginEdit("m"))
        XCTAssertTrue(core.reply(to: "t"))
        XCTAssertNil(core.editTarget)
        XCTAssertEqual(core.replyTarget, "$t")
    }

    func testAnEditOfAMessageDeletedMeanwhileIsNeverSentAsANewMessage() {
        var core = attachedCore([F.mine("m", "hello")], kind: .person, context: F.personRoom())
        XCTAssertTrue(core.beginEdit("m"))
        core.draft = "hello there"
        var deleted = F.mine("m")
        deleted.kind = .placeholder(.redacted)
        _ = core.receive(projection([deleted], change: .inPlace, context: F.personRoom()), now: now)
        XCTAssertEqual(core.send(now: now), [])
        XCTAssertNil(core.editTarget)
        XCTAssertEqual(core.draft, "hello there", "the text stays in the composer")
    }

    func testAnEditOfAMessageThatIsGoneIsNeverSentAsANewMessage() {
        var core = attachedCore([F.mine("m", "hello")], kind: .person, context: F.personRoom())
        XCTAssertTrue(core.beginEdit("m"))
        _ = core.receive(projection([], context: F.personRoom()), now: now)
        XCTAssertEqual(core.send(now: now), [])
        XCTAssertEqual(core.draft, "hello")
    }

    func testAnEditWaitsInTheComposerWhileDetached() {
        var core = attachedCore([F.mine("m", "hello")], kind: .person, context: F.personRoom())
        XCTAssertTrue(core.beginEdit("m"))
        core.draft = "hello there"
        core.detached()
        XCTAssertEqual(core.send(now: now), [])
        XCTAssertEqual(core.draft, "hello there")
        XCTAssertEqual(core.editTarget, "m", "the edit chip stays")
        XCTAssertEqual(core.pendingSends, [], "never held as a new message")
        _ = core.attached(now: now)
        XCTAssertEqual(core.send(now: now), [.edit(.event("$m"), text: "hello there")])
    }

    func testTheDraftFromBeforeAnEditComesBack() {
        var core = attachedCore([F.mine("m", "hello"), F.text("t", from: F.friend)], kind: .person,
                                context: F.personRoom())
        core.draft = "half a thought"
        XCTAssertTrue(core.beginEdit("m"))
        core.draft = "hello there"
        XCTAssertEqual(core.send(now: now), [.edit(.event("$m"), text: "hello there")])
        XCTAssertEqual(core.draft, "half a thought", "after the edit")
        XCTAssertTrue(core.beginEdit("m"))
        core.cancelEdit()
        XCTAssertEqual(core.draft, "half a thought", "after a cancel")
        XCTAssertTrue(core.beginEdit("m"))
        _ = core.leaving()
        XCTAssertEqual(core.draft, "half a thought", "leaving mid-edit keeps the draft, not the edit")
    }

    // MARK: Session renewal

    func testSendsTappedWhileDetachedGoOutInTapOrderOnAttach() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "one"
        XCTAssertEqual(core.send(), [])
        core.draft = "two"
        XCTAssertEqual(core.send(), [])
        XCTAssertEqual(core.draft, "", "the composer still clears at once")
        XCTAssertEqual(core.attached(now: now), [.send(text: "one", replyToEventID: nil), .send(text: "two", replyToEventID: nil)])
        XCTAssertEqual(core.pendingSends, [])
    }

    func testASendHeldWhileDetachedShowsAsMyRowWithAClockInTapOrder() {
        var core = attachedCore([F.text("a", from: F.agent)])
        core.detached()
        let before = core.scrollRequest.sequence
        core.draft = "one"
        _ = core.send(now: now)
        core.draft = "two"
        _ = core.send(now: now)
        let rows = core.snapshot.rows
        let held = rows.filter { $0.id.hasPrefix(ConversationCore.heldRowPrefix) }
        XCTAssertEqual(held.map(\.item.body), ["one", "two"])
        XCTAssertTrue(held.allSatisfy { $0.item.isOwn && $0.delivery == .sending }, "B9: a clock, never invisible")
        XCTAssertEqual(rows.map(\.grouping), Grouping.layout(rows, context: F.assistantRoom()),
                       "the run layout covers the held rows")
        XCTAssertEqual(held.map(\.grouping.position), [.first, .last], "two quick sends make one run")
        XCTAssertEqual(core.scrollRequest.command, .scrollToBottom(animated: false), "my send scrolls to the latest")
        XCTAssertGreaterThan(core.scrollRequest.sequence, before)
        XCTAssertEqual(core.snapshot.change, .appendedAtEnd(count: 0, localEcho: true))
    }

    func testLeavingPutsHeldSendsBackInTheDraft() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "one"
        _ = core.send(now: now)
        core.draft = "two"
        _ = core.send(now: now)
        core.draft = "still typing"
        _ = core.leaving()
        XCTAssertEqual(core.draft, "one\ntwo\nstill typing", "B8: the text is never lost")
        XCTAssertEqual(core.pendingSends, [])
        XCTAssertFalse(core.snapshot.rows.contains { $0.id.hasPrefix(ConversationCore.heldRowPrefix) })
    }

    func testAFailedAttachPutsHeldSendsBackInTheComposer() {
        var core = core()
        core.draft = "hello"
        _ = core.send(now: now)
        XCTAssertEqual(core.draft, "")
        core.attachFailed()
        XCTAssertEqual(core.draft, "hello")
        XCTAssertEqual(core.pendingSends, [])
    }

    func testAHeldSendCanBeDeletedBeforeItLeaves() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "oops"
        _ = core.send(now: now)
        let held = core.pendingSends[0].id
        XCTAssertEqual(core.delete(held), [])
        XCTAssertEqual(core.pendingSends, [])
        XCTAssertEqual(core.attached(now: now), [], "nothing goes out")
    }

    func testFlushedHeldRowsStayUntilTheirEchoesShow() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "one"
        _ = core.send(now: now)
        XCTAssertEqual(core.attached(now: now), [.send(text: "one", replyToEventID: nil)])
        func heldCount() -> Int { core.snapshot.rows.filter { $0.id.hasPrefix(ConversationCore.heldRowPrefix) }.count }
        XCTAssertEqual(heldCount(), 1, "handed to the SDK, its echo not shown yet: the row stays")
        _ = core.receive(projection([F.mine("q")]), now: now)
        XCTAssertEqual(heldCount(), 1, "the new timeline's first batch has no echo yet")
        _ = core.receive(projection([F.mine("q"), F.echo("e1", "one")], change: .appendedAtEnd(count: 0, localEcho: true)),
                         now: now)
        XCTAssertEqual(heldCount(), 0, "the echo replaced it")
        XCTAssertEqual(F.ids(core.snapshot.rows), ["q", "e1"])
    }

    func testAFlushedHeldRowNeverOutstaysTheGrace() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "one"
        _ = core.send(now: now)
        _ = core.attached(now: now)
        _ = core.receive(projection([F.mine("q")]), now: now.addingTimeInterval(ConversationCore.handingGrace))
        XCTAssertEqual(F.ids(core.snapshot.rows), ["q"])
    }

    func testASendThatLostItsTimelineMidFlightIsHeldBeforeLaterTaps() {
        var core = attachedCore([F.mine("q")])
        XCTAssertEqual(core.send(now: now), [], "empty draft")
        core.draft = "first"
        XCTAssertEqual(core.send(now: now), [.send(text: "first", replyToEventID: nil)])
        core.detached()
        core.draft = "second"
        _ = core.send(now: now)
        XCTAssertEqual(core.requeue(text: "first", replyToEventID: nil, now: now), [])
        XCTAssertEqual(core.pendingSends.map(\.text), ["first", "second"])
        XCTAssertEqual(core.attached(now: now), [.send(text: "first", replyToEventID: nil),
                                                 .send(text: "second", replyToEventID: nil)])
        XCTAssertEqual(core.requeue(text: "late", replyToEventID: "$q", now: now),
                       [.send(text: "late", replyToEventID: "$q")], "attached again by then: it just goes")
    }

    func testARefusedFlushedSendLosesItsHeldRow() {
        var core = attachedCore([F.mine("q")])
        core.detached()
        core.draft = "one"
        _ = core.send(now: now)
        _ = core.attached(now: now)
        core.sendRefused(text: "one")
        XCTAssertEqual(F.ids(core.snapshot.rows), ["q"], "the store put the text back in the composer")
    }

    // MARK: Failed sends (B8) and actions (B20, B22)

    func testRetryAndDeleteFollowTheFailureKind() {
        var core = attachedCore([F.echo("r", delivery: .failed(isRecoverable: true)),
                                 F.echo("p", delivery: .failed(isRecoverable: false)), F.mine("m")])
        XCTAssertEqual(core.retry("r"), [.repair(.enableRoomQueue)])
        XCTAssertEqual(core.retry("p"), [.repair(.retryParkedRequest(.transaction("txn-p")))])
        XCTAssertEqual(core.retry("m"), [])
        XCTAssertEqual(core.abort("p"), [.abortSend(.transaction("txn-p"))])
        XCTAssertEqual(core.delete("p"), [.abortSend(.transaction("txn-p"))], "deleting a failed send aborts it")
        XCTAssertEqual(core.delete("m"), [.redact(.event("$m"))])
    }

    /// U5, D8 (coordinator decision 9): "Thử lại" on a recoverable failure
    /// re-enables the room's queue, which tells the timeline nothing, so the
    /// row shows the clock again at once and keeps it until the source sends
    /// its next state for that item; then "Đã gửi".
    func testThuLaiOnARecoverableFailureShowsTheClockUntilTheSourcesNextState() {
        let failed = F.echo("r", "hi", delivery: .failed(isRecoverable: true))
        var core = attachedCore([F.mine("m"), failed])
        XCTAssertEqual(mark(core, "r"), .failed)
        XCTAssertEqual(core.retry("r"), [.repair(.enableRoomQueue)])
        XCTAssertEqual(mark(core, "r"), .sending, "the clock comes back at once")
        XCTAssertEqual(core.snapshot.change, .inPlace, "a local change, not a replay of the last projection's")

        // A batch about another item: the queue has said nothing yet.
        var reacted = F.mine("m")
        reacted.reactions = [ChatReaction(key: "👍", senderIDs: [F.agent])]
        _ = core.receive(projection([reacted, failed], change: .inPlace, touched: ["m"]), now: now)
        XCTAssertEqual(mark(core, "r"), .sending, "still going out")

        // The server accepted it: the source's next state, then "Đã gửi".
        var sent = failed
        sent.delivery = .sent(eventID: "$r")
        _ = core.receive(projection([reacted, sent], change: .inPlace, touched: ["r"]), now: now)
        XCTAssertEqual(mark(core, "r"), .sent)
        XCTAssertTrue(core.retryingIDs.isEmpty)
    }

    /// The resend failed again: the source sets the same failed value, and the
    /// failure shows again (with B26's warning, `SendFailureWatch`).
    func testARetriedSendThatFailsAgainShowsTheFailureAgain() {
        let failed = F.echo("r", "hi", delivery: .failed(isRecoverable: true))
        var core = attachedCore([failed])
        _ = core.retry("r")
        XCTAssertEqual(mark(core, "r"), .sending)
        _ = core.receive(projection([failed], change: .inPlace, touched: ["r"]), now: now)
        XCTAssertEqual(mark(core, "r"), .failed, "an equal value from the source is still its next state")
    }

    /// The queue resends every recoverable failure in the room; a parked
    /// request is left to the SDK (`retrySend` shows it sending); a send
    /// deleted meanwhile is forgotten.
    func testOnlyRecoverableFailuresShowTheClockAndGoneRowsAreForgotten() {
        let first = F.echo("r1", delivery: .failed(isRecoverable: true))
        let second = F.echo("r2", delivery: .failed(isRecoverable: true))
        let parked = F.echo("p", delivery: .failed(isRecoverable: false))
        var core = attachedCore([first, second, parked])
        XCTAssertEqual(core.retry("p"), [.repair(.retryParkedRequest(.transaction("txn-p")))])
        XCTAssertEqual(mark(core, "p"), .failed, "the SDK's own update brings its clock")
        _ = core.retry("r2")
        XCTAssertEqual([mark(core, "r1"), mark(core, "r2"), mark(core, "p")], [.sending, .sending, .failed])
        _ = core.receive(projection([second, parked], change: .inPlace), now: now)
        XCTAssertEqual(core.retryingIDs, ["r2"], "r1 left the timeline (aborted)")
        XCTAssertEqual(mark(core, "r2"), .sending)
    }

    func testDeleteOnlyMyOwnAndReactOnAnythingThatExists() {
        var deleted = F.text("x", from: F.friend)
        deleted.kind = .placeholder(.redacted)
        var core = attachedCore([F.text("t", from: F.agent), F.echo("e"), deleted])
        XCTAssertEqual(core.delete("t"), [], "never someone else's message")
        XCTAssertEqual(core.toggleReaction("t", key: "👍"), [.toggleReaction(.event("$t"), key: "👍")])
        XCTAssertEqual(core.toggleReaction("e", key: "❤️"), [.toggleReaction(.transaction("txn-e"), key: "❤️")],
                       "reactions work on a local echo too")
        XCTAssertEqual(core.toggleReaction("x", key: "👍"), [], "not on a deleted message")
    }

    // MARK: Pagination (B5, §2.3 rule 7)

    func testGeometryNearTheTopLoadsOnePageAtATimeThrottled() {
        var core = attachedCore([F.mine("q")])
        XCTAssertEqual(core.handle(geometry(top: 5000), now: now), [], "far from the top")
        XCTAssertEqual(core.handle(geometry(top: 100), now: now), [.paginateBackwards(events: 20)])
        XCTAssertEqual(core.handle(geometry(top: 50), now: now), [], "one request in flight")
        let throttled = now.addingTimeInterval(PaginationPolicy.throttleSeconds)
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [.wakePagination(at: throttled)],
                       "still near the top: the next page after the 0.1 s throttle")
        XCTAssertEqual(core.paginationWakeDue(now: throttled), [.paginateBackwards(events: 20)])
    }

    func testNothingLoadsAtTheStartOrWhileDetached() {
        var core = attachedCore([F.mine("q")])
        core.paginationChanged(.idle(hitTimelineStart: true), now: now)
        XCTAssertEqual(core.handle(geometry(top: 0), now: now), [])
        var detached = attachedCore([F.mine("q")])
        detached.detached()
        XCTAssertEqual(detached.handle(geometry(top: 0), now: now), [])
        XCTAssertEqual(detached.resumePagination(now: now), [])
    }

    func testTheSDKsPaginatingStatusBlocksAndIdleReleases() {
        var core = attachedCore([F.mine("q")])
        XCTAssertEqual(core.paginationChanged(.paginating, now: now), [])
        XCTAssertEqual(core.handle(geometry(top: 0), now: now), [])
        XCTAssertEqual(core.paginationChanged(.idle(hitTimelineStart: false), now: now),
                       [.paginateBackwards(events: 20)], "idle re-checks the last geometry")
    }

    func testAFailedScrollPageBacksOffThenResumesOnReconnect() {
        var core = attachedCore([F.mine("q")])
        XCTAssertEqual(core.handle(geometry(top: 0), now: now), [.paginateBackwards(events: 20)])
        var clock = now
        for delay in PaginationPolicy.failureRetrySeconds {
            let retryAt = clock.addingTimeInterval(delay)
            XCTAssertEqual(core.paginationFinished(hitTimelineStart: nil, now: clock), [.wakePagination(at: retryAt)],
                           "offline near the top: never ten times a second")
            XCTAssertEqual(core.handle(geometry(top: 0), now: clock), [.wakePagination(at: retryAt)],
                           "a backoff is never skipped")
            XCTAssertEqual(core.paginationWakeDue(now: retryAt), [.paginateBackwards(events: 20)])
            clock = retryAt
        }
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: nil, now: clock), [], "every step failed")
        XCTAssertEqual(core.paginationWakeDue(now: clock.addingTimeInterval(60)), [])
        XCTAssertEqual(core.resumePagination(now: clock.addingTimeInterval(60)), [.paginateBackwards(events: 20)],
                       "sync recovered or back in the foreground: try again")
    }

    func testABackgroundPageHoldsTheScrollPolicyUntilItFinishes() {
        var core = core()
        _ = core.attached(now: now)
        XCTAssertEqual(core.receive(projection([]), now: now), [.paginateBackwards(events: 20)], "rule 7")
        XCTAssertEqual(core.handle(geometry(top: 0), now: now), [], "never a second request at the same time")
        XCTAssertEqual(core.paginationChanged(.idle(hitTimelineStart: false), now: now), [],
                       "the SDK going idle first does not release it")
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [.paginateBackwards(events: 20)],
                       "then the scroll rule continues from the last geometry")
        XCTAssertEqual(core.handle(geometry(top: 0), now: now), [], "one in flight")
    }

    func testAnEmptyFirstProjectionAsksForOnePageInTheBackground() {
        var core = core()
        _ = core.attached(now: now)
        XCTAssertEqual(core.receive(projection([]), now: now), [.paginateBackwards(events: 20)])
        var cached = self.core()
        _ = cached.attached(now: now)
        XCTAssertEqual(cached.receive(projection([F.mine("q")]), now: now), [],
                       "cached rows show at once; the view's geometry decides the rest")
    }

    func testANewTimelineStartsFreshEvenAfterTheOldOneReachedTheStart() {
        var core = attachedCore([F.mine("q")])
        core.paginationChanged(.idle(hitTimelineStart: true), now: now)
        core.detached()
        _ = core.attached(now: now)
        XCTAssertEqual(core.receive(projection([]), now: now), [.paginateBackwards(events: 20)],
                       "rule 7 still runs on the renewed timeline")
    }

    func testAFailedPagePausesBackgroundLoading() {
        var core = attachedCore([F.mine("q")], history: .whileFollowing(pages: 5))
        // The first projection already started the first page.
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: nil, now: now), [])
        XCTAssertEqual(core.handle(geometry(top: 5000), now: now.addingTimeInterval(1)), [], "no retry loop")
        XCTAssertEqual(core.handle(geometry(top: 5000), now: now.addingTimeInterval(ConversationCore.pageRetryDelay)),
                       [.paginateBackwards(events: 20)])
    }

    func testTheInterimDepthLoadsOnlyWhileFollowingAndNeverOnScroll() {
        var core = core(history: .whileFollowing(pages: 2))
        _ = core.attached(now: now)
        XCTAssertEqual(core.receive(projection([F.mine("q")]), now: now),
                       [.paginateBackwards(events: 20)], "following: the first page at once")
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [.paginateBackwards(events: 20)])
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [], "the depth is reached")
        var reading = attachedCore([F.mine("q")], history: .whileFollowing(pages: 2))
        _ = reading.handle(.geometry(distanceFromBottom: 600, distanceFromTop: 10, viewportHeight: 800, motion: .user),
                           now: now)
        XCTAssertFalse(reading.follow.isFollowing)
        XCTAssertEqual(reading.paginationFinished(hitTimelineStart: false, now: now), [],
                       "scrolled up: no more pages land above the row being read")
        XCTAssertEqual(reading.handle(.geometry(distanceFromBottom: 600, distanceFromTop: 0, viewportHeight: 800,
                                                motion: .user), now: now), [], "not even at the very top")
    }

    // MARK: Follow (§2.5)

    func testTheSnapshotsChangeDrivesTheScrollRequest() {
        var core = attachedCore([F.mine("q")])
        let before = core.scrollRequest.sequence
        _ = core.receive(projection([F.mine("q"), F.echo("e")], change: .appendedAtEnd(count: 0, localEcho: true)),
                         now: now)
        XCTAssertEqual(core.scrollRequest.command, .scrollToBottom(animated: false))
        XCTAssertGreaterThan(core.scrollRequest.sequence, before)
    }

    func testTypingAppearingKeepsAFollowingViewPinned() {
        var core = attachedCore([F.mine("q")])
        let before = core.scrollRequest.sequence
        core.typingChanged(["Atum"])
        XCTAssertGreaterThan(core.scrollRequest.sequence, before)
        let after = core.scrollRequest.sequence
        core.typingChanged(["Atum"])
        XCTAssertEqual(core.scrollRequest.sequence, after, "only the appearance moves the view")
    }

    // MARK: Read (B13, B15)

    private func at(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }

    /// The bottom is visible: the receipt after the 300 ms settle.
    private func readBottom(_ core: inout ConversationCore, at seconds: Double = 0) -> [ConversationEffect] {
        let wake = core.setBottomVisible(true, now: at(seconds))
        XCTAssertEqual(wake, [.wakeReadGate(at: at(seconds + ReadPolicy.settleSeconds))])
        return core.readWakeDue(now: at(seconds + ReadPolicy.settleSeconds))
    }

    func testNothingIsReadUntilTheBottomIsVisibleThenAfterTheSettle() {
        var core = attachedCore([F.mine("q"), F.text("a", from: F.agent)])
        XCTAssertEqual(core.readWakeDue(now: at(5)), [], "scrolled up: nothing")
        XCTAssertEqual(readBottom(&core), [.markReadPrivate])
        XCTAssertEqual(core.receiptFinished(succeeded: true, now: at(0.4)), [])
        XCTAssertEqual(core.setBottomVisible(true, now: at(1)), [], "already read up to the newest event")
        _ = core.setBottomVisible(false, now: at(2))
        _ = core.receive(projection([F.mine("q"), F.text("a", from: F.agent), F.text("b", from: F.agent)],
                                    change: .appendedAtEnd(count: 1, localEcho: false)), now: at(3))
        XCTAssertEqual(readBottom(&core, at: 4), [.markReadPrivate], "a newer event is unread again")
    }

    func testAMessageStillOnItsWayIsNeverAcknowledged() {
        var core = attachedCore([F.echo("e")])
        XCTAssertEqual(core.setBottomVisible(true, now: now), [], "a receipt must name an event the server knows")
    }

    func testABurstBecomesOneReceiptNeverLaterThanTwoSeconds() {
        var core = attachedCore([F.text("a0", from: F.agent)])
        XCTAssertEqual(core.setBottomVisible(true, now: now), [.wakeReadGate(at: at(0.3))])
        var items = [F.text("a0", from: F.agent)]
        var lastWake = [ConversationEffect]()
        for step in 1...9 {
            items.append(F.text("a\(step)", from: F.agent))
            lastWake = core.receive(projection(items, change: .appendedAtEnd(count: 1, localEcho: false)),
                                    now: at(Double(step) * 0.2))
        }
        XCTAssertEqual(lastWake, [.wakeReadGate(at: at(ReadPolicy.maximumWaitSeconds))],
                       "each arrival postpones it, never past 2 s after the first")
        XCTAssertEqual(core.readWakeDue(now: at(ReadPolicy.maximumWaitSeconds)), [.markReadPrivate])
    }

    func testNothingIsReadWhileDetached() {
        var core = attachedCore([F.text("a", from: F.agent)])
        _ = core.setBottomVisible(true, now: now)
        core.detached()
        XCTAssertEqual(core.readWakeDue(now: at(1)), [], "no timeline: no receipt")
    }

    func testFullyReadGoesOutOnLeavingOnlyForWhatAReceiptAcknowledged() {
        var unread = attachedCore([F.text("a", from: F.agent)])
        XCTAssertEqual(unread.leaving(), [], "scrolled up the whole visit")
        var inFlight = attachedCore([F.text("a", from: F.agent)])
        XCTAssertEqual(readBottom(&inFlight), [.markReadPrivate])
        XCTAssertEqual(inFlight.leaving(), [], "a receipt still on its way acknowledged nothing yet")
        var read = attachedCore([F.text("a", from: F.agent)])
        XCTAssertEqual(readBottom(&read), [.markReadPrivate])
        _ = read.receiptFinished(succeeded: true, now: at(0.5))
        _ = read.setBottomVisible(false, now: at(1))
        _ = read.receive(projection([F.text("a", from: F.agent), F.text("b", from: F.agent)],
                                    change: .appendedAtEnd(count: 1, localEcho: false)), now: at(2))
        XCTAssertEqual(read.leaving(), [.markFullyRead(eventID: "$a")],
                       "by event ID: what arrived while scrolled up stays unread")
        XCTAssertEqual(read.leaving(), [], "once per event")
    }

    func testAFailedReceiptIsRetriedOnTheReadPolicysSchedule() {
        var core = attachedCore([F.text("a", from: F.agent)])
        XCTAssertEqual(readBottom(&core), [.markReadPrivate])
        var clock = at(ReadPolicy.settleSeconds)
        for delay in ReadPolicy.retrySeconds {
            let retryAt = clock.addingTimeInterval(delay)
            XCTAssertEqual(core.receiptFinished(succeeded: false, now: clock), [.wakeReadGate(at: retryAt)])
            XCTAssertEqual(core.readWakeDue(now: retryAt), [.markReadPrivate], "the Mac badge clears once back online")
            clock = retryAt
        }
        XCTAssertEqual(core.receiptFinished(succeeded: false, now: clock), [], "then it waits for the next change")
    }

    func testAMarkUnreadFromAnotherDeviceSchedulesAReceiptWithoutANewMessage() {
        var core = attachedCore([F.text("a", from: F.agent)])
        XCTAssertEqual(readBottom(&core), [.markReadPrivate])
        XCTAssertEqual(core.receiptFinished(succeeded: true, now: at(0.4)), [])

        XCTAssertEqual(core.markedUnreadChanged(true, now: at(1)),
                       [.wakeReadGate(at: at(1 + ReadPolicy.settleSeconds))])
        XCTAssertEqual(core.readWakeDue(now: at(1 + ReadPolicy.settleSeconds)), [.markReadPrivate])
    }

    // MARK: Reply details (B21)

    func testUnavailableReplyDetailsAreFetchedOncePerAttach() {
        var core = core()
        _ = core.attached(now: now)
        let items = [F.text("r", from: F.friend, replyTo: "$gone")]
        let details = ["r": ChatReplyDetails(eventID: "$gone", state: .unavailable)]
        XCTAssertEqual(core.receive(projection(items, replyDetails: details), now: now),
                       [.fetchReplyDetails(eventID: "$r")])
        XCTAssertEqual(core.receive(projection(items, change: .inPlace, replyDetails: details), now: now), [])
        core.detached()
        _ = core.attached(now: now)
        XCTAssertEqual(core.receive(projection(items, replyDetails: details), now: now),
                       [.fetchReplyDetails(eventID: "$r")], "a new timeline asks again")
    }
}

/// The renewal handover inside the core: the kept rows act like any other
/// row, and the new timeline pages back until it reaches them.
final class ConversationCoreHandoverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func projection(_ items: [ChatItem], change: SnapshotChange = .reset) -> ProjectedTimeline {
        ProjectedTimeline(snapshot: Snapshot(rows: Projection.rows(items, context: F.assistantRoom(), options: .s1),
                                             change: change, generation: 2),
                          nextNoAnswerChange: nil, sequence: 1)
    }

    /// A person reading history (scrolled up) when the session is renewed.
    private func readingCore() -> ConversationCore {
        var core = ConversationCore(context: F.assistantRoom())
        _ = core.attached(now: now)
        _ = core.receive(projection([F.mine("a"), F.text("b", from: F.agent), F.mine("c"),
                                     F.text("d", from: F.agent)]), now: now)
        _ = core.handle(.geometry(distanceFromBottom: 900, distanceFromTop: 0, viewportHeight: 800, motion: .user),
                        now: now)
        core.detached()
        _ = core.attached(now: now)
        return core
    }

    func testKeptRowsStayAndTheirActionsWork() {
        var core = readingCore()
        _ = core.receive(projection([F.mine("c"), F.text("d", from: F.agent)]), now: now)
        XCTAssertEqual(F.ids(core.snapshot.rows), ["a", "b", "c", "d"], "nothing above the reader vanished")
        XCTAssertEqual(core.toggleReaction("b", key: "👍"), [.toggleReaction(.event("$b"), key: "👍")])
        XCTAssertTrue(core.reply(to: "b"))
        XCTAssertEqual(core.snapshot.rows.map(\.grouping.position), [.single, .single, .single, .single],
                       "the kept rows are laid out with the new ones")
    }

    func testTheNewTimelinePagesBackUntilItReachesTheKeptRows() {
        var core = readingCore()
        let first = core.receive(projection([F.mine("c"), F.text("d", from: F.agent)]), now: now)
        XCTAssertTrue(first.contains(.paginateBackwards(events: 20)), "nobody has to scroll for it")
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [.paginateBackwards(events: 20)],
                       "still short of the kept rows: the next page")
        let caughtUp = core.receive(projection([F.mine("a"), F.text("b", from: F.agent), F.mine("c"),
                                                F.text("d", from: F.agent)], change: .prependedAtStart(count: 2)),
                                    now: now)
        XCTAssertFalse(caughtUp.contains(.paginateBackwards(events: 20)))
        XCTAssertEqual(core.paginationFinished(hitTimelineStart: false, now: now), [], "the handover is over")
    }

    func testAnEmptyNewTimelineKeepsTheRowsEvenWhileFollowing() {
        var core = ConversationCore(context: F.assistantRoom())
        _ = core.attached(now: now)
        _ = core.receive(projection([F.mine("a"), F.text("b", from: F.agent)]), now: now)
        XCTAssertTrue(core.follow.isFollowing)
        core.detached()
        _ = core.attached(now: now)
        _ = core.receive(projection([]), now: now)
        XCTAssertEqual(F.ids(core.snapshot.rows), ["a", "b"], "never blank")
        _ = core.receive(projection([F.text("b", from: F.agent)]), now: now)
        XCTAssertEqual(F.ids(core.snapshot.rows), ["b"], "following: the new timeline as it is")
    }
}

/// A renewed session's timeline catching up under a person reading history.
final class SessionHandoverTests: XCTestCase {
    private func rows(_ items: [ChatItem]) -> [ChatRow] { items.map { ChatRow(item: $0) } }

    func testOlderRowsStayAboveTheNewTimelineUntilItReachesThem() {
        let old = rows([F.divider("virtual.1"), F.mine("a"), F.text("b", from: F.agent), F.divider("virtual.2"),
                        F.mine("c"), F.text("d", from: F.agent)])
        let incoming = rows([F.divider("virtual.9"), F.mine("c"), F.text("d", from: F.agent)])
        XCTAssertEqual(F.ids(SessionHandover.rows(displayed: old, incoming: incoming) ?? []),
                       ["virtual.1", "a", "b", "virtual.2", "c", "d"],
                       "the new timeline's own divider for that day is not shown twice")
        let caughtUp = rows([F.divider("virtual.8"), F.mine("a"), F.text("b", from: F.agent), F.divider("virtual.9"),
                             F.mine("c"), F.text("d", from: F.agent)])
        XCTAssertNil(SessionHandover.rows(displayed: old, incoming: caughtUp))
    }

    func testNoSharedEventEndsTheHandoverAndAnEmptyTimelineNeverBlanks() {
        let old = rows([F.mine("a"), F.text("b", from: F.agent)])
        XCTAssertNil(SessionHandover.rows(displayed: old, incoming: rows([F.mine("x")])))
        XCTAssertEqual(F.ids(SessionHandover.rows(displayed: old, incoming: []) ?? []), ["a", "b"])
        XCTAssertNil(SessionHandover.rows(displayed: [], incoming: []))
    }

    func testOldSyntheticRowsAreNotCarriedOver() {
        let loading = ChatItem(id: Projection.loadingEarlierRowID, kind: .loadingEarlier)
        let typing = ChatItem(id: Projection.typingRowID, kind: .typing(names: ["Atum"]))
        let old = rows([loading, F.mine("a"), F.mine("b"), typing])
        XCTAssertEqual(F.ids(SessionHandover.rows(displayed: old, incoming: rows([F.mine("b")])) ?? []), ["a", "b"])
    }

    func testAnIDTheNewTimelineAlsoShowsIsNotShownTwice() {
        let old = rows([F.mine("a"), F.readMarker("virtual.read-marker"), F.mine("b"), F.mine("c")])
        let incoming = rows([F.mine("b"), F.readMarker("virtual.read-marker"), F.mine("c")])
        XCTAssertEqual(F.ids(SessionHandover.rows(displayed: old, incoming: incoming) ?? []),
                       ["a", "b", "virtual.read-marker", "c"])
    }

    func testANewTimelineWithOnlyItsLoadingRowKeepsTheOldRows() {
        let loading = ChatItem(id: Projection.loadingEarlierRowID, kind: .loadingEarlier)
        let old = rows([F.mine("a"), F.mine("b")])
        XCTAssertEqual(F.ids(SessionHandover.rows(displayed: old, incoming: rows([loading]), following: true) ?? []),
                       ["a", "b"])
        XCTAssertNil(SessionHandover.rows(displayed: old, incoming: rows([F.mine("b")]), following: true),
                     "following: older rows do not matter once the new timeline has events")
    }
}
