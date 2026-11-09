import XCTest
@testable import AtumChat

/// `atum.agent-turns/1.4` A7–A9 markers, parsed from the SDK's latest JSON.
/// Synthetic values only.
final class AtumTurnMarkersTests: XCTestCase {
    func testAnInterimRemark() {
        let json = #"{"msgtype":"m.text","body":"Để mình xem.","io.atum.interim":true}"#
        let markers = AtumTurnMarkers.parse(json: json)
        XCTAssertTrue(markers.interim)
        XCTAssertNil(markers.progress)
    }

    func testAWorkingProgressLine() {
        let json = #"{"msgtype":"m.notice","body":"Đang đọc…","io.atum.progress":{"profile":"atum.agent-turns/1.3","scope":"owner_private","phase":"working","kind":"interim","revision":0}}"#
        let markers = AtumTurnMarkers.parse(json: json)
        XCTAssertFalse(markers.interim)
        XCTAssertEqual(markers.progress?.phase, .working)
        XCTAssertEqual(markers.progress?.kind, "interim")
        XCTAssertEqual(markers.progress?.revision, 0)
    }

    func testASettledEditPrefersTheNewContent() {
        let json = #"""
        {"msgtype":"m.notice","io.atum.progress":{"phase":"working","revision":2},
         "m.new_content":{"msgtype":"m.notice","body":"Xong","io.atum.progress":{"phase":"settled","revision":3}},
         "m.relates_to":{"rel_type":"m.replace","event_id":"$root"}}
        """#
        XCTAssertEqual(AtumTurnMarkers.parse(json: json).progress?.phase, .settled)
        XCTAssertEqual(AtumTurnMarkers.parse(json: json).progress?.revision, 3)
    }

    func testAnUnknownPhaseStaysLiveRatherThanDeletingEarly() {
        let json = #"{"io.atum.progress":{"phase":"starting-soon"}}"#
        XCTAssertEqual(AtumTurnMarkers.parse(json: json).progress?.phase, .unknown)
    }

    func testMissingUnreadableOrWrongShapesAreIgnored() {
        XCTAssertEqual(AtumTurnMarkers.parse(json: nil), AtumTurnMarkers())
        XCTAssertEqual(AtumTurnMarkers.parse(json: "not json"), AtumTurnMarkers())
        XCTAssertEqual(AtumTurnMarkers.parse(json: #"{"io.atum.interim":"true"}"#), AtumTurnMarkers())
        XCTAssertEqual(AtumTurnMarkers.parse(json: #"{"io.atum.progress":true}"#), AtumTurnMarkers())
        XCTAssertEqual(AtumTurnMarkers.parse(json: #"{"io.atum.interim":false}"#), AtumTurnMarkers())
    }
}
