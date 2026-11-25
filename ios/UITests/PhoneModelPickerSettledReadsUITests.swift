import AtumChat
import XCTest

/// W4-X2: the composer picker's settled read lines (desktop #126 `a55f1f3f`).
/// Synthetic scripted data only (`-AtumScriptedSubscriptions ready`,
/// `-AtumScriptedConnections work`, `-AtumScriptedPickerReads …`).
///
/// - A failed ChatGPT relay read shows its own line with Try again; the saved
///   ChatGPT row alone carries the failed words, ChatGPT gets no Work hand-off,
///   the other sources settle quietly and Claude's Work models hand off to the Mac.
/// - A failed destination readback shows its own line with Try again above
///   the models; Atum's line-up and the ChatGPT catalog stay visible but
///   read-only and unchecked.
///
/// `ATUM_PICKER_LOCALE` (`vi` default, or `en`), `ATUM_PICKER_AX=1` (an
/// accessibility text size) and `ATUM_CAPTURE_TAG` name the run; pass them as
/// `TEST_RUNNER_…` to `xcodebuild`. Light or dark comes from the simulator.
final class PhoneModelPickerSettledReadsUITests: WS3UITestCase {
    private struct Words {
        let modelsFailed: String
        let destinationFailed: String
        let retry: String
        let inWork: String
        let needsMac: String
    }

    /// The pinned words each line must show (`model-picker-copy.ts`, `connections/copy.ts`).
    private static let words: [String: Words] = [
        "en": Words(modelsFailed: "Couldn’t load this connection’s models.",
                    destinationFailed: "Couldn’t choose this model for this assistant right now.",
                    retry: "Try again", inWork: "Works in Work for now",
                    needsMac: "Open Atum on your Mac to connect."),
        "vi": Words(modelsFailed: "Chưa tải được danh sách mô hình của kết nối này.",
                    destinationFailed: "Chưa chọn được mô hình cho trợ lý này lúc này.",
                    retry: "Thử lại", inWork: "Hiện chỉ dùng trong Work",
                    needsMac: "Mở Atum trên máy Mac để kết nối."),
    ]

    private var locale: String { ProcessInfo.processInfo.environment["ATUM_PICKER_LOCALE"] == "en" ? "en" : "vi" }
    private var tag: String {
        let environment = ProcessInfo.processInfo.environment
        let appearance = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let size = environment["ATUM_PICKER_AX"] == "1" ? "-ax" : ""
        return (environment["ATUM_CAPTURE_TAG"] ?? "capture") + "-\(locale)-\(appearance)\(size)"
    }

    @MainActor
    func testAFailedChatGPTReadShowsItsLineAndTryAgainAndClaudeHandsOffToTheMac() {
        let expected = Self.words[locale]!
        let app = openPicker(reads: "chatgpt-failed")

        let line = reveal(app, "phone.model.status.chatGPT")
        // The saved GPT-6.1 row says why; the line keeps its source and Try again only.
        let saved = element(app, "phone.model.row.gpt-6.1")
        XCTAssertTrue(saved.exists, "the saved ChatGPT model must stay listed")
        XCTAssertTrue(saved.label.contains(expected.modelsFailed), saved.label)
        XCTAssertFalse(line.label.contains(expected.modelsFailed), "the failed words are repeated: \(line.label)")
        let retry = element(app, "phone.model.status.chatGPT.retry")
        XCTAssertTrue(retry.exists, "a failed ChatGPT read must offer Try again")
        XCTAssertTrue(retry.label.hasPrefix(expected.retry), retry.label)
        XCTAssertFalse(element(app, "phone.model.status.openCodeGo").exists, "OpenCode Go answered")
        XCTAssertFalse(element(app, "phone.model.status.destination").exists, "the destination answered")
        keepEvidence("chatgpt-failed-\(tag)", of: app)

        // Try again settles to the same scripted failure, never an endless loading line.
        retry.tap()
        XCTAssertTrue(element(app, "phone.model.status.chatGPT.retry").waitForExistence(timeout: Self.waitSeconds))

        // Claude reports Work models on the Mac: read-only, with the hand-off.
        let handoff = reveal(app, "phone.model.handoff.claude-plan.open")
        XCTAssertTrue(handoff.label.contains(expected.inWork), handoff.label)
        XCTAssertTrue(element(app, "phone.model.handoff.claude-plan.model.claude-sonnet-5-5").exists)
        // The ChatGPT line stands for ChatGPT: no hand-off lists its models a second time.
        XCTAssertFalse(element(app, "phone.model.handoff.openai-codex").exists, "ChatGPT hand-off beside its line")
        XCTAssertFalse(element(app, "phone.model.handoff.openai-codex.open").exists, "ChatGPT hand-off beside its line")
        keepEvidence("work-handoff-\(tag)", of: app)
        handoff.tap()
        let needsMac = element(app, "connections.sheet.needs-mac")
        XCTAssertTrue(needsMac.waitForExistence(timeout: Self.waitSeconds), "the hand-off sheet did not open")
        XCTAssertEqual(needsMac.label, expected.needsMac)
        XCTAssertFalse(element(app, "connections.sheet.done").exists, "a hand-off must not read as just connected")
        keepEvidence("work-handoff-sheet-\(tag)", of: app)
    }

