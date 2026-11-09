import XCTest
@testable import AtumChat

/// B9, B30, §2.8: foreground, background, network regain, the glyph.
final class SessionLifecyclePolicyTests: XCTestCase {
    private typealias Policy = SessionLifecyclePolicy

    func testForegroundStartsSyncAndWakesTheQueues() {
        var policy = Policy()
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: true)),
                       [.startSync, .wakeSendQueues(.foreground)])
    }

    func testARunningSyncIsNotStartedAgainButTheQueuesAreWoken() {
        var policy = Policy()
        _ = policy.handle(.syncState(.running, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.inactive, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: true)), [.wakeSendQueues(.foreground)])
    }

    func testBackgroundStopsSyncAfterTheGraceAndHoldsATaskMeanwhile() {
        var policy = Policy()
        _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
        _ = policy.handle(.syncState(.running, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.inactive, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.background, sessionIsCurrent: true)),
                       [.beginBackgroundTask, .scheduleBackgroundStop(after: Policy.backgroundGraceSeconds)])
        XCTAssertEqual(policy.handle(.backgroundGraceElapsed), [.stopSync, .endBackgroundTask])
        XCTAssertEqual(policy.handle(.backgroundGraceElapsed), [], "stopped once")
    }

    func testComingBackWithinTheGraceCancelsTheStopAndRefreshesDomainReads() {
        var policy = Policy()
        _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
        _ = policy.handle(.syncState(.running, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.background, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.inactive, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: true)),
                       [.cancelBackgroundStop, .endBackgroundTask, .refreshDomainReads, .wakeSendQueues(.foreground)])
        XCTAssertEqual(policy.handle(.backgroundGraceElapsed), [], "a late timer changes nothing")
    }

    func testAReturnAfterSyncStoppedStartsItAgainAndRefreshes() {
        var policy = Policy()
        _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
        _ = policy.handle(.syncState(.running, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.background, sessionIsCurrent: true))
        _ = policy.handle(.backgroundGraceElapsed)
        _ = policy.handle(.syncState(.terminated, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: true)),
                       [.refreshDomainReads, .startSync, .wakeSendQueues(.foreground)])
    }

    func testTheFirstActivationIsNotARefresh() {
        var policy = Policy()
        XCTAssertFalse(policy.handle(.scenePhase(.active, sessionIsCurrent: true)).contains(.refreshDomainReads))
        _ = policy.handle(.scenePhase(.inactive, sessionIsCurrent: true))
        XCTAssertFalse(policy.handle(.scenePhase(.active, sessionIsCurrent: true)).contains(.refreshDomainReads),
                       "Control Center is not a return from the background")
    }

    func testNetworkRegainWakesTheQueues() {
        for lost in [Policy.SyncState.offline, .error] {
            var policy = Policy()
            _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
            _ = policy.handle(.syncState(lost, sessionIsCurrent: true))
            XCTAssertEqual(policy.handle(.syncState(.running, sessionIsCurrent: true)), [.wakeSendQueues(.syncRecovered)])
        }
        var policy = Policy()
        _ = policy.handle(.syncState(.idle, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.syncState(.running, sessionIsCurrent: true)), [],
                       "a first start is not a regain")
    }

    func testARegainDuringTheBackgroundGraceWakesTheQueuesButNotAfterSyncStopped() {
        var policy = Policy()
        _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
        _ = policy.handle(.syncState(.running, sessionIsCurrent: true))
        _ = policy.handle(.scenePhase(.background, sessionIsCurrent: true))
        _ = policy.handle(.syncState(.offline, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.syncState(.running, sessionIsCurrent: true)), [.wakeSendQueues(.syncRecovered)],
                       "pending sends get the network back inside the grace")
        _ = policy.handle(.syncState(.offline, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.backgroundGraceElapsed), [.stopSync, .endBackgroundTask])
        XCTAssertEqual(policy.handle(.syncState(.running, sessionIsCurrent: true)), [],
                       "sync stopped: nothing wakes in the background")
    }

    func testAnExpiredSessionNeverStartsSyncOrWakesQueues() {
        var policy = Policy()
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: false)), [])
        _ = policy.handle(.syncState(.offline, sessionIsCurrent: false))
        XCTAssertEqual(policy.handle(.syncState(.running, sessionIsCurrent: false)), [])
        _ = policy.handle(.scenePhase(.background, sessionIsCurrent: false))
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: false)),
                       [.cancelBackgroundStop, .endBackgroundTask, .refreshDomainReads],
                       "domain reads still refresh; the keep-alive renews the Matrix session")
    }

    func testTheGlyphShowsOnlyWhileOfflineOrInError() {
        var policy = Policy()
        for (state, shows) in [(Policy.SyncState.idle, false), (.running, false), (.offline, true),
                               (.error, true), (.terminated, false)] {
            _ = policy.handle(.syncState(state, sessionIsCurrent: true))
            XCTAssertEqual(policy.showsConnectionGlyph, shows, "\(state)")
        }
    }

    func testRepeatedPhasesChangeNothing() {
        var policy = Policy()
        _ = policy.handle(.scenePhase(.active, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.active, sessionIsCurrent: true)), [])
        _ = policy.handle(.scenePhase(.background, sessionIsCurrent: true))
        XCTAssertEqual(policy.handle(.scenePhase(.background, sessionIsCurrent: true)), [])
    }
}
