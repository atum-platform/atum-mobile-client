import AtumChat
import XCTest

/// Wave 3 TS-11/TS-13 on the real `TeamSpaceScreen` with the scripted host's
/// synthetic invite answers: Invite teammates opens "Add people to Anka", a typed
/// @handle becomes one row with Add, the share link is shown once, Join with
/// invite link previews and joins, and the channel list has Favorites, a
/// collapsed Archived and "+" Create a channel. Screenshots are kept in the
/// result bundle (copied to .scratch/ by the capture step).
final class TeamSpaceInviteUITests: TranscriptUITestCase {
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    private static let vietnamese = ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
    private static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
    private static let ax5Text = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    private func launchWorkplace(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumDebugTeamSpace"] + probeArguments + extra
        app.launch()
        XCTAssertTrue(element(app, "teamSpace.screen").waitForExistence(timeout: 15), "no Workplace")
        return app
    }

    @MainActor private func probed(_ line: String) -> Bool {
        probeLines("team-actions.txt").contains { $0.text == line }
    }

    @MainActor
    private func openInviteSheet(_ app: XCUIApplication) -> XCUIElement {
        let footer = app.buttons.matching(identifier: "company.invite.teammates").firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !footer.isHittable { list.swipeUp() }
        XCTAssertTrue(footer.waitForExistence(timeout: 3), boundedHierarchy(app))
        footer.tap()
        let search = app.textFields.matching(identifier: "company.invite.search").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "no invite sheet")
        return search
    }

    @MainActor
    func testInviteSheetAddsAHandleAndShowsTheLinkOnce() {
        let app = launchWorkplace(Self.english + Self.largeText)
        let search = openInviteSheet(app)
        XCTAssertTrue(element(app, "company.invite.title").label.contains("Anka"))

        // Someone already in says so, with no Add.
        search.typeText("minh")
        XCTAssertTrue(element(app, "company.invite.member.minh").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertFalse(app.buttons.matching(identifier: "company.invite.add.minh").firstMatch.exists)

        // Typing on makes it another handle, which can be added.
        search.typeText("_tran")
        let add = app.buttons.matching(identifier: "company.invite.add.minh_tran").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), boundedHierarchy(app))
        add.tap()
        XCTAssertTrue(element(app, "company.invite.invited.minh_tran").waitForExistence(timeout: 3),
                      "the row says Invited")
        XCTAssertTrue(element(app, "company.invite.status").label.contains("@minh_tran"))
        XCTAssertTrue(waitFor(3) { self.probed("invite minh_tran") })

        let create = app.buttons.matching(identifier: "company.invite.link.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        XCTAssertTrue(element(app, "company.invite.link.url").waitForExistence(timeout: 3), "the link is shown once")
        keepScreenshot("ts11-invite-sheet-en", of: app)
    }

    @MainActor
    func testARefusedHandleSaysWhyInVietnamese() {
        let app = launchWorkplace(Self.vietnamese + Self.largeText)
        let search = openInviteSheet(app)
        search.typeText("nobody")
        let add = app.buttons.matching(identifier: "company.invite.add.nobody").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let status = element(app, "company.invite.status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("Không mời được"), status.label)
        keepScreenshot("ts11-invite-refused-vi", of: app)
    }

    @MainActor
    func testJoinWithInviteLinkPreviewsThenJoins() {
        let app = launchWorkplace(Self.english + Self.largeText)
        app.buttons.matching(identifier: "company.menu").firstMatch.tap()
        // System menu items carry their label, not the SwiftUI identifier.
        let add = app.buttons["Add company"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), boundedHierarchy(app))
        add.tap()
        let open = app.buttons.matching(identifier: "company.join.open").firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 3), boundedHierarchy(app))
        open.tap()
        let input = app.textViews.matching(identifier: "company.join.input").firstMatch.exists
            ? app.textViews.matching(identifier: "company.join.input").firstMatch
            : app.textFields.matching(identifier: "company.join.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 3), boundedHierarchy(app))
        input.tap()
        input.typeText("https://atum.app/j/PUBLIC_FIXTURE_ONLY_61818fe4de417671d243876c2279bbbe")
        app.buttons.matching(identifier: "company.join.previewButton").firstMatch.tap()
        XCTAssertTrue(element(app, "company.join.preview").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(element(app, "company.join.preview").label.contains("Labs"))
        keepScreenshot("ts11-join-preview-en", of: app)
        app.buttons.matching(identifier: "company.join.submit").firstMatch.tap()
        XCTAssertTrue(waitFor(3) { self.probed("invite-link redeem") })
        XCTAssertTrue(waitFor(3) { !self.element(app, "company.join.sheet").exists }, "joining closes the sheet")
    }

    @MainActor
    func testABadLinkIsNotValidAndNothingIsSent() {
        let app = launchWorkplace(Self.english + Self.largeText)
        app.buttons.matching(identifier: "company.menu").firstMatch.tap()
        let add = app.buttons["Add company"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), boundedHierarchy(app))
        add.tap()
        app.buttons.matching(identifier: "company.join.open").firstMatch.tap()
        let field = app.textViews.matching(identifier: "company.join.input").firstMatch.exists
            ? app.textViews.matching(identifier: "company.join.input").firstMatch
            : app.textFields.matching(identifier: "company.join.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("https://example.com/not-a-link")
        app.buttons.matching(identifier: "company.join.previewButton").firstMatch.tap()
        XCTAssertTrue(element(app, "company.join.failure").waitForExistence(timeout: 3))
        XCTAssertFalse(probed("invite-link redeem"))
    }

    @MainActor
    func testChannelSectionsAndCreateAChannel() {
        let app = launchWorkplace(Self.english + Self.largeText)
        XCTAssertTrue(element(app, "company.channels.favorites").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(app.buttons.matching(identifier: "company.channel.launch").firstMatch.exists)
        let archived = app.buttons.matching(identifier: "company.channels.archived").firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 where !archived.isHittable { list.swipeUp() }
        XCTAssertTrue(archived.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertFalse(app.buttons.matching(identifier: "company.channel.retro-2025").firstMatch.exists,
                       "Archived starts collapsed")
        archived.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "company.channel.retro-2025").firstMatch
            .waitForExistence(timeout: 3))
        keepScreenshot("ts13-channel-sections-en", of: app)

        for _ in 0..<4 where !element(app, "company.channel.add").isHittable { list.swipeDown() }
        element(app, "company.channel.add").tap()
        let create = app.buttons["Create a channel"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields.matching(identifier: "company.channel.create.name").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("launch plans")
        keepScreenshot("ts13-create-channel-en", of: app)
        app.buttons.matching(identifier: "company.channel.create.submit").firstMatch.tap()
        XCTAssertTrue(waitFor(3) { self.probed("create-channel launch plans") })
        XCTAssertTrue(waitFor(3) { !self.element(app, "company.channel.create").exists })
    }

    /// AX5 and dark: the sheet's words wrap instead of clipping.
    @MainActor
    func testInviteSheetAtAX5DarkHasNoClippedText() throws {
        XCTAssertTrue(requestRunner("appearance dark"), "no content-size runner beside the run")
        defer { requestRunner("appearance light") }
        let app = launchWorkplace(Self.vietnamese + Self.ax5Text)
        let search = openInviteSheet(app)
        search.typeText("@lan_tran")
        XCTAssertTrue(app.buttons.matching(identifier: "company.invite.add.lan_tran").firstMatch
            .waitForExistence(timeout: 3))
        keepScreenshot("ts11-invite-sheet-ax5-dark-vi", of: app)
        try auditSheetText(app)

        // Scrolling puts the keyboard away and brings the link section up.
        element(app, "company.invite.sheet").swipeUp()
        let create = app.buttons.matching(identifier: "company.invite.link.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(waitFor(3) { !app.keyboards.firstMatch.exists }, "scrolling dismisses the keyboard")
        create.tap()
        XCTAssertTrue(element(app, "company.invite.link.url").waitForExistence(timeout: 3))
        keepScreenshot("ts11-invite-links-ax5-dark-vi", of: app)
        try auditSheetText(app)
    }

    /// Clipped text in the sheet fails. The system keyboard and the Workplace behind the
    /// sheet are not this screen's text.
    @MainActor
    private func auditSheetText(_ app: XCUIApplication) throws {
        let sheet = element(app, "company.invite.sheet")
        try app.performAccessibilityAudit(for: .textClipped) { issue in
            guard let found = issue.element else { return false }
            if found.elementType == .key || found.elementType == .keyboard { return true }
            guard !found.label.isEmpty else { return false }
            return sheet.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", found.label)).count == 0
        }
    }
}
