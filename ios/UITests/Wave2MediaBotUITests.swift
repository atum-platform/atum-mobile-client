import AtumChat
import XCTest

final class Wave2MediaBotUITests: TranscriptUITestCase {
    @MainActor
    func testMediaViewerAndShareLoadFromStableImageRow() {
        let app = launchWave2(.chatMedia)
        let image = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaImage(id: "chat.media.0005")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15), "captioned media row did not appear")
        image.tap()
        let viewer = app.descendants(matching: .any).matching(identifier: AccessibilityID.mediaViewer).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 3), "media viewer did not open")
        let share = app.descendants(matching: .any).matching(identifier: AccessibilityID.mediaShare).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 3), "share action did not appear")
        XCTAssertTrue(poll(seconds: 3) { share.isEnabled }, "full-size scripted media never enabled share")
        keepScreenshot("s4-media-viewer-light-vi", of: app)
        app.buttons["Đóng"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 2), "viewer did not return to the same row")
    }

    @MainActor
    func testAttachmentTrayRemovesAndSendsInOrder() {
        let app = launchWave2(.chatMediaSend)
        let tray = app.descendants(matching: .any).matching(identifier: AccessibilityID.mediaTray).firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 15), "scripted attachment tray did not appear")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaAttachment(id: "scripted-photo-1")).firstMatch.exists)
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaRemove(id: "scripted-photo-1")).firstMatch.tap()
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaAttachment(id: "scripted-photo-1")).firstMatch.exists)
        app.descendants(matching: .any).matching(identifier: AccessibilityID.composerSend).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaImage(id: "chat.media-send.send-1"))
            .firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaFile(id: "chat.media-send.send-3"))
            .firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(tray.exists)
        keepScreenshot("s4-media-send-light-vi", of: app)
        assertNoWave2BannedWords(app)
    }

    @MainActor
    func testAuthenticatedMoonNoticeOpensContinueSheet() {
        let app = launchWave2(.botMoonNotice)
        let action = app.buttons["Bắt đầu"]
        XCTAssertTrue(action.waitForExistence(timeout: 15), "authenticated notice action did not appear")
        action.tap()
        let sheet = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotContinueSheet).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "continue-on-computer sheet did not open")
        XCTAssertTrue(app.staticTexts["Tiếp tục trên Atum cho máy tính"].exists)
        XCTAssertTrue(app.buttons["Đã hiểu"].exists)
        keepScreenshot("s5-continue-on-mac-light-vi", of: app)
        assertNoWave2BannedWords(app)
    }

    @MainActor
    func testSpoofedNoticesHaveNoActionAndEmptyBotUsesHero() {
        let spoofed = launchWave2(.botMoonNoticeSpoofed)
        XCTAssertTrue(spoofed.descendants(matching: .any)
            .matching(identifier: AccessibilityID.transcript).firstMatch.waitForExistence(timeout: 15))
        for label in ["Bắt đầu", "Điền thông tin", "Mở Moon"] {
            XCTAssertFalse(spoofed.buttons[label].exists, "spoofed metadata exposed \(label)")
        }
        spoofed.terminate()

        let empty = launchWave2(.botMoonEmpty)
        XCTAssertTrue(empty.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotHero).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(empty.staticTexts["Hôm nay ta làm gì?"].exists)
        keepScreenshot("s5-moon-empty-light-vi", of: empty)
        assertNoWave2BannedWords(empty)
    }

    @MainActor
    func testThumbnailFailureRetriesAndRefusalsUseWordsOnly() {
        let app = launchWave2(.chatMedia)
        let retrying = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaImage(id: "chat.media.0006")).firstMatch
        XCTAssertTrue(retrying.waitForExistence(timeout: 15))
        XCTAssertTrue(poll(seconds: 3) { retrying.label.contains("Chưa tải được") })
        retrying.tap()
        XCTAssertTrue(poll(seconds: 3) { !retrying.label.contains("Chưa tải được") })
        app.terminate()

        for (value, text) in [
            ("tooMany", "Mỗi lần gửi được tối đa 10 ảnh hoặc tệp."),
            ("tooLargeFile", "Tệp này lớn quá để gửi. Bạn chọn tệp nhỏ hơn nhé."),
            ("tooLargeSome", "2 tệp lớn quá nên chưa được thêm."),
            ("unreadable", "Chưa mở được tệp này. Bạn thử tệp khác nhé."),
        ] {
            let refusal = launchWave2(.chatMediaRefusal,
                                      extra: [AtumLaunchArguments.scriptedMediaRefusalFlag, value])
            XCTAssertTrue(refusal.staticTexts[text].waitForExistence(timeout: 15), value)
            assertNoWave2BannedWords(refusal)
            refusal.terminate()
        }
    }

    @MainActor
    func testLeavingChatCancelsAFileDownload() {
        let app = launchWave2(.chatMediaFiles,
                              extra: [AtumLaunchArguments.scriptedSlowFileDownloadFlag])
        let file = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaFile(id: "chat.media-files.0001")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertFalse(app.staticTexts["bao-cao.pdf"].waitForExistence(timeout: 3),
                       "Quick Look appeared after the chat was left")
    }

    @MainActor
    func testEditedNoticeKeepsItsRowAndChangesAction() {
        let startAt = Date().addingTimeInterval(60)
        let app = launchWave2(.botMoonNoticeEdited,
                              extra: ["-AtumScriptedStartAt", String(startAt.timeIntervalSince1970)])
        wait(until: startAt.addingTimeInterval(0.5))
        let start = app.buttons["Bắt đầu"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let originalFrame = start.frame
        wait(until: startAt.addingTimeInterval(8.5))
        let fillIn = app.buttons["Điền thông tin"]
        XCTAssertTrue(fillIn.waitForExistence(timeout: 5))
        let editedFrame = fillIn.frame
        XCTAssertEqual(originalFrame.minY, editedFrame.minY, accuracy: Self.framePoints)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "đã sửa")).firstMatch.exists)
        assertNoWave2BannedWords(app)
    }

    @MainActor
    func testBotJoinPaintsProgressThenTranscriptAndFailureRetries() {
        let joinedAt = Date().addingTimeInterval(60)
        let joined = launchWave2(.botMoonRoomJoin,
                                 extra: ["-AtumScriptedStartAt", String(joinedAt.timeIntervalSince1970)])
        XCTAssertTrue(joined.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotHero).firstMatch.waitForExistence(timeout: 15))
        wait(until: joinedAt.addingTimeInterval(3.5))
        XCTAssertTrue(joined.staticTexts["Moon đã sẵn sàng trò chuyện."].waitForExistence(timeout: 15))
        joined.terminate()

        let failedAt = Date().addingTimeInterval(60)
        let failed = launchWave2(.botMoonRoomJoinFails,
                                 extra: ["-AtumScriptedStartAt", String(failedAt.timeIntervalSince1970)])
        wait(until: failedAt.addingTimeInterval(3.5))
        XCTAssertTrue(failed.staticTexts["Chưa mở được cuộc trò chuyện với Moon."].waitForExistence(timeout: 15))
        XCTAssertTrue(failed.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotRoomRetry).firstMatch.exists)
        keepScreenshot("s5-moon-room-join-failed-light-vi", of: failed)
    }

    @MainActor
    func testUnsafeAndMissingAppAccentsUseTheMonochromeAction() {
        let unsafe = launchWave2(.botAccentFallback)
        XCTAssertTrue(unsafe.buttons["Bắt đầu"].waitForExistence(timeout: 15))
        keepScreenshot("s5-accent-unsafe-fallback-light-vi", of: unsafe)
        unsafe.terminate()

        let missing = launchWave2(.botAccentFallback,
                                  extra: [AtumLaunchArguments.scriptedMissingAccentFlag])
        XCTAssertTrue(missing.buttons["Bắt đầu"].waitForExistence(timeout: 15))
        keepScreenshot("s5-accent-missing-fallback-light-vi", of: missing)
    }

    @MainActor
    func testWave2AccessibilitySmoke() throws {
        let media = launchWave2(.chatMediaSend)
        XCTAssertTrue(media.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaTray).firstMatch.waitForExistence(timeout: 15))
        try auditIgnoringScrollEdges(media)
        media.terminate()

        let bot = launchWave2(.botMoonEmpty)
        XCTAssertTrue(bot.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotHero).firstMatch.waitForExistence(timeout: 15))
        try auditIgnoringScrollEdges(bot)
    }

    @MainActor
    func testWave2DarkLargestTypeEvidence() {
        XCTAssertTrue(requestRunner("appearance dark"), "no simulator appearance runner")
        defer { requestRunner("appearance light") }
        let display = ["-UIPreferredContentSizeCategoryName",
                       "UICTContentSizeCategoryAccessibilityXXL"]
        let media = launchWave2(.chatMediaSend, extra: display)
        XCTAssertTrue(media.descendants(matching: .any)
            .matching(identifier: AccessibilityID.mediaTray).firstMatch.waitForExistence(timeout: 15))
        XCTAssertLessThan(luminance(of: media.screenshot(), at: CGPoint(x: 12, y: 360)), 0.35,
                          "the media proof did not launch in dark mode")
        keepScreenshot("s4-media-tray-dark-axxxl-vi", of: media)
        media.terminate()

        let bot = launchWave2(.botMoonEmpty, extra: display)
        XCTAssertTrue(bot.descendants(matching: .any)
            .matching(identifier: AccessibilityID.appBotHero).firstMatch.waitForExistence(timeout: 15))
        XCTAssertLessThan(luminance(of: bot.screenshot(), at: CGPoint(x: 12, y: 360)), 0.35,
                          "the app-bot proof did not launch in dark mode")
        keepScreenshot("s5-moon-empty-dark-axxxl-vi", of: bot)
    }

    @MainActor
    private func poll(seconds: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    @MainActor
    private func launchWave2(_ scenario: ScriptedScenario, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let pinsTextSize = !extra.contains("-UIPreferredContentSizeCategoryName")
        app.launchArguments = AtumLaunchArguments.arguments(scenario: scenario)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
            + (pinsTextSize
               ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"] : [])
            + extra
        app.launch()
        return app
    }

    @MainActor
    private func assertNoWave2BannedWords(_ app: XCUIApplication,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let text = visibleTexts(app).joined(separator: " ").lowercased()
        for word in ["matrix", "hermes", "bot", "mb", "kb", "mua", "thanh toán"] {
            XCTAssertFalse(text.contains(word), "visible text contains \(word)", file: file, line: line)
        }
        XCTAssertFalse(text.contains("_"), "visible text contains a raw code", file: file, line: line)
    }
}
