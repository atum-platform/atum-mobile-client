@testable import AtumMobile
import AtumNativeAPI
import XCTest

final class AssistantRoutineStateTests: XCTestCase {
    func testRequestLedgerReusesOnlyTheSameOpaqueDraftAndClearsAfterConfirmation() throws {
        let suite = "AssistantRoutineStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = RoutineRequestLedger(defaults: defaults)
        let key = ledger.key(scope: "00000000-0000-4000-8000-32cfb078b995",
                             operation: "create", fingerprint: "private title\u{0}private instruction")
        XCTAssertFalse(key.contains("private"))
        let first = ledger.requestID(for: key)
        XCTAssertEqual(ledger.requestID(for: key), first)
        let other = ledger.requestID(for: ledger.key(scope: "00000000-0000-4000-8000-32cfb078b995",
                                                     operation: "create", fingerprint: "different"))
        XCTAssertNotEqual(other, first)
        ledger.clear(key)
        XCTAssertNotEqual(ledger.requestID(for: key), first)
    }

    func testChangingTimezonePreservesRecurringWallClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let saigon = RoutineWallClock.date(hour: 8, minute: 30,
                                           timezone: "Asia/Ho_Chi_Minh", now: now)
        XCTAssertEqual(RoutineWallClock.parts(saigon, timezone: "Asia/Ho_Chi_Minh").hour, 8)
        let newYork = RoutineWallClock.date(hour: 8, minute: 30,
                                            timezone: "America/New_York", now: now)
        let parts = RoutineWallClock.parts(newYork, timezone: "America/New_York")
        XCTAssertEqual(parts.hour, 8)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertNotEqual(saigon, newYork)
    }
}
