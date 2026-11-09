import AtumChat
import XCTest

/// The first UI test: the app starts with the UI-test launch arguments
/// (animations off). It checks only that the app launches; nothing here can
/// observe the flag yet. The U1–U10 scenario tests join once the scripted
/// source exists (S0 part B).
final class LaunchUITests: AtumUITestCase {
    @MainActor
    func testLaunches() {
        let app = launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        keepScreenshot("launch", of: app)
    }
}

/// W4 E3, coordinator decision 11 (plan §3.8, §5.2 D "an expired session
/// leads to sign-in, not a lock screen"): the expired-session screen is a
/// sign-in screen with its notice and "Đăng nhập lại", in Vietnamese, with no
/// lock symbol and no "Thiết bị này cần khôi phục.". Shown alone
/// (`-AtumExpiredSessionPreview`): reaching it live takes a stranded custody
/// record, which the device round checks; the archive and the decisions are
/// T (`StrandedSessionArchiveTests`).
final class ExpiredSessionUITests: TranscriptUITestCase {
    @MainActor
    func testExpiredSessionIsASignInScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: nil)
            + ["-AtumExpiredSessionPreview", "-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let button = app.descendants(matching: .any)["live-sign-in"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no sign-in button")
        XCTAssertEqual(button.label, "Tiếp tục")
        XCTAssertTrue(app.staticTexts["Đăng nhập lại để tiếp tục"].exists, "no expired-session notice")
        XCTAssertTrue(app.staticTexts["Phiên đăng nhập đã hết hạn. Cuộc trò chuyện của bạn vẫn được giữ nguyên."].exists)
        let texts = visibleTexts(app)
        XCTAssertFalse(texts.contains { $0.contains("Thiết bị này cần khôi phục") }, "the old lock screen's words")
        XCTAssertFalse(texts.contains { $0 == "Thử lại" }, "a retry instead of sign-in")
        keepScreenshot("expired-session-sign-in", of: app)
        try auditIgnoringScrollEdges(app)
    }
}
