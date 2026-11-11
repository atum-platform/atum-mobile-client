import AtumChat
import XCTest

/// AS-11: an app chat's side panel shows the app's pages (desktop
/// `matrix/app-bots/panel.tsx`), and an app row's "Info" opens the official app
/// card (`assistant-card/app-card.tsx`). Scripted chats and Home only:
/// `-AtumScriptedAppPanel <mode>` supplies a synthetic Moon manifest.
final class AppSidePanelUITests: TranscriptUITestCase {
    @MainActor private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor
    private func launchMoonPanel(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.botMoonNotice.rawValue)
            + [AtumLaunchArguments.scriptedAppPanelFlag, mode,
               "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15), "no chat title: \(boundedHierarchy(app))")
        title.tap()
        XCTAssertTrue(element(app, "info.sheet").waitForExistence(timeout: 3), boundedHierarchy(app))
        return app
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 where !target.isHittable {
            element(app, "info.sheet").swipeUp()
        }
    }

    /// The declared pages, in their declared order, after the header; the chat
    /// itself is not repeated. Only a page the mobile contract admits opens.
    @MainActor
    func testAppPanelListsDeclaredPagesAndOpensAnAdmittedOne() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchMoonPanel("pages")
        let readings = element(app, "info.app.page.readings")
        XCTAssertTrue(readings.waitForExistence(timeout: 3), boundedHierarchy(app))
        for id in ["library", "match", "tarot"] {
            XCTAssertTrue(element(app, "info.app.page." + id).exists, id)
            XCTAssertFalse(element(app, "info.app.page." + id).isEnabled, "\(id) opens on the phone")
        }
        XCTAssertFalse(element(app, "info.app.page.chat").exists, "the chat is offered as a page")
        let order = ["readings", "library", "match", "tarot"].map { element(app, "info.app.page." + $0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "pages are not in the declared order")
        XCTAssertTrue(app.buttons["Luận Giải"].exists, boundedHierarchy(app))
        // The phone's chat controls stay below the pages.
        XCTAssertGreaterThan(element(app, "info.pin").frame.minY, element(app, "info.app.page.tarot").frame.minY)
        keepScreenshot("as11-app-panel-pages-vi", of: app)

        reveal(readings, in: app)
        XCTAssertTrue(readings.isEnabled)
        readings.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Luận Giải"].waitForExistence(timeout: 3),
                      "the page's bar does not name it: \(boundedHierarchy(app))")
        XCTAssertTrue(element(app, "info.app.page.failed").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts["Không mở được trang này."].exists)
        XCTAssertEqual(probeLines("app-panel.txt").map(\.text).filter { $0.hasPrefix("launch") }, ["launch readings"])
        keepScreenshot("as11-app-panel-page-failed-vi", of: app)

        element(app, "info.app.page.retry").tap()
        XCTAssertTrue(waitFor(3) {
            self.probeLines("app-panel.txt").map(\.text).filter { $0.hasPrefix("launch") }.count == 2
        }, "Retry did not open the page again")
        XCTAssertTrue(element(app, "info.app.page.failed").waitForExistence(timeout: 3))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "info.app.page.readings").waitForExistence(timeout: 3),
                      "Back did not return to the app's pages: \(boundedHierarchy(app))")
    }

    @MainActor
    func testAppPanelWithoutPagesSaysSo() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchMoonPanel("empty")
        XCTAssertTrue(element(app, "info.app.empty").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts["Ứng dụng này chưa có màn hình nào."].exists)
    }

    @MainActor
    func testAppPanelReadFailureOffersRetry() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchMoonPanel("failed")
        XCTAssertTrue(element(app, "info.app.unavailable").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts["Ứng dụng này hiện không khả dụng."].exists)
        XCTAssertTrue(waitFor(3) { self.probeLines("app-panel.txt").map(\.text) == ["refresh"] })
        element(app, "info.app.retry").tap()
        XCTAssertTrue(waitFor(3) { self.probeLines("app-panel.txt").map(\.text) == ["refresh", "refresh"] },
                      "Retry did not read the pages again")
        XCTAssertTrue(element(app, "info.app.unavailable").waitForExistence(timeout: 3))
    }

    /// An app whose account is not linked offers one action: back to the chat,
    /// where its connect card lives.
    @MainActor
    func testUnlinkedAppPanelConnectReturnsToTheChat() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchMoonPanel("connect")
        let connect = element(app, "info.app.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertFalse(element(app, "info.app.page.readings").exists)
        connect.tap()
        XCTAssertTrue(waitFor(3) { !self.element(app, "info.sheet").exists }, "Connect did not close the panel")
    }

    /// Home: an app row's long-press menu leads with "Info", which opens the
    /// official app card: name, "An Atum app", "Open Moon", and Done.
    @MainActor
    func testAppRowInfoOpensTheOfficialAppCard() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let list = element(app, "home.list")
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let moonQuery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moon'"))
        var attempts = 0
        while !moonQuery.firstMatch.exists, attempts < 5 {
            list.swipeUp()
            attempts += 1
        }
        let moon = moonQuery.firstMatch
        XCTAssertTrue(moon.exists)
        moon.press(forDuration: 1)
        let info = app.buttons["Thông tin"]
        for _ in 0..<2 where !info.waitForExistence(timeout: 5) {
            moon.press(forDuration: 1.2)
        }
        XCTAssertTrue(info.waitForExistence(timeout: 5), boundedHierarchy(app))
        info.tap()

        XCTAssertTrue(element(app, "app.card").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts["Ứng dụng của Atum"].exists)
        XCTAssertTrue(element(app, "app.card.open").exists)
        XCTAssertTrue(app.buttons["Mở Moon"].exists)
        XCTAssertTrue(probeLines("home-actions.txt").map(\.text).contains { $0.hasPrefix("appInfo ") })
        keepScreenshot("as11-app-card-vi", of: app)

        element(app, "app.card.done").tap()
        XCTAssertTrue(waitFor(3) { !self.element(app, "app.card").exists }, "Done did not close the card")
    }
}
