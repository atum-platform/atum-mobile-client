import AtumChat
import XCTest

/// Wave 3, Assistants stream: new assistant (AS-3), delete (AS-4), bot handle
/// (AS-5) and routines polish (AS-6), on scripted Home and chat scenarios in
/// Vietnamese. Text size comes from the launch argument, so nothing here
/// changes the simulator while the app runs.
final class AssistantsWave3UITests: TranscriptUITestCase {
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    @MainActor
    private func launchHome(size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", size]
        app.launch()
        return app
    }

    @MainActor
    private func openNewAssistant(_ app: XCUIApplication) {
        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let newAssistant = app.buttons.matching(identifier: "home.startChat.newAssistant").firstMatch
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 3))
        newAssistant.tap()
        XCTAssertTrue(element(app, "home.newAssistant.name").waitForExistence(timeout: 3))
    }

    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        for _ in 0..<attempts where !(target.exists && target.isHittable) { app.swipeUp() }
    }

    // MARK: AS-3

    @MainActor
    func testNewAssistantHasDesktopsFieldsAndTheHandleFollowsTheName() {
        let app = launchHome()
        openNewAssistant(app)
        let name = element(app, "home.newAssistant.name")
        name.tap()
        name.typeText("Tiếp thị")
        let handle = app.textFields.matching(identifier: "home.newAssistant.handle").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 2))
        XCTAssertEqual(handle.value as? String, "tiep_thi")
        let status = element(app, "home.newAssistant.handle.status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["@tiep_thi_bot còn trống."].waitForExistence(timeout: 3)
                      || (status.label.contains("tiep_thi_bot")), "no available line: \(status.label)")
        for id in ["home.newAssistant.photo", "home.newAssistant.who", "home.newAssistant.job"] {
            let field = element(app, id)
            scrollTo(field, in: app)
            XCTAssertTrue(field.exists, "missing \(id)")
        }
        keepScreenshot("as3-new-assistant", of: app)
        assertPrimaryLabelIsReadable(app.buttons.matching(identifier: "home.newAssistant.create").firstMatch, in: app)
    }

    /// A solid ink button must draw its words in a contrasting colour: the
    /// brightest point across its middle is far from the fill at its edge.
    @MainActor
    private func assertPrimaryLabelIsReadable(_ button: XCUIElement, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.exists, file: file, line: line)
        let shot = app.screenshot()
        let frame = button.frame
        let fill = luminance(of: shot, at: CGPoint(x: frame.minX + 24, y: frame.midY))
        var brightest: CGFloat = 0
        var x = frame.midX - 60
        while x <= frame.midX + 60 {
            for offset: CGFloat in [-4, -2, 0, 2, 4] {
                brightest = max(brightest, luminance(of: shot, at: CGPoint(x: x, y: frame.midY + offset)))
            }
            x += 1
        }
        XCTAssertGreaterThan(brightest - fill, 0.5, "button words are not readable on their fill",
                             file: file, line: line)
    }

    /// Dark appearance comes from the runner beside the test run.
    @MainActor
    func testNewAssistantReadsInDark() {
        XCTAssertTrue(requestRunner("appearance dark"), "no content-size runner beside the run")
        defer { requestRunner("appearance light") }
        let app = launchHome()
        openNewAssistant(app)
        let name = element(app, "home.newAssistant.name")
        name.tap()
        name.typeText("Lan")
        keepScreenshot("as3-new-assistant-dark", of: app)
        assertPrimaryLabelIsReadable(app.buttons.matching(identifier: "home.newAssistant.create").firstMatch, in: app)
    }

    @MainActor
    func testATakenHandleOffersTheSameWithANumber() {
        let app = launchHome()
        openNewAssistant(app)
        let name = element(app, "home.newAssistant.name")
        name.tap()
        name.typeText("Taken")
        let tryButton = app.buttons.matching(identifier: "home.newAssistant.handle.try").firstMatch
        XCTAssertTrue(tryButton.waitForExistence(timeout: 4), "no numbered suggestion for a taken handle")
        XCTAssertTrue(tryButton.label.hasPrefix("Dùng @taken"))
        keepScreenshot("as3-handle-taken", of: app)
    }

    @MainActor
    func testADuplicateNameIsRefusedBeforeAnythingIsCreated() {
        let app = launchHome()
        openNewAssistant(app)
        let name = element(app, "home.newAssistant.name")
        name.tap()
        name.typeText("alfred")
        let create = app.buttons.matching(identifier: "home.newAssistant.create").firstMatch
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let problem = element(app, "home.newAssistant.name.problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 2))
        XCTAssertTrue(problem.label.contains("alfred"), problem.label)
        // Nothing reached the create action.
        XCTAssertFalse(app.staticTexts["Đang hoàn tất thiết lập…"].exists)
    }

    @MainActor
    func testNewAssistantFitsAtTheLargestTextSize() {
        let app = launchHome(size: Self.ax5)
        openNewAssistant(app)
        let name = element(app, "home.newAssistant.name")
        name.tap()
        name.typeText("Lan")
        app.swipeUp()
        keepScreenshot("as3-new-assistant-ax5", of: app)
        let create = app.buttons.matching(identifier: "home.newAssistant.create").firstMatch
        XCTAssertTrue(create.exists && create.isHittable, "Create is not reachable at AX5")
    }

    // MARK: AS-4 and AS-5 (the card of a non-primary assistant)

    @MainActor
    private func openOtherAssistantCard(extra: [String] = [],
                                        size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", size,
               "-AtumScriptedOtherAssistant"] + probeArguments + extra
        app.launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(app.textFields.matching(identifier: "assistant.card.name").firstMatch
            .waitForExistence(timeout: 3))
        return app
    }

    @MainActor
    func testDeletingAnAssistantAsksWithDesktopsWordsThenLeaves() {
        let app = openOtherAssistantCard()
        let delete = app.buttons.matching(identifier: "assistant.card.retire").firstMatch
        scrollTo(delete, in: app)
        XCTAssertTrue(delete.exists, "no Delete row on a non-primary card")
        XCTAssertTrue(delete.label.hasPrefix("Xóa "), delete.label)
        keepScreenshot("as4-card-delete-row", of: app)
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(alert.label.contains("vĩnh viễn"), alert.label)
        keepScreenshot("as4-delete-confirm", of: app)
        alert.buttons.matching(identifier: "assistant.card.retire.confirm").firstMatch.tap()
        XCTAssertTrue(waitFor(5) { self.probeLines("assistant-retire.txt").contains { $0.text == "retired" } })
        XCTAssertTrue(waitFor(5) { !self.element(app, "chat.title").exists }, "the chat stayed open")
    }

    @MainActor
    func testAFailedDeleteChangesNothingAndSaysSo() {
        let app = openOtherAssistantCard(extra: ["-AtumScriptedRetireFails"])
        let delete = app.buttons.matching(identifier: "assistant.card.retire").firstMatch
        scrollTo(delete, in: app)
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        alert.buttons.matching(identifier: "assistant.card.retire.confirm").firstMatch.tap()
        let failed = element(app, "assistant.card.retire.failed")
        XCTAssertTrue(failed.waitForExistence(timeout: 4))
        XCTAssertEqual(failed.label, "Chưa xóa được trợ lý. Hãy thử lại.")
        XCTAssertTrue(app.textFields.matching(identifier: "assistant.card.name").firstMatch.exists)
    }

    @MainActor
    func testThePrimaryCardHasNoDeleteRow() {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(app.textFields.matching(identifier: "assistant.card.name").firstMatch
            .waitForExistence(timeout: 3))
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertFalse(app.buttons.matching(identifier: "assistant.card.retire").firstMatch.exists)
    }

    @MainActor
    func testChoosingABotHandleChecksConfirmsAndClaims() {
        let app = openOtherAssistantCard()
        let edit = app.buttons.matching(identifier: "assistant.card.handle.edit").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        let field = app.textFields.matching(identifier: "assistant.card.handle.field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText("lan")
        let save = app.buttons.matching(identifier: "assistant.card.handle.save").firstMatch
        XCTAssertTrue(waitFor(4) { save.isEnabled }, "Save never enabled after the check")
        keepScreenshot("as5-handle-editor", of: app)
        save.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 2))
        XCTAssertTrue(alert.label.contains("lan_bot") || alert.staticTexts.allElementsBoundByIndex
            .contains { $0.label.contains("lan_bot") })
        alert.buttons.matching(identifier: "assistant.card.handle.confirm").firstMatch.tap()
        XCTAssertTrue(element(app, "assistant.card.handle").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "assistant.card.handle").label, "@lan_bot")
        XCTAssertTrue(probeLines("assistant-handle.txt").contains { $0.text == "claim lan_bot" })
    }

    @MainActor
    func testTheCardWithDeleteFitsAtTheLargestTextSize() {
        let app = openOtherAssistantCard(size: Self.ax5)
        let delete = app.buttons.matching(identifier: "assistant.card.retire").firstMatch
        scrollTo(delete, in: app, attempts: 14)
        XCTAssertTrue(delete.exists && delete.isHittable, "Delete is not reachable at AX5")
        keepScreenshot("as4-card-ax5", of: app)
    }

    // MARK: AS-6

    @MainActor
    private func openRoutines(size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.chatEmpty.rawValue)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", size]
        app.launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        let routines = app.buttons.matching(identifier: "assistant.card.routines").firstMatch
        scrollTo(routines, in: app, attempts: 10)
        XCTAssertTrue(routines.waitForExistence(timeout: 3))
        routines.tap()
        XCTAssertTrue(app.staticTexts["Morning brief"].waitForExistence(timeout: 3))
        return app
    }

    @MainActor
    func testRoutineRowsSayTheScheduleAndPauseFromASwipe() {
        let app = openRoutines()
        // The scripted routine runs daily at 8:30 in the device's own zone
        // family, so the row says the sentence and no raw zone ID.
        XCTAssertTrue(app.staticTexts["Hằng ngày lúc 8:30"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Asia/Ho_Chi_Minh"].exists)
        keepScreenshot("as6-routine-rows", of: app)
        app.staticTexts["Morning brief"].swipeLeft()
        let pause = app.buttons["Tạm dừng"]
        XCTAssertTrue(pause.waitForExistence(timeout: 2), "no swipe Pause")
        pause.tap()
        XCTAssertTrue(app.staticTexts["Đã tạm dừng"].waitForExistence(timeout: 3)
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'dừng'")).count > 0)
    }

    @MainActor
    func testTheRoutineEditorCarriesDesktopsSubtitleAndHint() {
        let app = openRoutines()
        app.buttons.matching(identifier: "assistant.routines.add").firstMatch.tap()
        XCTAssertTrue(element(app, "assistant.routine.subtitle").waitForExistence(timeout: 3))
        let title = app.textFields.matching(identifier: "assistant.routine.title").firstMatch
        XCTAssertEqual(title.placeholderValue, "Để trống, lấy từ câu đầu tiên")
        let instruction = app.textFields.matching(identifier: "assistant.routine.instruction").firstMatch
        instruction.tap()
        instruction.typeText("Tóm tắt lịch hôm nay. Rồi gửi cho tôi.")
        // An empty name takes the instruction's first words, so Save is ready.
        XCTAssertTrue(app.buttons.matching(identifier: "assistant.routine.save").firstMatch.isEnabled)
        keepScreenshot("as6-routine-editor", of: app)
    }

    @MainActor
    func testRoutinesFitAtTheLargestTextSize() {
        let app = openRoutines(size: Self.ax5)
        keepScreenshot("as6-routine-rows-ax5", of: app)
        app.staticTexts["Morning brief"].tap()
        XCTAssertTrue(element(app, "assistant.routine.subtitle").waitForExistence(timeout: 3))
        keepScreenshot("as6-routine-editor-ax5", of: app)
    }
}
