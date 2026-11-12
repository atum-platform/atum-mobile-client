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
    /// toggle opens it in place ("Thu gọn"): its top stays where it was and
    /// the chat no longer follows the bottom (owner, 2026-11-12). Show less
    /// folds it again.
    @MainActor
    func testALongAnswerFoldsAndOpens() {
        let app = launchChat(.chatBubbles)
        let long = "chat.bubbles.long" // ScriptedChats.bubblesLongID
        let toggle = element(app, "message.fold." + long)
        // The body's top: the toggled message's own place on screen. (Its
        // accessibility frame spans the unclipped text below, so only its
        // top measures anything.)
        let body = element(app, "message.body." + long)
        let question = element(app, AccessibilityID.row(id: "chat.bubbles.0003"))
        if !toggle.waitForExistence(timeout: Self.waitSeconds) {
            app.swipeDown()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: Self.waitSeconds), "no fold toggle")
        XCTAssertEqual(toggle.label, "Xem thêm")
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, "the toggle is a full tap target")
        pause(0.5)
        let bodyTop = body.frame.minY
        let questionTop = question.frame.minY
        let toggleFolded = toggle.frame.minY
        keepScreenshot("fold-collapsed", of: app)
        toggle.tap()
        XCTAssertTrue(eventually { toggle.label == "Thu gọn" }, "the toggle did not open the answer")
        pause(0.6)
        XCTAssertEqual(body.frame.minY, bodyTop, accuracy: 1, "Show more moved the message")
        XCTAssertEqual(question.frame.minY, questionTop, accuracy: 1, "Show more moved the chat")
        XCTAssertGreaterThan(toggle.frame.minY - toggleFolded, 150, "the answer did not open below")
        XCTAssertNotEqual(element(app, AccessibilityID.transcript).value as? String, "following",
                          "the chat still follows the bottom after Show more")
        keepScreenshot("fold-expanded", of: app)
        if !toggle.isHittable { app.swipeUp() }
        toggle.tap()
        XCTAssertTrue(eventually { toggle.label == "Xem thêm" }, "Show less did not fold it")
        XCTAssertTrue(toggle.isHittable, "the folded answer is out of view")
        keepScreenshot("fold-refolded", of: app)
    }

    /// A long answer that streams in while Atum types never folds while it
    /// grows, and folds once final (owner, 2026-11-12): the chat stays at its
    /// bottom with "Xem thêm" in view. Show more then opens it in place: its
    /// top does not move, the chat stops following and the jump pill shows.
    /// The answer streams only after my send, so every phase is seen however
    /// long the launch takes.
    @MainActor
    func testALiveLongAnswerFoldsOnceFinalAndOpensInPlace() {
        let app = launchChat(.chatBubblesLive)
        let live = "chat.bubbles-live.answer-1" // ScriptedChats.bubblesLiveID
        let toggle = element(app, "message.fold." + live)
        let body = element(app, "message.body." + live)
        let typing = element(app, AccessibilityID.rowTyping)
        let transcript = element(app, AccessibilityID.transcript)
        field(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds), "no keyboard")
        field(app).typeText("Lên giúp mình kế hoạch cả tuần tới nhé.")
        element(app, AccessibilityID.composerSend).tap()
        // Keyboard away (a tap on the transcript, clear of the rows' controls),
        // so the bottom of the chat is the composer's.
        let window = app.windows.firstMatch
        let frame = transcript.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: frame.minY + frame.height * 0.35)).tap()
        XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "the keyboard did not hide")

        // Growing: long (two of its three growths in) while Atum still types.
        XCTAssertTrue(body.waitForExistence(timeout: 15), "the live answer never arrived")
        XCTAssertTrue(eventually(12) { body.frame.height > 800 }, "the live answer did not grow long")
        let toggleWhileGrowing = toggle.exists
        let stillTyping = typing.exists
        XCTAssertTrue(stillTyping, "the answer finished before it was seen growing")
        XCTAssertFalse(toggleWhileGrowing, "a growing answer shows a toggle")
        keepScreenshot("fold-live-growing", of: app)

        // Final: folded at the bottom, still following.
        XCTAssertTrue(eventually(15) { !typing.exists }, "Atum never stopped typing")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the final answer shows no toggle")
        XCTAssertTrue(eventually(5) { toggle.label == "Xem thêm" }, "the final answer did not fold")
        XCTAssertTrue(eventually { transcript.value as? String == "following" }, "the chat left its bottom")
        pause(0.6)
        let composer = element(app, "composer.pill").frame.minY
        XCTAssertTrue(toggle.isHittable, "Show more is out of view")
        XCTAssertLessThanOrEqual(toggle.frame.maxY, composer + 1, "Show more is under the composer")
        XCTAssertGreaterThan(toggle.frame.maxY, composer - 160, "the folded answer is not at the bottom")
        let bodyTop = body.frame.minY
        let toggleFolded = toggle.frame.minY
        print("MEASURE fold.live.folded bodyTop=\(bodyTop) toggle=\(toggle.frame) composer=\(composer)")
        keepScreenshot("fold-live-folded", of: app)

        // Show more: opens in place, the chat detaches.
        toggle.tap()
        XCTAssertTrue(eventually { toggle.label == "Thu gọn" }, "Show more did not open the answer")
        pause(0.6)
        print("MEASURE fold.live.opened bodyTop=\(body.frame.minY) toggle=\(toggle.frame)")
        XCTAssertEqual(body.frame.minY, bodyTop, accuracy: 1, "Show more moved the message")
        XCTAssertGreaterThan(toggle.frame.minY - toggleFolded, 150, "the answer did not open below")
        XCTAssertTrue((transcript.value as? String ?? "").hasPrefix("detached"),
                      "the chat still follows the bottom after Show more")
        XCTAssertTrue(element(app, AccessibilityID.pillLatest).waitForExistence(timeout: 3), "no jump pill")
        keepScreenshot("fold-live-expanded", of: app)
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
