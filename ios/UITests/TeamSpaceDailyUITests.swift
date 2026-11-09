import AtumChat
import XCTest

/// Workplace daily-use slice (U1/U2/U4) on the real `TeamSpaceScreen` and
/// `ChatComposer` with synthetic data: the channel list is the Workplace root
/// (not a sheet), marks render from counts, "Not now" clears an invitation,
/// mute goes through the same call as a Home row, and the `@` picker inserts a
/// name and sends `m.mentions.user_ids`.
final class TeamSpaceDailyUITests: TranscriptUITestCase {
    private static let vietnamese = ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
                                     "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]

    @MainActor
    private func launchWorkplace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumDebugTeamSpace"] + probeArguments + Self.vietnamese
        app.launch()
        XCTAssertTrue(element(app, "teamSpace.screen").waitForExistence(timeout: 15), "no Workplace")
        return app
    }

    @MainActor
    func testWorkplaceRootIsTheChannelListAndAChannelPushesAndPopsBack() {
        let app = launchWorkplace()
        XCTAssertTrue(element(app, "company.section").waitForExistence(timeout: 3))
        let general = app.buttons.matching(identifier: "company.channel.general").firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(element(app, "company.header").exists, "the company header carries the switcher")
        XCTAssertFalse(element(app, "company.channels.sheet").exists)

        general.tap()
        XCTAssertTrue(element(app, "teamSpace.scripted.destination").waitForExistence(timeout: 3),
                      "a channel pushes instead of dismissing a sheet")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(3) { self.element(app, "company.channel.general").exists },
                      "Back returns to the list")
    }

    @MainActor
    func testChannelMarksRenderFromCountsAndMutedStaysQuiet() {
        let app = launchWorkplace()
        let general = app.buttons.matching(identifier: "company.channel.general").firstMatch
        let random = app.buttons.matching(identifier: "company.channel.random").firstMatch
        let ops = app.buttons.matching(identifier: "company.channel.ops").firstMatch
        let design = app.buttons.matching(identifier: "company.channel.design").firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 3))
        XCTAssertTrue(general.label.contains("Nhắc đến bạn"), "mention: \(general.label)")
        XCTAssertTrue(random.label.contains("3"), "unread count: \(random.label)")
        XCTAssertFalse(random.label.contains("Nhắc đến bạn"))
        XCTAssertTrue(ops.label.contains("Đã tắt thông báo"), "muted: \(ops.label)")
        XCTAssertFalse(design.label.contains("Nhắc đến bạn"))
        XCTAssertFalse(design.label.contains("Đã tắt thông báo"))

        // The Workplace tab carries the company mention as its value.
        let tab = app.buttons.matching(identifier: "phone.tab.team_space").firstMatch
        XCTAssertTrue(tab.exists)
        let tabValue = tab.value as? String ?? ""
        XCTAssertTrue(tabValue.contains("Nhắc đến bạn"), "tab value: \(tabValue)")
        XCTAssertTrue(tabValue.contains("7"), "the tab folds all unmuted notifications: \(tabValue)")
    }

    @MainActor
    func testNotNowClearsTheInvitationCard() {
        let app = launchWorkplace()
        let card = element(app, "company.invitation.labs")
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        let later = app.descendants(matching: .any)["Để sau"].firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 3))
        later.tap()
        XCTAssertTrue(waitFor(3) { !card.exists }, "Not now removes the invitation")
        XCTAssertTrue(app.buttons.matching(identifier: "company.channel.general").firstMatch.exists)
    }

    @MainActor
    func testSwipeMutesAndUnmutesThroughTheRoomMutePath() {
        let app = launchWorkplace()
        let random = app.buttons.matching(identifier: "company.channel.random").firstMatch
        XCTAssertTrue(random.waitForExistence(timeout: 3))
        random.swipeLeft()
        let mute = app.buttons.matching(identifier: "company.channel.mute.random").firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 2), boundedHierarchy(app))
        mute.tap()
        XCTAssertTrue(waitFor(3) { random.label.contains("Đã tắt thông báo") })

        random.swipeLeft()
        app.buttons.matching(identifier: "company.channel.mute.random").firstMatch.tap()
        XCTAssertTrue(waitFor(3) { !random.label.contains("Đã tắt thông báo") })
        XCTAssertEqual(probeLines("team-actions.txt").map(\.text), [
            "mute !random:atum.test true",
            "mute !random:atum.test false",
        ])
    }

    @MainActor
    func testSwitcherChangesTheChannelList() {
        let app = launchWorkplace()
        let header = app.buttons.matching(identifier: "company.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        header.tap()
        app.buttons.matching(identifier: "company.switch.studio").firstMatch.tap()
        XCTAssertTrue(waitFor(3) { self.element(app, "company.channel.studio-general").exists })
        XCTAssertFalse(element(app, "company.channel.random").exists)
    }

    @MainActor
    func testTheHeaderOpensTheSwitcherSheetWithTheCurrentCompanyCheckedAndCreateOffered() {
        let app = launchWorkplace()
        let header = app.buttons.matching(identifier: "company.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        header.tap()
        XCTAssertTrue(element(app, "company.switcher").waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(element(app, "company.switch.current.anka").exists, "a check on the current company")
        XCTAssertFalse(element(app, "company.switch.current.studio").exists)
        XCTAssertTrue(app.buttons.matching(identifier: "company.switch.studio").firstMatch.exists)
        XCTAssertTrue(element(app, "company.switcher.invitations").exists, "invitations sit in the sheet too")
        XCTAssertTrue(element(app, "company.create.open").exists, "Create company is one tap from the header")
        app.buttons.matching(identifier: "company.switcher.close").firstMatch.tap()
        XCTAssertTrue(waitFor(3) { !self.element(app, "company.switcher").exists })
    }

    @MainActor
    func testCreateCompanyFromTheSwitcherSendsTheNameAndShowsTheNewCompany() {
        let app = launchWorkplace()
        app.buttons.matching(identifier: "company.header").firstMatch.tap()
        XCTAssertTrue(element(app, "company.create.open").waitForExistence(timeout: 3))
        element(app, "company.create.open").tap()
        let field = app.textFields.matching(identifier: "company.create.name").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), boundedHierarchy(app))
        let submit = app.buttons.matching(identifier: "company.create.submit").firstMatch
        XCTAssertFalse(submit.isEnabled, "Create stays off until there is a name")
        field.typeText("Studio")
        XCTAssertTrue(waitFor(2) { submit.isEnabled })
        submit.tap()
        XCTAssertTrue(waitFor(5) { self.element(app, "company.channel.studio-general").exists },
                      "the new company's list is the Workplace root")
        XCTAssertFalse(element(app, "company.create").exists, "the form closes with the sheet")
        XCTAssertEqual(probeLines("team-actions.txt").map(\.text), ["create Studio"])
    }

    @MainActor
    func testAClosedCreateIsSaidUnderTheNameAndTheNameStays() {
        let app = launchWorkplace()
        app.buttons.matching(identifier: "company.header").firstMatch.tap()
        element(app, "company.create.open").tap()
        let field = app.textFields.matching(identifier: "company.create.name").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("closed")
        app.buttons.matching(identifier: "company.create.submit").firstMatch.tap()
        let error = element(app, "company.create.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5), boundedHierarchy(app))
        XCTAssertEqual(error.label, "Hiện chưa mở tạo công ty.")
        XCTAssertEqual(field.value as? String, "closed", "the name is kept so the person can change it")
    }

    @MainActor
    func testMentionPickerInsertsANameAndTheSendCarriesTheUserID() {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatPeople)
            + probeArguments + Self.vietnamese
        app.launch()
        let field = element(app, AccessibilityID.composerField)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("chào @minh")

        let picker = element(app, "composer.mentions")
        XCTAssertTrue(picker.waitForExistence(timeout: 3), boundedHierarchy(app))
        let minhAnh = element(app, "composer.mention.@minh-anh:atum.test")
        XCTAssertTrue(minhAnh.exists)
        minhAnh.tap()
        XCTAssertTrue(waitFor(3) { !picker.exists }, "the picker closes after a pick")
        XCTAssertTrue((field.value as? String ?? "").hasPrefix("chào @"), "the pick is in the text")
        XCTAssertTrue((field.value as? String ?? "").hasSuffix(" "))

        element(app, AccessibilityID.composerSend).tap()
        XCTAssertTrue(waitFor(3) { !self.probeLines("chat-actions.txt").isEmpty })
        XCTAssertEqual(probeLines("chat-actions.txt").map(\.text),
                       ["send mentions=@minh-anh:atum.test html=true"])
    }

    @MainActor
    func testNoPickerForTextWithoutAnAt() {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatPeople)
            + probeArguments + Self.vietnamese
        app.launch()
        let field = element(app, AccessibilityID.composerField)
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("không nhắc ai")
        XCTAssertFalse(element(app, "composer.mentions").exists)
    }
}
