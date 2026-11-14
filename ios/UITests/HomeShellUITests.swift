import AtumChat
import XCTest

/// The first S2 shell/Home acceptance slice: the system tabs and the frozen
/// `home.roster` projection use the real app root and real Home row renderer.
final class HomeShellUITests: TranscriptUITestCase {
    @MainActor
    func testSyntheticRosterLastRowScrollsAboveTheInsetTabBarAtCompactAndLargeText() {
        for contentSize in ["UICTContentSizeCategoryL",
                            "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
                + ["-AtumDebugLongRoster", "-UIPreferredContentSizeCategoryName", contentSize]
            app.launch()

            let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
            let homeTab = app.buttons.matching(identifier: "phone.tab.chats").firstMatch
            let lastRow = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Roster final row'")
            ).firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 15), "Home list did not appear")
            XCTAssertTrue(homeTab.waitForExistence(timeout: 3), "Home tab button did not appear")
            let listTop = list.frame.minY

            for _ in 0..<24 {
                if lastRow.exists && lastRow.isHittable
                    && lastRow.frame.maxY <= homeTab.frame.minY + 1
                    && lastRow.frame.minY >= listTop - 1 { break }
                let window = app.windows.firstMatch
                let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
                let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                start.press(forDuration: 0.05, thenDragTo: end,
                            withVelocity: XCUIGestureVelocity(rawValue: 3500),
                            thenHoldForDuration: 0.1)
            }

            XCTAssertTrue(lastRow.exists, "Synthetic roster tail did not appear")
            XCTAssertTrue(lastRow.isHittable,
                          "Roster tail did not scroll into view at \(contentSize)")
            XCTAssertLessThanOrEqual(lastRow.frame.maxY, homeTab.frame.minY + 1,
                                     "Last row extends under the bottom tab bar at \(contentSize)")
            XCTAssertGreaterThanOrEqual(lastRow.frame.minY, listTop - 1,
                                        "Last row extends above the Home list at \(contentSize)")
            keepScreenshot("home-roster-tail-\(contentSize)", of: app)
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5),
                          "the previous roster process did not terminate")
        }
    }

    @MainActor
    func testPersonalRosterHeaderAndFourDistinctDestinations() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15), "Home list did not appear")
        XCTAssertEqual(list.value as? String, "badge:9")
        XCTAssertTrue(app.staticTexts["Trợ lý"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch.exists)
        // Apps and people sit under their own label, as on desktop, not under Assistants.
        let assistantsLabel = element(app, "home.section.assistants")
        let chatsLabel = element(app, "home.section.chats")
        XCTAssertTrue(assistantsLabel.exists, boundedHierarchy(app))
        XCTAssertTrue(chatsLabel.exists, boundedHierarchy(app))
        XCTAssertEqual(chatsLabel.label, "Trò chuyện")
        XCTAssertLessThan(assistantsLabel.frame.minY, chatsLabel.frame.minY)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Luna'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lan'")).firstMatch.exists)

        let homeTab = app.buttons.matching(identifier: "phone.tab.chats").firstMatch
        let driveTab = app.buttons.matching(identifier: "phone.tab.drive").firstMatch
        let storeTab = app.buttons.matching(identifier: "phone.tab.store").firstMatch
        let teamSpaceTab = app.buttons.matching(identifier: "phone.tab.team_space").firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 3))
        XCTAssertTrue(driveTab.exists)
        XCTAssertTrue(storeTab.exists)
        XCTAssertTrue(teamSpaceTab.exists)
        XCTAssertEqual(storeTab.label, "Cửa hàng")
        XCTAssertEqual(teamSpaceTab.label, "Không gian nhóm")
        XCTAssertTrue(homeTab.isSelected)
        XCTAssertEqual(driveTab.value as? String, "Sắp có")
        XCTAssertEqual(storeTab.value as? String ?? "", "")
        // The scripted roster has unread company mentions, so the Workplace tab speaks its mark
        // (count first), matching the badge drawn on its icon. Anka, the active company, folds as
        // desktop's company rail does: general 4 + random 3 notifications, the muted ops channel adds
        // only its mentions (none) = 7; Studio is a dot. The tab counts every company, the active one too.
        XCTAssertTrue((teamSpaceTab.value as? String ?? "").contains("7"),
                      "Workplace tab should announce its unread/mention mark")
        XCTAssertEqual(homeTab.value as? String ?? "", "")
        XCTAssertFalse(app.buttons["phone.tab.account"].exists)
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
        // centre and the glass pencil share one row. The tab bar has no search.
        let account = app.buttons.matching(identifier: "home.account").firstMatch
        let search = app.textFields.matching(identifier: "home.search").firstMatch
        let plus = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(account.exists && search.exists && plus.exists, boundedHierarchy(app))
        XCTAssertLessThan(account.frame.midX, search.frame.midX)
        XCTAssertLessThan(search.frame.midX, plus.frame.midX)
        XCTAssertEqual(search.frame.midY, account.frame.midY, accuracy: 4, "one top row")
        XCTAssertFalse(element(app, "home.title").exists, "Chats has no title")
        XCTAssertFalse(app.buttons.matching(identifier: "phone.tab.search").firstMatch.exists)
        XCTAssertFalse(element(app, "company.section").exists,
                       "Personal Home must not contain company rows or invitations\n\(boundedHierarchy(app))")

        keepScreenshot("s2-home-roster-light-vi", of: app)

        driveTab.tap()
        XCTAssertTrue(waitFor(2) { driveTab.isSelected })
        XCTAssertTrue(element(app, "phone.comingSoon.drive").waitForExistence(timeout: 3))
        storeTab.tap()
        XCTAssertTrue(waitFor(2) { storeTab.isSelected })
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 3))
        teamSpaceTab.tap()
        XCTAssertTrue(waitFor(2) { teamSpaceTab.isSelected })
        XCTAssertTrue(element(app, "teamSpace.screen").waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "company.section").exists)
        XCTAssertTrue(element(app, "company.header").exists, boundedHierarchy(app))
        XCTAssertTrue(app.buttons.matching(identifier: "company.channel.general").firstMatch.exists,
                      boundedHierarchy(app))
        homeTab.tap()
        XCTAssertTrue(waitFor(2) { homeTab.isSelected })
        XCTAssertFalse(element(app, "company.section").exists, boundedHierarchy(app))

        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "account.close").firstMatch.tap()
        XCTAssertTrue(waitFor(2) { !element(app, "account.screen").exists })
    }

    @MainActor
    func testAccountStoreRowOpensStore() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let account = element(app, "home.account")
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        account.tap()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 3))

        // The Store is on the Protons page, with the balance it is bought for.
        openSettingsPage("protons", in: app)
        let store = element(app, "account.settings.protons.store")
        XCTAssertTrue(store.waitForExistence(timeout: 3), "Protons has no Store row")
        XCTAssertEqual(store.label, "Cửa hàng")
        store.tap()
        XCTAssertTrue(element(app, "store.catalog").waitForExistence(timeout: 3),
                      "Store did not open from Settings")
    }

    @MainActor
    func testSearchFiltersNamesAndCancelRestoresRows() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let field = app.descendants(matching: .any).matching(identifier: "home.search").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Top search field did not appear")
        field.tap()
        field.typeText("lan")

        let lan = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lan'")).firstMatch
        XCTAssertTrue(lan.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch.exists)

        let clear = app.buttons.matching(identifier: "home.search.clear").firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 2), "Search clear did not appear")
        clear.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
            .waitForExistence(timeout: 2))

        field.tap()
        field.typeText("zzz")
        XCTAssertTrue(app.staticTexts["Không tìm thấy kết quả nào"].waitForExistence(timeout: 2))
        app.buttons.matching(identifier: "home.search.clear").firstMatch.tap()

        app.buttons.matching(identifier: "home.search.cancel").firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "home.create").firstMatch.waitForExistence(timeout: 2),
                      "Cancel did not restore the header controls")
        XCTAssertTrue(field.exists, "the search field stays at the top")
    }

    @MainActor
    func testPlusOpensStartChatWithRealRowsAndAvailableCreationActions() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15), "Plus button did not appear beside search")
        create.tap()
        XCTAssertTrue(app.staticTexts["Bắt đầu trò chuyện"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(identifier: "home.startChat.addFriend").firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "home.startChat.newAssistant").firstMatch.exists)
        // HC-5: New group is the People section's last row, as on desktop.
        XCTAssertTrue(revealStartChatNewGroup(app).exists, "no inline New group row")

        // Any row still in view after the scroll opens its conversation.
        let existing = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.startChat.row.'")
        ).allElementsBoundByIndex.first { $0.isHittable && $0.isEnabled }
        XCTAssertNotNil(existing, "Start chat has no existing conversation")
        existing?.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.scripted.destination"]
            .waitForExistence(timeout: 3))
    }

    /// HC-5: Start chat's "New group" is an inline row at the end of People
    /// (desktop `start-chat.tsx`), so a long list scrolls it into view.
    @MainActor
    private func revealStartChatNewGroup(_ app: XCUIApplication) -> XCUIElement {
        let newGroup = app.buttons.matching(identifier: "home.startChat.newGroup").firstMatch
        let sheet = app.descendants(matching: .any).matching(identifier: "home.startChat").firstMatch
        _ = sheet.waitForExistence(timeout: 3)
        for _ in 0..<6 where !(newGroup.exists && newGroup.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        return newGroup
    }

    /// HC-5: a typed @name offers "Find @x on Atum", which opens Add friend
    /// already searching; a name with no match says so.
    @MainActor
    func testStartChatFindsATypedHandleOnAtum() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15), boundedHierarchy(app))
        create.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Zzz Không ai")
        XCTAssertTrue(app.descendants(matching: .any)["home.startChat.noMatches"].waitForExistence(timeout: 3),
                      "no no-match state")
        search.buttons.firstMatch.tap()
        search.typeText("@LAN_ANH")
        let find = app.buttons.matching(identifier: "home.startChat.find").firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 3), "no Find on Atum row")
        XCTAssertTrue(find.label.contains("@lan_anh"), find.label)
        find.tap()
        XCTAssertTrue(app.staticTexts["Không có ai trên Atum tên là @lan_anh."]
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testAddFriendFormNormalizesHandleAndShowsDirectoryResult() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15), boundedHierarchy(app))
        create.tap()
        let addFriend = app.buttons.matching(identifier: "home.startChat.addFriend").firstMatch
        XCTAssertTrue(addFriend.waitForExistence(timeout: 3))
        addFriend.tap()

        let field = app.textFields.matching(identifier: "home.addFriend.handle").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("@LAN_ANH")
        let find = app.buttons.matching(identifier: "home.addFriend.find").firstMatch
        XCTAssertTrue(waitFor(3) { find.isEnabled }, "the normalized handle did not enable Find")
        find.tap()
        XCTAssertTrue(app.staticTexts["Không có ai trên Atum tên là @lan_anh."]
            .waitForExistence(timeout: 3))
    }

    @MainActor
    func testNewGroupSelectsKnownPersonAndOpensPublishedRoom() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15), boundedHierarchy(app))
        create.tap()
        let newGroup = revealStartChatNewGroup(app)
        XCTAssertTrue(newGroup.exists, "no inline New group row")
        newGroup.tap()

        let name = app.textFields.matching(identifier: "home.newGroup.name").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Nhóm thử")
        let lookup = app.textFields.matching(identifier: "home.newGroup.handle").firstMatch
        XCTAssertTrue(lookup.exists)
        let member = app.buttons.matching(identifier: "home.newGroup.member.@lan:atum.test").firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 3))
        XCTAssertLessThan(name.frame.minY, lookup.frame.minY)
        XCTAssertLessThan(lookup.frame.minY, member.frame.minY)
        XCTAssertFalse(app.buttons.matching(identifier: "home.newGroup.member.@alfred:atum.test").firstMatch.exists,
                       "phone has no shared-agent group consent/capability contract")
        XCTAssertTrue(app.staticTexts["Người được thêm sau cũng xem được tin nhắn trước đó."].exists)
        member.tap()
        let submit = app.buttons.matching(identifier: "home.newGroup.create").firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.scripted.destination"]
            .waitForExistence(timeout: 3))
    }

    @MainActor
    func testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let newAssistant = app.buttons.matching(identifier: "home.startChat.newAssistant").firstMatch
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 3))
        newAssistant.tap()

        let disclosure = app.staticTexts.matching(identifier: "home.newAssistant.disclosure").firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        let name = app.textFields.matching(identifier: "home.newAssistant.name").firstMatch
        XCTAssertTrue(name.exists)
        name.tap()
        // Not "Alfred": the scripted roster already has one, and the sheet
        // refuses a duplicate before anything is created (AS-3, desktop
        // `isDuplicateAssistantName`).
        name.typeText("Mây")
        let submit = app.buttons.matching(identifier: "home.newAssistant.create").firstMatch
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        XCTAssertTrue(waitFor(3) { submit.label == "Thử lại" && !name.isEnabled })
        submit.tap()
        XCTAssertTrue(waitFor(3) { self.probeLines("home-actions.txt").count == 2 })
        XCTAssertEqual(probeLines("home-actions.txt").map(\.text),
                       ["newAssistant Mây", "newAssistant Mây"])
    }

    @MainActor
    func testRosterAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15), "Home list did not appear")
        try auditIgnoringScrollEdges(app)
    }

    @MainActor
    func testRetappingHomeAtRootScrollsRosterToTop() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15), "Home list did not appear")
        let atum = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
        XCTAssertTrue(atum.exists)

        list.swipeUp()
        list.swipeUp()
        XCTAssertTrue(waitFor(2) { !atum.exists }, "Atum never moved offscreen")

        app.buttons.matching(identifier: "phone.tab.chats").firstMatch.tap()
        let restored = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atum'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 2), "Home re-tap did not restore the roster top")
    }

    @MainActor
    func testInvitationShowsJoinProgressThenPushes() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeInvite.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let invite = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Đặng'")).firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 15), "Invitation did not appear")
        XCTAssertTrue(invite.label.contains("Mời bạn trò chuyện"))

        invite.tap()
        XCTAssertTrue(waitFor(0.8) { (invite.value as? String) == "joining" }, "Join atom state did not appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.scripted.destination")
            .firstMatch.waitForExistence(timeout: 2), "Joined invitation did not push")
        XCTAssertFalse(app.buttons.matching(identifier: "phone.tab.chats").firstMatch.exists,
                       "Tab bar remains visible in the pushed destination")
    }

    @MainActor
    func testSwipeActionsMutateRowsOnce() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        XCTAssertEqual(list.value as? String, "badge:9")

        var luna = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Luna'")).firstMatch
        XCTAssertTrue(luna.exists)
        luna.swipeRight()
        app.buttons["Đánh dấu đã đọc"].tap()
        XCTAssertTrue(waitFor(2) { (list.value as? String) == "badge:7" })

        luna = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Luna'")).firstMatch
        luna.swipeLeft()
        app.buttons["Tắt thông báo"].tap()
        XCTAssertTrue(waitFor(2) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Luna' AND label CONTAINS 'Đã tắt thông báo'"))
                .firstMatch.exists
        })

        var family = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gia đình'")).firstMatch
        family.swipeLeft()
        app.buttons["Ghim"].tap()
        family = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gia đình'")).firstMatch
        XCTAssertTrue(waitFor(2) { family.label.contains("Đã ghim") })

        XCTAssertEqual(probeLines("home-actions.txt").map(\.text), [
            "unread !luna-plain:atum.test false",
            "muted !luna-plain:atum.test true",
            "pinned !gia-dinh:atum.test true",
        ])
    }

    @MainActor
    func testInvitationMenuDeclinesOnce() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeInvite.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let invite = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Đặng'")).firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 15))
        invite.press(forDuration: 1)
        let decline = app.buttons["Từ chối lời mời"]
        for _ in 0..<2 where !decline.waitForExistence(timeout: 5) {
            invite.press(forDuration: 1.2)
        }
        XCTAssertTrue(decline.waitForExistence(timeout: 5))
        decline.tap()
        XCTAssertTrue(waitFor(2) { !invite.exists })
        XCTAssertEqual(probeLines("home-actions.txt").map(\.text), [
            "declined !dang-invite:atum.test",
        ])
    }

    @MainActor
    func testPinLimitMenuKeepsDeleteAndDisablesPin() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homePinsFull.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
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
        let pin = app.buttons["Ghim"]
        for _ in 0..<2 where !pin.waitForExistence(timeout: 5) {
            moon.press(forDuration: 1.2)
        }
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertFalse(pin.isEnabled)
        let delete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Xóa cuộc trò chuyện'"))
            .firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testDeletingAppRoomLeavesReopenableAppRow() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let list = app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        let moonQuery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moon'"))
        var attempts = 0
        while !moonQuery.firstMatch.exists, attempts < 5 {
            list.swipeUp()
            attempts += 1
        }
        var moon = moonQuery.firstMatch
        XCTAssertTrue(moon.exists)
        moon.press(forDuration: 1)
        let delete = app.buttons.matching(NSPredicate(format: "label == 'Xóa cuộc trò chuyện'"))
            .firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        delete.tap()
        let confirm = app.sheets.buttons["Xóa cuộc trò chuyện"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        confirm.tap()

        moon = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Moon' AND NOT label CONTAINS 'Hôm nay bạn sẽ có một ngày thuận lợi'"
        )).firstMatch
        XCTAssertTrue(moon.waitForExistence(timeout: 2), "Synthetic app row did not replace the hidden room")
        moon.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.scripted.destination")
            .firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(probeLines("home-actions.txt").map(\.text), [
            "hidden !moon-plain:atum.test",
        ])
    }

    // MARK: Home search: People (desktop roster global search)

    @MainActor
    private func launchPeopleSearch(language: String = "vi", size: String = "UICTContentSizeCategoryL",
                                    extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-UIPreferredContentSizeCategoryName", size]
            + extraArguments
            + probeArguments
        app.launch()
        let search = element(app, "home.search")
        XCTAssertTrue(search.waitForExistence(timeout: 15), boundedHierarchy(app))
        // A loaded simulator can drop the first tap or be slow to hand the
        // field the keyboard: tap again until it has focus.
        var focused = false
        for _ in 0..<4 where !focused {
            search.tap()
            focused = waitFor(8) { (search.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "the Home search did not take focus")
        return app
    }

    @MainActor
    private func peopleSearches() -> [String] {
        probeLines("home-actions.txt").map(\.text).filter { $0.hasPrefix("peopleSearch ") }
    }

    /// The owner's report: an @handle typed into Home's search found nothing.
    /// Desktop's search lists People found by the directory under the
    /// roster's own matches' search block; tapping one opens their chat.
    @MainActor
    func testHomeSearchFindsAPersonByHandleAndOpensTheirChat() {
        let app = launchPeopleSearch()
        let search = element(app, "home.search")

        // One character asks nothing (desktop: two or more).
        search.typeText("@")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(peopleSearches(), [], "a single character searched the directory")
        XCTAssertFalse(element(app, "home.section.people").exists)

        search.typeText("somehandle")
        let person = element(app, "home.people.@somehandle:atum.test")
        XCTAssertTrue(person.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(element(app, "home.section.people").exists)
        XCTAssertTrue(person.label.contains("Thảo Nguyên") && person.label.contains("@somehandle"),
                      "row reads \(person.label)")
        XCTAssertEqual(peopleSearches().last, "peopleSearch @somehandle")
        XCTAssertFalse(element(app, "home.people.@some-assistant:atum.test").exists,
                       "an assistant is not a person")

        person.tap()
        XCTAssertTrue(element(app, "home.scripted.destination").waitForExistence(timeout: 15))
        XCTAssertTrue(probeLines("home-actions.txt").map(\.text).contains("openPerson @somehandle:atum.test"))
    }

    @MainActor
    func testHomeSearchDoesNotListAKnownChatAgainUnderPeople() {
        let app = launchPeopleSearch()
        element(app, "home.search").typeText("lan")
        XCTAssertTrue(waitFor(15) { self.peopleSearches().contains("peopleSearch lan") },
                      "the directory was not asked")
        // The answer has landed (Lan, already a chat); only the roster's own row shows.
        XCTAssertTrue(waitFor(15) { !self.element(app, "home.people.searching").exists })
        XCTAssertFalse(element(app, "home.people.@lan:atum.test").exists, "Lan is listed twice")
        XCTAssertFalse(element(app, "home.section.people").exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lan'")).firstMatch.exists)
    }

    /// Evidence of the People section: light and dark, English and
    /// Vietnamese, and the largest accessibility size.
    @MainActor
    func testHomeSearchPeopleAppearances() {
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        let runs: [(String, XCUIDevice.Appearance, String)] = [
            ("en", .light, "UICTContentSizeCategoryAccessibilityXXXL"),
            ("en", .light, "UICTContentSizeCategoryL"),
            ("en", .dark, "UICTContentSizeCategoryL"),
            ("vi", .light, "UICTContentSizeCategoryL"),
            ("vi", .dark, "UICTContentSizeCategoryL"),
        ]
        for (language, appearance, size) in runs {
            XCUIDevice.shared.appearance = appearance
            let app = showPeople(language: language, size: size)
            let tag = "\(language)-\(appearance == .dark ? "dark" : "light")-"
                + (size.hasSuffix("AccessibilityXXXL") ? "ax5" : "l")
            keepScreenshot("home-search-people-\(tag)", of: app)
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }
    }

    /// The accessibility audit of the People section at the largest size.
    @MainActor
    func testHomeSearchPeopleAccessibilityAudit() throws {
        let app = showPeople(language: "en", size: "UICTContentSizeCategoryAccessibilityXXXL")
        try auditIgnoringScrollEdges(app)
    }

    /// Control for the audit above: the same search header with only a
    /// roster match (Lan is a chat, so People stays empty).
    @MainActor
    func testHomeSearchRosterMatchAccessibilityAuditControl() throws {
        let app = launchPeopleSearch(language: "en", size: "UICTContentSizeCategoryAccessibilityXXXL")
        element(app, "home.search").typeText("lan\n")
        XCTAssertTrue(waitFor(15) { self.peopleSearches().contains("peopleSearch lan") })
        XCTAssertTrue(waitFor(15) { !self.element(app, "home.people.searching").exists })
        XCTAssertFalse(element(app, "home.section.people").exists)
        try auditIgnoringScrollEdges(app)
    }

    @MainActor
    private func showPeople(language: String, size: String) -> XCUIApplication {
        let app = launchPeopleSearch(language: language, size: size)
        // Return ends editing and keeps the query (`HomeSearchField`), so
        // the audit judges the app, not the system keyboard.
        element(app, "home.search").typeText("@somehandle\n")
        let person = element(app, "home.people.@somehandle:atum.test")
        XCTAssertTrue(person.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(person.isHittable, "the person row is not reachable at \(size)")
        return app
    }

    // MARK: Channels, Messages and Files (desktop roster global search)

    @MainActor
    private func companySearches() -> [String] {
        probeLines("home-actions.txt").map(\.text).filter { $0.hasPrefix("companySearch ") }
    }

    /// Desktop's global search block, top to bottom: Searching…, People,
    /// Channels, Messages, Files; then the roster's own matches.
    @MainActor
    func testHomeSearchListsChannelsMessagesAndFilesInDesktopOrder() {
        let app = launchPeopleSearch(language: "en")
        let search = element(app, "home.search")
        search.typeText("l")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(companySearches(), [], "a single character searched the companies")
        XCTAssertFalse(element(app, "home.section.channels").exists)

        search.typeText("aunch\n")
        let files = element(app, "home.section.files")
        XCTAssertTrue(files.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(waitFor(15) { !self.element(app, "home.people.searching").exists })
        let headers = ["people", "channels", "messages", "files"].map { element(app, "home.section.\($0)") }
        XCTAssertTrue(headers.allSatisfy(\.exists), boundedHierarchy(app))
        let tops = headers.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "sections out of desktop order: \(tops)")
        XCTAssertEqual(element(app, "home.section.channels").label, "Channels and teams")
        XCTAssertEqual(Set(companySearches()), ["companySearch messages launch", "companySearch files launch"])

        // Channels: the Team Space rooms named "launch…", not "general".
        XCTAssertTrue(element(app, "home.channels.!launch:atum.test").exists)
        XCTAssertTrue(element(app, "home.channels.!launch-vn:atum.test").exists)
        XCTAssertFalse(element(app, "home.channels.!general:atum.test").exists)
        // Messages and Files: the room's name, then the words or the file's name.
        let message = element(app, "home.messages.$launch-review")
        XCTAssertTrue(message.label.hasPrefix("general, Can we move the launch review"), message.label)
        XCTAssertEqual(element(app, "home.files.$launch-deck").label, "launch, launch-deck.pdf")

        message.tap()
        XCTAssertTrue(element(app, "home.scripted.destination").waitForExistence(timeout: 15))
        XCTAssertTrue(probeLines("home-actions.txt").map(\.text).contains("openResult $launch-review"))
    }

    /// Review should-fix 3: when the re-check or the navigation fails, the
    /// tap opens nothing and the row can be tried again (Home posts the
    /// generic error announcement and the error haptic).
    @MainActor
    func testHomeSearchResultThatCannotOpenStaysOnHome() {
        let app = launchPeopleSearch(language: "en")
        element(app, "home.search").typeText("launch\n")
        let draft = element(app, "home.messages.$launch-draft")
        XCTAssertTrue(draft.waitForExistence(timeout: 15), boundedHierarchy(app))
        draft.tap()
        XCTAssertTrue(waitFor(10) { self.probeLines("home-actions.txt").map(\.text).contains("openResult $launch-draft") })
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(element(app, "home.scripted.destination").exists, "a refused result navigated")
        XCTAssertTrue(draft.exists && draft.isEnabled, "the row did not come back after the failure")
        // The next result still opens.
        element(app, "home.messages.$launch-review").tap()
        XCTAssertTrue(element(app, "home.scripted.destination").waitForExistence(timeout: 15))
    }

    /// Review round 2, Home rendering: rows already on screen follow the
    /// live eligibility. The account leaves "Launch Việt Nam" after the answer
    /// landed (same query, same companies, so no new search): its message row
    /// goes, the others stay.
    @MainActor
    func testHomeSearchHidesResultsOfARoomLeftWhileShown() {
        let app = launchPeopleSearch(language: "en",
                                     extraArguments: ["-AtumScriptedLeaveAfterSearch", "!launch-vn:atum.test"])
        element(app, "home.search").typeText("launch\n")
        let draft = element(app, "home.messages.$launch-draft")
        XCTAssertTrue(draft.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(waitFor(15) { self.probeLines("home-actions.txt").map(\.text).contains("left !launch-vn:atum.test") })
        XCTAssertTrue(waitFor(10) { !draft.exists }, "a left room's result stayed on screen")
        XCTAssertTrue(element(app, "home.messages.$launch-review").exists)
        XCTAssertTrue(element(app, "home.files.$launch-deck").exists)
        let searches = probeLines("home-actions.txt").map(\.text).filter { $0 == "companySearch messages launch" }
        XCTAssertEqual(searches.count, 1, "the row went by rendering, not by a new search")
    }

    /// Tapping a channel opens its room, as desktop selects it.
    @MainActor
    func testHomeSearchChannelOpensItsRoom() {
        let app = launchPeopleSearch(language: "en")
        element(app, "home.search").typeText("launch viet\n")
        let channel = element(app, "home.channels.!launch-vn:atum.test")
        XCTAssertTrue(channel.waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertFalse(element(app, "home.channels.!launch:atum.test").exists)
        channel.tap()
        XCTAssertTrue(element(app, "home.scripted.destination").waitForExistence(timeout: 15))
    }

    /// Evidence of the new sections: light and dark, English and Vietnamese,
    /// and the largest accessibility size (top, then scrolled to Files).
    @MainActor
    func testHomeSearchChannelsMessagesFilesAppearances() {
        addTeardownBlock { XCUIDevice.shared.appearance = .light }
        let runs: [(String, XCUIDevice.Appearance, String)] = [
            ("en", .light, "UICTContentSizeCategoryL"),
            ("en", .dark, "UICTContentSizeCategoryL"),
            ("vi", .light, "UICTContentSizeCategoryL"),
            ("vi", .dark, "UICTContentSizeCategoryL"),
            ("en", .light, "UICTContentSizeCategoryAccessibilityXXXL"),
        ]
        for (language, appearance, size) in runs {
            XCUIDevice.shared.appearance = appearance
            let app = showGlobalSections(language: language, size: size)
            let tag = "\(language)-\(appearance == .dark ? "dark" : "light")-"
                + (size.hasSuffix("AccessibilityXXXL") ? "ax5" : "l")
            keepScreenshot("home-search-cmf-\(tag)", of: app)
            if size.hasSuffix("AccessibilityXXXL") {
                let file = element(app, "home.files.$launch-deck")
                for _ in 0..<8 where !file.isHittable { app.swipeUp() }
                XCTAssertTrue(file.isHittable, "the Files row is not reachable at \(size)")
                keepScreenshot("home-search-cmf-\(tag)-files", of: app)
            }
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }
    }

    /// The accessibility audit of the new sections at the largest size.
    /// "kickoff" finds a channel, a message and a file and nobody in the
    /// directory, so the People row's quarantined monogram finding
    /// (`testHomeSearchPeopleAccessibilityAudit`) stays out of this one.
    @MainActor
    func testHomeSearchChannelsMessagesFilesAccessibilityAudit() throws {
        let app = launchPeopleSearch(language: "en", size: "UICTContentSizeCategoryAccessibilityXXXL")
        element(app, "home.search").typeText("kickoff\n")
        XCTAssertTrue(element(app, "home.section.channels").waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(waitFor(15) { !self.element(app, "home.people.searching").exists })
        XCTAssertFalse(element(app, "home.section.people").exists)
        XCTAssertTrue(element(app, "home.channels.!kickoff:atum.test").exists)
        try auditIgnoringScrollEdges(app)
        // Then the Messages and Files rows, scrolled into view.
        let file = element(app, "home.files.$kickoff-agenda")
        for _ in 0..<8 where !file.isHittable { app.swipeUp() }
        XCTAssertTrue(file.isHittable, "the Files row is not reachable at AX XXXL")
        try auditIgnoringScrollEdges(app)
    }

    @MainActor
    private func showGlobalSections(language: String, size: String) -> XCUIApplication {
        let app = launchPeopleSearch(language: language, size: size)
        // Return ends editing and keeps the query, so the keyboard is gone.
        element(app, "home.search").typeText("launch\n")
        XCTAssertTrue(element(app, "home.section.channels").waitForExistence(timeout: 15), boundedHierarchy(app))
        XCTAssertTrue(waitFor(15) { !self.element(app, "home.people.searching").exists })
        // At AX sizes the List draws only what fits; Messages may be below.
        if !size.contains("Accessibility") {
            XCTAssertTrue(element(app, "home.messages.$launch-review").exists, boundedHierarchy(app))
        }
        return app
    }
}
