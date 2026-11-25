import AtumChat
import XCTest

/// WS3's U proofs (revamp plan §5.2 S1 acceptance): U4 and U4b (instant send,
/// the clock, unread then Seen), U5 (a failed send: "Thử lại", "Xóa"), the
/// composer parts of U7 and U8, and `chat.actions` (the menu per room kind,
/// reply and quote, reaction toggles), plus B11's people line and the B30
/// glyph. Scripted scenarios only, synthetic data, Vietnamese.
///
/// They run on the real `ChatScreen` (`-AtumScripted`, `ScriptedChatHost`).
/// Queries use the frozen accessibility IDs, the composer's control IDs
/// (`composer.pill`, `composer.reply`, `composer.edit`, `composer.typing`),
/// `chat.connection`, `selectText.*`, the rows' `send.failed`, `quote`,
/// `reaction.<key>` and `answer.copy`, or exported words. A bubble is one
/// element read as sender, time, content and delivery (B16), so a row's
/// words are matched with CONTAINS on its label.
class WS3UITestCase: AtumUITestCase {
    static let connectionGlyphFlag = "-AtumScriptedConnectionGlyph"
    /// The app language is Vietnamese (the development language), at the
    /// default text size whatever the simulator was left at.
    static let vietnamese = ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
    /// The failed mark under a bubble (`DeliveryLine.failedID`).
    static let failedID = "send.failed"

