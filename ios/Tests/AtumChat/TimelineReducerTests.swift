import XCTest
@testable import AtumChat

/// Plan S1a T: all 11 diff kinds on the buffer, `truncate`, `clear` and
/// `reset` included, and the change kind each batch reports (§2.3 rules 4-5).
final class TimelineReducerTests: XCTestCase {
    private func buffer(_ ids: String...) -> TimelineBuffer {
        TimelineBuffer(items: ids.map { F.text($0, from: F.agent) })
    }

    // MARK: The 11 diff kinds

    func testAppendAddsAtTheEnd() throws {
        var b = buffer("a")
        let change = try b.apply([.append([F.text("b", from: F.agent), F.notice("c", from: F.agent)])])
        XCTAssertEqual(F.ids(b.items), ["a", "b", "c"])
        XCTAssertEqual(change, .appendedAtEnd(count: 1, localEcho: false), "the notice is not counted")
    }

    func testClearEmptiesTheBufferAndIsAReset() throws {
        var b = buffer("a", "b")
        XCTAssertEqual(try b.apply([.clear]), .reset)
        XCTAssertTrue(b.items.isEmpty)
    }

    func testPushFrontPrepends() throws {
        var b = buffer("b")
        XCTAssertEqual(try b.apply([.pushFront(F.text("a", from: F.agent))]), .prependedAtStart(count: 1))
        XCTAssertEqual(F.ids(b.items), ["a", "b"])
    }

    func testPushFrontIntoAnEmptyBufferIsAnAppend() throws {
        var b = TimelineBuffer()
        XCTAssertEqual(try b.apply([.pushFront(F.text("a", from: F.agent))]),
                       .appendedAtEnd(count: 1, localEcho: false))
    }

