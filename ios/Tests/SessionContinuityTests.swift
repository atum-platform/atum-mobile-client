import XCTest
@testable import AtumNativeAPI

/// W4 E3 as decided on 2026-10-11 (coordinator decision 5): a session or
/// custody failure never blocks the app or a chat, and a renewal never spends
/// the one-time refresh token when custody already holds a grant that will do.
/// These are the decisions `LiveAppModel` takes (renewal, keep-alive, launch).
final class SessionContinuityTests: XCTestCase {
    private typealias Policy = MobileSessionContinuityPolicy
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let lead = MobileMatrixSessionKeepAlivePolicy.refreshLeadSeconds

    // MARK: Renewal grant

    func testASpendThatWasNeverInstalledIsResumedNotSpentAgain() {
        // The renewal spent (custody now holds a fresh ~300 s grant), then the
        // runtime or the account check failed. The runtime still holds the
        // expired grant, so the keep-alive asks again: custody's grant does.
        let afterSpend = Policy.CustodyGrant.ready(expiresAt: now.addingTimeInterval(270))
        XCTAssertEqual(Policy.renewalGrant(custody: afterSpend, now: now, requiredLifetimeSeconds: lead),
                       .resumeStored)
    }

    func testAGrantInsideTheLeadOrExpiredIsSpent() {
        for remaining in [lead, 30, 0, -120] as [TimeInterval] {
            XCTAssertEqual(Policy.renewalGrant(custody: .ready(expiresAt: now.addingTimeInterval(remaining)),
                                               now: now, requiredLifetimeSeconds: lead),
                           .spend, "remaining \(remaining) s")
        }
    }

    func testAnInvalidSessionWhoseGrantHasNotExpiredIsRebuiltWithoutSpending() {
        // Pull-to-refresh or the recovery sheet on a session that no longer
        // matches custody: what the old lock screen's "Thử lại" did through
        // launch, which spends only when the token has expired.
        XCTAssertEqual(Policy.renewalGrant(custody: .ready(expiresAt: now.addingTimeInterval(200)),
                                           now: now, requiredLifetimeSeconds: lead),
                       .resumeStored)
    }

    func testAVerificationCeremonySpendsWhenTheStoredGrantIsTooShortForIt() {
        let ceremony = MobileMatrixVerificationPolicy.minimumSessionLifetimeSeconds
        XCTAssertEqual(Policy.renewalGrant(custody: .ready(expiresAt: now.addingTimeInterval(ceremony - 10)),
                                           now: now, requiredLifetimeSeconds: ceremony), .spend)
        XCTAssertEqual(Policy.renewalGrant(custody: .ready(expiresAt: now.addingTimeInterval(ceremony + 10)),
                                           now: now, requiredLifetimeSeconds: ceremony), .resumeStored)
    }

    func testARefusingCustodyStopsAndAnUnreadableOneWaitsBothWithoutSpending() {
        XCTAssertEqual(Policy.renewalGrant(custody: .refused, now: now, requiredLifetimeSeconds: lead), .stop)
        XCTAssertEqual(Policy.renewalGrant(custody: .unreadable, now: now, requiredLifetimeSeconds: lead), .retryLater)
    }

    func testCustodyReadsAreClassifiedByWhatCustodyThrows() {
        let expiry = now.addingTimeInterval(100)
        XCTAssertEqual(Policy.custodyGrant { expiry }, .ready(expiresAt: expiry))
        // A spend journaled and never finished, an unfinished preparation, a
        // record from another installation: custody refuses.
        for failure in [MatrixCustodyFailure.refreshRequired, .interruptedPreparation, .recoveryRequired, .invalidIdentity] {
            XCTAssertEqual(Policy.custodyGrant { throw failure }, .refused, "\(failure)")
        }
        XCTAssertEqual(Policy.custodyGrant { throw OIDCGrantFailure.reauthenticationRequired }, .refused)
        XCTAssertEqual(Policy.custodyGrant { throw MatrixCustodyFailure.storageUnavailable }, .unreadable)
        XCTAssertEqual(Policy.custodyGrant { throw OIDCGrantFailure.storageUnavailable }, .unreadable)
    }

    // MARK: Automatic retries

