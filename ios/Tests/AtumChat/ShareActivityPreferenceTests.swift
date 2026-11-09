import XCTest
@testable import AtumChat

/// The owner's activity switch (§9.1; `io.atum.desktop.share_activity`).
/// Synthetic values only.
final class ShareActivityPreferenceTests: XCTestCase {
    func testItIsOnByDefaultWhenUnsetOrUnreadable() {
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: nil))
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: "not json"))
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: "{}"))
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: #"{"version":1}"#))
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: #"{"version":1,"value":"false"}"#))
    }

    func testItReadsTheSharedDesktopShape() {
        XCTAssertTrue(ShareActivityPreference.value(fromAccountData: #"{"version":1,"value":true}"#))
        XCTAssertFalse(ShareActivityPreference.value(fromAccountData: #"{"version":1,"value":false}"#))
    }

    func testItWritesTheSameShapeDesktopReads() {
        XCTAssertEqual(ShareActivityPreference.accountDataJSON(sharing: true), #"{"version":1,"value":true}"#)
        XCTAssertEqual(ShareActivityPreference.accountDataJSON(sharing: false), #"{"version":1,"value":false}"#)
    }

    func testTheReceiptTypeFollowsTheSwitch() {
        XCTAssertEqual(ShareActivityPreference.receipt(sharing: true), .readPublic)
        XCTAssertEqual(ShareActivityPreference.receipt(sharing: false), .readPrivate)
        XCTAssertEqual(ShareActivityPreference.eventType, "io.atum.desktop.share_activity")
    }
}
