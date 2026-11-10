import AtumChat
import AtumDesign
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

/// AS-2: the card rows and the routines and "where it lives" words. Every
/// export key the phone asks for is in the pin (`LiveDesign.text` stops the
/// app otherwise); every other word comes from desktop's own five-locale
/// pending tables, so no locale reads another language (lane 3 D-5, D-8).
@MainActor
final class AssistantCardCopyTests: XCTestCase {
    func testEveryHomeWordIsInThePinOrThePendingTable() throws {
        let pin = try AtumCopy()
        for key in AgentHomeCopy.Key.allCases {
            switch AgentHomeCopy.source(key) {
            case let .export(name):
                XCTAssertTrue(pin.contains(name), "\(key): \(name) is not in the pin")
            case let .pending(pending):
                for locale in pin.locales {
                    let value = AgentHomePendingCopy.text(pending, locale: locale)
                    XCTAssertNotEqual(value, pending.rawValue, "\(locale) \(key) fell through")
                }
            }
        }
    }

    func testTheHomeSheetReadsExportedArgumentWords() throws {
        let pin = try AtumCopy()
        for key in ["summary", "waitingForMac", "noModels", "anotherMac", "ready", "moveSection"] {
            XCTAssertTrue(pin.contains("src.matrix.agent-home-copy.words." + key), key)
        }
        for loss in AgentHomeFeatureLoss.allCases {
            XCTAssertTrue(pin.contains("src.matrix.agent-home-copy.words.losses." + loss.rawValue), "\(loss)")
        }
    }

    func testTheCardRowWordsAreInThePin() throws {
        let pin = try AtumCopy()
        for key: AssistantCardCopyKey in [.pet, .petChoose, .skills, .skillsLabel, .findSkills, .offline,
                                          .routines, .setupRow, .footnote, .saveFailed] {
            XCTAssertTrue(pin.contains(key.rawValue), "\(key)")
        }
    }

    func testRoutineWordsFollowTheAppLanguage() throws {
        let design = try LiveDesign()
        let copy = AssistantCardCopy(design: design)
        let pin = try AtumCopy()
        for key in AssistantRoutinePendingCopy.Key.allCases where !pin.contains(key.exportKey) {
            XCTAssertEqual(copy.routine(key, name: "Mai"),
                           AssistantRoutinePendingCopy.text(key, locale: design.locale, name: "Mai"))
        }
        if !pin.contains(AssistantCardCopyKey.routineCount.rawValue) {
            XCTAssertEqual(copy.routineCount(3), AssistantRoutinePendingCopy.count(3, locale: design.locale))
        }
    }
}
