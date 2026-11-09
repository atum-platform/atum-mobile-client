import XCTest
@testable import AtumChat

final class HomeReadinessTests: XCTestCase {
    func testCachedAndProjectedRowsPaintWithoutWaitingForClassification() {
        let input = HomeReadiness.Input(
            hasListedRows: true, hasMatrixRooms: true,
            rooms: .loading, agents: .loading, apps: .loading,
            holdExpired: false
        )
        XCTAssertEqual(HomeReadiness.decide(input), .ready)
    }

    func testMissingInputWaitsOnlyUntilTheHoldExpires() {
        var input = HomeReadiness.Input(
            hasListedRows: false, hasMatrixRooms: false,
            rooms: .ready, agents: .ready, apps: .loading,
            holdExpired: false
        )
        XCTAssertEqual(HomeReadiness.decide(input), .loading)
        input.holdExpired = true
        XCTAssertEqual(HomeReadiness.decide(input), .empty)
    }

    func testAgentFailureStillPaintsKnownMatrixRoomsAsPartialRoster() {
        let input = HomeReadiness.Input(
            hasListedRows: false, hasMatrixRooms: true,
            rooms: .ready, agents: .failed, apps: .ready,
            holdExpired: true
        )
        XCTAssertEqual(HomeReadiness.decide(input), .ready)
    }

    func testNoDataFailuresChooseOfflineOrError() {
        let cases: [(HomeReadiness.Source, HomeReadiness.Source, HomeReadiness.Result)] = [
            (.offline, .ready, .offline),
            (.failed, .ready, .error),
            (.ready, .offline, .offline),
            (.ready, .failed, .error),
        ]
        for (rooms, agents, expected) in cases {
            let input = HomeReadiness.Input(
                hasListedRows: false, hasMatrixRooms: false,
                rooms: rooms, agents: agents, apps: .ready,
                holdExpired: true
            )
            XCTAssertEqual(HomeReadiness.decide(input), expected)
        }
    }

    func testAppsFailureDoesNotHideAnOtherwiseAuthoritativeEmptyHome() {
        let input = HomeReadiness.Input(
            hasListedRows: false, hasMatrixRooms: false,
            rooms: .ready, agents: .ready, apps: .failed,
            holdExpired: true
        )
        XCTAssertEqual(HomeReadiness.decide(input), .empty)
    }
}
