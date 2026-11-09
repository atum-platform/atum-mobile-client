@testable import AtumMobile
import XCTest

@MainActor
final class FirstRunIntegrationTests: XCTestCase {
    func testMarkerRecordIsPresenceOnlyAndPhoneCompletionUsesLegacyShape() throws {
        XCTAssertEqual(FirstRunMarkerRecord.eventType, "io.atum.onboarding.first_run")
        XCTAssertEqual(FirstRunMarkerRecord.state(from: nil), .unseen)
        XCTAssertEqual(FirstRunMarkerRecord.state(from: "{}"), .answered)
        XCTAssertEqual(FirstRunMarkerRecord.state(from: "not json another build wrote"),
                       .answered)

        let json = try XCTUnwrap(FirstRunMarkerRecord.phoneCompletionAnswerJSON(
            nowMilliseconds: 1_760_000_000_000
        ))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["folders"] as? String, "declined",
                       "legacy shape only: the phone did not ask for or reject Mac folders")
        XCTAssertEqual((object["at"] as? NSNumber)?.int64Value, 1_760_000_000_000)
        XCTAssertNil(FirstRunMarkerRecord.phoneCompletionAnswerJSON(nowMilliseconds: -1))
    }

    func testPreSyncAccountDataIsNotAuthoritative() {
        XCTAssertFalse(FirstRunMarkerReadiness.canRead(sessionReady: true,
                                                       completedInitialSync: false))
        XCTAssertFalse(FirstRunMarkerReadiness.canRead(sessionReady: false,
                                                       completedInitialSync: true))
        XCTAssertTrue(FirstRunMarkerReadiness.canRead(sessionReady: true,
                                                      completedInitialSync: true))
    }

    func testMarkerRefreshNeverTurnsAnAnswerBackIntoAnOffer() async {
        var content: String? = nil
        var current = true
        let coordinator = FirstRunMarkerCoordinator(io: .init(
            read: { content },
            write: { _ in XCTFail("refresh never writes") },
            isCurrent: { current },
            nowMilliseconds: { 1 }
        ))

        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .unseen)

        content = #"{"v":1,"folders":"declined","at":1}"#
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .answered)

        content = nil
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .answered,
                       "a synced answer stays answered through later missing reads")

        current = false
        content = #"{"v":1}"#
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .answered,
                       "a stale refresh never publishes into a newer context")
    }

    func testMarkerReadFailureIsUnknownRatherThanAnOffer() async {
        struct Refused: Error {}
        let coordinator = FirstRunMarkerCoordinator(io: .init(
            read: { throw Refused() },
            write: { _ in XCTFail("refresh never writes") },
            isCurrent: { true },
            nowMilliseconds: { 1 }
        ))

        await coordinator.refresh()
        XCTAssertEqual(coordinator.state, .unknown)
    }

    func testConcurrentAnswersShareOneSuspendedReadAndOneWrite() async throws {
        var content: String?
        var reads = 0
        var writes = 0
        var continuation: CheckedContinuation<Void, Never>?
        let coordinator = FirstRunMarkerCoordinator(io: .init(
            read: {
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { continuation = $0 }
                }
                return content
            },
            write: { payload in
                writes += 1
                content = payload
            },
            isCurrent: { true },
            nowMilliseconds: { 42 }
        ))

        let first = Task { try await coordinator.answer() }
        for _ in 0..<100 where reads == 0 { await Task.yield() }
        XCTAssertEqual(reads, 1)

        let second = Task { try await coordinator.answer() }
        for _ in 0..<100 { await Task.yield() }
        let overlappedReads = reads

        continuation?.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(overlappedReads, 1,
                       "the second caller joins the one suspended answer")
        XCTAssertEqual(writes, 1, "two local answers never write twice")
        XCTAssertEqual(coordinator.state, .answered)

        let readsAfterAnswer = reads
        try await coordinator.answer()
        XCTAssertEqual(reads, readsAfterAnswer, "the answered latch issues no further read")
    }

    func testRetryAfterAnswerFailureStartsAFreshSingleFlight() async throws {
        struct Refused: Error {}
        var content: String?
        var writes = 0
        var refuseWrite = true
        let coordinator = FirstRunMarkerCoordinator(io: .init(
            read: { content },
            write: { payload in
                if refuseWrite { throw Refused() }
                writes += 1
                content = payload
            },
            isCurrent: { true },
            nowMilliseconds: { 1 }
        ))
        await coordinator.refresh()

        do {
            try await coordinator.answer()
            XCTFail("a refused account-data write must not complete setup")
        } catch {
            XCTAssertEqual(error as? FirstRunMarkerFailure, FirstRunMarkerFailure.failed)
        }
        XCTAssertEqual(coordinator.state, .unseen)

        refuseWrite = false
        try await coordinator.answer()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(coordinator.state, .answered)
    }

    func testMarkerAnswerStaleCompletionWritesNothing() async {
        var writes = 0
        var current = true
        let coordinator = FirstRunMarkerCoordinator(io: .init(
            read: { nil },
            write: { _ in
                writes += 1
                current = false
            },
            isCurrent: { current },
            nowMilliseconds: { 1 }
        ))
        await coordinator.refresh()
        do {
            try await coordinator.answer()
            XCTFail("the old account/assistant context is a hard fence")
        } catch {
            XCTAssertEqual(error as? FirstRunMarkerFailure, FirstRunMarkerFailure.stale)
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(coordinator.state, .unseen)
    }

    func testGreetingScopeChangesAcrossAccountDeviceAndAssistant() {
        let primary = FirstRunContext.scope(accountID: "account-a", deviceID: "device-a",
                                            assistantID: "agent-primary")
        XCTAssertNotEqual(primary, FirstRunContext.scope(accountID: "account-b",
                                                         deviceID: "device-a",
                                                         assistantID: "agent-primary"))
        XCTAssertNotEqual(primary, FirstRunContext.scope(accountID: "account-a",
                                                         deviceID: "device-b",
                                                         assistantID: "agent-primary"))
        XCTAssertNotEqual(primary, FirstRunContext.scope(accountID: "account-a",
                                                         deviceID: "device-a",
                                                         assistantID: "agent-second"))
    }
}
