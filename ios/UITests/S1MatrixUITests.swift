import AtumChat
import XCTest

/// The S1 matrix (revamp plan §2.10, §5.2 "Accept, U"): every S1 screen in
/// one cell of light/dark × vi/en × default/AX XXL, each with a screenshot,
/// the visible-text bans and `performAccessibilityAudit()`. The run picks the
/// cell through the test runner's environment
/// (`TEST_RUNNER_ATUM_UI_MATRIX="<vi|en> <light|dark> <default|axxl>"`,
/// default `vi light default`): the language is a launch argument, the text
/// size the content-size runner's (`scripts/sim-content-size-runner.sh`; the
/// app does not pin it, so the audit can change it), and the appearance the
/// simulator's (a dark run boots a device dark: on this runtime the
/// appearance changes only after a restart), checked on each screen.
///
/// Copy the export does not have yet (`ChatCopy.pendingRepin`, until the
/// re-pin) reads Vietnamese in every language; the tests look for it as it
/// reads today ("Chọn văn bản"). The scripted messages are Vietnamese in
/// every language (synthetic data).
final class S1MatrixUITests: TranscriptUITestCase {
    struct Cell {
        let language: String
        let appearance: String
        let size: String

        var tag: String { "\(language)-\(appearance)-\(size)" }
        var english: Bool { language == "en" }
    }

    static let cell: Cell = {
        let parts = (ProcessInfo.processInfo.environment["ATUM_UI_MATRIX"] ?? "")
            .split(separator: " ").map(String.init)
        return Cell(language: parts.count > 0 ? parts[0] : "vi",
                    appearance: parts.count > 1 ? parts[1] : "light",
                    size: parts.count > 2 ? parts[2] : "default")
    }()

    var cell: Cell { Self.cell }

    /// The exported words a test looks for, in the cell's language.
    func word(_ vi: String, _ en: String) -> String { cell.english ? en : vi }

    /// Plan §0.2 and U: desktop's words for the same states, in English.
    static let bannedEnglish = ["Preparing", "Getting ready", "Sending...", "Working…"]

    /// The runner leaves the simulator at the default size; only an AX XXL
    /// cell changes it (and puts it back), so a default cell runs exactly as
    /// the other tests' audits do.
    override func setUp() {
        super.setUp()
        XCTAssertTrue(requestRunner("appearance \(cell.appearance)"),
                      "no simulator appearance runner beside the matrix")
        if cell.size == "axxl" {
            XCTAssertTrue(requestRunner("accessibility-extra-extra-large"), "no content-size runner beside the run")
        }
    }

    override func tearDown() {
        if cell.size == "axxl" { requestRunner("large") }
        requestRunner("appearance light")
        super.tearDown()
    }

    @MainActor
    private func launchCell(_ scenario: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let locale = cell.english ? "en_US" : "vi_VN"
        app.launchArguments = ScriptedScenarios.arguments(name: scenario)
            + ["-AppleLanguages", "(\(cell.language))", "-AppleLocale", locale] + extra
        app.launch()
        return app
    }

    @MainActor
    private func launchChatCell(_ scenario: String, extra: [String] = []) -> XCUIApplication {
        let app = launchCell(scenario, extra: extra)
        XCTAssertTrue(transcript(app).waitForExistence(timeout: 15), "no transcript")
        wait(1)
        return app
    }

    /// The screen's ground is light or dark as the cell says (a point at the
    /// window's left edge, half way down, where no row draws).
    @MainActor
    private func checkAppearance(_ app: XCUIApplication, _ screen: String, strict: Bool) {
        let window = app.windows.firstMatch.frame
        let ground = luminance(of: app.screenshot(), at: CGPoint(x: 3, y: window.midY))
        record("matrix.\(screen).\(cell.tag).groundLuminance", String(format: "%.2f", ground))
        guard strict else { return }
        if cell.appearance == "dark" {
            XCTAssertLessThan(ground, 0.3, "\(screen): not dark")
        } else {
            XCTAssertGreaterThan(ground, 0.7, "\(screen): not light")
        }
    }

    @MainActor
    private func assertNoBannedWordsInCell(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        assertNoBannedWords(app, file: file, line: line)
        guard cell.english else { return }
        let texts = visibleTexts(app)
        for word in Self.bannedEnglish {
            XCTAssertFalse(texts.contains { $0.contains(word) }, "visible text contains \(word)", file: file, line: line)
        }
        let stop = try! NSRegularExpression(pattern: "\\bStop\\b")
        XCTAssertFalse(texts.contains { stop.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil },
                       "visible text contains Stop", file: file, line: line)
    }

