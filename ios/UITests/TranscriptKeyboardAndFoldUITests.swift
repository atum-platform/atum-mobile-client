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
        XCTAssertTrue(eventually { toggle.isHittable }, "the folded answer is out of view")
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
        let app = launchChat(.chatBubblesLive, extra: ["-AtumUITestSlowBubbleStream"])
        let live = "chat.bubbles-live.answer-1" // ScriptedChats.bubblesLiveID
        let toggle = element(app, "message.fold." + live)
        let body = element(app, "message.body." + live)
        let typing = element(app, AccessibilityID.rowTyping)
        let transcript = element(app, AccessibilityID.transcript)
        let input = app.textFields[AccessibilityID.composerField]
        let keyboard = app.keyboards.firstMatch
        let hasKeyboardFocus = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<2 {
            XCTAssertTrue(input.wait(for: \.isHittable, toEqual: true, timeout: 15),
                          "the composer did not become hittable")
            // Once the input has focus, allow the keyboard to finish appearing.
            if keyboard.exists || hasKeyboardFocus.evaluate(with: input) { break }
            input.tap()
            if keyboard.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "no keyboard")
        input.typeText("Lên giúp mình kế hoạch cả tuần tới nhé.")
        let send = element(app, AccessibilityID.composerSend)
        XCTAssertTrue(send.wait(for: \.isHittable, toEqual: true, timeout: 15), "no send button")
        send.tap()
        // Keyboard away (a tap on the transcript, clear of the rows' controls),
        // so the bottom of the chat is the composer's.
        let window = app.windows.firstMatch
        let frame = transcript.frame
        let transcriptTap = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.midX, dy: frame.minY + frame.height * 0.35))
        transcriptTap.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 15), "the keyboard did not hide")

        // Observe any partial body, rather than racing the second growth's
        // height. One snapshot keeps the body, typing and toggle at the same
        // instant even when separate accessibility queries are slow.
        XCTAssertTrue(body.waitForExistence(timeout: 30), "the live answer never arrived")
        var growingBody = ""
        XCTAssertTrue(eventually(30) {
            guard let root = try? app.snapshot() else { return false }
            var pending = [root]
            var nodes: [String: XCUIElementSnapshot] = [:]
            while let node = pending.popLast() {
                if !node.identifier.isEmpty { nodes[node.identifier] = node }
                pending.append(contentsOf: node.children)
            }
            guard let partial = nodes["message.body." + live], !partial.label.isEmpty,
                  nodes[AccessibilityID.rowTyping] != nil else { return false }
            XCTAssertNil(nodes["message.fold." + live], "a growing answer shows a toggle")
            growingBody = partial.label
            return true
        }, "the answer finished before it was seen growing")
        keepScreenshot("fold-live-growing", of: app)

        // Final: folded at the bottom, still following.
        // The UI-only stream grows every 20 s and ends at 61.5 s.
        XCTAssertTrue(typing.waitForNonExistence(timeout: 75), "Atum never stopped typing")
        XCTAssertTrue(toggle.wait(for: \.label, toEqual: "Xem thêm", timeout: 15),
                      "the final answer did not fold")
        XCTAssertGreaterThan(body.label.count, growingBody.count, "the observed partial answer never grew")
        // Accessibility elements may report isHittable=false even
        // when already inside the window. Wait for the actual window/composer geometry.
        let composerPill = element(app, "composer.pill")
        func foldedAtBottom() -> Bool {
            guard toggle.exists, toggle.label == "Xem thêm",
                  transcript.value as? String == "following" else { return false }
            let target = toggle.frame
            let composerTop = composerPill.frame.minY
            return !target.isEmpty && window.frame.contains(target)
                && target.maxY <= composerTop + 1 && target.maxY > composerTop - 160
        }
        XCTAssertTrue(eventually(20, foldedAtBottom), "Show more is out of view or not at the bottom")
        let composer = composerPill.frame.minY
        XCTAssertLessThanOrEqual(toggle.frame.maxY, composer + 1, "Show more is under the composer")
        XCTAssertGreaterThan(toggle.frame.maxY, composer - 160, "the folded answer is not at the bottom")
        let bodyTop = body.frame.minY
        let toggleFolded = toggle.frame.minY
        print("MEASURE fold.live.folded bodyTop=\(bodyTop) toggle=\(toggle.frame) composer=\(composer)")
        keepScreenshot("fold-live-folded", of: app)

        // Show more: opens in place, the chat detaches.
        let toggleCenter = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        if toggle.isHittable { toggle.tap() } else { toggleCenter.tap() }
        if !toggle.wait(for: \.label, toEqual: "Thu gọn", timeout: 8), foldedAtBottom() {
            // The control and transcript still show the pre-tap state.
            toggleCenter.tap()
        }
        XCTAssertTrue(toggle.wait(for: \.label, toEqual: "Thu gọn", timeout: 15),
                      "Show more did not open the answer")
        XCTAssertTrue(eventually(15) { toggle.frame.minY - toggleFolded > 150 }, "the answer did not open below")
        XCTAssertTrue(element(app, AccessibilityID.pillLatest).waitForExistence(timeout: 15), "no jump pill")
        print("MEASURE fold.live.opened bodyTop=\(body.frame.minY) toggle=\(toggle.frame)")
        XCTAssertEqual(body.frame.minY, bodyTop, accuracy: 1, "Show more moved the message")
        XCTAssertGreaterThan(toggle.frame.minY - toggleFolded, 150, "the answer did not open below")
        XCTAssertTrue((transcript.value as? String ?? "").hasPrefix("detached"),
                      "the chat still follows the bottom after Show more")
        keepScreenshot("fold-live-expanded", of: app)
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