    @MainActor
    func testADestinationFailureShowsItsOwnLineAndKeepsTheCatalogReadOnly() {
        let expected = Self.words[locale]!
        let app = openPicker(reads: "destination-failed")

        let line = element(app, "phone.model.status.destination")
        XCTAssertTrue(line.waitForExistence(timeout: Self.waitSeconds), "no destination line")
        XCTAssertTrue(line.label.contains(expected.destinationFailed), line.label)
        let retry = element(app, "phone.model.status.destination.retry")
        XCTAssertTrue(retry.exists, "a failed destination read must offer Try again")
        XCTAssertFalse(element(app, "phone.model.status.chatGPT").exists, "ChatGPT answered")
        // Atum's line-up is listed, greyed and with no check: neither the 1.1
        // offer nor a cached snapshot may stand in for the failed readback.
        for model in ["nguyet-thuc", "nhat-thuc"] {
            let row = element(app, "phone.model.row.\(model)")
            XCTAssertTrue(row.waitForExistence(timeout: Self.waitSeconds), "missing \(model)")
            XCTAssertFalse(row.isEnabled, "\(model) must be read-only without a destination readback")
            XCTAssertFalse(row.isSelected, "\(model) must not be checked without a destination readback")
            XCTAssertEqual(row.value as? String ?? "", "", "\(model) must not read as current")
        }
        keepEvidence("destination-failed-\(tag)", of: app)

        // The relayed catalog is listed, and no model in it can be picked.
        let mini = reveal(app, "phone.model.row.gpt-6.1-mini")
        XCTAssertFalse(mini.isEnabled, "a catalog without destination readback must be read-only")
        keepEvidence("destination-failed-catalog-\(tag)", of: app)
    }

    // MARK: Helpers

    @MainActor
    private func openPicker(reads: String) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let vietnamese = ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
        let size = environment["ATUM_PICKER_AX"] == "1" ? "UICTContentSizeCategoryAccessibilityXL"
                                                        : "UICTContentSizeCategoryL"
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatEmpty)
            + (locale == "en" ? english : vietnamese)
            + ["-UIPreferredContentSizeCategoryName", size]
            + ["-AtumScriptedSubscriptions", "ready", "-AtumScriptedConnections", "work",
               "-AtumScriptedPickerReads", reads]
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        chip.tap()
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: Self.waitSeconds),
                      "the model sheet did not open")
        return app
    }

    /// The sheet opens at the medium detent and the list is lazy: scroll inside
    /// it until `identifier` is on screen.
    @MainActor
    private func reveal(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        var scrolls = 0
        while !target.waitForExistence(timeout: 1) || !target.isHittable, scrolls < 10 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
            scrolls += 1
        }
        XCTAssertTrue(target.exists, "missing \(identifier)")
        return target
    }
}
