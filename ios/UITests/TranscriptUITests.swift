import AtumChat
import XCTest

/// The transcript lane's U proofs (plan §5.2 S1 "Accept, U"): U1, U2, U3,
/// U6, U7, U8, U9, U10, `chat.reply-at-bottom`, the visible-text bans and the
/// accessibility audit. Scripted chats in Vietnamese, animations off.
final class TranscriptUITests: TranscriptUITestCase {
    /// U1: open lands at the latest message, with day dividers and grouping.
    @MainActor
    func testU1OpenLandsOnTheLatestMessage() {
        let app = launchChat(ScriptedScenario.chatKeyboard.rawValue)
        assertVisible(latest(app), in: app, "U1 latest")
        // B16: sender, time, content and delivery in one label, joined by the
        // system.
        let spoken = latest(app).descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Bạn, ")).firstMatch
        XCTAssertTrue(spoken.exists, "U1: the newest row's label does not start with its sender")
        record("u1.latestLabel", spoken.label)
        XCTAssertEqual(followValue(app), "following")
        XCTAssertTrue(app.staticTexts["Hôm nay"].exists || app.staticTexts["Hôm qua"].exists, "U1: no day divider")
        XCTAssertFalse(pill(app).exists)
        assertNoBannedWords(app)
        keepScreenshot("u1-open", of: app)
    }

    /// U2: typing dots, then the answer, fully visible; still following.
    @MainActor
    func testU2DotsThenAnswerStayInView() {
        let (app, start) = launchTimedChat(ScriptedScenario.chatLongAnswer.rawValue)
        wait(until: start.addingTimeInterval(2.0))
        keepScreenshot("u2-dots", of: app)
        assertVisible(element(app, AccessibilityID.rowTyping), in: app, "U2 typing row")
        XCTAssertEqual(followValue(app), "following")
        wait(until: start.addingTimeInterval(4))
        XCTAssertFalse(element(app, AccessibilityID.rowTyping).exists, "U2: dots after the answer")
        // The answer is two screens long and final: it folds (owner,
        // 2026-11-12), and the end of its folded bubble, "Show more", sits
        // at the bottom. (A folded row's frame spans its unclipped text.)
        let toggle = element(app, "message.fold.\(ScriptedScenario.chatLongAnswer.rawValue).answer")
        XCTAssertTrue(toggle.waitForExistence(timeout: 2), "U2: the long answer did not fold")
        XCTAssertLessThanOrEqual(toggle.frame.maxY, visibleBottom(app) + Self.framePoints, "U2: the answer's end is hidden")
        XCTAssertEqual(followValue(app), "following")
        XCTAssertFalse(pill(app).exists)
        keepScreenshot("u2-answer", of: app)
    }

    /// U3: scrolled up, three answers and the dots arrive; the top row stays
    /// within 4 pt, the pill reads 3, tapping it goes to the bottom and
    /// clears it.
    @MainActor
    func testU3ScrolledUpShowsThePill() {
        let (app, start) = launchTimedChat(ScriptedScenario.chatReplyScrolledUp.rawValue)
        XCTAssertTrue(latest(app).waitForExistence(timeout: 2))
        wait(0.3)
        for _ in 0..<3 where !followValue(app).hasPrefix("detached") {
            transcript(app).swipeDown(velocity: XCUIGestureVelocity(rawValue: 3500))
            wait(0.7)
        }
        guard let anchor = settledTopVisibleRow(app) else {
            keepScreenshot("u3-no-row", of: app)
            print("MEASURE u3.edges=\(visibleTop(app)) \(visibleBottom(app))")
            for node in snapshotElements(app) where node.identifier.hasPrefix("row.") {
                print("MEASURE u3.row \(node.identifier) \(node.frame)")
            }
            return XCTFail("U3: no visible row")
        }
        // The anchor may be taken after the three answers landed (XCUITest
        // is slow to settle after a fling); the typing row still arrives at
        // 6.5 s, and the measure covers whatever arrived after the anchor.
        record("u3.anchoredAtSecond", Date().timeIntervalSince(start))
        XCTAssertTrue(followValue(app).hasPrefix("detached"))
        wait(until: start.addingTimeInterval(7.5))
        let moved = abs(row(app, String(anchor.id.dropFirst(4))).frame.minY - anchor.frame.minY)
        record("u3.topRowMoved", moved)
        XCTAssertLessThanOrEqual(moved, Self.framePoints, "U3: the top row moved")
        XCTAssertTrue(pill(app).exists, "U3: no pill")
        XCTAssertTrue(pill(app).label.contains("3"), "U3: pill reads \(pill(app).label)")
        keepScreenshot("u3-pill", of: app)
        pill(app).tap()
        XCTAssertTrue(waitFor(3) { !self.pill(app).exists && self.followValue(app) == "following" }, "U3: pill stays")
        assertVisible(latest(app), in: app, "U3 latest after the jump")
        keepScreenshot("u3-after-jump", of: app)
    }

