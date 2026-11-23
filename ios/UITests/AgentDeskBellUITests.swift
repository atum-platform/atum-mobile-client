import AtumChat
import XCTest

/// W4-E3: the agent's desk in its chat's side panel (desktop #51) and Home's
/// notification bell (desktop #48), in English and Vietnamese, light and dark.
/// Scripted only: `chat.agent-desk` fakes the Shell's host routes with their
/// exact JSON; `-AtumScriptedSignInAgain` raises the bell's "Sign in again".
final class AgentDeskBellUITests: TranscriptUITestCase {
    private struct Words {
        let working: String
        let bell: String
        let needsYou: String
        let signIn: String
        let nothing: String
    }

    private let words: [String: Words] = [
        "en": Words(working: "Working", bell: "Notifications", needsYou: "Needs you:",
                    signIn: "Sign in again", nothing: "Nothing needs you right now"),
        "vi": Words(working: "Đang làm", bell: "Thông báo", needsYou: "Cần bạn:",
                    signIn: "Đăng nhập lại", nothing: "Hiện không có gì cần bạn"),
    ]

    @MainActor
    private func launch(_ scenario: ScriptedScenario, language: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: scenario.rawValue)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments + extra
        app.launch()
        return app
    }

    @MainActor
    func testDeskAndBellInEnglishAndVietnameseLightAndDark() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone sheet")
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        for language in ["en", "vi"] {
            for appearance in [XCUIDevice.Appearance.light, .dark] {
                XCUIDevice.shared.appearance = appearance
                let tag = "\(language)-\(appearance == .dark ? "dark" : "light")"
                try checkDesk(language: language, tag: tag)
                try checkSave(tag: tag)
                try checkBell(language: language, tag: tag)
            }
        }
    }

    @MainActor
    private func checkDesk(language: String, tag: String) throws {
        let expected = try XCTUnwrap(words[language])
        let app = launch(.chatAgentDesk, language: language)
        XCTAssertTrue(element(app, "chat.more").waitForExistence(timeout: 15), boundedHierarchy(app))
        element(app, "chat.more").tap()
        // The panel opens on the agent's own page, at medium, with Now, Files and Controls.
        XCTAssertTrue(element(app, "desk.page").waitForExistence(timeout: 5), boundedHierarchy(app))
        let head = element(app, "desk.now.head")
        XCTAssertTrue(head.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(head.label.hasPrefix(expected.working), head.label)
        XCTAssertTrue(element(app, "desk.now.steps").exists, "no checklist")
        XCTAssertTrue(element(app, "desk.files.sent").exists, "no sent files")
        XCTAssertTrue(element(app, "desk.files.own").waitForExistence(timeout: 3), "no own files")
        keepScreenshot("w4-e3-desk-\(tag)", of: app)

        // Large: its folder opens in place, Back returns; More shows the routines.
        // Swipe on the panel itself: it grows to large (a swipe on the app can land on the chat).
        element(app, "desk.page").swipeUp()
        XCTAssertTrue(element(app, "desk.page").waitForExistence(timeout: 3), "the panel closed: \(boundedHierarchy(app))")
        let folder = element(app, "desk.own.folder.reports")
        XCTAssertTrue(folder.waitForExistence(timeout: 3), boundedHierarchy(app))
        folder.tap()
        XCTAssertTrue(element(app, "desk.own.file.q3-summary.md").waitForExistence(timeout: 3), boundedHierarchy(app))
        element(app, "desk.own.back").tap()
        XCTAssertTrue(element(app, "desk.own.file.notes.md").waitForExistence(timeout: 3))

        let pause = app.switches["desk.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(pause.value as? String, "0", "one routine is live: not paused")
        element(app, "desk.more").tap()
        let brief = app.switches["desk.routine.job-brief"]
        XCTAssertTrue(brief.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(brief.value as? String, "1")
        XCTAssertEqual(app.switches["desk.routine.job-review"].value as? String, "0")
        keepScreenshot("w4-e3-desk-controls-\(tag)", of: app)

        // Pause moves every live switch at once and is sent to the host.
        // The row is the switch's label; iOS moves a switch from its knob.
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(3) { (pause.value as? String) == "1" }, "Pause did not move")
        XCTAssertTrue(waitFor(3) { (brief.value as? String) == "0" }, "the routine did not pause with it")
        XCTAssertTrue(waitFor(3) { self.probeLines("agent-desk.txt").contains { $0.text == "control pause" } })

        // All settings is the agent's card, one Back away.
        element(app, "desk.allSettings").tap()
        XCTAssertTrue(waitFor(3) { !self.element(app, "desk.page").exists }, "All settings stayed on the desk")
        XCTAssertTrue(element(app, "info.sheet").exists)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    /// Save: a download that fails says so in an alert; one that works opens
    /// the system's export sheet for that file.
    @MainActor
    private func checkSave(tag: String) throws {
        // The probe folder is this test's: count only what this launch adds.
        let pickers = { self.probeLines("agent-desk.txt").filter { $0.text.hasPrefix("save picker ") && $0.text.hasSuffix("ke-hoach-q4.pdf") }.count }
        let opened = pickers()
        let app = launch(.chatAgentDesk, language: tag.hasPrefix("vi") ? "vi" : "en")
        XCTAssertTrue(element(app, "chat.more").waitForExistence(timeout: 15), boundedHierarchy(app))
        element(app, "chat.more").tap()
        XCTAssertTrue(element(app, "desk.page").waitForExistence(timeout: 5), boundedHierarchy(app))
        element(app, "desk.page").swipeUp()
        let broken = app.buttons["desk.file.save.chat.agent-desk.file.8"]
        XCTAssertTrue(broken.waitForExistence(timeout: 3), boundedHierarchy(app))
        broken.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "a failed Save said nothing: \(boundedHierarchy(app))")
        keepScreenshot("w4-e3-desk-save-failed-\(tag)", of: app)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(3) { !alert.exists }, "the alert stayed")
        XCTAssertTrue(waitFor(3) { broken.isEnabled }, "Save stayed disabled after the failure")
        XCTAssertEqual(pickers(), opened, "a failed download opened the export sheet")

        app.buttons["desk.file.save.chat.agent-desk.file"].tap()
        XCTAssertTrue(waitFor(8) { pickers() == opened + 1 }, "the export sheet never opened")
        keepScreenshot("w4-e3-desk-save-picker-\(tag)", of: app)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }

    @MainActor
    private func checkBell(language: String, tag: String) throws {
        let expected = try XCTUnwrap(words[language])
        // Something needs the person: the badged bell says it, its list acts.
        var app = launch(.homeRoster, language: language, extra: ["-AtumScriptedSignInAgain"])
        let bell = app.buttons.matching(identifier: "home.bell").firstMatch
        let search = app.textFields.matching(identifier: "home.search").firstMatch
        let plus = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertEqual(bell.label, expected.needsYou + " " + expected.signIn)
        XCTAssertLessThan(search.frame.maxX, bell.frame.minX + Self.framePoints, "bell right of search")
        XCTAssertLessThan(bell.frame.maxX, plus.frame.minX + Self.framePoints, "bell left of plus")
        keepScreenshot("w4-e3-bell-badge-\(tag)", of: app)
        bell.tap()
        let item = app.buttons.matching(identifier: "home.bell.item.sign_in").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts[expected.bell].exists)
        keepScreenshot("w4-e3-bell-list-\(tag)", of: app)
        item.tap()
        XCTAssertTrue(waitFor(3) { self.probeLines("home-actions.txt").contains { $0.text == "reauthenticate" } })
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))

        // Nothing needs the person: a quiet bell and one line.
        app = launch(.homeRoster, language: language)
        let quiet = app.buttons.matching(identifier: "home.bell").firstMatch
        XCTAssertTrue(quiet.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertEqual(quiet.label, expected.bell)
        quiet.tap()
        let nothing = element(app, "home.bell.nothing")
        XCTAssertTrue(nothing.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(nothing.label, expected.nothing)
        keepScreenshot("w4-e3-bell-empty-\(tag)", of: app)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}
