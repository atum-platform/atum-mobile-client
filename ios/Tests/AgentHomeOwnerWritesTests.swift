import XCTest
@testable import AtumNativeAPI

final class AgentHomeOwnerWritesTests: XCTestCase {
    private struct Write: Hashable, Sendable {
        let target: String
        let epoch: Int64
    }

    private func counter() -> () -> NativeID {
        var next = 0
        return {
            next += 1
            return try! NativeID(String(format: "00000000-0000-4000-8000-%012d", next))
        }
    }

    func testARetryReusesBothTheRequestIDAndTheIdempotencyKey() {
        var writes = AgentHomeOwnerWrites<Write>()
        let first = writes.begin(Write(target: "mac", epoch: 4))
        // The write failed in transit: it may have reached the platform.
        let retry = writes.begin(Write(target: "mac", epoch: 4))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.requestID, retry.requestID, "the bearer replay fence sees one request twice")
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey, "the effect replays, it is not repeated")
        XCTAssertEqual(writes.pendingPayload, Write(target: "mac", epoch: 4))
    }

    func testAFreshOperationGetsTwoDifferentIDs() {
        var writes = AgentHomeOwnerWrites<Write>()
        let identity = writes.begin(Write(target: "mac", epoch: 4))
        XCTAssertNotEqual(identity.requestID, identity.idempotencyKey)
        XCTAssertNoThrow(try NativeID(identity.requestID.rawValue))
        XCTAssertNoThrow(try NativeID(identity.idempotencyKey.rawValue))
    }

    func testAChangedEffectIsAnotherOperationAndNeverRidesTheStalePair() {
        var writes = AgentHomeOwnerWrites<Write>()
        let first = writes.begin(Write(target: "mac", epoch: 4))
        let otherEpoch = writes.begin(Write(target: "mac", epoch: 5))
        XCTAssertNotEqual(first.requestID, otherEpoch.requestID)
        XCTAssertNotEqual(first.idempotencyKey, otherEpoch.idempotencyKey)
        XCTAssertEqual(writes.pendingPayload, Write(target: "mac", epoch: 5), "the stale one is gone")
        // Going back is a new operation too, not the old pair.
        let back = writes.begin(Write(target: "mac", epoch: 4))
        XCTAssertNotEqual(back.requestID, first.requestID)
        XCTAssertNotEqual(back.idempotencyKey, first.idempotencyKey)
    }

    func testADefinitiveAnswerNeverLendsItsIDsToTheNextWrite() {
        var writes = AgentHomeOwnerWrites<Write>()
        let first = writes.begin(Write(target: "cloud", epoch: 4))
        writes.settled()
        XCTAssertNil(writes.pendingPayload)
        let next = writes.begin(Write(target: "cloud", epoch: 4))
        XCTAssertNotEqual(next.requestID, first.requestID)
        XCTAssertNotEqual(next.idempotencyKey, first.idempotencyKey)
    }

    private func http(_ status: Int) throws -> NativeDomainClientFailure {
        let code = [400: "matrix_400", 401: "matrix_401", 403: "matrix_403", 404: "matrix_404",
                    409: "matrix_409", 429: "matrix_429", 503: "matrix_503"][status]!
        let headers = status == 429 ? ["Retry-After": "5"] : [:]
        return .http(try NativeHTTPFailure(status: status, headers: headers,
                                           body: Data("{\"error\":\"\(code)\"}".utf8)))
    }

    func testOnlyAnAnswerThePlatformMeantAsFinalReleasesTheIdentity() throws {
        for status in [400, 403, 404, 409] {
            XCTAssertTrue(AgentHomeOwnerWriteIdentity.isFinalAnswer(try http(status)),
                          "HTTP \(status) is the platform's refusal; repeating it only repeats the refusal")
        }
        // The write may have landed: the retry must repeat the same identity.
        for status in [401, 429, 503] {
            XCTAssertFalse(AgentHomeOwnerWriteIdentity.isFinalAnswer(try http(status)), "HTTP \(status)")
        }
        for failure in [NativeDomainClientFailure.transportUnavailable, .invalidResponse, .responseTooLarge,
                        .redirectRefused, .cancelled, .authenticationRefused] {
            XCTAssertFalse(AgentHomeOwnerWriteIdentity.isFinalAnswer(failure), "\(failure)")
        }
        XCTAssertFalse(AgentHomeOwnerWriteIdentity.isFinalAnswer(CancellationError()))
    }

    func testTheIDsComeFromTheInjectedSourceOncePerHalf() {
        var writes = AgentHomeOwnerWrites<Write>()
        let make = counter()
        let first = writes.begin(Write(target: "mac", epoch: 4), makeID: make)
        XCTAssertEqual(first.requestID.rawValue, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(first.idempotencyKey.rawValue, "00000000-0000-4000-8000-000000000002")
        // A retry asks the source for nothing.
        let retry = writes.begin(Write(target: "mac", epoch: 4), makeID: make)
        XCTAssertEqual(retry, first)
        let next = writes.begin(Write(target: "mac", epoch: 5), makeID: make)
        XCTAssertEqual(next.requestID.rawValue, "00000000-0000-4000-8000-000000000003")
        XCTAssertEqual(next.idempotencyKey.rawValue, "00000000-0000-4000-8000-000000000004")
    }
}