    /// §2.5 `chat.own-other-device`: my message from the Mac is counted by
    /// the pill and the view does not move.
    @MainActor
    func testU3MyMessageFromAnotherDeviceIsCounted() {
        let (app, start) = launchTimedChat(ScriptedScenario.chatOwnOtherDevice.rawValue)
        XCTAssertTrue(latest(app).waitForExistence(timeout: 2))
        wait(0.3)
        for _ in 0..<3 where !followValue(app).hasPrefix("detached") {
            transcript(app).swipeDown(velocity: XCUIGestureVelocity(rawValue: 3500))
            wait(0.7)
        }
        XCTAssertTrue(followValue(app).hasPrefix("detached"), "did not detach from the latest message")
        guard let anchor = settledTopVisibleRow(app) else { return XCTFail("no visible row") }
        wait(until: start.addingTimeInterval(6.5))
        let moved = abs(row(app, String(anchor.id.dropFirst(4))).frame.minY - anchor.frame.minY)
        record("u3.ownOtherDeviceMoved", moved)
        XCTAssertLessThanOrEqual(moved, Self.framePoints)
        XCTAssertTrue(pill(app).exists && pill(app).label.contains("1"), "pill reads \(pill(app).label)")
        XCTAssertEqual(followValue(app), "detached:1")
        keepScreenshot("u3-own-other-device", of: app)
    }

    /// U6: earlier history loads as I scroll up; the row I am reading stays
    /// within 4 pt; the start of the room is reached.
    @MainActor
    func testU6PaginationKeepsTheRowBeingRead() {
        let app = launchChat(ScriptedScenario.chatPaginate.rawValue)
        let screen = visibleBottom(app) - visibleTop(app)
        // Every loaded row exists in the eager stack: the start is reached
        // when its first rows are on screen.
        func startOnScreen() -> Bool {
            isOnScreen(row(app, "chat.paginate.0001"), in: app) || isOnScreen(row(app, "chat.paginate.0002"), in: app)
        }
        var worst: CGFloat = 0
        var windows = 0
        for _ in 0..<12 {
            if startOnScreen() { break }
            drag(app, by: screen * 0.8)
            guard let reading = topVisibleRow(app) else { continue }
            wait(1.2)
            let now = row(app, String(reading.id.dropFirst(4)))
            guard now.exists else { continue }
            worst = max(worst, abs(now.frame.minY - reading.frame.minY))
            windows += 1
        }
        record("u6.windows", windows)
        record("u6.rowMovedMax", worst)
        XCTAssertLessThanOrEqual(worst, Self.framePoints, "U6: the row being read moved")
        for _ in 0..<30 where !startOnScreen() {
            transcript(app).swipeDown(velocity: .fast)
        }
        wait(0.5)
        XCTAssertTrue(startOnScreen(), "U6: the start of the room was not reached")
        keepScreenshot("u6-start-of-room", of: app)
    }

