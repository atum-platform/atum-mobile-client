import XCTest
@testable import AtumChat

/// B5: the two-screen trigger, one request in flight, the 0.1 s throttle,
/// the backoff after failed pages and the start of the room.
final class PaginationPolicyTests: XCTestCase {
    private let screen = 800.0

    func testFarFromTheTopNothingIsRequested() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: screen * 2 + 1, viewportHeight: screen, now: 0), .none)
    }

    func testWithinTwoScreensOfTheTopOnePageIsRequested() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: screen * 2, viewportHeight: screen, now: 0), .request)
        XCTAssertTrue(policy.showsLoadingRow)
        XCTAssertEqual(PaginationPolicy.pageSize, 20)
    }

    func testOneRequestInFlight() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 100, viewportHeight: screen, now: 0), .request)
        XCTAssertEqual(policy.geometry(distanceFromTop: 50, viewportHeight: screen, now: 1), .none)
        XCTAssertEqual(policy.statusChanged(.paginating, now: 1.1), .none)
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 2), .none)
    }

    func testAFinishedPageAsksAgainWhileTheTopIsStillNearButThrottled() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 100, viewportHeight: screen, now: 0), .request)
        XCTAssertEqual(policy.requestFinished(hitTimelineStart: false, now: 0.05), .retry(at: 0.1))
        XCTAssertEqual(policy.decide(now: 0.1), .request)
        XCTAssertEqual(policy.requestFinished(hitTimelineStart: false, now: 0.5), .request,
                       "still inside the trigger after the throttle window")
    }

    func testGrowthAboveThatLeavesTheTriggerStopsRequesting() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 100, viewportHeight: screen, now: 0), .request)
        // The page landed above and the row being read kept its place, so
        // the distance from the top grew past two screens.
        XCTAssertEqual(policy.geometry(distanceFromTop: screen * 3, viewportHeight: screen, now: 0.3), .none)
        XCTAssertEqual(policy.requestFinished(hitTimelineStart: false, now: 0.4), .none)
        XCTAssertFalse(policy.showsLoadingRow)
    }

    func testTheStartOfTheRoomEndsPagination() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 0), .request)
        XCTAssertEqual(policy.requestFinished(hitTimelineStart: true, now: 1), .none)
        XCTAssertTrue(policy.hitTimelineStart)
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 5), .none)
        var reported = PaginationPolicy()
        XCTAssertEqual(reported.statusChanged(.idle(hitTimelineStart: true), now: 0), .none)
        XCTAssertEqual(reported.geometry(distanceFromTop: 0, viewportHeight: screen, now: 1), .none)
    }

    func testAShortChatSitsInsideTheTriggerSoTheOpenLoadsOnePageInTheBackground() {
        var policy = PaginationPolicy()
        // Fewer rows than one screen: the content's top is on screen.
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 0), .request)
    }

    func testAPaginationTheSDKRanItselfIsFollowedWhenItEnds() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.statusChanged(.paginating, now: 0), .none)
        XCTAssertTrue(policy.showsLoadingRow)
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 0.1), .none)
        XCTAssertEqual(policy.statusChanged(.idle(hitTimelineStart: false), now: 0.5), .request)
    }

    func testNoViewportYetMeansNoRequest() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: 0, now: 0), .none)
        XCTAssertEqual(policy.geometry(distanceFromTop: .infinity, viewportHeight: .nan, now: 0), .none)
    }

    // MARK: Failed pages

    func testRepeatedFailuresBackOffThenWaitInsteadOfAskingTenTimesASecond() {
        var policy = PaginationPolicy()
        var now = 0.0
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: now), .request)
        var requests = 1
        for delay in PaginationPolicy.failureRetrySeconds {
            now += 0.2
            XCTAssertEqual(policy.requestFailed(now: now), .retry(at: now + delay))
            XCTAssertFalse(policy.showsLoadingRow)
            XCTAssertEqual(policy.decide(now: now + delay - 0.01), .retry(at: now + delay), "not before the backoff")
            now += delay
            XCTAssertEqual(policy.decide(now: now), .request)
            requests += 1
        }
        XCTAssertEqual(policy.requestFailed(now: now + 0.2), .none, "every step failed: wait")
        for tick in 1...600 {
            XCTAssertEqual(policy.decide(now: now + Double(tick) * 0.1), .none)
        }
        XCTAssertEqual(policy.statusChanged(.idle(hitTimelineStart: false), now: now + 61), .none,
                       "the SDK's idle status after the failure does not re-arm it")
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: now + 62), .none,
                       "the same geometry again is not a scroll")
        XCTAssertEqual(requests, 1 + PaginationPolicy.failureRetrySeconds.count)
    }

    func testDuringABackoffStatusAndGeometryWaitForIt() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 100, viewportHeight: screen, now: 0), .request)
        XCTAssertEqual(policy.requestFailed(now: 0.5), .retry(at: 1.5))
        XCTAssertEqual(policy.statusChanged(.idle(hitTimelineStart: false), now: 0.6), .retry(at: 1.5))
        XCTAssertEqual(policy.geometry(distanceFromTop: 40, viewportHeight: screen, now: 0.7), .retry(at: 1.5),
                       "scrolling does not skip a backoff in progress")
        XCTAssertEqual(policy.decide(now: 1.5), .request)
    }

    func testAfterGivingUpAScrollOrAResumeTriesAgainWithAFreshBackoff() {
        var policy = PaginationPolicy()
        var now = 0.0
        XCTAssertEqual(policy.geometry(distanceFromTop: 200, viewportHeight: screen, now: now), .request)
        for delay in PaginationPolicy.failureRetrySeconds {
            _ = policy.requestFailed(now: now)
            now += delay
            XCTAssertEqual(policy.decide(now: now), .request)
        }
        XCTAssertEqual(policy.requestFailed(now: now), .none)
        XCTAssertEqual(policy.geometry(distanceFromTop: 150, viewportHeight: screen, now: now + 1), .request,
                       "the person scrolled")
        XCTAssertEqual(policy.requestFailed(now: now + 2), .retry(at: now + 2 + PaginationPolicy.failureRetrySeconds[0]),
                       "the backoff starts over")

        var offline = PaginationPolicy()
        now = 0
        XCTAssertEqual(offline.geometry(distanceFromTop: 0, viewportHeight: screen, now: now), .request)
        for delay in PaginationPolicy.failureRetrySeconds {
            _ = offline.requestFailed(now: now)
            now += delay
            _ = offline.decide(now: now)
        }
        XCTAssertEqual(offline.requestFailed(now: now), .none)
        XCTAssertEqual(offline.resume(now: now + 30), .request, "sync recovered: a short chat loads its history")
    }

    func testASuccessfulPageClearsTheBackoff() {
        var policy = PaginationPolicy()
        XCTAssertEqual(policy.geometry(distanceFromTop: 0, viewportHeight: screen, now: 0), .request)
        XCTAssertEqual(policy.requestFailed(now: 0.1), .retry(at: 1.1))
        XCTAssertEqual(policy.decide(now: 1.1), .request)
        XCTAssertEqual(policy.requestFinished(hitTimelineStart: false, now: 1.5), .request)
        XCTAssertEqual(policy.requestFailed(now: 1.6), .retry(at: 1.6 + PaginationPolicy.failureRetrySeconds[0]),
                       "a failure after a success starts at the first step")
    }
}