    func testFailedRenewalsBackOffInsteadOfRetryingEvery30Seconds() {
        var retry = Policy.RenewalRetry()
        XCTAssertEqual(retry.automaticWait(now: now), 0)
        let spacing = Policy.RenewalRetry.spacingSeconds
        XCTAssertEqual(spacing.count, 3)
        XCTAssertTrue(zip(spacing, spacing.dropFirst()).allSatisfy { $0 < $1 }, "each failure waits longer")

        var at = now
        for (index, expected) in (spacing + [spacing.last!]).enumerated() {
            retry.record(.failed, at: at)
            XCTAssertEqual(retry.automaticWait(now: at), expected, "after failure \(index + 1)")
            XCTAssertEqual(retry.automaticWait(now: at.addingTimeInterval(expected / 2)), expected / 2)
            XCTAssertEqual(retry.automaticWait(now: at.addingTimeInterval(expected)), 0)
            at = at.addingTimeInterval(expected)
        }
    }

    func testASuccessfulRenewalClearsTheBackoff() {
        var retry = Policy.RenewalRetry()
        retry.record(.failed, at: now)
        retry.record(.failed, at: now)
        retry.record(.renewed, at: now)
        XCTAssertEqual(retry.automaticWait(now: now), 0)
        retry.record(.failed, at: now)
        XCTAssertEqual(retry.automaticWait(now: now), Policy.RenewalRetry.spacingSeconds[0])
    }

    func testAnOfflinePhoneIsNotBackedOffSoItReconnectsWhenTheNetworkReturns() {
        var retry = Policy.RenewalRetry()
        for _ in 0..<5 { retry.record(.unreachable, at: now) }
        retry.record(.superseded, at: now)
        XCTAssertEqual(retry.automaticWait(now: now), 0, "only the keep-alive's own 30 s spacing applies")
    }

    func testACustodyRefusalStopsAutomaticRenewalsUntilOneSucceeds() {
        var retry = Policy.RenewalRetry()
        retry.record(.custodyRefused, at: now)
        XCTAssertNil(retry.automaticWait(now: now))
        XCTAssertNil(retry.automaticWait(now: now.addingTimeInterval(86_400)), "never by time alone")
        retry.record(.renewed, at: now)
        XCTAssertEqual(retry.automaticWait(now: now), 0)
    }

    func testABackwardsClockNeverStrandsTheRetry() {
        var retry = Policy.RenewalRetry()
        retry.record(.failed, at: now)
        XCTAssertEqual(retry.automaticWait(now: now.addingTimeInterval(-60)), 0)
    }

    // MARK: Launch

    func testAnAccountServiceFailureAtLaunchNeverHidesTheChats() {
        XCTAssertEqual(Policy.outcome(for: .domain(recordPresent: true)), .productWithoutDomain)
        XCTAssertEqual(Policy.outcome(for: .domain(recordPresent: nil)), .productWithoutDomain,
                       "an unreadable record is not a reason to block the chats")
        XCTAssertEqual(Policy.outcome(for: .domain(recordPresent: false)), .productWithoutDomain,
                       "no record: Home stays open and offers domain-only sign-in inline")
    }

    func testALaunchWithNoMatrixSessionIsRetriedNotLocked() {
        XCTAssertEqual(Policy.outcome(for: .matrix(custody: nil)), .retryLaunch)
        XCTAssertEqual(Policy.outcome(for: .matrix(custody: .unreadable)), .retryLaunch)
        XCTAssertEqual(Policy.outcome(for: .matrix(custody: .ready(expiresAt: now))), .retryLaunch)
    }

    func testARefusingCustodyAtLaunchIsAnExpiredSessionNotANetworkProblem() {
        let outcome = Policy.outcome(for: .matrix(custody: .refused))
        XCTAssertEqual(outcome, .sessionExpired)
        XCTAssertFalse(Policy.retriesLaunch(outcome, now: now, lastAttemptAt: nil),
                       "no automatic retries: only the person's Thử lại reads custody again")
    }

    func testForegroundRetriesOfAFailedLaunchAreSpaced() {
        let spacing = Policy.launchRetrySpacingSeconds
        XCTAssertGreaterThan(spacing, 0)
        XCTAssertTrue(Policy.retriesLaunch(.retryLaunch, now: now, lastAttemptAt: nil))
        XCTAssertFalse(Policy.retriesLaunch(.retryLaunch, now: now, lastAttemptAt: now.addingTimeInterval(-spacing / 2)))
        XCTAssertTrue(Policy.retriesLaunch(.retryLaunch, now: now, lastAttemptAt: now.addingTimeInterval(-spacing)))
        XCTAssertTrue(Policy.retriesLaunch(.retryLaunch, now: now, lastAttemptAt: now.addingTimeInterval(60)),
                      "a clock that moved backwards never strands the retry")
    }
}