    /// B4, B5, G-scroll check 4: the quotes of each older page arrive late,
    /// as the SDK delivers them, and a reaction lands on the page's newest
    /// message; those rows are above the row being read and change height
    /// after the page landed. The row being read stays within 4 pt.
    @MainActor
    func testU6LateQuotesAndReactionsAboveKeepTheRowBeingRead() {
        let app = launchChat(ScriptedScenario.chatPaginate.rawValue, extra: ["-AtumScriptedLateDetails"] + probeArguments)
        let screen = visibleBottom(app) - visibleTop(app)
        let chips = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '👍'"))
        var worst: CGFloat = 0
        var windows = 0
        for _ in 0..<12 {
            drag(app, by: screen * 0.8)
            guard let reading = readingRow(app) else { continue }
            wait(2) // a scripted page takes 0.4 s, its quotes and the reaction 0.8 s more
            let now = row(app, String(reading.id.dropFirst(4)))
            guard now.exists else { continue }
            worst = max(worst, abs(now.frame.minY - reading.frame.minY))
            print("MEASURE u6late.window \(windows) \(reading.id) moved \(now.frame.minY - reading.frame.minY)")
            windows += 1
        }
        let holds = probeLines("holds.txt")
        record("u6late.windows", windows)
        record("u6late.rowMovedMax", worst)
        record("u6late.holds", holds.count)
        for line in holds { print("MEASURE u6late.hold \(line.text)") }
        XCTAssertGreaterThan(windows, 3)
        // Pages and their late quotes that land during a drag show when it
        // ends, in one hold; at least a page and a late change.
        XCTAssertGreaterThanOrEqual(holds.count, 2, "late quotes and reactions were not held")
        XCTAssertTrue(holds.allSatisfy { $0.text.contains("kept=1") }, "holds that did not land: \(holds.map(\.text))")
        XCTAssertLessThanOrEqual(worst, Self.framePoints, "the row being read moved when rows above it changed height")
        XCTAssertGreaterThan(chips.count, 0, "no reaction landed")
    }

