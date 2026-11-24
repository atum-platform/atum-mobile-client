import AtumChat
import XCTest

/// W4-E6: Settings › Connections and the connect sheet over a synthetic
/// account registry (`connections.*` scripted scenarios), and the model
/// picker's Connect entries (`-AtumScriptedConnections plans`). No account,
/// Mac or network: every row comes from the scripted host.
final class AccountConnectionsUITests: TranscriptUITestCase {
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let ax5Size = "UICTContentSizeCategoryAccessibilityXXXL"

    @MainActor
    private func launchConnections(_ scenario: String, language: String = "en", dark: Bool = false,
                                   contentSize: String = AccountConnectionsUITests.defaultSize) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, AtumLaunchArguments.scriptedFlag, scenario,
                               "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
                               "-atum.appearance", dark ? "dark" : "light",
                               "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 20), "no Settings")
        openSettingsPage("connections", in: app)
        return app
    }

    @MainActor
    private func connection(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath,
                     line: UInt = #line) -> XCUIElement {
        let row = element(app, "account.settings.connections." + id)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(id) row", file: file, line: line)
        return row
    }

    @MainActor
    private func evidence(_ name: String, of app: XCUIApplication) {
        keepScreenshot(name, of: app)
        let folder = TranscriptUITestCase.liveEvidence
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("connections-\(name).png"))
    }

    // MARK: Settings › Connections

    /// Every plan, always: ChatGPT on a Mac, Claude last seen, Antigravity to
    /// connect, then OpenCode Go and Data and tools. Only Antigravity has an
    /// action, and its sheet says where to connect.
    @MainActor
    func testRowsSayWhereEachPlanRunsAndConnectSaysToUseTheMac() {
        let app = launchConnections("connections.mixed")
        XCTAssertTrue(connection(app, "plan.codex").label.contains("ChatGPT, On MacBook Pro"))
        XCTAssertTrue(connection(app, "plan.claude").label.contains("Claude, Last seen on Mac mini"))
        XCTAssertTrue(connection(app, "plan.antigravity").label.contains("Antigravity, Not connected"))
        XCTAssertFalse(element(app, "account.settings.connections.plan.codex.connect").exists,
                       "a connected plan offers no action on the phone")
        XCTAssertFalse(element(app, "account.settings.connections.plan.claude.connect").exists,
                       "a last-seen plan keeps its models and offers no Connect")
        XCTAssertTrue(connection(app, "opencode-go").label.contains("OpenCode Go, In the cloud"))
        let chats = connection(app, "owner-chats")
        XCTAssertTrue(scrollSettingsList(to: chats, in: app))
        XCTAssertEqual(chats.label, "Your chats, Every assistant knows your chats.")
        XCTAssertTrue(connection(app, "home_hub:strap-hub").label
            .contains("Strap hub, Every assistant can use it., Not connected"))
        evidence("rows-en-light", of: app)

        let connect = app.buttons["account.settings.connections.plan.antigravity.connect"]
        XCTAssertTrue(scrollSettingsList(to: connect, in: app))
        XCTAssertEqual(connect.label, "Connect Antigravity")
        connect.tap()
        let title = element(app, "connections.sheet.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the connect sheet did not open")
        XCTAssertEqual(title.label, "Connect Antigravity")
        XCTAssertEqual(element(app, "connections.sheet.needs-mac").label, "Open Atum on your Mac to connect.")
        XCTAssertFalse(labelExists(app, "Your assistants can use this plan through this Mac."),
                       "the phone is not a Mac: no consent sentence")
        evidence("sheet-en-light", of: app)
        app.buttons["connections.sheet.close"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Close did not close the sheet")
    }

    /// The owner connects on a Mac while the sheet is open: it says so with a
    /// check, leaves after a beat, and the row now names the Mac.
    @MainActor
    func testTheSheetSaysConnectedWhenTheMacReportsIt() {
        let app = launchConnections("connections.lands", language: "vi")
        let connect = app.buttons["account.settings.connections.plan.antigravity.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertTrue(scrollSettingsList(to: connect, in: app))
        connect.tap()
        XCTAssertEqual(element(app, "connections.sheet.needs-mac").label, "Mở Atum trên máy Mac để kết nối.")
        let done = element(app, "connections.sheet.done")
        XCTAssertTrue(done.waitForExistence(timeout: 20), "the sheet never saw the plan land")
        XCTAssertEqual(done.label, "Đã kết nối Antigravity")
        evidence("sheet-done-vi-light", of: app)
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "the sheet did not leave after the beat")
        let antigravity = element(app, "account.settings.connections.plan.antigravity")
        XCTAssertTrue(waitFor(5) { antigravity.label.contains("Trên Mac mini") },
                      "the row did not take the new read: \(antigravity.label)")
    }

    /// A failed read says so with Try again; it never claims "Not connected".
    @MainActor
    func testAFailedReadOffersTryAgain() {
        let app = launchConnections("connections.failed")
        let failed = connection(app, "failed")
        XCTAssertTrue(failed.label.contains("Couldn’t check this right now."), failed.label)
        XCTAssertFalse(element(app, "account.settings.connections.plan.antigravity").exists)
        XCTAssertTrue(connection(app, "owner-chats").exists, "your chats never depend on the read")
        app.buttons["account.settings.connections.retry"].tap()
        XCTAssertTrue(connection(app, "plan.codex").label.contains("On MacBook Pro"))
    }

    /// Dark and the largest accessibility size: the action sits under the
    /// text, and every row still reads in full.
    @MainActor
    func testDarkAtTheLargestTextSize() {
        let app = launchConnections("connections.mixed", dark: true, contentSize: Self.ax5Size)
        XCTAssertTrue(connection(app, "plan.antigravity").label.contains("Not connected"))
        let connect = app.buttons["account.settings.connections.plan.antigravity.connect"]
        XCTAssertTrue(scrollSettingsList(to: connect, in: app), "Connect is not reachable at AX5")
        evidence("rows-en-dark-ax5", of: app)
    }

    @MainActor
    private func labelExists(_ app: XCUIApplication, _ label: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
    }
}

/// The picker's Connect entries for the plans with nothing to pick.
final class AccountConnectionsPickerUITests: WS3UITestCase {
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]

    @MainActor
    func testThePickerOffersToConnectEachPlanWithNothingToPick() {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatEmpty) + Self.english
            + ["-AtumScriptedSubscriptions", "ready", "-AtumScriptedConnections", "plans"]
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: 5), "the model sheet did not open")

        let claude = element(app, "phone.model.plan.claude")
        var scrolls = 0
        while !(claude.exists && claude.isHittable), scrolls < 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            scrolls += 1
        }
        XCTAssertTrue(claude.exists, "no Connect entry for Claude")
        XCTAssertTrue(labelContains(claude, "Use your Claude plan").exists)
        XCTAssertTrue(element(app, "phone.model.plan.antigravity").exists)
        XCTAssertFalse(element(app, "phone.model.plan.codex").exists, "ChatGPT is connected: nothing to connect")
        keepEvidence("picker-connect-en", of: app)

        let connect = app.buttons["phone.model.plan.claude.connect"]
        XCTAssertEqual(connect.label, "Connect Claude")
        connect.tap()
        let title = element(app, "connections.sheet.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the connect sheet did not open")
        XCTAssertEqual(title.label, "Connect Claude")
        XCTAssertEqual(element(app, "connections.sheet.needs-mac").label, "Open Atum on your Mac to connect.")
        app.buttons["connections.sheet.close"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "composer.model.close").exists, "closing the sheet keeps the picker open")
    }
}