    @MainActor
    func launchChat(_ scenario: ScriptedScenario, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: scenario) + Self.vietnamese + extra
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")
        return app
    }

    @MainActor
    func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func labeled(_ scope: XCUIElement, _ label: String) -> XCUIElement {
        scope.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func labelContains(_ scope: XCUIElement, _ text: String) -> XCUIElement {
        scope.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    func field(_ app: XCUIApplication) -> XCUIElement { element(app, AccessibilityID.composerField) }

    /// Long-presses a row's text to open the system context menu.
    @MainActor
    func openMenu(_ app: XCUIApplication, row identifier: String, text: String) {
        let row = element(app, identifier)
        XCTAssertTrue(row.waitForExistence(timeout: Self.waitSeconds), "missing \(identifier)")
        let target = labelContains(row, text)
        XCTAssertTrue(target.waitForExistence(timeout: Self.waitSeconds), "missing text in \(identifier)")
        for _ in 0..<3 where shownItems(app).isEmpty {
            target.press(forDuration: 1.2)
            _ = eventually(5, { !self.shownItems(app).isEmpty })
        }
        XCTAssertTrue(eventually(5, { !self.shownItems(app).isEmpty }),
                      "the system context menu did not open")
    }

    /// Long-presses the first element whose label contains `text`, wherever
    /// it is (a row that is the newest carries `row.latest`, not its own ID;
    /// a bubble is one element, not a static text).
    @MainActor
    func openMenu(_ app: XCUIApplication, text: String) {
        let target = labelContains(element(app, AccessibilityID.transcript), text)
        XCTAssertTrue(target.waitForExistence(timeout: Self.waitSeconds), "missing \(text)")
        target.press(forDuration: 1.2)
    }

    /// Waits until `element` is gone.
    @MainActor
    func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 3,
                        file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(element.exists, "still there: \(element)", file: file, line: line)
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @MainActor
    func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    @MainActor
    static func labels(of snapshot: any XCUIElementSnapshot) -> [String] {
        [snapshot.label] + snapshot.children.flatMap { labels(of: $0) }
    }

    /// A text field's value without its placeholder.
    @MainActor
    static func text(of field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// A menu item by its exported label; never the newest answer's own
    /// "Sao chép" row in the transcript (`answer.copy`).
    @MainActor
    func menuButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, "answer.copy")).firstMatch
    }

    /// A palette button: its exported label ("Thả 😂"), or the emoji alone if
    /// the system menu keeps only the title.
    @MainActor
    func paletteButton(_ app: XCUIApplication, _ emoji: String) -> XCUIElement {
        let exported = labeled(app, "Thả " + emoji)
        return exported.waitForExistence(timeout: 1) ? exported : labeled(app, emoji)
    }

    /// The menu items shown now, among the ones a test cares about.
    @MainActor
    func shownItems(_ app: XCUIApplication) -> [String] {
        ["Trả lời", "Sao chép", "Chọn văn bản", "Sửa", "Báo cáo", "Xóa"].filter { menuButton(app, $0).exists }
    }

    /// The glass pill (`composer.pill`): U7 and U8 measure it, not the
    /// field inside it.
    @MainActor
    func pill(_ app: XCUIApplication) -> XCUIElement { element(app, "composer.pill") }

    @MainActor
    func composerTop(_ app: XCUIApplication) -> CGFloat {
        pill(app).frame.minY
    }

    /// Hides the keyboard as a person does: a slow drag from just above the
    /// pill into the keyboard (`.scrollDismissesKeyboard(.interactively)`),
    /// shorter than the keyboard is tall, so the transcript stays at the
    /// bottom (WS2's U7). With the keyboard up, an older row can sit under
    /// the navigation bar, where a long press reaches the bar, not the row.
    @MainActor
    func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: window.frame.midX, dy: composerTop(app) - 10))
        let to = origin.withOffset(CGVector(dx: window.frame.midX, dy: keyboard.frame.midY + 40))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "the keyboard did not hide")
    }

    /// The row with `identifier` shows `text`: on the row element itself or
    /// on one of its descendants (`descendants(matching:)` never includes the
    /// element), such as the bubble whose label carries it.
    @MainActor
    func rowShows(_ app: XCUIApplication, _ identifier: String, _ text: String) -> Bool {
        let itself = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", identifier, text)).firstMatch
        return itself.exists || labelContains(element(app, identifier), text).exists
    }

    /// The bubble in `row` that reads `text`, once it has settled: no clock
    /// ("Đang gửi") and no failure ("Chưa gửi được"). A settled message
    /// says nothing more until someone reads it (desktop #89: no "Đã gửi").
    @MainActor
    func settled(_ row: XCUIElement, _ text: String) -> XCUIElement {
        row.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND NOT (label CONTAINS %@) AND NOT (label CONTAINS %@)",
            text, "Đang gửi", "Chưa gửi được"))
            .firstMatch
    }

    /// The bubble in `row` that reads `text` and also `word` (a delivery word).
    @MainActor
    func bubble(_ row: XCUIElement, _ text: String, reading word: String) -> XCUIElement {
        row.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", text, word)).firstMatch
    }

    /// Keeps a measured value in the result bundle and the test log.
    @MainActor
    func keepNote(_ name: String, _ text: String) {
        print("[\(name)] \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class ComposerUITests: WS3UITestCase {
    @MainActor
    func testComposerControlsMatchPersonGroupAndAgentCapabilities() {
        let person = launchChat(.chatPeople)
        let personAdd = element(person, AccessibilityID.mediaAdd)
        XCTAssertTrue(personAdd.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertFalse(element(person, "composer.model").exists)
        XCTAssertLessThan(field(person).frame.maxY, personAdd.frame.maxY,
                          "text field stays above the bottom controls")
        person.terminate()

        let group = launchChat(.chatKinds)
        XCTAssertTrue(element(group, AccessibilityID.mediaAdd)
            .waitForExistence(timeout: Self.waitSeconds))
        XCTAssertFalse(element(group, "composer.model").exists)
        group.terminate()

        let agent = launchChat(.chatEmpty)
        let model = element(agent, AccessibilityID.composerModel)
        XCTAssertTrue(model.waitForExistence(timeout: Self.waitSeconds))
        let agentAdd = element(agent, AccessibilityID.mediaAdd)
        XCTAssertTrue(agentAdd.waitForExistence(timeout: Self.waitSeconds),
                      "agent chats have the same + as every other chat")
        XCTAssertLessThan(field(agent).frame.maxY, model.frame.maxY,
                          "agent field stays above the model selector")
    }

    /// The composer's model sheet with the account's subscriptions
    /// (`-AtumScriptedSubscriptions`, synthetic): captured for the port note,
    /// then, with a relay up, a pick of another plan model moves the check.
    /// `ATUM_SUBSCRIPTION_DEMO` (`ready`, `not-ready`) and `ATUM_CAPTURE_TAG`
    /// name the run; pass them as `TEST_RUNNER_…` to `xcodebuild`.
    @MainActor
    func testTheModelSheetListsTheAccountSubscriptions() {
        let environment = ProcessInfo.processInfo.environment
        let demo = environment["ATUM_SUBSCRIPTION_DEMO"] ?? "ready"
        let tag = environment["ATUM_CAPTURE_TAG"] ?? "capture"
        let app = launchChat(.chatEmpty, extra: ["-AtumScriptedSubscriptions", demo])
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        chip.tap()
        // The sheet's own close button, not `navigationBars.firstMatch`: that is
        // the chat's bar behind the sheet, and a swipe on it hits the dimmed
        // area and dismisses the sheet (iOS 27 simulator).
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: Self.waitSeconds),
                      "the model sheet did not open")
        // The sheet opens at the medium detent and the list is lazy, so the
        // Subscriptions header may be below the fold: scroll inside the sheet.
        let section = element(app, "phone.model.section.subscriptions")
        var scrolls = 0
        while !section.waitForExistence(timeout: 1), scrolls < 4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            scrolls += 1
        }
        XCTAssertTrue(section.exists, "no Subscriptions section")
        keepEvidence("subscriptions-\(demo)-\(tag)", of: app)

        let mini = element(app, "phone.model.row.gpt-6.1-mini")
        guard demo == "ready", mini.exists else { return }
        mini.tap()
        let moved = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: mini)
        wait(for: [moved], timeout: Self.waitSeconds)
        keepEvidence("subscriptions-\(demo)-picked-\(tag)", of: app)
    }

    /// The owner's ChatGPT-style row: + leading, model chip, mic, then the
    /// send circle once there is a draft; one row for every chat kind.
    @MainActor
    func testControlsRowOrderIsPlusModelMicSendInAnAgentChat() {
        let app = launchChat(.chatEmpty)
        let add = element(app, AccessibilityID.mediaAdd)
        let model = element(app, AccessibilityID.composerModel)
        let mic = element(app, AccessibilityID.composerMic)
        XCTAssertTrue(add.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(model.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(mic.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertLessThan(add.frame.maxX, model.frame.minX, "+ is left of the model chip")
        XCTAssertLessThan(model.frame.maxX, mic.frame.minX, "model chip is left of the mic")
        XCTAssertFalse(element(app, AccessibilityID.composerSend).exists, "no send circle for an empty draft")
        let rowHeight = mic.frame.height
        // Not listening: no value is spoken and the selected trait is off. The
        // recording state (ink fill, "stop" label, value) needs the microphone
        // permission prompt, which a scripted run cannot answer.
        XCTAssertFalse(mic.isSelected)
        XCTAssertTrue((mic.value as? String ?? "").isEmpty, "idle mic has no accessibility value")

        field(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds))
        field(app).typeText("xin chào")
        let send = element(app, AccessibilityID.composerSend)
        XCTAssertTrue(send.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertLessThan(mic.frame.maxX, send.frame.minX, "the mic is left of the send circle")
        XCTAssertEqual(mic.frame.height, rowHeight, accuracy: 0.5, "the row does not jump when send appears")
    }

    @MainActor
    func testPeopleAndGroupRowsHaveAPlusAndAMicWithoutAModelChip() {
        for scenario in [ScriptedScenario.chatPeople, .chatKinds] {
            let app = launchChat(scenario)
            let add = element(app, AccessibilityID.mediaAdd)
            let mic = element(app, AccessibilityID.composerMic)
            XCTAssertTrue(add.waitForExistence(timeout: Self.waitSeconds))
            XCTAssertTrue(mic.waitForExistence(timeout: Self.waitSeconds))
            XCTAssertLessThan(add.frame.maxX, mic.frame.minX)
            XCTAssertFalse(element(app, AccessibilityID.composerModel).exists)
            app.terminate()
        }
    }

    /// U4: the row exists at the first check after the tap with the literal
    /// text and a clock; the field is empty, the keyboard stays, and more
    /// typing lands in the field. U4b, one read signal (desktop #89): once
    /// accepted the clock goes and nothing says "Đã gửi"; then "Đã xem" (the
    /// reader's face) on the sent row itself after the test releases the receipt.
    @MainActor
    func testU4SendIsInstantLiteralAndKeepsTheKeyboard() throws {
        let receipt = ScriptedSendReceipt()
        let app = launchChat(.chatSend, extra: receipt.arguments)
        let field = field(app)
        XCTAssertTrue(field.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertFalse(element(app, AccessibilityID.composerSend).exists, "no send circle for an empty draft")
        field.tap()
        // The system keyboard took 12 s to appear after the tap on a loaded simulator.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the keyboard did not open")
        let text = "*hi* 1. a_b_"
        field.typeText(text)
        let send = element(app, AccessibilityID.composerSend)
        XCTAssertTrue(send.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(send.label, "Gửi")
        let tapped = Date()
        send.tap()

        // The first check after the tap: my text in the newest row (an older
        // message is `row.latest` until the echo lands), then one snapshot
        // of that row: the bubble reads the literal text and the clock.
        let latest = element(app, AccessibilityID.rowLatest)
        XCTAssertTrue(labelContains(latest, text).waitForExistence(timeout: Self.waitSeconds),
                      "the row is there at the first check")
        let snapshot = try? latest.snapshot()
        let firstCheck = Date().timeIntervalSince(tapped)
        keepScreenshot("U4-1-sending", of: app)
        keepNote("U4-first-check", String(format: "snapshot %.2f s after the tap began (acceptance at 1.5 s)",
                                          firstCheck))
        let labels = snapshot.map(Self.labels(of:)) ?? []
        let spoken = labels.first { $0.contains(text) } ?? ""
        XCTAssertTrue(spoken.contains(text), "literal text, no formatting: \(labels)")
        let sending = spoken.contains("Đang gửi")
        let wentOut = !sending && !spoken.contains("Chưa gửi được")
        XCTAssertFalse(spoken.contains("Đã gửi"), "no Sent receipt (desktop #89): \(spoken)")
        if firstCheck < 1.5 {
            XCTAssertTrue(sending, "a clock before acceptance, \(firstCheck) s after the tap: \(spoken)")
        } else {
            XCTAssertTrue(sending || wentOut,
                          "send state did not advance monotonically after \(firstCheck) s: \(spoken)")
        }
        XCTAssertEqual(Self.text(of: field), "", "the draft cleared in the same frame")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays")

        let transcript = element(app, AccessibilityID.transcript)
        let message = receipt.assertUnread(in: transcript, text: text, sending: "Đang gửi", failed: "Chưa gửi được",
                                           sent: "Đã gửi", seen: "Đã xem")
        keepScreenshot("U4b-1-unread", of: app)
        field.typeText("thêm")
        XCTAssertEqual(Self.text(of: field), "thêm", "focus kept: more typing lands in the field")
        try receipt.releaseAndAssertSeen(message, sent: "Đã gửi", seen: "Đã xem")
        keepScreenshot("U4b-2-seen", of: app)
    }

    /// Sends `text` in `chat.send-fails` and opens its failed-send sheet
    /// from "Chưa gửi được" under the bubble.
    @MainActor
    func sendThenOpenFailure(_ app: XCUIApplication, _ text: String) {
        let field = field(app)
        XCTAssertTrue(field.waitForExistence(timeout: Self.waitSeconds))
        field.tap()
        field.typeText(text)
        element(app, AccessibilityID.composerSend).tap()
        // The parked failure from an earlier run is the newest row until the
        // echo lands, and it has a failed mark too: wait for my text first.
        let latest = element(app, AccessibilityID.rowLatest)
        XCTAssertTrue(labelContains(latest, text).waitForExistence(timeout: Self.waitSeconds), "my send is the newest row")
        let failed = latest.descendants(matching: .any)[Self.failedID].firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 3), "Chưa gửi được under the bubble")
        XCTAssertEqual(failed.label, "Chưa gửi được")
        failed.tap()
        XCTAssertTrue(element(app, AccessibilityID.sendRetry).waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(element(app, AccessibilityID.sendDelete).exists)
    }

    /// U5, "Thử lại" on a recoverable failure: the clock comes back, then the
    /// resend goes out. The scripted queue, like the pinned SDK, sends no
    /// update when it is re-enabled, so the clock comes from the store
    /// (`ConversationCore.retry`, coordinator decision 9); the test checks the
    /// resend first and the clock last, so a missing clock is reported
    /// without hiding the rest.
    @MainActor
    func testU5RetryBringsBackTheClock() {
        let app = launchChat(.chatSendFails)
        let text = "Thử gửi lỗi"
        sendThenOpenFailure(app, text)
        let retry = element(app, AccessibilityID.sendRetry)
        XCTAssertEqual(retry.label, "Thử lại")
        keepScreenshot("U5-1-sheet", of: app)
        retry.tap()
        let latest = element(app, AccessibilityID.rowLatest)
        let clockBack = bubble(latest, text, reading: "Đang gửi").waitForExistence(timeout: 1)
        keepScreenshot("U5-2-retried", of: app)
        XCTAssertTrue(settled(latest, text).waitForExistence(timeout: 10), "the resend went out")
        XCTAssertTrue(clockBack, "Thử lại brought back the clock (plan U5)")
    }

    /// U5, "Xóa": the failed send's row goes.
    @MainActor
    func testU5DeleteRemovesTheFailedRow() {
        let app = launchChat(.chatSendFails)
        sendThenOpenFailure(app, "Lần hai")
        let delete = element(app, AccessibilityID.sendDelete)
        XCTAssertEqual(delete.label, "Xóa")
        keepScreenshot("U5-3-sheet", of: app)
        delete.tap()
        waitForAbsence(labelContains(element(app, AccessibilityID.transcript), "Lần hai"))
        keepScreenshot("U5-4-deleted", of: app)
    }

    /// U5, D8's cached case: a request parked on an earlier run is retried
    /// by its own call.
    @MainActor
    func testU5AParkedSendFromAnEarlierRunIsRetried() {
        let app = launchChat(.chatSendFails)
        // The parked send is the newest row at open (no other events here).
        let parked = element(app, AccessibilityID.rowLatest)
        let text = "Tin này chưa gửi được từ lần trước."
        XCTAssertTrue(labelContains(parked, text).waitForExistence(timeout: 5))
        let failed = parked.descendants(matching: .any)[Self.failedID].firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 5))
        failed.tap()
        let retry = element(app, AccessibilityID.sendRetry)
        XCTAssertTrue(retry.waitForExistence(timeout: Self.waitSeconds))
        retry.tap()
        // `Timeline.retrySend` unparks it, and the SDK shows it sending.
        XCTAssertTrue(bubble(parked, text, reading: "Đang gửi").waitForExistence(timeout: Self.waitSeconds),
                      "the clock is back")
        keepScreenshot("U5-5-parked-retried", of: app)
        XCTAssertTrue(settled(parked, text).waitForExistence(timeout: 4), "the parked send went out")
    }

    /// U7 (the composer's part): with the keyboard up, the newest row stays
    /// fully visible above the pill. Keyboard hiding and the transcript's
    /// pinning are WS2's `TranscriptView` (U7 on `ChatScreen`).
    @MainActor
    func testU7KeyboardKeepsTheLastRowAboveThePill() {
        let app = launchChat(.chatKeyboard)
        let latest = element(app, AccessibilityID.rowLatest)
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(pill(app).waitForExistence(timeout: Self.waitSeconds))
        XCTAssertLessThanOrEqual(latest.frame.maxY, composerTop(app) + Self.framePoints)
        field(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds))
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        XCTAssertLessThan(composerTop(app), keyboardTop, "the pill rides above the keyboard")
        XCTAssertTrue(eventually { latest.frame.maxY <= self.composerTop(app) + Self.framePoints },
                      "the newest row stays above the pill")
        keepScreenshot("U7-keyboard-up", of: app)
    }

    /// U8: one to six lines, then it scrolls inside; no height jump on focus;
    /// the send circle only for a draft with text. It measures the glass
    /// pill, which holds everything the composer shows besides the people
    /// line, so a row added on focus would show here.
    @MainActor
    func testU8ComposerGrowsToSixLinesWithoutAJumpOnFocus() {
        let app = launchChat(.chatKeyboard)
        let field = field(app)
        let pill = pill(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(pill.waitForExistence(timeout: Self.waitSeconds))
        let unfocused = pill.frame.height
        keepNote("U8-pill-unfocused", "\(unfocused) pt, field \(field.frame.height) pt")
        keepScreenshot("U8-1-unfocused", of: app)
        // The glass pill (a 36 pt row inside 4 pt padding), not the union of
        // its children (the field alone measures 24 pt).
        XCTAssertGreaterThanOrEqual(unfocused, 44 - Self.framePoints, "the pill's own frame")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(pill.frame.height, unfocused, accuracy: Self.framePoints, "no height jump on focus")

        field.typeText("Dòng 1")
        let one = pill.frame.height
        XCTAssertEqual(one, unfocused, accuracy: Self.framePoints, "the circle appearing changes nothing")
        XCTAssertTrue(element(app, AccessibilityID.composerSend).exists)
        field.typeText("\nDòng 2")
        let two = pill.frame.height
        XCTAssertGreaterThan(two, one + 10, "Return inserts a line and the pill grows")
        field.typeText("\nDòng 3\nDòng 4\nDòng 5\nDòng 6")
        let six = pill.frame.height
        XCTAssertGreaterThan(six, two + 3 * 10)
        keepNote("U8-pill-heights", "unfocused \(unfocused), one line \(one), two \(two), six \(six) pt")
        keepScreenshot("U8-2-six-lines", of: app)
        field.typeText("\nDòng 7\nDòng 8")
        XCTAssertEqual(pill.frame.height, six, accuracy: Self.framePoints, "capped at six lines, scrolls inside")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        keepScreenshot("U8-3-eight-lines-capped", of: app)
    }

    /// B11: in a people chat, "Minh Anh đang soạn tin…" shows above the pill
    /// (3 s to 6 s), never as a row.
    @MainActor
    func testB11PeopleTypingIsALineAboveTheComposer() {
        let app = launchChat(.chatPeople)
        let composer = field(app)
        composer.tap()
        composer.typeText("Bạn còn đó không?")
        element(app, AccessibilityID.composerSend).tap()
        let line = element(app, "composer.typing")
        XCTAssertTrue(line.waitForExistence(timeout: 6))
        XCTAssertEqual(line.label, "Minh Anh đang soạn tin…")
        XCTAssertFalse(element(app, AccessibilityID.rowTyping).exists, "no typing row in people chats")
        XCTAssertLessThan(line.frame.maxY, composerTop(app) + Self.framePoints)
        keepScreenshot("B11-people-line", of: app)
        waitForAbsence(line, timeout: 6)
    }

    /// B30: the glyph shows only while sync is offline or in error.
    @MainActor
    func testB30ConnectionGlyphShowsOnlyWhenOffline() {
        var app = launchChat(.chatKeyboard)
        XCTAssertFalse(element(app, "chat.connection").exists)
        app.terminate()
        app = launchChat(.chatKeyboard, extra: [Self.connectionGlyphFlag])
        let glyph = element(app, "chat.connection")
        XCTAssertTrue(glyph.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(glyph.label, "Đang kết nối")
        keepScreenshot("B30-connection-glyph", of: app)
    }
}

extension WS3UITestCase {
    /// Closes the actions overlay with a tap on its dim at the left edge,
    /// mid-screen: the capsule, the copy and the menu sit 16 pt in from the
    /// edges, and the top of the screen may hold the capsule.
    @MainActor
    func closeMenu(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 6, dy: window.frame.midY)).tap()
    }

    /// A capture written straight to `ui-evidence/` as a PNG (as
    /// `TranscriptUITestCase` does), so it survives without a result bundle.
    @MainActor
    func keepEvidence(_ name: String, of app: XCUIApplication) {
        keepScreenshot(name, of: app)
        let folder = TranscriptUITestCase.liveEvidence
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(type(of: self)).\(name).png"))
    }
}

