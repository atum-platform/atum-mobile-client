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
    private func launch(language: String, dark: Bool,
                        contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumDebugTeamSpace", "-AppleLanguages", "(\(language))",
               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-UIPreferredContentSizeCategoryName", contentSize,
               // The app's own appearance setting: the simulator's appearance alone left the
               // first dark captures light.
               "-atum.appearance", dark ? "dark" : "light"]
            + probeArguments
        app.launch()
        XCTAssertTrue(element(app, "teamSpace.screen").waitForExistence(timeout: 15), "no Workplace")
        return app
    }

    /// P6: Chat · Board, Board · List and Mine are the bar's view menu. The
    /// menu's rows follow Dynamic Type and keep 44 pt targets at AX sizes.
    @MainActor
    func testBoardControlsHave44PointTargetsAtAccessibilityTextSize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone list")
        let app = launch(language: "vi", dark: false, contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let expected = try XCTUnwrap(words["vi"])
        let page = companyViewMenuItem(app, id: "company.page.board", name: expected.board)
        XCTAssertTrue(page.waitForExistence(timeout: 5), boundedHierarchy(app))
        page.tap()
        XCTAssertTrue(waitFor(3) { (self.companyViewMenu(app).value as? String)?.hasPrefix(expected.board) == true },
                      boundedHierarchy(app))
        let list = companyViewMenuItem(app, id: "company.board.view.list", name: expected.list)
        XCTAssertTrue(list.waitForExistence(timeout: 5), boundedHierarchy(app))
        let mine = app.switches[expected.mine].exists ? app.switches[expected.mine] : app.buttons[expected.mine]
        XCTAssertTrue(mine.waitForExistence(timeout: 5), boundedHierarchy(app))
        for control in [list, mine] {
            XCTAssertTrue(control.isHittable, boundedHierarchy(app))
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.label)
            XCTAssertTrue(app.frame.contains(control.frame), control.label)
        }
        keepScreenshot("p6-team-space-view-menu-ax", of: app)
        mine.tap()
        XCTAssertTrue(waitFor(3) { (self.companyViewMenu(app).value as? String)?.hasSuffix(expected.mine) == true },
                      "Mine did not turn on: \(boundedHierarchy(app))")
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
                let app = launch(language: language, dark: appearance == .dark)
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
        // On a short screen (the hosted iPhone 16e) #design is below the fold, and the
        // List makes its row only once it scrolls near: scroll until it exists.
        XCTAssertTrue(app.buttons.matching(identifier: "company.channel.general").firstMatch
            .waitForExistence(timeout: 5), boundedHierarchy(app))
        for _ in 0..<6 where !(channel.exists && channel.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(channel.waitForExistence(timeout: 2), boundedHierarchy(app))
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

    /// Board · List and Mine over the board's unavailable state, chosen in the
    /// bar's view menu (P6). The menu button's value says the choice.
    @MainActor
    private func checkBoardViews(_ app: XCUIApplication, expected: Words, tag: String) {
        let menu = companyViewMenu(app)
        let value = { menu.value as? String ?? "" }
        XCTAssertTrue(menu.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(value(), expected.chat)
        XCTAssertEqual(menu.frame.midY, app.navigationBars.firstMatch.frame.midY,
                       accuracy: app.navigationBars.firstMatch.frame.height / 2, "the view menu is on the bar")
        let boardPage = companyViewMenuItem(app, id: "company.page.board", name: expected.board)
        XCTAssertTrue(boardPage.waitForExistence(timeout: 3), boundedHierarchy(app))
        keepScreenshot("p6-view-menu-chat-\(tag)", of: app)
        boardPage.tap()
        XCTAssertTrue(waitFor(3) { value() == expected.board }, "Board not chosen: \(value())")
        // The board's own unavailable state (the phone has no board read).
        XCTAssertTrue(app.staticTexts[expected.boardUnavailable].waitForExistence(timeout: 3), boundedHierarchy(app))

        let list = companyViewMenuItem(app, id: "company.board.view.list", name: expected.list)
        XCTAssertTrue(list.waitForExistence(timeout: 3), boundedHierarchy(app))
        keepScreenshot("p6-view-menu-board-\(tag)", of: app)
        list.tap()
        XCTAssertTrue(waitFor(3) { value() == expected.board + ", " + expected.list }, "List not chosen: \(value())")
        let mine = companyViewMenuItem(app, id: "company.board.mine", name: expected.mine)
        XCTAssertTrue(mine.waitForExistence(timeout: 3), boundedHierarchy(app))
        mine.tap()
        XCTAssertTrue(waitFor(3) { value() == [expected.board, expected.list, expected.mine].joined(separator: ", ") },
                      "Mine did not turn on: \(value())")
        keepScreenshot("w4-e7-board-list-mine-\(tag)", of: app)

        companyViewMenuItem(app, id: "company.page.chat", name: expected.chat).tap()
        XCTAssertTrue(element(app, "company.channel.general").waitForExistence(timeout: 3))
        // The page keeps its choices for the session.
        companyViewMenuItem(app, id: "company.page.board", name: expected.board).tap()
        XCTAssertTrue(waitFor(3) { value() == [expected.board, expected.list, expected.mine].joined(separator: ", ") },
                      "Board · List and Mine were not kept: \(value())")
        companyViewMenuItem(app, id: "company.page.chat", name: expected.chat).tap()
        XCTAssertTrue(element(app, "company.channel.general").waitForExistence(timeout: 3))
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
