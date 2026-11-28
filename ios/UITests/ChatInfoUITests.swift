import AtumChat
import XCTest

final class ChatInfoUITests: TranscriptUITestCase {
    @MainActor
    func testAssistantInfoOpensTheOneCardWithoutAnEditStep() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let chatTitle = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(chatTitle.waitForExistence(timeout: 15))
        chatTitle.tap()

        // The info sheet is the card itself: one screen, no "Edit assistant"
        // row and no second editor.
        XCTAssertTrue(app.textFields.matching(identifier: "assistant.card.name").firstMatch
            .waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "assistant.card.purpose").firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "assistant.card.personality").firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "assistant.card.message").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "info.assistant.edit").firstMatch.exists)
    }

    @MainActor
    func testAssistantPurposeSavesWhenLeavingTheField() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let purpose = app.descendants(matching: .any)
            .matching(identifier: "assistant.card.purpose").firstMatch
        XCTAssertTrue(purpose.waitForExistence(timeout: 3))
        purpose.tap()
        purpose.typeText(" Và lịch trình.")
        let done = app.buttons.matching(identifier: "assistant.card.keyboard.done").firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "assistant.card.saved").firstMatch
            .waitForExistence(timeout: 3))
    }

    @MainActor
    func testAssistantPersonalityExpandsAndSavesInTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let personality = app.buttons.matching(identifier: "assistant.card.personality").firstMatch
        XCTAssertTrue(personality.waitForExistence(timeout: 3)); personality.tap()
        let field = app.descendants(matching: .any)
            .matching(identifier: "assistant.card.personality.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("Điềm tĩnh")
        let done = app.buttons.matching(identifier: "assistant.card.keyboard.done").firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "assistant.card.saved").firstMatch
            .waitForExistence(timeout: 3))
    }

    // MARK: Desktop PR #95: field merge, conflict line, length hint

    @MainActor
    private func openPersonaCard(language: String, locale: String, size: String, dark: Bool,
                                 extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
               "-UIPreferredContentSizeCategoryName", size,
               "-atum.appearance", dark ? "dark" : "light"]
            + probeArguments + extra
        app.launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        return app
    }

    /// Scroll the card's list up by dragging its own side margin. The card is
    /// a system list (UX polish P2) whose persona fields scroll their own long
    /// text; a swipe from the screen's centre can start on such a field and
    /// scroll only its text, never the list (AX5, a long persona). The margin
    /// beside the groups belongs to the list alone.
    ///
    /// Going back the drag is short. Once the list reaches its top, the rest of
    /// a drag pulls the sheet itself down, and a long one (0.4 of the list,
    /// about 320 pt on a 390 x 844 phone) leaves it at its medium detent: the
    /// rows under the header are then off screen and the next drags start
    /// above the sheet, until one closes it (hosted iPhone 16e, PR #110, 26
    /// Nov). A short overshoot settles back at the large detent.
    @MainActor
    private func scrollCardList(_ app: XCUIApplication, back: Bool = false) {
        let list = panelList(app)
        guard list.exists else { if back { app.swipeDown() } else { app.swipeUp() }; return }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: back ? 0.2 : 0.6))
            .withOffset(CGVector(dx: 6, dy: 0))
        let travel = list.frame.height * (back ? 0.18 : -0.4)
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: travel)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor
    private func leaveField(_ app: XCUIApplication) {
        let done = app.buttons.matching(identifier: "assistant.card.keyboard.done").firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.swipeDown() }
    }

    /// Another device changed "What you do" while it was being edited: the
    /// card writes nothing over it, shows desktop's conflict line (no Retry)
    /// and the latest text.
    @MainActor
    func testAPurposeChangedElsewhereShowsTheLatestAndDesktopsLine() {
        let app = openPersonaCard(language: "en", locale: "en_US", size: "UICTContentSizeCategoryL",
                                  dark: false, extra: ["-AtumScriptedPersonaElsewhere"])
        let purpose = element(app, "assistant.card.purpose")
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        purpose.tap()
        purpose.typeText(" And email.")
        leaveField(app)
        let band = element(app, "assistant.card.persona-conflict")
        XCTAssertTrue(band.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This field changed while you were editing. Showing the latest version."]
            .exists)
        XCTAssertFalse(app.buttons["Try again"].exists)
        XCTAssertFalse(element(app, "assistant.card.saved").exists)
        XCTAssertEqual(purpose.value as? String, "Writes the weekly report.")
        XCTAssertTrue(probeLines("persona-save.txt").isEmpty, "the stale purpose was written")
        keepScreenshot("w4-e4-persona-conflict-light", of: app)
    }

    /// A personality edit that meets the same newer definition is rebased on
    /// it: the other device's purpose stays, the personality saves, and the
    /// quiet length hint reads under the footnote (dark, AX5).
    @MainActor
    func testAPersonalityEditKeepsTheOtherDevicesPurposeInDarkAtAX5() {
        let app = openPersonaCard(language: "vi", locale: "vi_VN",
                                  size: "UICTContentSizeCategoryAccessibilityXXXL", dark: true,
                                  extra: ["-AtumScriptedPersonaElsewhere", "-AtumScriptedPersonaLong"])
        let personality = app.buttons.matching(identifier: "assistant.card.personality").firstMatch
        for _ in 0..<10 where !(personality.exists && personality.isHittable) { scrollCardList(app) }
        XCTAssertTrue(personality.waitForExistence(timeout: 5)); personality.tap()
        let field = element(app, "assistant.card.personality.field")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        // At AX5 the opened field can sit under the keyboard's edge: bring it
        // into view and tap until it takes keyboard focus.
        for _ in 0..<4 where !field.isHittable { scrollCardList(app) }
        for _ in 0..<3 where !app.keyboards.firstMatch.exists {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the personality field never took focus")
        field.typeText(" Vui vẻ.")
        leaveField(app)
        // "Saved" (in the header) and the conflict band (the group under it,
        // above the handle row) head the card. The list builds rows only once
        // they are on screen, so scroll back until the header and the handle
        // row are both built: the band between them would then be built too.
        let saved = element(app, "assistant.card.saved")
        let handle = element(app, "assistant.card.handle")
        // Back-drags are short (see scrollCardList), so allow more of them.
        for _ in 0..<16 where !(saved.exists && saved.isHittable && handle.exists) {
            scrollCardList(app, back: true)
        }
        XCTAssertTrue(saved.waitForExistence(timeout: 5),
                      "Saved is not in the card header; card list at \(panelList(app).frame)")
        XCTAssertTrue(handle.exists, "the handle row under the band is not on screen")
        XCTAssertFalse(element(app, "assistant.card.persona-conflict").exists)
        let saves = probeLines("persona-save.txt").map(\.text)
        XCTAssertEqual(saves.count, 1)
        // Where the caret lands on tap varies, so read the section, not its order.
        let who = saves.first?.components(separatedBy: "## Who you are||").last?
            .components(separatedBy: "||## What you do").first ?? ""
        XCTAssertTrue(who.contains("Calm.") && who.contains("Vui vẻ."), "\(who)")
        XCTAssertTrue(saves.first?.contains("Writes the weekly report.") == true, "the other field was reverted")
        XCTAssertFalse(saves.first?.contains("Plans and writes.") == true, "the other field was reverted")
        let hint = element(app, "assistant.card.long-persona")
        for _ in 0..<12 where !(hint.exists && hint.isHittable) { scrollCardList(app) }
        XCTAssertTrue(hint.exists && hint.isHittable, "the length hint is not reachable at AX5")
        XCTAssertTrue(app.staticTexts["Trợ lý có thể chỉ đọc một phần hướng dẫn này."].exists)
        keepScreenshot("w4-e4-persona-long-dark-ax5", of: app)
    }

    @MainActor
    func testAssistantRoutineCreatesAndShowsAuthenticatedRunHistory() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        let routines = app.buttons.matching(identifier: "assistant.card.routines").firstMatch
        if !routines.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(routines.waitForExistence(timeout: 3)); routines.tap()

        let add = app.buttons.matching(identifier: "assistant.routines.add").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.tap()
        let routineTitle = app.textFields.matching(identifier: "assistant.routine.title").firstMatch
        let instruction = app.textFields.matching(identifier: "assistant.routine.instruction").firstMatch
        XCTAssertTrue(routineTitle.waitForExistence(timeout: 3)); routineTitle.tap(); routineTitle.typeText("Lên kế hoạch ngày")
        instruction.tap(); instruction.typeText("Tóm tắt lịch và ba ưu tiên.")
        let save = app.buttons.matching(identifier: "assistant.routine.save").firstMatch
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Lên kế hoạch ngày"].waitForExistence(timeout: 3))

        app.staticTexts["Morning brief"].tap()
        for _ in 0..<3 where !app.buttons.matching(identifier: "assistant.routine.run").firstMatch.exists {
            app.swipeUp()
        }
        let run = app.buttons.matching(identifier: "assistant.routine.run").firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 3)); run.tap()
        let history = app.buttons.matching(identifier: "assistant.routine.history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 3)); history.tap()
        XCTAssertTrue(app.staticTexts["Đã xong"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAssistantCardModelRowOpensTheComposerPicker() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        let model = app.buttons.matching(identifier: "assistant.card.model").firstMatch
        if !model.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        let hard = app.buttons.matching(identifier: "phone.model.row.nhat-thuc").firstMatch
        // The sheet can take over 3 s to present on a hosted runner (#44 shard 2,
        // `86228cb`, 12 Nov); every first-row wait after opening it is 10 s.
        XCTAssertTrue(hard.waitForExistence(timeout: 10))
        hard.tap()
        // The current row is marked by a check, spoken as the row's value. A
        // hosted runner missed it inside 3 s (#46 shard 2, `9d63d30`, 12 Nov).
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Đang dùng"), object: hard
        )], timeout: 10) == .completed)
    }

    /// Retains the workflow selector from the pre-Kit destination picker.
    /// The approved one-card design has one server-backed Atum choice with no
    /// route step; choosing another eligible Atum model still saves in place.
    @MainActor
    func testAssistantCardChoosesOneServerDestinationDefault() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let model = app.buttons.matching(identifier: "assistant.card.model").firstMatch
        if !model.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 10)); model.tap()

        let current = app.buttons.matching(identifier: "phone.model.row.nguyet-thuc").firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.value as? String, "Đang dùng")
        let hard = app.buttons.matching(identifier: "phone.model.row.nhat-thuc").firstMatch
        XCTAssertTrue(hard.exists); hard.tap()
        XCTAssertTrue(waitFor(10) { hard.value as? String == "Đang dùng" })
    }

    /// Retains the second workflow selector while asserting the approved Kit
    /// replacement: the one-card conversation picker exposes no external-Mac
    /// destination, and favorites remain scoped to rows actually in this menu.
    @MainActor
    func testAssistantCardPickerKeepsExternalMacTruthfulReadOnlyAndFavoritesScoped() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let model = app.buttons.matching(identifier: "assistant.card.model").firstMatch
        if !model.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 10)); model.tap()

        XCTAssertTrue(app.buttons.matching(identifier: "phone.model.row.nguyet-thuc").firstMatch
            .waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.model.destination.")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "phone.model.favorite.nguyet-thuc").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "phone.model.favorite.openai/gpt-6.1-sol").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "phone.model.row.openai/gpt-6.1-sol").firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "phone.model.filter").firstMatch.exists)
    }

    @MainActor
    func testAssistantComposerModelChoiceSavesAnEligibleServerOption() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let model = app.buttons.matching(identifier: "composer.model").firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        XCTAssertEqual(model.label, "Nguyệt Thực")
        model.tap()
        let hard = app.buttons.matching(identifier: "phone.model.row.nhat-thuc").firstMatch
        XCTAssertTrue(hard.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Phù hợp tác vụ hàng ngày"].exists,
                      "Nguyệt Thực names what it is for")
        XCTAssertTrue(app.staticTexts["Phù hợp với tác vụ khó khăn"].exists,
                      "Nhật Thực names what it is for")
        XCTAssertTrue(app.staticTexts["Mô hình quyền năng nhất"].exists,
                      "Thái Cực carries the flagship line")
        XCTAssertTrue(app.staticTexts["Sắp có"].exists, "Thái Cực is announced, not selectable")
        let flagship = app.buttons.matching(identifier: "phone.model.row.thai-cuc").firstMatch
        XCTAssertTrue(flagship.exists)
        XCTAssertFalse(flagship.isEnabled)
        XCTAssertFalse(app.staticTexts["~20× Proton"].exists)
        hard.tap()
        XCTAssertTrue(waitFor(3) {
            probeLines("model-choice.txt").last?.text == "saved nhat-thuc 2 medium"
        }, "Model row tap did not reach the scripted save boundary\n\(boundedHierarchy(app))")
        let selected = app.buttons.matching(identifier: "phone.model.row.nhat-thuc").firstMatch
        // The probe line lands when the scripted save returns; the row re-renders a
        // beat later, and a slow CI simulator needs more than one 3 s predicate poll.
        XCTAssertTrue(waitFor(10) { selected.value as? String == "Đang dùng" }, boundedHierarchy(app))
    }

    @MainActor
    func testAssistantComposerThinkingLevelSavesTheCurrentModelWithTheChosenLevel() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
            + probeArguments
        app.launch()

        let model = app.buttons.matching(identifier: "composer.model").firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        model.tap()
        let thinking = app.segmentedControls.matching(identifier: "phone.model.thinking").firstMatch
        XCTAssertTrue(thinking.waitForExistence(timeout: 3), boundedHierarchy(app))
        // The saved level is Cân bằng (balanced); Kỹ is the thorough one.
        XCTAssertTrue(thinking.buttons["Cân bằng"].isSelected)
        thinking.buttons["Kỹ"].tap()
        XCTAssertTrue(waitFor(3) {
            probeLines("model-choice.txt").last?.text == "saved nguyet-thuc 2 high"
        }, "The thinking level did not reach the scripted save boundary\n\(boundedHierarchy(app))")
        XCTAssertTrue(thinking.buttons["Kỹ"].isSelected)
        // It is the same model: the check did not move.
        let current = app.buttons.matching(identifier: "phone.model.row.nguyet-thuc").firstMatch
        XCTAssertEqual(current.value as? String, "Đang dùng")
    }

    /// A personal group's panel (M2): name, topic and "N members"
    /// (Members is its own page), the assistant-access line, and Pin and Mute
    /// as switches that answer at once.
    @MainActor
    func testGroupInfoShowsMembersRowAndOptimisticSwitches() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatKinds.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "Chat title button did not appear")
        title.tap()

        let sheet = app.descendants(matching: .any).matching(identifier: "info.sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Info sheet did not appear")
        XCTAssertTrue(app.staticTexts["Nhóm thử"].exists)
        XCTAssertTrue(app.staticTexts["4 thành viên"].exists)
        let scroll = panelList(app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        // Give the medium sheet enough travel to expand. The drag starts
        // inside its scroll view and can end above the medium detent.
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let assistantAccess = scroll.descendants(matching: .any)
            .matching(identifier: "info.assistant-access").firstMatch
        // The list builds a row once it is scrolled to.
        XCTAssertTrue(revealByScrolling(assistantAccess, in: scroll), boundedHierarchy(app))
        XCTAssertTrue(assistantAccess.label.contains("Trợ lý của bạn có thể đọc"))
        XCTAssertTrue(assistantAccess.label.contains("tin nhắn của người khác trong nhóm"))
        XCTAssertTrue(assistantAccess.label.localizedCaseInsensitiveContains("nhà cung cấp mô hình"))
        XCTAssertTrue(assistantAccess.label.contains("ngừng đọc tin nhắn mới"))
        XCTAssertTrue(assistantAccess.label.contains("không hoàn tác"))

        for id in ["info.pin", "info.mute"] {
            let toggle = scroll.switches.matching(identifier: id).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "missing \(id)")
            let knob = toggle.switches.firstMatch
            let hasKnob = knob.exists
            let target = hasKnob ? knob : toggle
            // XCTest can report a switch at the home indicator as hittable.
            // Scroll it inside the sheet before sending the coordinate tap.
            guard revealByScrolling(target, in: scroll, up: nil, verticalInset: 44) else {
                XCTFail("\(id) did not scroll into the sheet's safe tap area: \(scroll.debugDescription.prefix(4_000))")
                return
            }
            XCTAssertTrue(waitFor(15) { target.exists && target.isHittable && toggle.value as? String == "0" },
                          "\(id) did not become tappable and off: \(boundedHierarchy(app))")
            let horizontalOffset: CGFloat = hasKnob ? 0.5 : 0.9
            target.coordinate(withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)).tap()

            XCTAssertTrue(waitFor(15) { toggle.exists && toggle.value as? String == "1" },
                          "\(id) did not turn on: \(boundedHierarchy(app))")
        }

        keepScreenshot("s2-chat-info-group-light-vi", of: app)
    }

    @MainActor
    func testAppInfoConfirmsPhoneOnlyChatDeletion() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.botMoonNotice.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        let delete = app.descendants(matching: .any).matching(identifier: "info.delete").firstMatch
        // Below the fold at medium; the list builds the row once it is scrolled to.
        XCTAssertTrue(panelList(app).waitForExistence(timeout: 3), boundedHierarchy(app))
        XCTAssertTrue(revealByScrolling(delete, in: panelList(app)), boundedHierarchy(app))
        delete.tap()

        XCTAssertTrue(app.staticTexts["Xóa cuộc trò chuyện này?"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Tin nhắn với Moon vẫn được giữ lại"
        )).firstMatch.exists)
        app.sheets.buttons["Xóa cuộc trò chuyện"].tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "info.sheet").firstMatch
            .waitForExistence(timeout: 1))
    }

    @MainActor
    func testInfoPinIsDisabledAtFiveRoomLimit() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.botMoonNotice.rawValue)
            + [AtumLaunchArguments.scriptedPinsFullFlag,
               "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()

        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        let pin = app.descendants(matching: .any).matching(identifier: "info.pin").firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        XCTAssertFalse(pin.isEnabled)
        XCTAssertTrue(app.staticTexts["Chỉ ghim tối đa 5 cuộc trò chuyện"].exists)
    }
}