    /// A screen of the cell: appearance, bans, screenshot, then the audit.
    @MainActor
    private func check(_ app: XCUIApplication, _ screen: String, strictAppearance: Bool = true,
                       audits: Bool = true) throws {
        checkAppearance(app, screen, strict: strictAppearance)
        assertNoBannedWordsInCell(app)
        keepScreenshot("\(screen)--\(cell.tag)", of: app)
        if audits { try auditIgnoringScrollEdges(app) }
    }

    // MARK: The chat screen, per room kind

    /// My assistant, open at the latest message (U1).
    @MainActor
    func testAssistantChat() throws {
        let app = launchChatCell(ScriptedScenario.chatKeyboard.rawValue)
        assertVisible(latest(app), in: app, "latest")
        try check(app, "assistant")
    }

    /// Answers with quotes, reactions and the newest answer's own row.
    @MainActor
    func testAnswersQuotesAndReactions() throws {
        let app = launchChatCell(ScriptedScenario.chatActions.rawValue)
        try check(app, "answers")
    }

    /// A people chat: bubbles, and the people typing line above the composer.
    @MainActor
    func testPeopleChat() throws {
        let locale = cell.english ? "en_US" : "vi_VN"
        let (app, start) = launchTimedChat(ScriptedScenario.chatPeople.rawValue,
                                           extra: ["-AppleLanguages", "(\(cell.language))",
                                                   "-AppleLocale", locale])
        wait(until: start.addingTimeInterval(3.5))
        let line = element(app, "composer.typing")
        XCTAssertTrue(line.waitForExistence(timeout: 2), "no typing line")
        XCTAssertTrue(line.label.contains(word("đang soạn tin", "is typing")), line.label)
        try check(app, "people", audits: false)
        // The line goes at 6 s; the audit runs on the settled screen.
        wait(until: start.addingTimeInterval(8))
        XCTAssertFalse(line.exists, "the typing line stays")
        wait(2)
        try auditIgnoringScrollEdges(app)
    }

    /// A group: every placeholder kind, "Đã xem · 2", the read marker.
    @MainActor
    func testGroupChat() throws {
        let app = launchChatCell(ScriptedScenarios.chatKinds)
        try check(app, "group")
    }

    /// The empty chat's greeting (U10).
    @MainActor
    func testEmptyChat() throws {
        let app = launchChatCell(ScriptedScenario.chatEmpty.rawValue)
        let greeting = element(app, "chat.greeting")
        XCTAssertTrue(greeting.waitForExistence(timeout: 3), "no greeting")
        XCTAssertEqual(greeting.label, word("Hôm nay ta làm gì?", "What shall we do today?"))
        try check(app, "empty")
    }