    /// U7: the keyboard shows and hides at the bottom; the last row stays
    /// visible above the composer.
    @MainActor
    func testU7KeyboardKeepsTheLastRowVisible() {
        let app = launchChat(ScriptedScenario.chatKeyboard.rawValue)
        composerField(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "U7: no keyboard")
        wait(0.8)
        assertVisible(latest(app), in: app, "U7 latest with the keyboard up")
        XCTAssertEqual(followValue(app), "following")
        composerField(app).typeText("abc")
        XCTAssertTrue(waitFor(2) { self.composerField(app).value as? String == "abc" },
                      "U7: typing did not land in the field")
        keepScreenshot("u7-keyboard-up", of: app)
        // The interactive dismiss: a slow drag from just above the composer
        // into the lower half of the keyboard, shorter than the keyboard is
        // tall, as a person pulls it down. (The transcript moves with the
        // finger; a longer drag scrolls up on purpose.)
        let keyboard = app.keyboards.firstMatch.frame
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: window.frame.midX, dy: visibleBottom(app) - 10))
        let to = origin.withOffset(CGVector(dx: window.frame.midX, dy: keyboard.midY + 40))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(waitFor(3) { !app.keyboards.firstMatch.exists }, "U7: the keyboard did not hide")
        wait(0.8)
        assertVisible(latest(app), in: app, "U7 latest after the keyboard hid")
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("u7-keyboard-down", of: app)
    }

    /// B6 (and the hotfix's device check 4): I send while scrolled far up;
    /// my bubble appears at the bottom and the view goes there. Under
    /// G-scroll mechanism (a) a detached chat holds its rows from the top, so
    /// only a view-level check proves the jump (`FollowPolicy` alone is T).
    @MainActor
    func testB6SendWhileScrolledFarUpGoesToMyBubble() {
        let app = launchChat(ScriptedScenario.chatKeyboard.rawValue)
        XCTAssertTrue(latest(app).waitForExistence(timeout: 3))
        let field = composerField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no keyboard")
        let text = "Gửi khi đang ở xa phía trên"
        app.typeText(text)
        // About three screens up, without a fling (the drag also hides the
        // keyboard, as a person's does).
        let screen = visibleBottom(app) - visibleTop(app)
        for _ in 0..<6 {
            drag(app, by: screen * 0.6)
            wait(0.3)
        }
        wait(0.5)
        let distance = topVisibleRowDistance(app)
        record("b6.scrolledUpBy", String(format: "%.0f pt (screen %.0f pt)", distance, screen))
        XCTAssertGreaterThan(distance, screen * 2, "not far enough up to prove the jump")
        XCTAssertTrue(followValue(app).hasPrefix("detached"), "not detached: \(followValue(app))")
        keepScreenshot("b6-1-scrolled-up-with-draft", of: app)

        let send = element(app, AccessibilityID.composerSend)
        XCTAssertTrue(send.waitForExistence(timeout: 2), "no send circle for the draft")
        send.tap()
        let mine = latest(app).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "my message is not the newest row")
        XCTAssertTrue(waitFor(3) { self.followValue(app) == "following" }, "the view stayed up: \(followValue(app))")
        assertVisible(latest(app), in: app, "B6 my bubble after sending from far up")
        XCTAssertFalse(pill(app).exists, "a pill after my own send")
        keepScreenshot("b6-2-at-my-bubble", of: app)
    }

    /// U8: the composer grows to six lines and then scrolls inside; no
    /// height jump on focus; the last row stays visible.
    @MainActor
    func testU8ComposerGrowsToSixLines() {
        let app = launchChat(ScriptedScenario.chatKeyboard.rawValue)
        let field = composerField(app)
        let before = field.frame.height
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        wait(0.5)
        let focused = field.frame.height
        record("u8.heightBeforeFocus", before)
        record("u8.heightOnFocus", focused)
        XCTAssertEqual(focused, before, accuracy: 1, "U8: the composer jumped on focus")
        var heights: [CGFloat] = []
        for line in 1...8 {
            app.typeText(line == 1 ? "Dòng 1" : "\nDòng \(line)")
            wait(0.3)
            heights.append(field.frame.height)
        }
        record("u8.heights", heights.map { Int($0) })
        XCTAssertGreaterThan(heights[5], heights[0] + 40, "U8: the composer did not grow")
        XCTAssertEqual(heights[7], heights[5], accuracy: 1, "U8: the composer grew past six lines")
        assertVisible(latest(app), in: app, "U8 latest above the grown composer")
        keepScreenshot("u8-six-lines", of: app)
    }

    /// U9: dark mode, Reduce Transparency, Increase Contrast and AX XXL.
    /// The runner beside the run (`scripts/sim-content-size-runner.sh`) sets
    /// Reduce Transparency and Increase Contrast on the simulator before the
    /// launch (the composer turns opaque) and turns the simulator dark
    /// (`XCUIDevice.appearance` did not change this simulator; on this
    /// runtime the appearance changes only after a restart, so the run uses a
    /// device booted dark). The test checks the chat's ground in the
    /// screenshot is dark.
    @MainActor
    func testU9DarkModeAndLargestText() throws {
        let transparency = requestRunner("transparency on")
        let contrast = requestRunner("contrast on")
        guard transparency, contrast else {
            if transparency { requestRunner("transparency off") }
            if contrast { requestRunner("contrast off") }
            throw XCTSkip("no simulator accessibility-settings runner beside the run")
        }
        if !requestRunner("appearance dark") { XCUIDevice.shared.appearance = .dark }
        defer {
            requestRunner("transparency off")
            requestRunner("contrast off")
            if !requestRunner("appearance light") { XCUIDevice.shared.appearance = .light }
        }
        let app = launchChat(ScriptedScenario.chatPeople.rawValue,
                             extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        wait(1)
        assertVisible(latest(app), in: app, "U9 latest")
        XCTAssertEqual(followValue(app), "following")
        let screenshot = app.screenshot()
        // The ground beside my bubble, just above the composer.
        let ground = luminance(of: screenshot, at: CGPoint(x: 24, y: visibleBottom(app) - 8))
        record("u9.groundLuminance", String(format: "%.2f", ground))
        XCTAssertLessThan(ground, 0.3, "U9: the chat is not dark")
        keepScreenshot("u9-dark-axxxl", of: app)
    }

    /// U9 for reactions (B22): at AX XXL every reaction chip is whole, on
    /// screen and above the composer (the accessibility audit's clipping
    /// check flags emoji glyphs; this looks at the chips themselves).
    @MainActor
    func testU9ReactionChipsStayWholeAtTheLargestText() {
        let app = launchChat(ScriptedScenario.chatActions.rawValue,
                             extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        wait(1)
        let window = app.windows.firstMatch.frame
        let chips = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '❤️' OR label BEGINSWITH '👍'"))
        XCTAssertGreaterThan(chips.count, 0, "no reaction chips")
        for index in 0..<chips.count {
            let chip = chips.element(boundBy: index)
            let frame = chip.frame
            record("u9.chip\(index)", "\(chip.label) \(frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX, "chip off the left edge")
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX, "chip off the right edge")
            if frame.minY > visibleTop(app) {
                XCTAssertLessThanOrEqual(frame.maxY, visibleBottom(app) + Self.framePoints, "chip under the composer")
            }
        }
        keepScreenshot("u9-axxxl-reactions", of: app)
    }

    /// U10, HC-4: an empty assistant chat shows desktop's greeting once the
    /// start of the room is reached.
    @MainActor
    func testU10EmptyChatShowsTheGreeting() {
        let app = launchChat(ScriptedScenario.chatEmpty.rawValue)
        let greeting = element(app, "chat.greeting")
        XCTAssertTrue(greeting.waitForExistence(timeout: 3), "U10: no greeting")
        // HC-4: desktop's assistant greeting, its prompt and starters.
        XCTAssertTrue(app.staticTexts["Hôm nay mình giúp gì cho bạn?"].exists)
        XCTAssertTrue(element(app, "chat.starter.2").exists, "no starters")
        assertNoBannedWords(app)
        keepScreenshot("u10-greeting", of: app)
    }

    /// B17, G-scroll check 7: the working line shows at the bottom, is edited
    /// in place, and is hidden once the answer to the same message arrives.
    @MainActor
    func testReplyAtBottomHidesTheWorkingLine() {
        let (app, start) = launchTimedChat(ScriptedScenario.chatReplyAtBottom.rawValue)
        wait(until: start.addingTimeInterval(2.2))
        assertVisible(latest(app), in: app, "working line")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Đang xử lý'")).firstMatch.exists)
        keepScreenshot("reply-at-bottom-working", of: app)
        wait(until: start.addingTimeInterval(6.5))
        assertVisible(latest(app), in: app, "answer")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Đang xử lý'")).firstMatch.exists,
                       "B17: the working line still shows after the answer")
        XCTAssertEqual(followValue(app), "following")
        assertNoBannedWords(app)
        keepScreenshot("reply-at-bottom-answer", of: app)
    }

    /// §2.10: the accessibility audit on an open assistant chat.
    @MainActor
    func testAccessibilityAuditAssistantChat() throws {
        let app = launchChat(ScriptedScenario.chatActions.rawValue, pinsTextSize: false)
        wait(1)
        // The Seen faces draw at 16 pt but answer taps over 44 pt; the line
        // they sit on keeps its drawn height.
        let seen = app.descendants(matching: .any)["delivery.seen"].firstMatch
        XCTAssertTrue(seen.waitForExistence(timeout: 5), "no Seen faces")
        let line = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'delivery.line.'")).allElementsBoundByIndex
            .first { $0.frame.intersects(seen.frame) }
        print("MEASURE delivery.seen \(seen.frame) line \(line?.frame ?? .zero)")
        keepScreenshot("delivery-seen", of: app)
        XCTAssertGreaterThanOrEqual(seen.frame.width, 44, "Seen hit region too narrow")
        XCTAssertGreaterThanOrEqual(seen.frame.height, 44, "Seen hit region too short")
        try auditIgnoringScrollEdges(app)
    }

    /// The Seen faces' 44 pt region: a tap near its corner, outside the drawn
    /// 16 pt face, still lists the readers' names.
    @MainActor
    func testSeenFacesAnswerATapOutsideTheDrawnFace() {
        let app = launchChat(ScriptedScenario.chatActions.rawValue)
        let seen = app.descendants(matching: .any)["delivery.seen"].firstMatch
        XCTAssertTrue(seen.waitForExistence(timeout: 5), "no Seen faces")
        seen.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["delivery.seen.names"].waitForExistence(timeout: 3),
                      "tapping Seen lists no names")
        keepScreenshot("delivery-seen-names", of: app)
    }
}
