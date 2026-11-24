import AtumChat
import XCTest

/// W4-E7: the Team Space revamp (desktop #114) on the real `TeamSpaceScreen` with
/// scripted data, in English and Vietnamese, light and dark: a failed channel open
/// says so under its row and Try again opens it; the Board page has Board · List and
/// Mine; the header box offers "Search “…”", which shows the company's messages and
/// opens one, and says "No matches" when it filters everything out.
final class TeamSpaceRevampUITests: TranscriptUITestCase {
    private struct Words {
        let channelFailed: String
        let tryAgain: String
        let chat: String
        let board: String
        let list: String
        let mine: String
        let boardUnavailable: String
        let searchMessagesFor: String
        let noMatches: String
        let search: String
    }

    private let words: [String: Words] = [
        "en": Words(channelFailed: "Couldn’t open this channel.", tryAgain: "Try again", chat: "Chat",
                    board: "Board", list: "List", mine: "Mine", boardUnavailable: "Board is unavailable.",
                    searchMessagesFor: "Search messages for “launch”", noMatches: "No matches", search: "Search"),
        "vi": Words(channelFailed: "Không mở được kênh này.", tryAgain: "Thử lại", chat: "Trò chuyện",
                    board: "Bảng", list: "Danh sách", mine: "Của tôi",
                    boardUnavailable: "Không tải được bảng.",
                    searchMessagesFor: "Tìm tin nhắn có “launch”", noMatches: "Không có kết quả phù hợp",
                    search: "Tìm kiếm"),
    ]