final class AgentHomeProgressPollingTests: XCTestCase {
    func testTheCadenceStartsAtTwoSecondsAndDoublesToThirty() {
        var polling = AgentHomeProgressPolling()
        XCTAssertEqual(polling.delay(after: .started), 2)
        let waits = (0..<7).map { _ in polling.delay(after: .unchanged) }
        XCTAssertEqual(waits, [4, 8, 16, 30, 30, 30, 30], "never above the ceiling, never forever growing")
    }

    func testNeverFasterThanTwoSecondsAndASeenChangeStartsOver() {
        var polling = AgentHomeProgressPolling()
        _ = polling.delay(after: .started)
        for _ in 0..<5 { _ = polling.delay(after: .unchanged) }
        XCTAssertEqual(polling.delay(after: .changed), 2, "new information is followed up promptly")
        XCTAssertEqual(polling.delay(after: .unchanged), 4)
        XCTAssertGreaterThanOrEqual(AgentHomeProgressPolling.initialDelay, 2)
    }

    func testARateLimitHonoursRetryAfterButOnlyEverLengthensTheWait() {
        var polling = AgentHomeProgressPolling()
        _ = polling.delay(after: .started)
        XCTAssertEqual(polling.delay(after: .rateLimited(retryAfter: 45)), 45, "Retry-After beyond the backoff wins")
        // The server asked for less than the backoff: the backoff stands.
        XCTAssertEqual(polling.delay(after: .rateLimited(retryAfter: 1)), 8)
        XCTAssertEqual(polling.delay(after: .rateLimited(retryAfter: 0)), 16)
        // The wait the server named is capped; the next ordinary wait is back on the schedule.
        XCTAssertEqual(polling.delay(after: .rateLimited(retryAfter: 86_400)),
                       AgentHomeProgressPolling.maximumRetryAfter)
        XCTAssertEqual(polling.delay(after: .unchanged), 30)
    }

    func testADroppedConnectionJustBacksOff() {
        var polling = AgentHomeProgressPolling()
        _ = polling.delay(after: .started)
        XCTAssertEqual(polling.delay(after: .transientFailure), 4)
        XCTAssertEqual(polling.delay(after: .transientFailure), 8)
        XCTAssertEqual(polling.delay(after: .changed), 2)
    }

