import XCTest
@testable import AtumNativeAPI

/// Behaviour contracts for the 2026-10-10 phone chat hotfix: session
/// keep-alive timing, failed-send recovery, instant-send draft handling and
/// transcript following.
final class ChatSessionPolicyTests: XCTestCase {
    private typealias KeepAlive = MobileMatrixSessionKeepAlivePolicy
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Keep-alive

    func testKeepAliveWaitsUntilTheLeadBeforeExpiry() {
        let expiresAt = now.addingTimeInterval(300)
        XCTAssertFalse(KeepAlive.needsRefresh(expiresAt: expiresAt, now: now))
        XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: nil),
                       .wait(seconds: 300 - KeepAlive.refreshLeadSeconds))
    }

    func testKeepAliveRenewsInsideTheLeadAndWhenExpired() {
        for remaining in [KeepAlive.refreshLeadSeconds, 1, 0, -120] {
            let expiresAt = now.addingTimeInterval(remaining)
            XCTAssertTrue(KeepAlive.needsRefresh(expiresAt: expiresAt, now: now), "\(remaining)")
            XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: nil),
                           .renewNow, "\(remaining)")
        }
    }

    func testKeepAliveNeverWakesSoonerThanTheMinimum() {
        let expiresAt = now.addingTimeInterval(KeepAlive.refreshLeadSeconds + 1)
        XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: nil),
                       .wait(seconds: KeepAlive.minimumWaitSeconds))
    }

    func testKeepAliveSpacesAttemptsSoOfflineOrShortGrantsCannotSpin() {
        let expiresAt = now.addingTimeInterval(10)
        let recent = now.addingTimeInterval(-10)
        XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: recent),
                       .wait(seconds: KeepAlive.attemptSpacingSeconds - 10))
        let old = now.addingTimeInterval(-KeepAlive.attemptSpacingSeconds)
        XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: old), .renewNow)
        // A clock that moved backwards does not block renewal.
        let future = now.addingTimeInterval(60)
        XCTAssertEqual(KeepAlive.nextStep(expiresAt: expiresAt, now: now, lastAttemptAt: future), .renewNow)
    }

    func testFollowingThePolicyRenewsInsideTheLeadAndBeforeExpiry() {
        // Invariant: for any grant longer than the lead, a loop that obeys the
        // policy only ever waits a positive time and renews while the token
        // still has between 0 and `refreshLeadSeconds` left.
        for lifetime in stride(from: KeepAlive.refreshLeadSeconds + 1, through: 3_600, by: 37) {
            let expiresAt = now.addingTimeInterval(lifetime)
            var clock = now
            var steps = 0
            while case let .wait(seconds) = KeepAlive.nextStep(expiresAt: expiresAt, now: clock,
                                                               lastAttemptAt: nil) {
                XCTAssertGreaterThan(seconds, 0)
                clock = clock.addingTimeInterval(seconds)
                steps += 1
                guard steps < 10 else { return XCTFail("lifetime \(lifetime) never renews") }
            }
            let remaining = expiresAt.timeIntervalSince(clock)
            XCTAssertGreaterThan(remaining, 0, "lifetime \(lifetime)")
            XCTAssertLessThanOrEqual(remaining, KeepAlive.refreshLeadSeconds, "lifetime \(lifetime)")
        }
    }

    func testInvalidSessionRenewsOnlyForForegroundExpiry() {
        let expired = now.addingTimeInterval(-1)
        let valid = now.addingTimeInterval(30)
        XCTAssertTrue(KeepAlive.renewsInvalidSession(expiresAt: expired, now: now, isForeground: true,
                                                     lastAttemptAt: nil))
        XCTAssertFalse(KeepAlive.renewsInvalidSession(expiresAt: expired, now: now, isForeground: false,
                                                      lastAttemptAt: nil))
        XCTAssertFalse(KeepAlive.renewsInvalidSession(expiresAt: valid, now: now, isForeground: true,
                                                      lastAttemptAt: nil),
                       "an invalid session that has not expired is a custody decision, not a renewal")
        XCTAssertFalse(KeepAlive.renewsInvalidSession(expiresAt: expired, now: now, isForeground: true,
                                                      lastAttemptAt: now.addingTimeInterval(-5)))
    }

    // MARK: Failed sends

    func testRetryMapsRecoverableToTheRoomQueueAndParkedToAnItemRetry() {
        XCTAssertEqual(MobileSendRecoveryPolicy.retryAction(isRecoverable: true), .enableRoomQueue)
        XCTAssertEqual(MobileSendRecoveryPolicy.retryAction(isRecoverable: false), .retryParkedRequest)
    }

    func testOnlyATokenParkedRequestIsRetriedWithoutAskingAndOnlyOnce() {
        XCTAssertTrue(MobileSendRecoveryPolicy.autoRetriesAfterRenewal(failureIsExpiredToken: true,
                                                                       isRecoverable: false,
                                                                       alreadyRetried: false))
        XCTAssertFalse(MobileSendRecoveryPolicy.autoRetriesAfterRenewal(failureIsExpiredToken: true,
                                                                        isRecoverable: false,
                                                                        alreadyRetried: true))
        XCTAssertFalse(MobileSendRecoveryPolicy.autoRetriesAfterRenewal(failureIsExpiredToken: false,
                                                                        isRecoverable: false,
                                                                        alreadyRetried: false))
        XCTAssertFalse(MobileSendRecoveryPolicy.autoRetriesAfterRenewal(failureIsExpiredToken: true,
                                                                        isRecoverable: true,
                                                                        alreadyRetried: false))
    }

    // MARK: Instant send

    func testARefusedSendNeverLosesTheText() {
        typealias Draft = MobileComposerDraftPolicy
        XCTAssertEqual(Draft.draftAfterRefusedSend(currentDraft: "", sentBody: "xin chào", sameRoomOpen: true),
                       .init(draft: "xin chào", droppedRefusedText: false))
        // Text typed after the tap is kept, and the refused text follows it.
        XCTAssertEqual(Draft.draftAfterRefusedSend(currentDraft: "new", sentBody: "old", sameRoomOpen: true),
                       .init(draft: "new\nold", droppedRefusedText: false))
        // Another room's composer never receives this room's text; the drop is reported.
        XCTAssertEqual(Draft.draftAfterRefusedSend(currentDraft: "", sentBody: "old", sameRoomOpen: false),
                       .init(draft: "", droppedRefusedText: true))
        XCTAssertEqual(Draft.draftAfterRefusedSend(currentDraft: "here", sentBody: "old", sameRoomOpen: false),
                       .init(draft: "here", droppedRefusedText: true))
    }

    func testTwoChainedRefusedSendsComeBackInTapOrder() {
        // The draft clears at each tap; refusals arrive in tap order.
        var draft = ""
        for body in ["first", "second"] {
            draft = MobileComposerDraftPolicy.draftAfterRefusedSend(currentDraft: draft, sentBody: body,
                                                                    sameRoomOpen: true).draft
        }
        XCTAssertEqual(draft, "first\nsecond")
    }

    // MARK: Renewal handover

    private typealias Handover = MobileTimelineHandoverPolicy

    func testHandoverKeepsOlderRowsAboveAShorterNewTimeline() {
        let shown = ["e1", "e2", "e3", "e4", "e5"]
        XCTAssertEqual(Handover.rows(displayed: shown, incoming: ["e4", "e5", "e6"], id: { $0 }),
                       ["e1", "e2", "e3", "e4", "e5", "e6"])
    }

    func testHandoverIsTheNewTimelineOnceItReachesTheOldestShownRow() {
        let shown = ["e2", "e3", "e4"]
        XCTAssertEqual(Handover.rows(displayed: shown, incoming: ["e2", "e3", "e4", "e5"], id: { $0 }),
                       ["e2", "e3", "e4", "e5"])
        XCTAssertEqual(Handover.rows(displayed: shown, incoming: ["e1", "e2", "e3"], id: { $0 }),
                       ["e1", "e2", "e3"], "an item the new timeline removed does not come back")
    }

    func testHandoverNeverBlanksAndNeverMixesUnrelatedRows() {
        XCTAssertEqual(Handover.rows(displayed: ["e1", "e2"], incoming: [String](), id: { $0 }), ["e1", "e2"])
        XCTAssertEqual(Handover.rows(displayed: ["e1", "e2"], incoming: ["x9"], id: { $0 }), ["x9"])
        XCTAssertEqual(Handover.rows(displayed: [String](), incoming: ["e1"], id: { $0 }), ["e1"])
    }

    func testHandoverAppliedToEachPublishConvergesOnTheNewTimeline() {
        // Invariant: as the new timeline pages older events in, the shown
        // list never loses a row it had and ends equal to the new timeline.
        let all = (1...40).map { "e\($0)" }
        var shown = Array(all[10...])
        let original = shown
        for start in stride(from: 35, through: 0, by: -5) {
            let incoming = Array(all[start...])
            let next = Handover.rows(displayed: shown, incoming: incoming, id: { $0 })
            XCTAssertTrue(Set(original).isSubset(of: Set(next)), "start \(start)")
            XCTAssertEqual(next.suffix(incoming.count), incoming[...], "start \(start)")
            XCTAssertEqual(Set(next).count, next.count, "no duplicate rows")
            shown = next
        }
        XCTAssertEqual(shown, all)
    }

    // MARK: Renewal single flight

    @MainActor
    func testSingleFlightJoinsAConcurrentCallerInsteadOfRunningTwice() async {
        let flight = MobileSingleFlight()
        var runs = 0
        let gate = AsyncGate()
        let first = Task { @MainActor in
            await flight.run {
                runs += 1
                await gate.wait()
            }
        }
        // Let the first run start and park on the gate.
        while runs == 0 { await Task.yield() }
        XCTAssertTrue(flight.isRunning)
        let second = Task { @MainActor in await flight.run { runs += 1 } }
        let joiner = Task { @MainActor in await flight.joinIfRunning() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(runs, 1, "a caller during a run never starts another")
        await gate.open()
        let firstRan = await first.value
        let secondRan = await second.value
        let joined = await joiner.value
        XCTAssertTrue(firstRan)
        XCTAssertFalse(secondRan)
        XCTAssertTrue(joined)
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(flight.isRunning)
        let noneToJoin = await flight.joinIfRunning()
        XCTAssertFalse(noneToJoin)
    }

    @MainActor
    func testSingleFlightRunsAgainAfterTheRunFinishes() async {
        let flight = MobileSingleFlight()
        var runs = 0
        let firstRan = await flight.run { runs += 1 }
        let secondRan = await flight.run { runs += 1 }
        XCTAssertTrue(firstRan)
        XCTAssertTrue(secondRan)
        XCTAssertEqual(runs, 2)
    }
}

/// Opens once; every waiter before and after the opening proceeds.
private actor AsyncGate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
