import AtumChat
import XCTest

/// The chat's side panel (M1, M2): a sheet with two heights; person
/// and group info as on the desktop's conversation info panel. Scripted chats
/// only.
final class ChatPanelUITests: TranscriptUITestCase {
    private enum Size: String, CaseIterable {
        case large = "UICTContentSizeCategoryL"
        case ax3 = "UICTContentSizeCategoryAccessibilityXL"
        var tag: String { self == .large ? "L" : "AX3" }
    }

    @MainActor
    private func launchPanelChat(_ scenario: ScriptedScenario, language: String = "vi",
                                 size: Size = .large) -> XCUIApplication {
        let app = XCUIApplication()
        let locale = language == "vi" ? "vi_VN" : "en_US"
        app.launchArguments = ScriptedScenarios.arguments(name: scenario.rawValue)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
               "-UIPreferredContentSizeCategoryName", size.rawValue]
            + probeArguments
        app.launch()
        XCTAssertTrue(element(app, "chat.title").waitForExistence(timeout: 15),
                      "no chat title: \(boundedHierarchy(app))")
        return app
    }

    @MainActor
    private func panel(_ app: XCUIApplication) -> XCUIElement { element(app, "info.sheet") }

    @MainActor private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor private var appearanceTag: String { XCUIDevice.shared.appearance == .dark ? "dark" : "light" }

    /// The title and the "…" open the same panel at medium, with the chat in
    /// view above it; the grabber raises it to large; the X closes it.
    @MainActor
    func testPersonPanelOpensFromTitleAndMoreAtMediumAndGrows() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchPanelChat(.chatPeople)
        element(app, "chat.title").tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3), boundedHierarchy(app))
        // Medium: the chat's title is still in view above the panel. It is
        // dimmed behind the sheet (M1), so it is seen, not hittable:
        // a medium sheet blocks the chat until it closes.
        let title = element(app, "chat.title").frame
        XCTAssertFalse(title.isEmpty, "no chat title behind the panel")
        XCTAssertLessThanOrEqual(title.maxY, panel(app).frame.minY + 1,
                                 "medium covers the chat: title \(title), panel \(panel(app).frame)")
        XCTAssertTrue(element(app, "info.encryption").waitForExistence(timeout: 3), boundedHierarchy(app))
        keepScreenshot("m1-person-medium-\(appearanceTag)-vi", of: app)

        app.swipeUp()
        XCTAssertTrue(element(app, "info.exit.deleteChat").waitForExistence(timeout: 3))
        keepScreenshot("m1-person-large-\(appearanceTag)-vi", of: app)

        element(app, "info.close").tap()
        XCTAssertTrue(waitFor(3) { !self.panel(app).exists }, "the X did not close the panel")
        element(app, "chat.more").tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3), "the … did not open the panel")
    }

    /// The person panel's sections in the desktop's order, its switches, and
    /// Block undone in place.
    @MainActor
    func testPersonPanelShowsConversationFactsAndBlocksInPlace() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchPanelChat(.chatPeople)
        element(app, "chat.title").tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Thông tin hội thoại"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "info.team-spaces").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Example Team"].exists)
        XCTAssertTrue(element(app, "info.started").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(element(app, "info.started").label.contains("Bắt đầu"))
        app.swipeUp()

        let low = element(app, "info.low-priority")
        XCTAssertTrue(low.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertEqual(low.value as? String, "0")
        // The swipe can leave the panel still decelerating, and a tap then
        // only stops the scroll: tap again once it has settled.
        for _ in 0..<3 where low.value as? String != "1" {
            _ = waitFor(2) { low.isHittable }
            low.switches.firstMatch.exists ? low.switches.firstMatch.tap() : low.tap()
            _ = waitFor(2) { low.value as? String == "1" }
        }
        XCTAssertTrue(waitFor(3) { low.value as? String == "1" }, "low priority did not turn on")

        let block = element(app, "info.block")
        XCTAssertTrue(block.waitForExistence(timeout: 3))
        block.tap()
        // iOS 26 no longer presents the dialog as a sheet element.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                       "Chặn người này", "info.block")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), boundedHierarchy(app))
        confirm.tap()
        XCTAssertTrue(element(app, "info.unblock").waitForExistence(timeout: 3), "Block did not become Unblock")
        keepScreenshot("m2-person-blocked-\(appearanceTag)-vi", of: app)
        element(app, "info.unblock").tap()
        XCTAssertTrue(element(app, "info.block").waitForExistence(timeout: 3))
        XCTAssertEqual(probeLines("panel.txt").map(\.text).filter { $0.hasPrefix("ignored") }.count, 2)
    }

    /// A group's panel: its topic, "N members" opening Members inside the
    /// panel, and moderation fenced by power levels.
    @MainActor
    func testGroupMembersPageModeratesByPowerLevel() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        let app = launchPanelChat(.chatKinds)
        element(app, "chat.title").tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Thông tin nhóm"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "info.topic").exists)
        keepScreenshot("m2-group-medium-\(appearanceTag)-vi", of: app)

        element(app, "info.members.open").tap()
        XCTAssertTrue(element(app, "info.members").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.staticTexts["Bạn"].exists)
        XCTAssertTrue(app.staticTexts["Đã bị cấm"].exists, "the banned person is listed")
        keepScreenshot("m2-group-members-\(appearanceTag)-vi", of: app)

        let huy = element(app, "info.member.options." + ScriptedCast.huy)
        XCTAssertTrue(huy.waitForExistence(timeout: 3))
        huy.tap()
        XCTAssertTrue(element(app, "info.member.action.remove").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "info.member.action.ban").exists)
        XCTAssertTrue(element(app, "info.member.action.block").exists)
        keepScreenshot("m2-group-member-menu-\(appearanceTag)-vi", of: app)
        element(app, "info.member.action.ban").tap()
        let confirm = app.sheets.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Cấm")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), boundedHierarchy(app))
        confirm.tap()
        XCTAssertTrue(waitFor(3) { self.probeLines("panel.txt").last?.text == "ban \(ScriptedCast.huy)" },
                      "ban did not reach the scripted boundary")

        let khoa = element(app, "info.member.options." + ScriptedCast.anhKhoa)
        XCTAssertTrue(khoa.waitForExistence(timeout: 3))
        khoa.tap()
        XCTAssertTrue(element(app, "info.member.action.unban").waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "info.member.action.remove").exists, "a banned person can't be removed")
    }

    /// Screens for review: person and group at medium in Vietnamese and
    /// English, at Large and AX3 text.
    @MainActor
    func testPanelScreensForReviewAcrossLanguagesAndTextSizes() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        for language in ["vi", "en"] {
            for size in Size.allCases {
                for scenario in [ScriptedScenario.chatPeople, .chatKinds] {
                    let app = launchPanelChat(scenario, language: language, size: size)
                    element(app, "chat.title").tap()
                    XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
                    XCTAssertTrue(element(app, "info.encryption").waitForExistence(timeout: 3))
                    let kind = scenario == .chatPeople ? "person" : "group"
                    keepScreenshot("m2-\(kind)-\(size.tag)-\(appearanceTag)-\(language)", of: app)
                    app.terminate()
                }
            }
        }
    }

    /// iPad: the same panel opens as a sheet and Members pushes inside it.
    /// The trailing inspector column (M1) is deferred until it can
    /// be attached outside the chat's NavigationStack (M1 follow-up).
    @MainActor
    func testPanelOpensAndPushesMembersOnIPad() throws {
        try XCTSkipUnless(isPad, "iPad")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchPanelChat(.chatKinds)
        element(app, "chat.title").tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3), boundedHierarchy(app))
        keepScreenshot("m1-ipad-panel-\(appearanceTag)-vi", of: app)
        element(app, "info.members.open").tap()
        XCTAssertTrue(element(app, "info.members").waitForExistence(timeout: 3))
        keepScreenshot("m2-ipad-members-\(appearanceTag)-vi", of: app)
        XCUIDevice.shared.orientation = .portrait
    }

    /// Members shows each person's verified @handle on the quiet line under
    /// their name (desktop `MatrixMembers`); each visible row asks for it.
    /// Evidence in English and Vietnamese, light and dark.
    @MainActor
    func testGroupMembersShowVerifiedHandles() throws {
        try XCTSkipIf(isPad, "iPhone sheet")
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        for language in ["en", "vi"] {
            for appearance in [XCUIDevice.Appearance.light, .dark] {
                XCUIDevice.shared.appearance = appearance
                let app = launchPanelChat(.chatKinds, language: language)
                element(app, "chat.title").tap()
                XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
                element(app, "info.members.open").tap()
                XCTAssertTrue(element(app, "info.members").waitForExistence(timeout: 3), boundedHierarchy(app))
                let huy = element(app, "info.member.handle." + ScriptedCast.huy)
                XCTAssertTrue(huy.waitForExistence(timeout: 3), boundedHierarchy(app))
                XCTAssertEqual(huy.label, "@huydo")
                XCTAssertTrue(waitFor(5) {
                    self.probeLines("handle-requests.txt").contains { $0.text.contains(ScriptedCast.huy) }
                }, "the member row did not ask for its handle")
                keepScreenshot("handles-chat-members-\(language)-\(appearanceTag)", of: app)
                app.terminate()
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            }
        }
    }
}