    private func http(_ status: Int, retryAfter: String? = nil) throws -> NativeDomainClientFailure {
        let code = ["400": "matrix_400", "401": "matrix_401", "403": "matrix_403", "404": "matrix_404",
                    "409": "matrix_409", "429": "matrix_429", "503": "matrix_503"][String(status)]!
        let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
        return .http(try NativeHTTPFailure(status: status, headers: headers,
                                           body: Data("{\"error\":\"\(code)\"}".utf8)))
    }

    func testARateLimitIsNeverAFailure() throws {
        XCTAssertEqual(AgentHomeProgressPolling.classify(try http(429, retryAfter: "7")),
                       .rateLimited(retryAfter: 7))
        XCTAssertEqual(AgentHomeProgressPolling.classify(try http(429, retryAfter: "0")),
                       .rateLimited(retryAfter: 0))
    }

    func testOnlyAFinalAnswerFailsTheRead() throws {
        for status in [400, 401, 403, 404, 409] {
            XCTAssertEqual(AgentHomeProgressPolling.classify(try http(status)), .definitive, "HTTP \(status)")
        }
        XCTAssertEqual(AgentHomeProgressPolling.classify(NativeDomainClientFailure.invalidResponse), .definitive)
        XCTAssertEqual(AgentHomeProgressPolling.classify(NativeDomainClientFailure.authenticationRefused), .definitive)
        XCTAssertEqual(AgentHomeProgressPolling.classify(NativeDomainClientFailure.invalidRequest), .definitive)
    }

    func testOfflineAndAnUnavailablePlatformSayNothingAboutTheMove() throws {
        XCTAssertEqual(AgentHomeProgressPolling.classify(NativeDomainClientFailure.transportUnavailable), .transient)
        XCTAssertEqual(AgentHomeProgressPolling.classify(try http(503)), .transient)
    }

    func testACancelledLoopStopsQuietly() {
        XCTAssertEqual(AgentHomeProgressPolling.classify(NativeDomainClientFailure.cancelled), .cancelled)
        XCTAssertEqual(AgentHomeProgressPolling.classify(CancellationError()), .cancelled)
    }
}

final class AgentHomeCardRouteTests: XCTestCase {
    func testTheFirstReadWaitsInsteadOfFlashingEitherRow() {
        XCTAssertEqual(AgentHomeCardRoute(.pending), .waiting)
    }

    func testPlacementIsOfferedOnlyWhenThePlatformAdvertisesIt() {
        XCTAssertEqual(AgentHomeCardRoute(.answered(.available)), .placement)
    }

    func testEveryOtherSettledStateKeepsTheLegacyModelEditor() {
        XCTAssertEqual(AgentHomeCardRoute(.answered(.unavailable(.clientUpdateRequired))), .legacyEditor)
        XCTAssertEqual(AgentHomeCardRoute(.answered(.unavailable(.platformNotReady))), .legacyEditor)
        XCTAssertEqual(AgentHomeCardRoute(.unavailable), .legacyEditor)
        XCTAssertEqual(AgentHomeCardRoute(.failed), .legacyEditor)
    }

    /// The assistant's Mac is not answering: the platform advertises no move, yet the owner can still
    /// wait, move to the cloud knowingly, or cancel, so the sheet stays. Only for that one reason.
    func testASheetStaysReachableWhileTheHomeMacIsNotAnswering() {
        XCTAssertEqual(AgentHomeCardRoute(.answered(.unavailable(.platformNotReady), waitingForHome: true)), .placement)
        // A client that must update, or a platform that is not ready for a cloud home, is not that wait.
        XCTAssertEqual(AgentHomeCardRoute(.answered(.unavailable(.clientUpdateRequired), waitingForHome: true)), .legacyEditor)
        XCTAssertEqual(AgentHomeCardRoute(.answered(.unavailable(.platformNotReady), waitingForHome: false)), .legacyEditor)
        XCTAssertEqual(AgentHomeCardRoute(.answered(.available, waitingForHome: true)), .placement)
    }
}