    /// Moon's room: a catalog bot's notice in the app's language. Moon types
    /// at 3 s and answers at 5 s; the audit looks at the settled screen.
    @MainActor
    func testBotRoom() throws {
        let app = launchChatCell(ScriptedScenario.botMoonNotice.rawValue)
        XCTAssertTrue(latest(app).descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "ngày tốt")).firstMatch.waitForExistence(timeout: 8),
                      "Moon's answer")
        XCTAssertTrue(waitFor(3) { !self.element(app, AccessibilityID.rowTyping).exists }, "Moon's dots stay")
        wait(1)
        try check(app, "bot")
    }

    // MARK: Menu and sheets

    /// The long-press menu on an answer, then the select-text sheet.
    @MainActor
    func testMenuAndSelectTextSheet() throws {
        let app = launchChatCell(ScriptedScenario.chatActions.rawValue)
        let answer = row(app, "chat.actions.0002")
        XCTAssertTrue(answer.waitForExistence(timeout: 3))
        let text = answer.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Dự án Góc Phố"))
            .firstMatch
        // At AX XXL the answer sits screens above the bottom: scroll it into view.
        for _ in 0..<12 where !(text.isHittable && text.frame.minY > visibleTop(app)) {
            drag(app, by: 300)
            wait(0.5)
        }
        let reply = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                     word("Trả lời", "Reply"), "answer.copy")).firstMatch
        for _ in 0..<3 where !reply.waitForExistence(timeout: 5) {
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            origin.withOffset(CGVector(dx: text.frame.midX, dy: text.frame.midY)).press(forDuration: 1.2)
        }
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "no menu")
        checkAppearance(app, "menu", strict: false)
        keepScreenshot("menu--\(cell.tag)", of: app)
        let select = app.buttons.matching(NSPredicate(format: "label == %@", "Chọn văn bản")).firstMatch
        XCTAssertTrue(select.exists, "no select-text item")
        select.tap()
        XCTAssertTrue(element(app, "selectText.body").waitForExistence(timeout: 3), "no select-text sheet")
        wait(0.5)
        try check(app, "select-text", strictAppearance: false)
    }

    /// The failed-send sheet ("Thử lại", "Xóa") from a parked send.
    @MainActor
    func testFailedSendSheet() throws {
        let app = launchChatCell(ScriptedScenario.chatSendFails.rawValue)
        let failed = latest(app).descendants(matching: .any)["send.failed"].firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 5), "no failed mark")
        XCTAssertEqual(failed.label, word("Chưa gửi được", "Not sent"))
        try check(app, "failed", audits: false)
        failed.tap()
        let retry = element(app, AccessibilityID.sendRetry)
        XCTAssertTrue(retry.waitForExistence(timeout: 3), "no failed-send sheet")
        XCTAssertEqual(retry.label, word("Thử lại", "Retry"))
        wait(0.5)
        try check(app, "failed-sheet", strictAppearance: false)
    }

    /// A send: the clock, then "Đã gửi" and "Đã xem" on it (U4, U4b), with
    /// the keyboard up (no audit: the system keyboard is not the app's).
    @MainActor
    func testSendThenSeen() throws {
        let app = launchChatCell(ScriptedScenario.chatSend.rawValue)
        let field = composerField(app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let text = "Ma trận \(cell.tag)"
        field.typeText(text)
        element(app, AccessibilityID.composerSend).tap()
        let seen = latest(app).descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", text, word("Đã xem", "Seen"))).firstMatch
        XCTAssertTrue(seen.waitForExistence(timeout: 8), "no Seen on my message")
        try check(app, "sent", audits: false)
    }

    // MARK: Home (today's), `bot.moon-no-room`

    /// The chat list on `bot.moon-no-room`: the screenshot and bans in this
    /// cell. The proof's assertions are `BotRoomUITests`; the list's audit
    /// is `testRosterAudit`.
    @MainActor
    func testRoster() throws {
        let app = launchCell(ScriptedScenario.botMoonNoRoom.rawValue)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
            .waitForExistence(timeout: 15), "no roster")
        wait(1)
        try check(app, "roster", audits: false)
    }

    /// `performAccessibilityAudit()` on today's Home (S2 replaces it; S6's
    /// acceptance names Home's audit).
    @MainActor
    func testRosterAudit() throws {
        let app = launchCell(ScriptedScenario.botMoonNoRoom.rawValue)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
            .waitForExistence(timeout: 15), "no roster")
        wait(1)
        try auditIgnoringScrollEdges(app)
    }
}

/// `bot.moon-no-room` (plan §5.2 U, §4.2 item 1): Moon is in the catalog but
/// this person has only an old encrypted room with it (which the desktop
/// pointer still names). No Moon row is listed and nothing opens the Store;
/// Andy, with a plain room, is listed, and Atum. Vietnamese, default size.
final class BotRoomUITests: TranscriptUITestCase {
    @MainActor
    func testMoonWithoutAPlainRoomHasNoRowAndNoStore() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.botMoonNoRoom.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let atum = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
        XCTAssertTrue(atum.waitForExistence(timeout: 15), "no roster")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Andy'")).firstMatch.exists,
                      "Andy has a plain room and is listed")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Đang chuẩn bị'"))
            .firstMatch.exists, "the approved waiting state stays attached to an assistant row")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Moon'"))
            .firstMatch.exists, "a Moon row is listed")
        // An app row without a room would read "<name>, Cửa hàng"; the one
        // element that says "Cửa hàng" is the bottom bar's Store tab.
        let storeTab = app.buttons.matching(identifier: "phone.tab.store")
        record("moonNoRoom.storeLabels", (0..<storeTab.count).map { storeTab.element(boundBy: $0).label })
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ', Cửa hàng'"))
            .firstMatch.exists, "a row opens the Store")
        XCTAssertEqual(storeTab.count, 1, "only the bottom bar's Store tab")
        assertNoBannedWords(app)
        keepScreenshot("moon-no-room", of: app)
    }
}
