import XCTest
@testable import AtumChat

/// B13 and B15: private receipts when the bottom is visible, with the 300 ms
/// settle and the 2 s cap; nothing while detached; `.fullyRead` on leaving.
final class ReadPolicyTests: XCTestCase {
    private func assertDeadline(_ policy: ReadPolicy, _ expected: TimeInterval,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let deadline = policy.nextDeadline else {
            return XCTFail("no deadline, expected \(expected)", file: file, line: line)
        }
        XCTAssertEqual(deadline, expected, accuracy: 1e-9, file: file, line: line)
    }

    private func reading(_ eventID: String = "$a", at now: TimeInterval = 0) -> ReadPolicy {
        var policy = ReadPolicy()
        policy.latestEventChanged(eventID, now: now)
        policy.setBottomVisible(true, now: now)
        return policy
    }

    func testTheReceiptGoesOutAfterTheSettle() {
        var policy = reading()
        assertDeadline(policy, 0.3)
        XCTAssertNil(policy.tick(now: 0.29))
        XCTAssertEqual(policy.tick(now: 0.3), .privateReceipt(eventID: "$a", clearsUnreadFlag: false))
        XCTAssertEqual(policy.inFlight, "$a")
    }

    func testEachNewEventPostponesItButNeverPastTwoSeconds() {
        var policy = reading("$0", at: 0)
        var now = 0.0
        for index in 1...8 {
            now += 0.25
            policy.latestEventChanged("$\(index)", now: now)
            XCTAssertLessThanOrEqual(policy.nextDeadline ?? .infinity, 2, "a stream is acknowledged within 2 s")
        }
        assertDeadline(policy, 2)
        XCTAssertEqual(policy.tick(now: 2), .privateReceipt(eventID: "$8", clearsUnreadFlag: false))
    }

    func testNothingIsSentWhileDetachedAndItGoesOutOnReachingTheBottom() {
        var policy = ReadPolicy()
        policy.latestEventChanged("$a", now: 0)
        XCTAssertNil(policy.nextDeadline, "scrolled up: nothing scheduled")
        XCTAssertNil(policy.tick(now: 5))
        policy.setBottomVisible(true, now: 5)
        policy.setBottomVisible(false, now: 5.1)
        XCTAssertNil(policy.nextDeadline, "leaving the bottom cancels the pending receipt")
        XCTAssertNil(policy.tick(now: 6))
        policy.latestEventChanged("$b", now: 7)
        XCTAssertNil(policy.nextDeadline, "new messages while scrolled up send nothing")
        policy.setBottomVisible(true, now: 8)
        XCTAssertEqual(policy.tick(now: 8.3), .privateReceipt(eventID: "$b", clearsUnreadFlag: false))
    }

    func testAnAcknowledgedEventIsNotAcknowledgedAgain() {
        var policy = reading()
        _ = policy.tick(now: 0.3)
        policy.finished(succeeded: true, now: 0.5)
        XCTAssertEqual(policy.acknowledgedEventID, "$a")
        XCTAssertNil(policy.nextDeadline)
        policy.setBottomVisible(false, now: 1)
        policy.setBottomVisible(true, now: 2)
        XCTAssertNil(policy.nextDeadline, "back at the bottom with nothing new")
    }

    func testOneRequestAtATimeAndANewerEventFollowsWhenItFinishes() {
        var policy = reading()
        _ = policy.tick(now: 0.3)
        policy.latestEventChanged("$b", now: 0.4)
        XCTAssertNil(policy.nextDeadline, "no second request while one is in flight")
        policy.finished(succeeded: true, now: 0.6)
        assertDeadline(policy, 0.9)
        XCTAssertEqual(policy.tick(now: 0.9), .privateReceipt(eventID: "$b", clearsUnreadFlag: false))
    }

