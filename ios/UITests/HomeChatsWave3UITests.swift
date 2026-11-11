import AtumChat
import XCTest

/// Parity plan v2 wave 3, Home and chats: HC-6 (header subtitle, in-chat
/// search) and HC-7 (Rename, Low priority, Block). Scripted hosts only.
final class HomeChatsWave3UITests: TranscriptUITestCase {
    @MainActor
    private func launchScripted(_ scenario: ScriptedScenario, language: String = "en",
                                size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: scenario.rawValue)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-UIPreferredContentSizeCategoryName", size]
            + probeArguments
        app.launch()
        return app
    }

    @MainActor private var appearanceTag: String { XCUIDevice.shared.appearance == .dark ? "dark" : "light" }

    // MARK: HC-6

    /// The magnifier opens the bar in the composer's place; "da lat" is not
    /// in the loaded rows, so the search walks older pages until the one
    /// message three pages back is found, brought into view and counted.
    @MainActor
    func testSearchFindsAWordThreePagesBackAndCloses() {
        let app = launchScripted(.chatSearch)
        let open = element(app, "chat.search.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15), boundedHierarchy(app))
        open.tap()
        let field = element(app, "chat.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertFalse(element(app, AccessibilityID.composerField).exists, "the bar takes the composer's place")
        field.typeText("da lat")
        let count = element(app, "chat.search.count")
        XCTAssertTrue(waitFor(15) { (count.label).hasPrefix("Result 1 of 1") }, "count: \(count.label)")
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Đà Lạt")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5), boundedHierarchy(app))
        XCTAssertTrue(waitFor(3) { match.isHittable }, "the match was not brought into view")
        keepScreenshot("hc6-search-found-\(appearanceTag)-en", of: app)

        element(app, "chat.search.close").tap()
        XCTAssertTrue(element(app, AccessibilityID.composerField).waitForExistence(timeout: 3),
                      "Close brings the composer back")
        XCTAssertTrue(open.waitForExistence(timeout: 3))
    }

    /// No match anywhere: "No results", after a walk to the room's start.
    @MainActor
    func testSearchWithNoMatchSaysNoResultsInVietnamese() {
        let app = launchScripted(.chatSearch, language: "vi")
        let open = element(app, "chat.search.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let field = element(app, "chat.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("qqzzxx")
        let count = element(app, "chat.search.count")
        XCTAssertTrue(waitFor(20) { count.label.hasPrefix("Không có kết quả") && count.label.contains("Đã tìm") },
                      "count: \(count.label)")
        XCTAssertFalse(element(app, "chat.search.older").isEnabled)
        keepScreenshot("hc6-search-none-\(appearanceTag)-vi", of: app)
    }

    /// The group's topic sits under its name; a person chat has none.
    @MainActor
    func testHeaderSubtitleShowsTheGroupTopic() {
        let app = launchScripted(.chatMedia, language: "vi")
        let subtitle = element(app, "chat.title.subtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertEqual(subtitle.label, "Lên kế hoạch cuối tuần")
        keepScreenshot("hc6-group-topic-\(appearanceTag)-vi", of: app)
        app.terminate()

        let people = launchScripted(.chatPeople, language: "vi")
        XCTAssertTrue(element(people, "chat.title").waitForExistence(timeout: 15))
        XCTAssertFalse(element(people, "chat.title.subtitle").exists, "a person chat has no subtitle")
    }

    /// The search bar keeps every word at the largest text size.
    @MainActor
    func testSearchBarAtAccessibilitySizePassesTheAudit() throws {
        let app = launchScripted(.chatSearch, size: "UICTContentSizeCategoryAccessibilityXXXL")
        let open = element(app, "chat.search.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()
        let field = element(app, "chat.search.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("da lat")
        let count = element(app, "chat.search.count")
        XCTAssertTrue(waitFor(15) { count.label.hasPrefix("Result 1 of 1") }, "count: \(count.label)")
        keepScreenshot("hc6-search-ax5-\(appearanceTag)-en", of: app)
        try app.performAccessibilityAudit(for: [.textClipped]) { issue in
            // Only the bar is this slice's; transcript rows have their own audits.
            guard let element = issue.element else { return true }
            return !element.identifier.hasPrefix("chat.search")
        }
    }

    // MARK: HC-7

    /// Rename from the panel: the alert starts from the name, Save names it.
    @MainActor
    func testPanelRenamesAPersonChatPrivately() {
        let app = launchScripted(.chatPeople)
        element(app, "chat.title").tap()
        let rename = element(app, "info.rename")
        XCTAssertTrue(rename.waitForExistence(timeout: 5), boundedHierarchy(app))
        if !rename.isHittable { app.swipeUp() }
        XCTAssertTrue(waitFor(3) { rename.isHittable })
        rename.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["Rename chat"].exists, alert.debugDescription)
        XCTAssertTrue(alert.staticTexts["Only you see this name."].exists, alert.debugDescription)
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "Minh Anh")
        field.tap()
        field.typeText(" ✿")
        keepScreenshot("hc7-rename-\(appearanceTag)-en", of: app)
        alert.buttons["Save"].tap()
        XCTAssertTrue(waitFor(3) { self.probeLines("panel.txt").map(\.text).contains("rename false Minh Anh ✿") },
                      "\(probeLines("panel.txt").map(\.text))")
    }

    /// The Home long-press offers Rename, Low priority (a checked toggle)
    /// and Block person, confirmed first, on a person chat.
    @MainActor
    func testHomeLongPressRenamesSinksAndBlocksAPerson() {
        let app = launchScripted(.homeRoster, language: "vi")
        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))

        func openMenu(_ name: String, until item: XCUIElement) {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            var attempts = 0
            while !row.exists, attempts < 4 { list.swipeUp(); attempts += 1 }
            XCTAssertTrue(row.exists, "no \(name) row")
            row.press(forDuration: 1)
            for _ in 0..<2 where !item.waitForExistence(timeout: 5) { row.press(forDuration: 1.2) }
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        }

        let low = app.buttons["Ưu tiên thấp"]
        openMenu("Hoa", until: low)
        XCTAssertTrue(app.buttons["Đổi tên"].exists, "Rename is in the menu")
        XCTAssertTrue(app.buttons["Chặn người này"].exists, "Block is in the menu")
        keepScreenshot("hc7-home-menu-\(appearanceTag)-vi", of: app)
        low.tap()

        let block = app.buttons["Chặn người này"]
        openMenu("Hoa", until: block)
        block.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Chặn người này")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Block is confirmed first")
        XCTAssertTrue(app.staticTexts["Chặn người này?"].exists)
        confirm.tap()

        let unblock = app.buttons["Bỏ chặn"]
        openMenu("Hoa", until: unblock)
        app.buttons["Đổi tên"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(" 2")
        alert.buttons["Lưu"].tap()

        XCTAssertTrue(waitFor(3) { self.probeLines("home-actions.txt").count == 3 })
        XCTAssertEqual(probeLines("home-actions.txt").map(\.text), [
            "lowPriority !hoa:atum.test true",
            "blocked @peer:!hoa:atum.test true",
            "rename !hoa:atum.test Hoa 2",
        ])
    }

    /// A group offers Rename and Low priority but no Block.
    @MainActor
    func testHomeGroupMenuHasNoBlock() {
        let app = launchScripted(.homeRoster, language: "vi")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gia đình'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.press(forDuration: 1)
        let rename = app.buttons["Đổi tên"]
        for _ in 0..<2 where !rename.waitForExistence(timeout: 5) { row.press(forDuration: 1.2) }
        XCTAssertTrue(rename.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Ưu tiên thấp"].exists)
        XCTAssertFalse(app.buttons["Chặn người này"].exists)
    }
}