    @MainActor
    private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumDebugTeamSpace", "-AppleLanguages", "(\(language))",
               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()
        XCTAssertTrue(element(app, "teamSpace.screen").waitForExistence(timeout: 15), "no Workplace")
        return app
    }

    @MainActor
    func testRevampWalkInEnglishAndVietnameseLightAndDark() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone list")
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        for language in ["en", "vi"] {
            for appearance in [XCUIDevice.Appearance.light, .dark] {
                XCUIDevice.shared.appearance = appearance
                let tag = "\(language)-\(appearance == .dark ? "dark" : "light")"
                let expected = try XCTUnwrap(words[language])
                let app = launch(language: language)
                checkChannelRetry(app, expected: expected, tag: tag)
                checkBoardViews(app, expected: expected, tag: tag)
                checkHeaderSearch(app, expected: expected, tag: tag)
                app.terminate()
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            }
        }
    }

    /// #design fails once: the line and Try again sit under it; Try again opens it.
    @MainActor
    private func checkChannelRetry(_ app: XCUIApplication, expected: Words, tag: String) {
        // The probe folder is this test's, shared by its four launches: count what this one adds.
        let designOpens = { self.probeLines("team-actions.txt").filter { $0.text == "open-channel !design:atum.test" }.count }
        let before = designOpens()
        let channel = app.buttons.matching(identifier: "company.channel.design").firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 5), boundedHierarchy(app))
        for _ in 0..<6 where !channel.isHittable { app.swipeUp(velocity: .slow) }
        channel.tap()
        XCTAssertTrue(waitFor(3) { designOpens() - before == 1 }, "the tap did not ask to open #design")
        XCTAssertFalse(element(app, "teamSpace.scripted.destination").exists, "a failed open pushed")
        // #design is the last row on a 6.1" screen; the line under it is made once the List
        // scrolls it on screen.
        let retry = app.buttons.matching(identifier: "company.channel.retry").firstMatch
        for _ in 0..<4 where !(retry.exists && retry.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(retry.waitForExistence(timeout: 3), "no failed line: \(boundedHierarchy(app))")
        XCTAssertTrue(element(app, "company.channel.failed").exists, boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts[expected.channelFailed].exists, boundedHierarchy(app))
        keepScreenshot("w4-e7-channel-failed-\(tag)", of: app)

        XCTAssertEqual(retry.label, expected.tryAgain)
        retry.tap()
        XCTAssertTrue(element(app, "teamSpace.scripted.destination").waitForExistence(timeout: 3),
                      "Try again did not open the channel")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(3) { self.element(app, "company.channel.design").exists }, "Back did not return")
        XCTAssertFalse(element(app, "company.channel.failed").exists, "the opened channel kept its failure")
        XCTAssertEqual(designOpens() - before, 2, "one failed open and one retry")
        app.swipeDown(velocity: .fast)
    }

    /// A button-style toggle reads as selected, or as a toggle whose value is 1.
    @MainActor
    private func isOn(_ toggle: XCUIElement) -> Bool {
        toggle.isSelected || (toggle.value as? String) == "1"
    }

    /// Board · List and Mine over the board's unavailable state.
    @MainActor
    private func checkBoardViews(_ app: XCUIApplication, expected: Words, tag: String) {
        let chatPage = app.buttons.matching(identifier: "company.page.chat").firstMatch
        let boardPage = app.buttons.matching(identifier: "company.page.board").firstMatch
        XCTAssertTrue(boardPage.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(boardPage.label, expected.board)
        boardPage.tap()
        let board = app.buttons.matching(identifier: "company.board.view.board").firstMatch
        let list = app.buttons.matching(identifier: "company.board.view.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(board.label, expected.board)
        XCTAssertEqual(list.label, expected.list)
        XCTAssertTrue(board.isSelected)
        // The controls sit over the board's own unavailable state (the phone has no board read).
        XCTAssertTrue(app.staticTexts[expected.boardUnavailable].exists, boundedHierarchy(app))

        list.tap()
        XCTAssertTrue(waitFor(3) { list.isSelected }, "List not chosen")
        // A button-style Toggle is a switch named by its label; its identifier has lost to the
        // screen's before, so it is found the way a person names it.
        let mine = app.switches[expected.mine]
        XCTAssertTrue(mine.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertFalse(isOn(mine))
        mine.tap()
        XCTAssertTrue(waitFor(3) { self.isOn(mine) }, "Mine did not turn on: \(self.boundedHierarchy(app))")
        XCTAssertTrue(list.isSelected, "Mine changed the view")
        keepScreenshot("w4-e7-board-list-mine-\(tag)", of: app)

        XCTAssertEqual(chatPage.label, expected.chat)
        chatPage.tap()
        XCTAssertTrue(element(app, "company.channel.general").waitForExistence(timeout: 3))
        // The page keeps its choices for the session.
        boardPage.tap()
        XCTAssertTrue(waitFor(3) { list.isSelected && self.isOn(mine) }, "Board · List and Mine were not kept")
        chatPage.tap()
    }

    /// The header box: nothing matched says so; "Search “launch”" opens the results
    /// sheet, which searched the open company, and a result opens its channel.
    @MainActor
    private func checkHeaderSearch(_ app: XCUIApplication, expected: Words, tag: String) {
        XCTAssertTrue(element(app, "company.channel.general").waitForExistence(timeout: 3))
        let field = app.searchFields.firstMatch
        if !field.exists { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(field.waitForExistence(timeout: 3), boundedHierarchy(app))
        field.tap()
        field.typeText("zzqx")
        XCTAssertTrue(app.staticTexts[expected.noMatches].waitForExistence(timeout: 3), boundedHierarchy(app))
        field.buttons.firstMatch.tap()

        field.typeText("launch")
        let row = app.buttons.matching(identifier: "company.search.messages").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(row.label, expected.searchMessagesFor)
        keepScreenshot("w4-e7-search-row-\(tag)", of: app)
        row.tap()

        XCTAssertTrue(app.navigationBars[expected.search].waitForExistence(timeout: 5), boundedHierarchy(app))
        let result = app.buttons.matching(identifier: "company.search.result.$scripted-launch-date").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(probeLines("team-actions.txt").contains { $0.text == "search anka launch" })
        keepScreenshot("w4-e7-search-results-\(tag)", of: app)
        result.tap()
        XCTAssertTrue(element(app, "teamSpace.scripted.destination").waitForExistence(timeout: 5),
                      "the result did not open its channel")
        XCTAssertTrue(probeLines("team-actions.txt").contains { $0.text == "search-open $scripted-launch-date" })
    }
}