    func testAFailedReceiptRetriesThreeTimesThenWaitsForTheNextChange() {
        var policy = reading()
        var now = 0.3
        XCTAssertNotNil(policy.tick(now: now))
        for delay in ReadPolicy.retrySeconds {
            policy.finished(succeeded: false, now: now)
            assertDeadline(policy, now + delay)
            now += delay
            XCTAssertEqual(policy.tick(now: now), .privateReceipt(eventID: "$a", clearsUnreadFlag: false))
        }
        policy.finished(succeeded: false, now: now)
        XCTAssertNil(policy.nextDeadline, "gave up until something changes")
        policy.latestEventChanged("$b", now: now + 1)
        assertDeadline(policy, now + 1.3)
    }

    func testARoomMarkedUnreadIsClearedWithTheReceipt() {
        var policy = reading()
        _ = policy.tick(now: 0.3)
        policy.finished(succeeded: true, now: 0.4)
        policy.setMarkedUnread(true, now: 5)
        XCTAssertEqual(policy.tick(now: 5.3), .privateReceipt(eventID: "$a", clearsUnreadFlag: true),
                       "marked unread on the Mac while reading here")
        policy.finished(succeeded: true, now: 5.4)
        XCTAssertFalse(policy.markedUnread)
        XCTAssertNil(policy.nextDeadline)
    }

    func testAMarkUnreadThatArrivesWhileAReceiptIsInFlightIsClearedByAFollowUp() {
        var policy = reading()
        XCTAssertEqual(policy.tick(now: 0.3), .privateReceipt(eventID: "$a", clearsUnreadFlag: false))
        policy.setMarkedUnread(true, now: 0.35)
        XCTAssertNil(policy.nextDeadline, "still one request at a time")
        policy.finished(succeeded: true, now: 0.4)
        XCTAssertTrue(policy.markedUnread, "the receipt in flight did not clear the flag")
        assertDeadline(policy, 0.7)
        XCTAssertEqual(policy.tick(now: 0.7), .privateReceipt(eventID: "$a", clearsUnreadFlag: true))
        policy.finished(succeeded: true, now: 0.8)
        XCTAssertFalse(policy.markedUnread)
        XCTAssertNil(policy.nextDeadline)
    }

    func testMarkedUnreadAgainDuringAClearingReceiptIsNotForgotten() {
        var policy = reading()
        policy.setMarkedUnread(true, now: 0)
        XCTAssertEqual(policy.tick(now: 0.3), .privateReceipt(eventID: "$a", clearsUnreadFlag: true))
        // RoomInfo reports our own clear, then the Mac marks it unread again.
        policy.setMarkedUnread(false, now: 0.35)
        policy.setMarkedUnread(true, now: 0.38)
        policy.finished(succeeded: true, now: 0.4)
        XCTAssertTrue(policy.markedUnread)
        XCTAssertEqual(policy.tick(now: 0.7), .privateReceipt(eventID: "$a", clearsUnreadFlag: true))
    }

    func testLeavingMovesTheFullyReadMarkerToWhatWasReadOnce() {
        var policy = ReadPolicy()
        XCTAssertNil(policy.leave(), "nothing read, nothing to mark")
        policy = reading()
        _ = policy.tick(now: 0.3)
        policy.finished(succeeded: true, now: 0.4)
        XCTAssertEqual(policy.leave(), .fullyRead(eventID: "$a"))
        XCTAssertNil(policy.leave())
        XCTAssertFalse(policy.bottomVisible)
    }

    func testTheLatestSettledEventSkipsEchoesStillOnTheirWayAndVirtualRows() {
        let items = [
            F.text("a", from: F.agent),
            F.mine("b"),
            F.echo("c", delivery: .sent(eventID: "$c-server")),
            F.echo("d", delivery: .sending()),
            F.echo("e", delivery: .failed(isRecoverable: true)),
            F.readMarker()
        ]
        XCTAssertEqual(ReadPolicy.latestSettledEventID(in: items), "$c-server",
                       "an accepted echo counts by its server event ID")
        XCTAssertEqual(ReadPolicy.latestSettledEventID(in: Array(items.prefix(2))), "$b")
        XCTAssertNil(ReadPolicy.latestSettledEventID(in: [F.echo("x"), F.start()]))
    }
}
