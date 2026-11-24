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
        let searchMessagesFor: String
        let noMatches: String
        let search: String
    }

    private let words: [String: Words] = [
        "en": Words(channelFailed: "Couldn’t open this channel.", tryAgain: "Try again", chat: "Chat",
                    board: "Board", list: "List", mine: "Mine",
                    searchMessagesFor: "Search messages for “launch”", noMatches: "No matches", search: "Search"),
        "vi": Words(channelFailed: "Không mở được kênh này.", tryAgain: "Thử lại", chat: "Trò chuyện",
                    board: "Bảng", list: "Danh sách", mine: "Của tôi",
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
        let failed = element(app, "company.channel.failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 3), "no failed line: \(boundedHierarchy(app))")
        XCTAssertTrue(app.staticTexts[expected.channelFailed].exists, boundedHierarchy(app))
        XCTAssertFalse(element(app, "teamSpace.scripted.destination").exists, "a failed open pushed")
        keepScreenshot("w4-e7-channel-failed-\(tag)", of: app)

        let retry = app.buttons.matching(identifier: "company.channel.retry").firstMatch
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

    /// Board · List and Mine over the board's unavailable state.
    @MainActor
    private func checkBoardViews(_ app: XCUIApplication, expected: Words, tag: String) {
        let pages = app.segmentedControls["company.pages"]
        XCTAssertTrue(pages.waitForExistence(timeout: 3), boundedHierarchy(app))
        pages.buttons[expected.board].tap()
        let views = app.segmentedControls["company.board.views"]
        XCTAssertTrue(views.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(views.buttons[expected.board].isSelected)
        XCTAssertTrue(element(app, "company.board.unavailable").exists)

        views.buttons[expected.list].tap()
        XCTAssertTrue(waitFor(3) { views.buttons[expected.list].isSelected }, "List not chosen")
        let mine = element(app, "company.board.mine")
        XCTAssertTrue(mine.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(mine.label, expected.mine)
        XCTAssertFalse(mine.isSelected)
        mine.tap()
        XCTAssertTrue(waitFor(3) { mine.isSelected }, "Mine did not turn on")
        XCTAssertTrue(views.buttons[expected.list].isSelected, "Mine changed the view")
        keepScreenshot("w4-e7-board-list-mine-\(tag)", of: app)

        pages.buttons[expected.chat].tap()
        XCTAssertTrue(element(app, "company.channel.general").waitForExistence(timeout: 3))
        // The page keeps its choices for the session.
        pages.buttons[expected.board].tap()
        XCTAssertTrue(waitFor(3) { views.buttons[expected.list].isSelected && mine.isSelected },
                      "Board · List and Mine were not kept")
        pages.buttons[expected.chat].tap()
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
        let none = element(app, "company.search.noMatches")
        XCTAssertTrue(none.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(none.label, expected.noMatches)
        field.buttons.firstMatch.tap()

        field.typeText("launch")
        let row = app.buttons.matching(identifier: "company.search.messages").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(row.label, expected.searchMessagesFor)
        keepScreenshot("w4-e7-search-row-\(tag)", of: app)
        row.tap()

        let sheet = element(app, "company.search.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.navigationBars[expected.search].waitForExistence(timeout: 3), boundedHierarchy(app))
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
