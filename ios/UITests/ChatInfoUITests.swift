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
        if !model.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.tap()
        let hard = app.buttons.matching(identifier: "phone.model.row.nhat-thuc").firstMatch
        XCTAssertTrue(hard.waitForExistence(timeout: 3))
        hard.tap()
        // The current row is marked by a check, spoken as the row's value.
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Đang dùng"), object: hard
        )], timeout: 3) == .completed)
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
        if !model.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 3)); model.tap()

        let current = app.buttons.matching(identifier: "phone.model.row.nguyet-thuc").firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 3))
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
        if !model.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 3)); model.tap()

        XCTAssertTrue(app.buttons.matching(identifier: "phone.model.row.nguyet-thuc").firstMatch
            .waitForExistence(timeout: 3))
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
        XCTAssertTrue(hard.waitForExistence(timeout: 3))
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

    @MainActor
    func testGroupInfoShowsMembersAndOptimisticTiles() {
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
        XCTAssertTrue(app.staticTexts["Thành viên"].exists)
        XCTAssertTrue(app.staticTexts["Bạn"].exists)
        let assistantAccess = app.descendants(matching: .any)
            .matching(identifier: "info.assistant-access").firstMatch
        XCTAssertTrue(assistantAccess.exists)
        XCTAssertTrue(assistantAccess.label.contains("Trợ lý của bạn có thể đọc"))
        XCTAssertTrue(assistantAccess.label.contains("tin nhắn của người khác trong nhóm"))
        XCTAssertTrue(assistantAccess.label.localizedCaseInsensitiveContains("nhà cung cấp mô hình"))
        XCTAssertTrue(assistantAccess.label.contains("ngừng đọc tin nhắn mới"))
        XCTAssertTrue(assistantAccess.label.contains("không hoàn tác"))

        let pin = app.descendants(matching: .any).matching(identifier: "info.pin").firstMatch
        let mute = app.descendants(matching: .any).matching(identifier: "info.mute").firstMatch
        XCTAssertTrue(pin.exists)
        XCTAssertTrue(mute.exists)
        pin.tap()
        XCTAssertTrue(app.buttons["Bỏ ghim"].waitForExistence(timeout: 2))
        mute.tap()
        XCTAssertTrue(app.buttons["Bật thông báo"].waitForExistence(timeout: 2))

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
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
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