    func testPushBackAppends() throws {
        var b = buffer("a")
        XCTAssertEqual(try b.apply([.pushBack(F.text("b", from: F.friend))]),
                       .appendedAtEnd(count: 1, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["a", "b"])
    }

    func testPopFrontAndPopBackRemoveTheEnds() throws {
        var b = buffer("a", "b", "c")
        XCTAssertEqual(try b.apply([.popFront]), .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["b", "c"])
        XCTAssertEqual(try b.apply([.popBack]), .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["b"])
    }

    func testInsertAtTheStartMiddleAndEnd() throws {
        var b = buffer("b", "d")
        XCTAssertEqual(try b.apply([.insert(index: 0, item: F.text("a", from: F.agent))]),
                       .prependedAtStart(count: 1))
        XCTAssertEqual(try b.apply([.insert(index: 2, item: F.text("c", from: F.agent))]),
                       .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(try b.apply([.insert(index: 4, item: F.text("e", from: F.agent))]),
                       .appendedAtEnd(count: 1, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["a", "b", "c", "d", "e"])
    }

    func testSetReplacesInPlace() throws {
        var b = buffer("a", "b")
        var edited = F.text("b", from: F.agent, "edited")
        edited.isEdited = true
        XCTAssertEqual(try b.apply([.set(index: 1, item: edited)]), .inPlace)
        XCTAssertEqual(b.items[1].body, "edited")
        XCTAssertEqual(b.items.count, 2)
    }

    func testRemoveDropsOneIndex() throws {
        var b = buffer("a", "b", "c")
        XCTAssertEqual(try b.apply([.remove(index: 1)]), .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["a", "c"])
    }

    func testTruncateKeepsTheFirstItems() throws {
        var b = buffer("a", "b", "c", "d")
        XCTAssertEqual(try b.apply([.truncate(length: 2)]), .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["a", "b"])
        XCTAssertEqual(try b.apply([.truncate(length: 2)]), .inPlace, "truncating to the current length changes nothing")
        XCTAssertEqual(try b.apply([.truncate(length: 0)]), .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertTrue(b.items.isEmpty)
    }

    func testResetReplacesEverything() throws {
        var b = buffer("a", "b")
        XCTAssertEqual(try b.apply([.reset([F.text("x", from: F.agent)])]), .reset)
        XCTAssertEqual(F.ids(b.items), ["x"])
    }

    // MARK: Batches

    func testAppliesABatchInOrder() throws {
        var b = TimelineBuffer()
        try b.apply([.reset([F.text("a", from: F.agent)]), .pushBack(F.text("b", from: F.agent)),
                     .insert(index: 1, item: F.text("ab", from: F.agent)), .remove(index: 0),
                     .pushFront(F.text("z", from: F.agent)), .set(index: 2, item: F.text("b2", from: F.agent))])
        XCTAssertEqual(F.ids(b.items), ["z", "ab", "b2"])
    }

    func testAnOutOfRangeIndexLeavesTheBufferUntouched() {
        for bad: ChatDiff in [.set(index: 2, item: F.text("x", from: F.agent)), .remove(index: 2),
                              .insert(index: 3, item: F.text("x", from: F.agent)), .truncate(length: 3),
                              .set(index: -1, item: F.text("x", from: F.agent))] {
            var b = buffer("a", "b")
            XCTAssertThrowsError(try b.apply([.pushBack(F.text("c", from: F.agent)), .popFront, bad])) { error in
                XCTAssertEqual(error as? TimelineReducerError, .indexOutOfRange(diffIndex: 2))
            }
            XCTAssertEqual(F.ids(b.items), ["a", "b"], "\(bad) must not half-apply its batch")
        }
        var empty = TimelineBuffer()
        XCTAssertThrowsError(try empty.apply([.popFront]))
        XCTAssertThrowsError(try empty.apply([.popBack]))
    }

    func testIndicesStayAlignedWithTheSDKListWhatTheProjectionHides() throws {
        // A divider and a superseded notice take buffer indices even though the
        // S1a projection hides them; a later `set` at the SDK index still lands.
        var b = TimelineBuffer()
        try b.apply([.reset([F.divider("d"), F.mine("q"), F.notice("n", from: F.agent, replyTo: "$q"),
                             F.text("a", from: F.agent, "answer", replyTo: "$q")])])
        try b.apply([.set(index: 3, item: F.text("a", from: F.agent, "answer v2", replyTo: "$q"))])
        XCTAssertEqual(b.items[3].body, "answer v2")
        XCTAssertEqual(b.items.count, 4)
    }

    // MARK: Change kind

    func testALocalEchoAppendIsMarkedAndNotCounted() throws {
        var b = buffer("a")
        XCTAssertEqual(try b.apply([.pushBack(F.echo("e"))]), .appendedAtEnd(count: 0, localEcho: true))
    }

    func testMyMessageFromAnotherDeviceCountsLikeAnyoneElses() throws {
        var b = buffer("a")
        XCTAssertEqual(try b.apply([.pushBack(F.mine("m"))]), .appendedAtEnd(count: 1, localEcho: false))
    }

    func testSetsAlongsideAnAppendKeepTheAppendCount() throws {
        // A new message often comes with receipts moving off the previous item.
        var b = buffer("a", "b")
        let change = try b.apply([.set(index: 1, item: F.text("b", from: F.agent)),
                                  .pushBack(F.text("c", from: F.agent))])
        XCTAssertEqual(change, .appendedAtEnd(count: 1, localEcho: false))
    }

    func testSetsAlongsideAPrependKeepThePrependKind() throws {
        var b = buffer("b")
        let change = try b.apply([.pushFront(F.text("a", from: F.agent)), .set(index: 1, item: F.text("b", from: F.agent))])
        XCTAssertEqual(change, .prependedAtStart(count: 1))
    }

    func testBothEndsOrRemovalsWithAnAppendAreMixedAndKeepTheCount() throws {
        var b = buffer("b")
        XCTAssertEqual(try b.apply([.pushFront(F.text("a", from: F.agent)), .pushBack(F.text("c", from: F.agent))]),
                       .mixed(appendedAtEnd: 1, localEcho: false))
        XCTAssertEqual(try b.apply([.popBack, .pushBack(F.echo("c2"))]),
                       .mixed(appendedAtEnd: 0, localEcho: true))
    }

    func testAResetAnywhereInTheBatchWins() throws {
        var b = buffer("a")
        XCTAssertEqual(try b.apply([.pushBack(F.text("b", from: F.agent)), .clear,
                                    .append([F.text("c", from: F.agent)])]), .reset)
        XCTAssertEqual(F.ids(b.items), ["c"])
    }

    func testAnEmptyBatchIsInPlace() throws {
        var b = buffer("a")
        XCTAssertEqual(try b.apply([]), .inPlace)
    }

    // MARK: Change kind against the SDK's real shapes

    func testAnIncomingMessageAbovePendingOrFailedEchoesIsAnAppend() throws {
        // matrix-sdk-ui keeps local echoes at the bottom and inserts remote
        // events above them, so the answer arrives as insert(count - 1).
        for parked in [ChatDelivery.sending(), .failed(isRecoverable: true), .failed(isRecoverable: false),
                       .sent(eventID: "$f")] {
            var b = TimelineBuffer(items: [F.mine("q"), F.echo("f", delivery: parked)])
            let change = try b.apply([.insert(index: 1, item: F.text("a", from: F.agent, replyTo: "$q"))])
            XCTAssertEqual(change, .appendedAtEnd(count: 1, localEcho: false), "\(parked)")
            XCTAssertEqual(F.ids(b.items), ["q", "a", "f"])
        }
        var two = TimelineBuffer(items: [F.mine("q"), F.echo("f1"), F.echo("f2")])
        XCTAssertEqual(try two.apply([.insert(index: 1, item: F.text("a", from: F.friend)),
                                      .insert(index: 2, item: F.notice("n", from: F.agent))]),
                       .appendedAtEnd(count: 1, localEcho: false), "the notice rides along, uncounted")
    }

    func testTheRemoteCopyOfMyEchoMovedAboveAnotherEchoIsNotANewMessage() throws {
        // When the echo is not last, the SDK removes it and re-inserts its
        // remote copy above the remaining echoes, under the same unique ID.
        var b = TimelineBuffer(items: [F.text("a", from: F.agent), F.echo("e1", delivery: .sent(eventID: "$e1")),
                                       F.echo("e2")])
        let remote = F.mine("e1") // same ID, now from the server
        let change = try b.apply([.remove(index: 1), .insert(index: 1, item: remote)])
        XCTAssertEqual(change, .mixed(appendedAtEnd: 0, localEcho: false))
        XCTAssertEqual(FollowInput.from(change), .inPlaceEdit, "the pill never counts my own send")
        XCTAssertEqual(F.ids(b.items), ["a", "e1", "e2"])
    }

    func testBackPaginationWithTheDividerShuffleIsAPrepend() throws {
        // The date-divider adjuster drops the old first divider and adds a
        // new one at the top in the same batch as the older events.
        var b = TimelineBuffer(items: [F.divider("d1"), F.text("x", from: F.agent), F.mine("y")])
        let change = try b.apply([.pushFront(F.text("o1", from: F.agent)), .pushFront(F.mine("o2")),
                                  .remove(index: 2), .pushFront(F.divider("d0"))])
        XCTAssertEqual(change, .prependedAtStart(count: 3))
        XCTAssertEqual(F.ids(b.items), ["d0", "o2", "o1", "x", "y"])
    }

    func testTheStartItemAddedAtTheTopIsAPrepend() throws {
        var b = buffer("a", "b")
        XCTAssertEqual(try b.apply([.pushFront(F.start())]), .prependedAtStart(count: 1))
    }

    func testANewDayMessageWithItsDividerIsAnAppend() throws {
        var b = buffer("x")
        XCTAssertEqual(try b.apply([.pushBack(F.text("n", from: F.friend)), .insert(index: 1, item: F.divider("d"))]),
                       .appendedAtEnd(count: 1, localEcho: false))
        XCTAssertEqual(F.ids(b.items), ["x", "d", "n"])
    }

    func testVirtualItemsMovingInTheMiddleChangeNothing() throws {
        var b = TimelineBuffer(items: [F.text("a", from: F.agent), F.readMarker(), F.text("b", from: F.agent),
                                       F.text("c", from: F.agent)])
        XCTAssertEqual(try b.apply([.remove(index: 1), .insert(index: 2, item: F.readMarker())]), .inPlace)
        XCTAssertEqual(F.ids(b.items), ["a", "b", "read-marker", "c"])
        XCTAssertEqual(try b.apply([.remove(index: 2)]), .inPlace)
    }

    func testAMiddleInsertBetweenOldMessagesIsStillMixed() throws {
        var b = TimelineBuffer(items: [F.text("a", from: F.agent), F.text("c", from: F.agent), F.echo("e")])
        XCTAssertEqual(try b.apply([.insert(index: 1, item: F.text("b", from: F.agent))]),
                       .mixed(appendedAtEnd: 0, localEcho: false))
    }

    func testWithNothingButMyOwnEchoesEverythingIsAnAppend() throws {
        var b = TimelineBuffer(items: [F.echo("e")])
        XCTAssertEqual(try b.apply([.insert(index: 0, item: F.text("a", from: F.agent))]),
                       .appendedAtEnd(count: 1, localEcho: false))
    }

    func testRemovingMyFailedEchoIsStructural() throws {
        var b = TimelineBuffer(items: [F.text("a", from: F.agent), F.echo("f", delivery: .failed(isRecoverable: false))])
        XCTAssertEqual(try b.apply([.remove(index: 1)]), .mixed(appendedAtEnd: 0, localEcho: false))
    }

    func testTheProbeShapeIsContentFree() {
        let shape = ChatDiff.probeShape([.insert(index: 1, item: F.text("a", from: F.agent, "secret")),
                                         .set(index: 2, item: F.echo("e", "secret")), .pushFront(F.divider("d")),
                                         .append([F.mine("m"), F.mine("n")]), .remove(index: 0), .truncate(length: 3),
                                         .popBack, .reset([]), .clear])
        XCTAssertEqual(shape, "insert@1:remote,set@2:echo,pushFront:virtual,append×2,remove@0,truncate@3,popBack,reset×0,clear")
        XCTAssertFalse(shape.contains("secret"))
    }
}
