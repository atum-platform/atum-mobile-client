import AtumChat
import XCTest

/// FlowPhone3's interactive panels on the real chat screen, kept as
/// screenshots for the board comparison (the evidence folder's capture step
/// runs this once per appearance): the message-actions overlay, opened by a
/// long press, and the attach sheet, opened by the composer's +.
final class KitBoardCaptureUITests: WS3UITestCase {
    /// A long press opens the Kit overlay: the reaction capsule, the message
    /// and the short menu with the exported words; a tap outside closes it.
    @MainActor
    func testMessageActionsOverlay() {
        let app = launchChat(.chatPeople)
        openMenu(app, text: "Nhớ mang cuốn sách")
        let reply = menuButton(app, "Trả lời")
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "the overlay did not open")
        XCTAssertTrue(paletteButton(app, "👍").exists, "the reaction capsule")
        XCTAssertTrue(menuButton(app, "Sao chép").exists)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("kit-message-actions", of: app)
        // Outside the incoming message's stack (left-aligned, at most 352 pt).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        waitForAbsence(reply)
    }

    /// The composer's + opens the attach sheet: recent photos, then Photos
    /// and Files.
    @MainActor
    func testAttachSheet() {
        let app = launchChat(.chatEmpty)
        let add = element(app, AccessibilityID.mediaAdd)
        XCTAssertTrue(add.waitForExistence(timeout: Self.waitSeconds))
        add.tap()
        let photos = element(app, "chat.attach.photos")
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "the attach sheet did not open")
        XCTAssertTrue(element(app, "chat.attach.files").exists)
        Thread.sleep(forTimeInterval: 2)
        keepScreenshot("kit-attach-sheet", of: app)
    }

    /// The assistant's card from the chat header, as on the desktop.
    @MainActor
    func testAssistantCard() {
        let app = launchChat(.chatEmpty)
        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(element(app, "assistant.card.message").waitForExistence(timeout: 5)
                      || app.descendants(matching: .any).matching(identifier: "assistant.card.routines")
                        .firstMatch.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("kit-assistant-card", of: app)
    }
}

/// The Settings and Team space captures (owner notes, 2026-11-04): they use the
/// Settings helpers of `TranscriptUITestCase`.
final class KitBoardSettingsCaptureUITests: TranscriptUITestCase {
    static let vietnamese = ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
                             "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]

    /// Team space: the company's app tile with its logo in the header capsule,
    /// and the switcher (Studio has a logo, Anka shows the Kit monogram).
    @MainActor
    func testTeamSpaceHeaderAndSwitcher() {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .homeRoster) + Self.vietnamese
        app.launch()
        let tab = app.buttons.matching(identifier: "phone.tab.team_space").firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let header = element(app, "company.header")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "no company header")
        if header.label != "Studio" {
            header.tap()
            let studio = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Studio")).firstMatch
            XCTAssertTrue(studio.waitForExistence(timeout: 3))
            studio.tap()
            XCTAssertTrue(element(app, "company.header").waitForExistence(timeout: 3))
        }
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("kit-team-header", of: app)
        element(app, "company.header").tap()
        XCTAssertTrue(element(app, "company.switcher").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("kit-team-switcher", of: app)
    }

    /// Settings: the profile card index, the folded Account and Connections
    /// pages, and General's appearance control forcing Dark, then Light,
    /// then back to the system.
    @MainActor
    func testSettingsPagesAndAppearanceSwitch() {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, AtumLaunchArguments.scriptedFlag,
                               "account.default"] + Self.vietnamese
        app.launch()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "account.settings.index.account").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("kit-settings-index", of: app)

        openSettingsPage("account", in: app)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("kit-settings-account", of: app)
        closeSettingsPage(in: app)
        openSettingsPage("connections", in: app)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("kit-settings-connections", of: app)
        closeSettingsPage(in: app)

        openSettingsPage("general", in: app)
        let control = app.segmentedControls.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 3), "no appearance control")
        for (word, name) in [("Tối", "dark"), ("Sáng", "light"), ("Theo hệ thống", "system")] {
            let segment = control.buttons[word]
            XCTAssertTrue(segment.exists, "no \(word) segment")
            segment.tap()
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(segment.isSelected)
            keepScreenshot("kit-appearance-" + name, of: app)
        }
    }

    /// The owner's ask (2026-11-04): a person's chat offers Delete chat and a
    /// group Leave group from the row's long press; an assistant's offers
    /// neither. Delete is confirmed first.
    @MainActor
    func testRowExitsPerChatKind() {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .homeRoster) + Self.vietnamese
        app.launch()
        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))

        func press(_ name: String) -> XCUIElement {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(scrollSettingsList(to: row, in: app), "no \(name) row")
            row.press(forDuration: 1.2)
            return row
        }

        _ = press("Lan")
        let delete = app.buttons["Xóa cuộc trò chuyện"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "a person's chat offers Delete chat")
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("kit-row-person-menu", of: app)
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Xóa cuộc trò chuyện")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Delete chat is confirmed first")
        keepScreenshot("kit-row-person-confirm", of: app)
        // iOS 26 draws the dialog's Cancel as a tap outside, not a button.
        let cancel = app.buttons["Hủy"].firstMatch
        if cancel.exists { cancel.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(waitFor(3) { !confirm.exists }, "Cancel keeps the chat")

        _ = press("Gia đình")
        XCTAssertTrue(app.buttons["Rời nhóm"].waitForExistence(timeout: 3), "a group offers Leave group")
        keepScreenshot("kit-row-group-menu", of: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        _ = press("Luna")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["Xóa cuộc trò chuyện"].exists, "no Delete chat for an assistant")
        XCTAssertFalse(app.buttons["Rời nhóm"].exists, "no Leave group for an assistant")
    }
}
