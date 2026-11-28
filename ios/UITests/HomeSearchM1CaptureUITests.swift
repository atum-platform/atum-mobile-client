import AtumChat
import XCTest

/// ML3 S1/S2/S16 on the scripted Home (`-AtumScriptedMessageSearch`): the M1
/// results, the device-only scope and the list filters, light and dark, with
/// screenshots kept for comparison against the approved M1 frames.
final class HomeSearchM1CaptureUITests: TranscriptUITestCase {
    @MainActor
    func testResultsPrivateScopeAndFiltersLightAndDark() {
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let suffix = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
                + ["-AtumScriptedMessageSearch", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                   "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
                + probeArguments
            app.launch()

            // S16: the filters under the field; Unread keeps only unread rows.
            let unread = element(app, "home.filter.unread")
            XCTAssertTrue(unread.waitForExistence(timeout: 15), boundedHierarchy(app))
            keepScreenshot("s16-filters-\(suffix)", of: app)
            unread.tap()
            XCTAssertTrue(waitFor(5) { unread.isSelected }, "Unread did not select")
            keepScreenshot("s16-unread-\(suffix)", of: app)
            element(app, "home.filter.all").tap()

            // S1: plain results grouped by chat, company-only label, coverage.
            let search = element(app, "home.search")
            var focused = false
            for _ in 0..<4 where !focused {
                search.tap()
                focused = waitFor(8) { (search.value(forKey: "hasKeyboardFocus") as? Bool) == true }
            }
            XCTAssertTrue(focused, "the Home search did not take focus")
            XCTAssertTrue(element(app, "home.search.scope.device").waitForExistence(timeout: 5), boundedHierarchy(app))
            keepScreenshot("m1-open-\(suffix)", of: app)
            search.typeText("launch")
            let coverage = element(app, "home.search.coverage")
            XCTAssertTrue(coverage.waitForExistence(timeout: 15), boundedHierarchy(app))
            XCTAssertTrue(element(app, "home.messages.$luna-budget").exists, boundedHierarchy(app))
            XCTAssertTrue(element(app, "home.messages.$launch-review").exists, boundedHierarchy(app))
            XCTAssertTrue(app.staticTexts["Atum Studio"].exists, "company label missing")
            XCTAssertTrue(coverage.label.hasPrefix("Searched "), coverage.label)
            XCTAssertFalse(element(app, "home.messages.$lan-photos").exists, "a private hit in plain results")
            app.swipeDown() // keyboard away, results in view
            keepScreenshot("m1-results-\(suffix)", of: app)

            // S2: choosing the private scope clears the field; the private
            // term reaches only the device index, never a remote source.
            let remoteBefore = remoteSearches()
            element(app, "home.search.scope.device").tap()
            XCTAssertTrue(waitFor(5) { (search.value as? String).map { $0.isEmpty || $0 != "launch" } ?? true })
            search.tap()
            search.typeText("launch")
            XCTAssertTrue(waitFor(15) { self.element(app, "home.messages.$lan-photos").exists }, boundedHierarchy(app))
            XCTAssertFalse(element(app, "home.messages.$luna-budget").exists, "a plain hit in private results")
            XCTAssertTrue(coverage.waitForExistence(timeout: 5))
            XCTAssertTrue(coverage.label.contains("private chats on this device"), coverage.label)
            XCTAssertEqual(remoteSearches(), remoteBefore, "the private term reached a remote source")
            XCTAssertTrue(probeLines("home-actions.txt").contains { $0.text == "deviceSearch launch" })
            XCTAssertTrue(probeLines("home-actions.txt").contains { $0.text == "backfill start" })
            app.swipeDown()
            keepScreenshot("m1-private-\(suffix)", of: app)

            // Opening routes the exact event; Cancel returns to the roster.
            element(app, "home.messages.$lan-photos").tap()
            XCTAssertTrue(waitFor(5) {
                self.probeLines("home-actions.txt").contains { $0.text == "openHit $lan-photos deviceOnly" }
            })
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }
    }

    @MainActor
    private func remoteSearches() -> Int {
        probeLines("home-actions.txt").map(\.text).filter {
            $0.hasPrefix("personalSearch ") || $0.hasPrefix("companySearch ") || $0.hasPrefix("peopleSearch ")
        }.count
    }
}
