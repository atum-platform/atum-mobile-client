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
    func testSDKFullEventEnvelopeCarriesTheWorkingMarker() {
        let raw = #"{"type":"m.room.message","sender":"@agent:example.test","event_id":"$work","content":{"msgtype":"m.notice","body":"Đang chạy tác vụ…","io.atum.progress":{"phase":"working","revision":0}}}"#
        let marker = AtumTurnMarkers.parse(json: raw)
        XCTAssertEqual(marker.progress?.phase, .working)
        XCTAssertEqual(marker.progress?.revision, 0)
    }

    func testSDKFullEditEnvelopePrefersReplacementMarker() {
        let raw = #"{"type":"m.room.message","content":{"msgtype":"m.notice","io.atum.progress":{"phase":"working","revision":0},"m.new_content":{"msgtype":"m.notice","body":"Done","io.atum.progress":{"phase":"settled","revision":3}},"m.relates_to":{"rel_type":"m.replace","event_id":"$work"}}}"#
        let marker = AtumTurnMarkers.parse(json: raw)
        XCTAssertEqual(marker.progress?.phase, .settled)
        XCTAssertEqual(marker.progress?.revision, 3)
    }

    func testSDKFullInterimEnvelopeIsRecognized() {
        XCTAssertTrue(AtumTurnMarkers.parse(json: #"{"content":{"msgtype":"m.text","io.atum.interim":true}}"#).interim)
    }

    func testReplacementWithoutMarkerDoesNotRestoreOriginalProgress() {
        let raw = #"{"content":{"io.atum.progress":{"phase":"working"},"m.new_content":{"msgtype":"m.notice","body":"Outcome"}}}"#
        XCTAssertNil(AtumTurnMarkers.parse(json: raw).progress)
        XCTAssertNil(AtumTurnMarkers.parse(json: #"{"content":null,"io.atum.progress":{"phase":"working"}}"#).progress)
        XCTAssertNil(AtumTurnMarkers.parse(json: #"{"content":{"m.new_content":null,"io.atum.progress":{"phase":"working"}}}"#).progress)
    }

}

extension AtumTurnMarkersTests {
    private func status(_ descriptor: String, kind: String, phase: String = "working") -> ChatProgressPresentation? {
        AtumTurnMarkers.parse(json: """
        {"msgtype":"m.notice","io.atum.progress":{"phase":"\(phase)","kind":"\(kind)","revision":2},
         "io.atum.presentation":\(descriptor)}
        """).progress?.presentation
    }

    func testDesktop63StatusDescriptorsUseOnlyClosedTypedArguments() {
        for activity in ChatProgressPresentation.Activity.allCases {
            let descriptor = """
            {"version":1,"code":"tool_activity","args":{"activity":"\(activity.rawValue)"}}
            """
            XCTAssertEqual(status(descriptor, kind: "todo"), .toolActivity(activity))
        }
        XCTAssertEqual(status(#"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":4}}"#, kind: "heartbeat"),
                       .heartbeat(minutes: 4))
        XCTAssertEqual(status(#"{"version":1,"code":"approval_wait","args":{}}"#, kind: "device", phase: "waiting"),
                       .approvalWait)
        XCTAssertEqual(status(#"{"version":1,"code":"video_consent_required","args":{}}"#,
                              kind: "device", phase: "waiting"), .videoConsentRequired)
        for invalid in [
            #"{"version":true,"code":"heartbeat","args":{"elapsed_minutes":4}}"#,
            #"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":true}}"#,
            #"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":4.5}}"#,
            #"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":1441}}"#,
            #"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":4,"detail":"private"}}"#,
            #"{"version":1,"code":"heartbeat","args":{"elapsed_minutes":4},"extra":true}"#
        ] {
            XCTAssertNil(status(invalid, kind: "heartbeat"))
        }
        XCTAssertNil(status(#"{"version":1,"code":"approval_wait","args":{}}"#, kind: "todo"))
    }

    func testStatusRenderingReadsTheExportFirstAndKeepsOnlyChecklistRows() {
        let body = "Old header\n ✓ Finished \nInternal note\n • Next "
        let line = WorkingLineText(body: body, presentation: .heartbeat(minutes: 5)) { key, minutes in
            XCTAssertEqual(key, "shared.matrix-status-line-copy.matrixProgressCopy.heartbeat")
            XCTAssertEqual(minutes, 5)
            return "Exported line"
        }
        XCTAssertEqual(line, WorkingLineText(current: "Exported line", steps: [
            .init(text: "Finished", done: true), .init(text: "Next", done: false)
        ]))
        XCTAssertEqual(WorkingLineText(body: "", presentation: .approvalWait) { _, _ in nil }.current,
                       "Waiting for your OK…")
        XCTAssertEqual(WorkingLineText(body: "Old header", presentation: nil) { _, _ in nil }.current, "Old header")
    }

    func testCronEditsKeepTheOriginalExecutionIdentity() throws {
        let first = """
        {"event_id":"$work","content":{"msgtype":"m.notice","io.atum.progress":{
          "profile":"atum.agent-turns/1.3","scope":"owner_private","phase":"working","kind":"todo",
          "revision":0,"trigger":"cron","schedule":{"job":"fixture-job","execution":"run-a"}}}}
        """
        func edit(_ execution: String) -> String {
            """
            {"event_id":"$edit","content":{"m.new_content":{"msgtype":"m.notice","io.atum.progress":{
              "profile":"atum.agent-turns/1.3","scope":"owner_private","phase":"working","kind":"todo",
              "revision":1,"trigger":"cron","schedule":{"job":"fixture-job","execution":"\(execution)"}}}}}
            """
        }
        XCTAssertEqual(AtumTurnMarkers.parse(json: first).progress?.schedule?.execution, "run-a")
        XCTAssertEqual(AtumTurnMarkers.parse(json: edit("run-a"), originalJSON: first).progress?.schedule?.execution,
                       "run-a")
        let changed = AtumTurnMarkers.parse(json: edit("run-b"), originalJSON: first).progress
        XCTAssertEqual(changed?.isScheduled, true)
        XCTAssertNil(changed?.schedule)
        XCTAssertNil(AtumTurnMarkers.parse(json: edit("run-a")).progress?.schedule)
    }
}
