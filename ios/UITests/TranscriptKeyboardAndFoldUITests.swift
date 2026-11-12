import AtumChat
import XCTest

/// Keyboard dismissal from the transcript and the long-message fold
/// (owner, 2026-11-11; docs/ports/bubble-width-collapse.md).
final class TranscriptKeyboardAndFoldUITests: WS3UITestCase {
    /// A tap on the transcript puts the keyboard away, as in Telegram and
    /// Messages; the draft stays and the chat stays at its bottom.
    @MainActor
    func testTappingTheTranscriptHidesTheKeyboardAndKeepsTheDraft() {
        let app = launchChat(.chatKeyboard)
        field(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds), "no keyboard")
        field(app).typeText("bản nháp")
        XCTAssertEqual(element(app, AccessibilityID.transcript).value as? String, "following")
        let window = app.windows.firstMatch
        // Between the navigation bar and the composer, clear of both.
        let transcript = element(app, AccessibilityID.transcript).frame
        let point = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: transcript.minY + transcript.height * 0.35))
        point.tap()
        XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "the keyboard did not hide")
        XCTAssertTrue((field(app).value as? String ?? "").contains("bản nháp"), "the draft was lost")
        XCTAssertTrue(eventually { self.element(app, AccessibilityID.transcript).value as? String == "following" },
                      "the chat left its bottom")
        keepScreenshot("keyboard-dismissed", of: app)
    }

    /// The long answer, final at open, shows folded with "Xem thêm"; the
    /// toggle opens it ("Thu gọn") and folds it again.
    @MainActor
    func testALongAnswerFoldsAndOpens() {
        let app = launchChat(.chatBubbles)
        let long = "chat.bubbles.long" // ScriptedChats.bubblesLongID
        let toggle = element(app, "message.fold." + long)
        // My question just above the answer: while the chat follows its
        // bottom, opening the answer pushes it up by the hidden lines. (A
        // row's own accessibility frame spans its unclipped text, so it is
        // no measure of the fold.)
        let question = element(app, AccessibilityID.row(id: "chat.bubbles.0003"))
        if !toggle.waitForExistence(timeout: Self.waitSeconds) {
            app.swipeDown()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: Self.waitSeconds), "no fold toggle")
        XCTAssertEqual(toggle.label, "Xem thêm")
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, "the toggle is a full tap target")
        let folded = question.frame.minY
        keepScreenshot("fold-collapsed", of: app)
        toggle.tap()
        XCTAssertTrue(eventually { toggle.label == "Thu gọn" }, "the toggle did not open the answer")
        XCTAssertGreaterThan(abs(question.frame.minY - folded), 200, "the answer did not open")
        keepScreenshot("fold-expanded", of: app)
        if !toggle.isHittable { app.swipeUp() }
        toggle.tap()
        XCTAssertTrue(eventually { toggle.label == "Xem thêm" }, "Show less did not fold it")
        XCTAssertTrue(toggle.isHittable, "the folded answer is out of view")
        keepScreenshot("fold-refolded", of: app)
    }
}