final class MessageMenuUITests: WS3UITestCase {
    private let answer = "row.chat.actions.0002"
    private let mineWithAnswerBelow = "row.chat.actions.0004"
    private let laterAnswer = "row.chat.actions.0005"

    /// My assistant, an answer: the palette, "Trả lời", "Sao chép" and
    /// "Chọn văn bản" and Report; never "Sửa" or "Xóa". "Chọn văn bản" opens the sheet.
    @MainActor
    func testAnswerMenuInMyAssistantChatAndSelectText() {
        let app = launchChat(.chatActions)
        openMenu(app, row: answer, text: "Dự án Góc Phố")
        XCTAssertTrue(menuButton(app, "Trả lời").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Chọn văn bản", "Báo cáo"])
        XCTAssertTrue(paletteButton(app, "😂").exists, "the reaction palette")
        keepScreenshot("actions-1-assistant-answer-menu", of: app)
        menuButton(app, "Chọn văn bản").tap()
        let body = element(app, "selectText.body")
        XCTAssertTrue(body.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(labeled(app, "Chọn văn bản").exists, "the sheet's title")
        keepScreenshot("actions-2-select-text-sheet", of: app)
        element(app, "selectText.done").tap()
        waitForAbsence(body)
    }

    /// My assistant, my message: no "Sửa" (editing a prompt does not re-run
    /// an agent), no "Chọn văn bản"; "Xóa" asks first, with the note that
    /// the assistant may remember it, then the row shows the deleted
    /// placeholder.
    @MainActor
    func testMyMessageInMyAssistantChatDeletesAfterAsking() {
        let app = launchChat(.chatActions)
        openMenu(app, row: mineWithAnswerBelow, text: "ngân sách")
        XCTAssertTrue(menuButton(app, "Xóa").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Xóa"])
        keepScreenshot("actions-3-assistant-mine-menu", of: app)
        menuButton(app, "Xóa").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(labeled(alert, "Xóa với mọi người?").exists)
        XCTAssertTrue(labelContains(alert, "Atum có thể vẫn nhớ nội dung đã đọc.").exists)
        keepScreenshot("actions-4-delete-confirmation", of: app)
        alert.buttons["Xóa"].tap()
        XCTAssertTrue(eventually { self.rowShows(app, self.mineWithAnswerBelow, "Tin nhắn đã bị xóa.") },
                      "the row shows the deleted placeholder")
        keepScreenshot("actions-5-deleted", of: app)
    }

    /// B21: "Trả lời" puts the chip in the pill with the keyboard up; the
    /// sent reply shows its quote. An answer directly under its question has
    /// no quote; one with my other message in between has one.
    @MainActor
    func testReplyChipThenQuote() {
        let app = launchChat(.chatActions)
        XCTAssertTrue(element(app, answer).waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, answer).descendants(matching: .any)["quote"].exists,
                       "no quote under an agent answer directly below its question")
        XCTAssertTrue(element(app, laterAnswer).descendants(matching: .any)["quote"].exists,
                      "a visible row in between: the answer quotes")

        openMenu(app, row: answer, text: "Dự án Góc Phố")
        menuButton(app, "Trả lời").tap()
        let chip = element(app, "composer.reply")
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(chip.label.hasPrefix("Đang trả lời Atum"), chip.label)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: Self.waitSeconds), "the keyboard comes up")
        keepScreenshot("actions-6-reply-chip", of: app)
        field(app).typeText("Cảm ơn, hay lắm")
        element(app, AccessibilityID.composerSend).tap()
        XCTAssertFalse(chip.exists, "the chip closes with the send")
        let quote = element(app, AccessibilityID.rowLatest).descendants(matching: .any)["quote"].firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 3), "my reply quotes the answer")
        XCTAssertTrue(quote.label.contains("Dự án Góc Phố"), quote.label)
        keepScreenshot("actions-7-reply-quote", of: app)
    }

    /// Polish P3 (audit issue 5): one press, as the system's context menus
    /// work. A press released in place leaves the menu open and runs
    /// nothing, even with a part under the finger. Then: hold the later
    /// answer, keep the finger down, slide on to the first reaction (👍) and
    /// let go: the reaction is added, with no second tap.
    @MainActor
    func testPressAndSlideOntoAReactionRunsItWithoutASecondTap() {
        let app = launchChat(.chatActions)
        let row = element(app, laterAnswer)
        XCTAssertTrue(row.waitForExistence(timeout: Self.waitSeconds))
        let bubble = labelContains(row, "Kết luận")
        XCTAssertTrue(bubble.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(bubble.isHittable, "the answer is on screen")
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))

        // Held and released in place: the menu stays for a tap, and where
        // its 👍 sits is read from the screen (`MessageMenuLayout` may move
        // the copy up to fit the menu, so it is not computed from the row).
        start.press(forDuration: 1.2)
        let palette = paletteButton(app, "👍")
        XCTAssertTrue(palette.waitForExistence(timeout: Self.waitSeconds), "the menu opened")
        XCTAssertTrue(menuButton(app, "Trả lời").exists, "a press without a slide keeps the menu open")
        XCTAssertFalse(row.descendants(matching: .any)["reaction.👍"].exists, "and runs nothing")
        keepScreenshot("p3-press-menu-open", of: app)
        let target = palette.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        waitForAbsence(menuButton(app, "Trả lời"))

        // Held well past the 0.35 s threshold: on a simulator driven by
        // XCUITest the menu is on screen about 1 s after the touch begins
        // (before and after P3 alike). The finger rests on 👍 before it
        // lifts; the lift is hit-tested where it happens.
        let thumbs = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.midX, dy: target.midY))
        start.press(forDuration: 1.6, thenDragTo: thumbs, withVelocity: .slow, thenHoldForDuration: 1.0)
        let chip = row.descendants(matching: .any)["reaction.👍"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds), "the slide added 👍")
        XCTAssertTrue(chip.isSelected, "mine")
        waitForAbsence(menuButton(app, "Trả lời"))
        keepScreenshot("p3-slide-reaction-added", of: app)
    }

    /// B22: the palette adds my reaction; tapping a chip toggles mine.
    @MainActor
    func testReactionsToggleFromThePaletteAndTheChips() {
        let app = launchChat(.chatActions)
        let later = element(app, laterAnswer)
        openMenu(app, row: laterAnswer, text: "Kết luận")
        let laugh = paletteButton(app, "😂")
        XCTAssertTrue(laugh.waitForExistence(timeout: Self.waitSeconds))
        laugh.tap()
        waitForAbsence(menuButton(app, "Trả lời"))  // a reaction closes the menu
        let chip = later.descendants(matching: .any)["reaction.😂"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(chip.label.hasPrefix("😂") && chip.label.hasSuffix("1"), "the emoji and its count: \(chip.label)")
        XCTAssertTrue(chip.isSelected, "mine")
        XCTAssertTrue(eventually { chip.isHittable }, "the chip is on screen, not behind the menu")
        keepScreenshot("actions-8-reaction-added", of: app)
        chip.tap()
        waitForAbsence(chip)

        let thumbs = element(app, answer).descendants(matching: .any)["reaction.👍"].firstMatch
        XCTAssertTrue(thumbs.exists && thumbs.isSelected, "my earlier 👍")
        thumbs.tap()
        waitForAbsence(thumbs)
        keepScreenshot("actions-9-reactions-toggled", of: app)
    }

    /// A 1:1 people chat: the other person's message has no "Chọn văn bản";
    /// mine adds "Sửa" and "Xóa". "Sửa" loads it into the pill with the edit
    /// chip, and the circle saves.
    @MainActor
    func testPeopleChatMenuAndEdit() {
        let app = launchChat(.chatPeople)
        openMenu(app, text: "Ok bạn.")
        XCTAssertTrue(menuButton(app, "Sửa").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Sửa", "Xóa"])
        keepScreenshot("kinds-1-person-mine-menu", of: app)
        menuButton(app, "Sửa").tap()
        let chip = element(app, "composer.edit")
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(chip.label.hasPrefix("Đang sửa tin nhắn"), chip.label)
        XCTAssertEqual(Self.text(of: field(app)), "Ok bạn.")
        XCTAssertEqual(element(app, AccessibilityID.composerSend).label, "Lưu")
        keepScreenshot("kinds-2-person-edit-chip", of: app)
        field(app).typeText(" Hẹn mai!")
        element(app, AccessibilityID.composerSend).tap()
        XCTAssertTrue(labelContains(app, "Ok bạn. Hẹn mai!").waitForExistence(timeout: 10),
                      "the edit landed in place")
        XCTAssertFalse(chip.exists)

        dismissKeyboard(app)
        openMenu(app, text: "Tuyệt!")
        XCTAssertTrue(menuButton(app, "Trả lời").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Báo cáo"])
        keepScreenshot("kinds-3-person-theirs-menu", of: app)
    }

    /// A group: as a person chat.
    @MainActor
    func testGroupChatMenu() {
        let app = launchChat(.chatKinds)
        openMenu(app, row: "row.chat.kinds.0017", text: "Thứ Sáu đi ăn trưa")
        XCTAssertTrue(menuButton(app, "Trả lời").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Báo cáo"])
        keepScreenshot("kinds-4-group-theirs-menu", of: app)
        closeMenu(app)
        openMenu(app, row: "row.chat.kinds.0019", text: "hẹn 12 giờ")
        XCTAssertTrue(menuButton(app, "Sửa").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Trả lời", "Sao chép", "Sửa", "Xóa"])
        keepScreenshot("kinds-5-group-mine-menu", of: app)
    }

    /// B17 in the select-text sheet: a link tapped there goes through
    /// `LinkPolicy` like every other: the sheet closes, then a PayOS link
    /// shows the held-link line and an ordinary link opens the in-app Safari
    /// page.
    @MainActor
    func testLinksInTheSelectTextSheetGoThroughLinkPolicy() {
        let app = launchChat(.botMoonNotice)
        // Moon's later answer lands at 5 s; open the menu after it.
        XCTAssertTrue(labelContains(element(app, AccessibilityID.transcript), "ngày tốt").waitForExistence(timeout: 8))
        openSelectText(app)
        var payos = sheetLink(app, "payos")
        // The sheet's paragraphs join the tree one by one: look again each time.
        XCTAssertTrue(eventually { payos = self.sheetLink(app, "payos"); return payos.exists },
                      "no PayOS link in the sheet: \(sheetLabels(app))")
        keepScreenshot("links-1-select-text-sheet", of: app)
        tapLink(payos)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no held-link line")
        XCTAssertTrue(alert.label.contains("Liên kết này chưa mở được trên iPhone."), alert.label)
        XCTAssertFalse(element(app, "selectText.body").exists, "the sheet stays under the line")
        keepScreenshot("links-2-held-from-sheet", of: app)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(eventually { !app.alerts.firstMatch.exists }, "the held-link line stays")

        openSelectText(app)
        var page = sheetLink(app, "atumplatform.com")
        XCTAssertTrue(eventually { page = self.sheetLink(app, "atumplatform.com"); return page.exists },
                      "no ordinary link in the sheet: \(sheetLabels(app))")
        keepScreenshot("links-3-select-text-sheet-again", of: app)
        tapLink(page)
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Đóng", "Close", "Xong", "Done"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the in-app Safari page did not show")
        XCTAssertFalse(element(app, "selectText.body").exists, "the sheet stays under the page")
        XCTAssertEqual(app.state, .runningForeground, "the link left the app")
        keepScreenshot("links-4-safari-from-sheet", of: app)
        close.tap()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 5))
    }

    /// Opens Moon's linked answer's menu, then "Chọn văn bản".
    @MainActor
    private func openSelectText(_ app: XCUIApplication) {
        openMenu(app, text: "Xem thêm tại")
        let select = menuButton(app, "Chọn văn bản")
        XCTAssertTrue(select.waitForExistence(timeout: Self.waitSeconds), "no select-text item")
        select.tap()
        XCTAssertTrue(element(app, "selectText.body").waitForExistence(timeout: Self.waitSeconds), "no sheet")
    }

    /// A link inside the select-text sheet (never the transcript's own,
    /// under the sheet). The sheet's structured text is one element per
    /// paragraph, each carrying `selectText.body`.
    @MainActor
    private func sheetLink(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let paragraphs = app.descendants(matching: .any).matching(identifier: "selectText.body")
        for index in 0..<max(paragraphs.count, 1) {
            let link = paragraphs.element(boundBy: index).descendants(matching: .link)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            if link.exists { return link }
        }
        return paragraphs.firstMatch.descendants(matching: .link)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps a link as a finger does, at a point on its text. A link that
    /// wraps onto a second line (both links here, at the default size) has a
    /// frame spanning both lines whose centre falls beside the text, which
    /// XCUITest calls "not hittable"; its first line ends at the frame's
    /// right edge, so the tap lands near there, in the upper quarter.
    @MainActor
    private func tapLink(_ link: XCUIElement) {
        let lines = link.frame.height > 30
        link.coordinate(withNormalizedOffset: CGVector(dx: lines ? 0.9 : 0.5, dy: lines ? 0.25 : 0.5)).tap()
    }

    /// What the sheet holds, for a failure message.
    @MainActor
    private func sheetLabels(_ app: XCUIApplication) -> String {
        let paragraphs = app.descendants(matching: .any).matching(identifier: "selectText.body")
        func walk(_ node: any XCUIElementSnapshot) -> [String] {
            ["\(node.elementType.rawValue):\(node.label)"] + node.children.flatMap(walk)
        }
        return (0..<paragraphs.count).compactMap { try? paragraphs.element(boundBy: $0).snapshot() }
            .flatMap(walk).joined(separator: " | ")
    }

    /// Moon: copy, select text and Report on its answers; no palette.
    @MainActor
    func testBotRoomMenuOffersCopySelectAndReport() {
        let app = launchChat(.botMoonNotice)
        openMenu(app, row: "row.bot.moon-notice.0001", text: "mình là Moon")
        XCTAssertTrue(menuButton(app, "Sao chép").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Sao chép", "Chọn văn bản", "Báo cáo"])
        XCTAssertFalse(paletteButton(app, "😂").exists, "no reactions in bot rooms")
        keepScreenshot("kinds-6-bot-answer-menu", of: app)
    }

    @MainActor
    func testAssistantAnswerOpensMessageReportSheet() {
        let app = launchChat(.chatActions)
        openMenu(app, row: answer, text: "Dự án Góc Phố")
        assertMessageReportSheet(app)
    }

    @MainActor
    func testAppBotMessageOpensMessageReportSheet() {
        let app = launchChat(.botMoonNotice)
        openMenu(app, row: "row.bot.moon-notice.0001", text: "mình là Moon")
        assertMessageReportSheet(app)
    }

    @MainActor
    func testAppBotNoticeMenuSubmitsReportWithReason() throws {
        let probe = TranscriptUITestCase.liveEvidence.appendingPathComponent("probe/\(UUID().uuidString)")
        let app = launchChat(.botMoonNotice, extra: ["-AtumUITestProbeDir", probe.path])
        let notice = element(app, "row.bot.moon-notice.0003")
        XCTAssertTrue(notice.waitForExistence(timeout: Self.waitSeconds))
        notice.press(forDuration: 1.2)
        XCTAssertTrue(menuButton(app, "Báo cáo").waitForExistence(timeout: Self.waitSeconds))
        XCTAssertEqual(shownItems(app), ["Sao chép", "Chọn văn bản", "Báo cáo"])
        XCTAssertFalse(menuButton(app, "Chặn").exists)
        menuButton(app, "Báo cáo").tap()
        let reason = app.textFields["report.reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: Self.waitSeconds))
        reason.tap()
        reason.typeText("  unsafe content  ")
        element(app, "report.send").tap()
        try assertReportProbe(probe, roomID: "bot.moon-notice", eventID: "$bot.moon-notice.0003", reason: "unsafe content")
        XCTAssertTrue(eventually(5) { !self.element(app, "report.sheet").exists })
    }

    @MainActor
    func testAssistantReportSubmissionUsesDefaultReason() throws {
        let probe = TranscriptUITestCase.liveEvidence.appendingPathComponent("probe/\(UUID().uuidString)")
        let app = launchChat(.chatActions, extra: ["-AtumUITestProbeDir", probe.path])
        openMenu(app, row: answer, text: "Dự án Góc Phố")
        menuButton(app, "Báo cáo").tap()
        XCTAssertTrue(element(app, "report.send").waitForExistence(timeout: Self.waitSeconds))
        element(app, "report.send").tap()
        try assertReportProbe(probe, roomID: "chat.actions", eventID: "$chat.actions.0002", reason: "abuse")
        XCTAssertTrue(eventually(5) { !self.element(app, "report.sheet").exists })
    }

    @MainActor
    private func assertReportProbe(_ folder: URL, roomID: String, eventID: String, reason: String) throws {
        let file = folder.appendingPathComponent("reports.txt")
        XCTAssertTrue(eventually(5) { FileManager.default.fileExists(atPath: file.path) })
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one routed report per submission")
        let json = try XCTUnwrap(lines.first?.split(separator: " ", maxSplits: 1).last)
        let request = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(request, ["roomID": roomID, "eventID": eventID, "reason": reason])
    }

    /// These fixtures have no homeserver: verify the shared sheet and its
    /// exported message wording, then cancel without claiming a server report.
    @MainActor
    private func assertMessageReportSheet(_ app: XCUIApplication) {
        let report = menuButton(app, "Báo cáo")
        XCTAssertTrue(report.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertFalse(menuButton(app, "Chặn").exists, "reporting content must not add Block")
        report.tap()
        let sheet = element(app, "report.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: Self.waitSeconds))
        XCTAssertTrue(labeled(app, "Báo cáo tin nhắn này?").exists)
        XCTAssertTrue(element(app, "report.reason").exists)
        XCTAssertTrue(element(app, "report.send").isEnabled)
        element(app, "report.cancel").tap()
        waitForAbsence(sheet)
    }

    /// Review A1: while the menu is open the pressed message shows once (its
    /// lifted copy; the row itself is hidden), and the capsule, the copy and
    /// the menu never overlap one another or leave the screen. Every reaction
    /// is at least 44 pt to tap.
    @MainActor
    func testTheLiftedMessageShowsOnceAndNothingCoversIt() {
        let app = launchChat(.chatActions)
        for (row, text) in [(answer, "Dự án Góc Phố"), (laterAnswer, "Kết luận")] {
            openMenu(app, row: row, text: text)
            let reactions = element(app, "menu.reactions")
            let preview = element(app, "menu.preview")
            let menu = element(app, "menu.items")
            XCTAssertTrue(reactions.waitForExistence(timeout: Self.waitSeconds))
            XCTAssertTrue(preview.exists && menu.exists)
            let copies = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text)).allElementsBoundByIndex
                .filter { $0.isHittable }
            // The copy may expose its text view as a second element; every
            // visible match must be inside the lifted copy, none elsewhere.
            XCTAssertFalse(copies.isEmpty, "the lifted copy shows the text")
            let outside = copies.filter { !preview.frame.insetBy(dx: -1, dy: -1).contains($0.frame) }
            XCTAssertTrue(outside.isEmpty, "the text shows once: "
                + outside.map { "\($0.identifier) \($0.elementType.rawValue) \($0.frame)" }.joined(separator: ", "))
            print("MENU \(row) matches: " + copies.map { "\($0.identifier) \($0.frame)" }.joined(separator: ", "))
            let window = app.windows.firstMatch.frame
            let parts = [reactions.frame, preview.frame, menu.frame]
            for part in parts {
                XCTAssertTrue(window.contains(part), "on screen: \(part)")
            }
            for (index, part) in parts.enumerated() {
                for other in parts.dropFirst(index + 1) {
                    XCTAssertFalse(part.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(part) covers \(other)")
                }
            }
            for button in reactions.buttons.allElementsBoundByIndex {
                XCTAssertGreaterThanOrEqual(min(button.frame.width, button.frame.height), 44, button.label)
            }
            keepEvidence("actions-10-lifted-\(row)", of: app)
            // A tap on the dim closes it and the row comes back.
            closeMenu(app)
            waitForAbsence(menu)
            XCTAssertTrue(element(app, row).waitForExistence(timeout: Self.waitSeconds), "the row is back")
        }
    }
}

/// Review C1: in my assistant's chat, while it works on what I sent, the
/// empty send circle is Stop; the request is sent once, with an honest
/// pending line, and a failure brings Stop back and re-sends the same key.
/// Hosts without the stop route (live today, and scripted without
/// `-AtumScriptedTurnStop`) draw no Stop at all.
final class TurnStopUITests: WS3UITestCase {
    private let probe = TranscriptUITestCase.liveEvidence
        .appendingPathComponent("probe/\(UUID().uuidString)", isDirectory: true)

    @MainActor
    private func launch(answer: String?) -> XCUIApplication {
        var extra = ["-AtumUITestProbeDir", probe.path]
        if let answer { extra += [AtumLaunchArguments.scriptedTurnStopFlag, answer] }
        return launchChat(.chatTurnStop, extra: extra)
    }

    @MainActor
    private func ask(_ app: XCUIApplication) {
        let composer = app.textFields[AccessibilityID.composerField]
        guard eventually(15, { composer.exists && composer.isHittable }) else {
            return XCTFail("The composer field did not become hittable")
        }
        // On a loaded simulator one element query can take ~10 s, so a
        // polled focus check spent its whole budget without a second tap
        // (run-3). Wait on the keyboard with XCTest's own expectation, long
        // enough for a slow snapshot, and tap again only if it never came.
        let focus = NSPredicate(format: "hasKeyboardFocus == true")
        let keyboard = app.keyboards.firstMatch
        var focused = false
        for _ in 0..<3 where !focused {
            composer.tap()
            focused = keyboard.waitForExistence(timeout: 20) || focus.evaluate(with: composer)
        }
        guard focused else {
            return XCTFail("The composer field did not take keyboard focus")
        }
        composer.typeText("Tóm tắt giúp mình")
        let send = element(app, AccessibilityID.composerSend)
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send circle")
        send.tap()
    }

    @MainActor
    private func stopRequests() -> [String] {
        let text = (try? String(contentsOf: probe.appendingPathComponent("turn-stop.txt"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { String($0.split(separator: " ", maxSplits: 1).last ?? "") }
    }

    /// Desktop `cloud.stopping` (atum-desktop #46): the control's own label
    /// while a stop is unconfirmed.
    private let stopping = "Đang dừng…"
    /// Desktop `cloud.stopRefused`.
    private let refused = "Chưa dừng được câu trả lời này. Có thể trợ lý đã trả lời xong."

    @MainActor
    func testStopWhileWorkingThenStopped() {
        let app = launch(answer: "stopped")
        ask(app)
        let stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "Stop while Atum works")
        XCTAssertEqual(stop.label, "Dừng")
        XCTAssertTrue(stop.isEnabled)
        assertSingleWorkingRow(app)
        // This fixture acknowledges Stop but does not fabricate a synced
        // turn-end event. Footer disappearance is proved by TranscriptUITests
        // when the final message arrives and the typing signal actually ends.
        // 44 wide; 36 tall in the layout so the row never jumps, with its
        // hit shape 4 pt beyond above and below.
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
        keepEvidence("stop-1-working", of: app)
        stop.tap()
        stop.tap()  // a second tap while the request is out sends nothing
        // The scripted route answers in 0.4 s, shorter than one element query
        // on a loaded simulator, so the transient Stopping… is proved by
        // `testStopRequestedSaysStoppingThenSettles`, where it lasts 15 s.
        // Confirmed: desktop leaves the Stop glyph, disabled, until the turn
        // ends, with no band under the composer.
        XCTAssertTrue(eventually(5) { stop.label == "Dừng" }, stop.label)
        XCTAssertFalse(stop.isEnabled, "no second Stop once stopped")
        XCTAssertFalse(element(app, "composer.turn").exists, "a turn's stop has no band")
        XCTAssertEqual(stopRequests().count, 1, "\(stopRequests())")
        keepEvidence("stop-3-stopped", of: app)
    }

    @MainActor
    func testStopRequestedSaysStoppingThenSettles() {
        let app = launch(answer: "stop_requested")
        ask(app)
        let stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        stop.tap()
        XCTAssertTrue(eventually(3) { stop.label == self.stopping }, stop.label)
        // The request is answered `stop_requested`: still Stopping…, never stopped.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(stop.label, stopping, "never shown as stopped on stop_requested")
        XCTAssertFalse(stop.isEnabled)
        XCTAssertFalse(element(app, "composer.turn").exists)
        keepEvidence("stop-4-requested", of: app)
        // A draft keeps the in-flight label until the request settles.
        field(app).typeText(" thêm")
        XCTAssertTrue(eventually(5) { (self.field(app).value as? String)?.contains("thêm") == true })
        XCTAssertEqual(stop.label, stopping, "Stopping… stays with a draft")
        let send = element(app, AccessibilityID.composerSend)
        XCTAssertFalse(send.exists, "Send waits for the request to settle")
        keepEvidence("stop-4b-requested-with-draft", of: app)
        // Desktop `MATRIX_STOP_SETTLE_MS`: after 15 s it settles quietly.
        XCTAssertTrue(eventually(20) { send.exists && send.isEnabled }, "Send takes the slot after settling")
        XCTAssertFalse(stop.exists)
        XCTAssertFalse(element(app, "composer.turn").exists, "settles without a word")
        XCTAssertEqual(stopRequests().count, 1)
        keepEvidence("stop-5-settled", of: app)
    }

    @MainActor
    func testAFailedStopComesBackAndTheRetryResendsTheSameRequest() {
        let app = launch(answer: "failed-then-stopped")
        ask(app)
        let stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        stop.tap()
        XCTAssertTrue(eventually(5) { stop.exists && stop.isEnabled && stop.label == "Dừng"
                          && self.stopRequests().count == 1 },
                      "Stop comes back after the failure")
        let band = element(app, "composer.turn")
        XCTAssertTrue(band.waitForExistence(timeout: 3), "the refused band")
        XCTAssertEqual(band.label, refused)
        keepEvidence("stop-6-refused", of: app)
        stop.tap()
        XCTAssertTrue(eventually(5) { !self.element(app, "composer.turn").exists
                          && stop.label == "Dừng" && !stop.isEnabled },
                      "the retry is confirmed; the band goes")
        let requests = stopRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests).count, 1, "the same event and request ID: \(requests)")
    }

    /// The runner beside the test run (`verify.sh`) applies `appearance
    /// dark|light` to the simulator; true once applied.
    @discardableResult
    private func requestAppearance(_ value: String) -> Bool {
        let file = TranscriptUITestCase.runnerRequest
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("appearance \(value)".utf8).write(to: file)
        let deadline = Date().addingTimeInterval(20)
        while FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let applied = !FileManager.default.fileExists(atPath: file.path)
        if !applied { try? FileManager.default.removeItem(at: file) }
        return applied
    }

    /// Stopping… and the refused band in dark, kept as evidence. Each state
    /// is one that lasts: `stop_requested` holds Stopping… for 15 s, and
    /// `failed` keeps the band.
    @MainActor
    func testStoppingAndTheRefusedBandInDark() {
        XCTAssertTrue(requestAppearance("dark"), "no appearance runner beside the run")
        addTeardownBlock { [self] in requestAppearance("light") }
        var app = launch(answer: "stop_requested")
        ask(app)
        var stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        keepEvidence("stop-dark-1-working", of: app)
        stop.tap()
        XCTAssertTrue(eventually(10) { stop.label == self.stopping }, stop.label)
        XCTAssertFalse(stop.isEnabled)
        keepEvidence("stop-dark-2-stopping", of: app)
        app.terminate()
        app = launch(answer: "failed")
        ask(app)
        stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        stop.tap()
        let band = element(app, "composer.turn")
        XCTAssertTrue(band.waitForExistence(timeout: 15))
        XCTAssertEqual(band.label, refused)
        keepEvidence("stop-dark-3-refused", of: app)
    }

    /// At the largest accessibility text size the Stopping… capsule keeps
    /// its whole label inside the screen, and the refused band leaves the
    /// field above the keyboard; VoiceOver reads both.
    @MainActor
    private func launchLargest(answer: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatTurnStop)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
               "-AtumUITestProbeDir", probe.path, AtumLaunchArguments.scriptedTurnStopFlag, answer]
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")
        return app
    }

    @MainActor
    func testStoppingFitsAtTheLargestTextSize() {
        var app = launchLargest(answer: "stop_requested")
        ask(app)
        var stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        let glyphWidth = stop.frame.width
        stop.tap()
        XCTAssertTrue(eventually(10) { stop.label == self.stopping }, stop.label)
        let screen = app.windows.firstMatch.frame
        let capsule = stop.frame
        XCTAssertGreaterThan(capsule.width, glyphWidth, "the label is drawn, not just a glyph: \(capsule)")
        XCTAssertGreaterThanOrEqual(capsule.minX, screen.minX, "\(capsule) in \(screen)")
        XCTAssertLessThanOrEqual(capsule.maxX, screen.maxX, "\(capsule) in \(screen)")
        keepEvidence("stop-ax-1-stopping", of: app)
        app.terminate()
        app = launchLargest(answer: "failed")
        ask(app)
        stop = element(app, "composer.stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        stop.tap()
        let band = element(app, "composer.turn")
        XCTAssertTrue(band.waitForExistence(timeout: 15))
        XCTAssertEqual(band.label, refused, "VoiceOver reads the band's words")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(field(app).frame.maxY, keyboard.frame.minY + 1,
                                     "the band leaves the field above the keyboard")
        }
        keepEvidence("stop-ax-2-refused", of: app)
    }

    @MainActor
    func testNoStopRouteNoStop() {
        let app = launch(answer: nil)
        ask(app)
        XCTAssertTrue(element(app, "composer.pill").waitForExistence(timeout: 3))
        XCTAssertTrue(eventually(8) { (self.element(app, "composer.pill").value as? String) == "Đang thực hiện tác vụ này" },
                      "the pill reads as working")
        XCTAssertFalse(element(app, "composer.stop").exists, "never a dead button")
    }
}

/// W4-R: the model picker and the composer chip as the desktop draws them
/// (#119): the chip is the current model's mark and name with no chevron;
/// each row is the provider's mark, the name with the check beside it and
/// Atum's line; the plans with nothing to pick keep their real marks.
/// Synthetic scripted data (`-AtumScriptedSubscriptions ready`,
/// `-AtumScriptedConnections plans`). Captures go to the run's
/// `ATUM_UI_SCRATCH/ui-evidence` as `PhoneModelPickerVisualsUITests.*.png`.
final class PhoneModelPickerVisualsUITests: WS3UITestCase {
    private static let sheetWait: TimeInterval = 8
    @MainActor
    private func openPicker(language: String, dark: Bool,
                            size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatEmpty)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-atum.appearance", dark ? "dark" : "light", "-UIPreferredContentSizeCategoryName", size,
               "-AtumScriptedSubscriptions", "ready", "-AtumScriptedConnections", "plans"]
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: Self.sheetWait), "no model chip")
        return app
    }

    @MainActor
    private func scrollSheet(_ app: XCUIApplication, until target: XCUIElement, limit: Int = 8) {
        var scrolls = 0
        while !(target.exists && target.isHittable), scrolls < limit {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
            scrolls += 1
        }
    }

    @MainActor
    private func capture(language: String, dark: Bool) {
        let tag = language + "-" + (dark ? "dark" : "light")
        let app = openPicker(language: language, dark: dark)
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertFalse(chip.label.isEmpty, "the chip names the model")
        keepEvidence("chip-\(tag)", of: app)
        chip.tap()
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: Self.sheetWait),
                      "the model sheet did not open")
        let current = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'phone.model.row.' AND isSelected == true"))
            .firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: Self.sheetWait), "no current row")
        keepEvidence("sheet-\(tag)", of: app)
        let plan = element(app, "phone.model.plan.claude-plan")
        scrollSheet(app, until: plan)
        XCTAssertTrue(plan.exists, "no Claude plan entry")
        keepEvidence("sheet-plans-\(tag)", of: app)
        app.terminate()
    }

    @MainActor
    func testRowsAndChipInEnglishAndVietnameseLightAndDark() {
        for language in ["en", "vi"] {
            for dark in [false, true] { capture(language: language, dark: dark) }
        }
    }

    /// The largest accessibility size: the chip and the rows still read, the
    /// marks grow with the text, and the plans' Connect sits under the words.
    @MainActor
    func testTheLargestTextSize() {
        let app = openPicker(language: "en", dark: false, size: "UICTContentSizeCategoryAccessibilityXXXL")
        let chip = element(app, AccessibilityID.composerModel)
        keepEvidence("chip-en-light-ax5", of: app)
        chip.tap()
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: Self.sheetWait))
        keepEvidence("sheet-en-light-ax5", of: app)
        let connect = app.buttons["phone.model.plan.claude-plan.connect"]
        scrollSheet(app, until: connect, limit: 14)
        XCTAssertTrue(connect.exists && connect.isHittable, "Connect is not reachable at AX5")
        keepEvidence("sheet-plans-en-light-ax5", of: app)
    }
}
