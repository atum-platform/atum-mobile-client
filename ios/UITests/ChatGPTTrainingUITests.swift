import AtumChat
import XCTest

/// W4-E2: the ChatGPT-with-Google training-off confirmation in the composer's
/// model sheet (`-AtumScriptedSubscriptions ready -AtumScriptedTraining
/// required`, synthetic). A ChatGPT pick shows the card instead of writing;
/// Keep writes nothing; Confirm stays disabled until the box is ticked, and
/// only then does the pick land.
///
/// `ATUM_TRAINING_LOCALE` (`vi` default, or `en`) and `ATUM_CAPTURE_TAG` name
/// the run; pass them as `TEST_RUNNER_…` to `xcodebuild`. Light or dark comes
/// from the simulator's appearance, set before the run.
final class ChatGPTTrainingUITests: WS3UITestCase {
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                  "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]

    /// The exported words this card must show (`chatgpt-training-copy.ts`).
    private static let words: [String: (title: String, confirm: String, keep: String)] = [
        "en": ("ChatGPT and your Google data", "Confirm and use ChatGPT", "Keep protected model"),
        "vi": ("ChatGPT và dữ liệu Google của bạn", "Xác nhận và dùng ChatGPT", "Giữ mô hình được bảo vệ"),
    ]

    @MainActor
    func testAChatGPTPickAsksOnceAndConfirmsOnlyAfterTheTick() {
        let environment = ProcessInfo.processInfo.environment
        let locale = environment["ATUM_TRAINING_LOCALE"] == "en" ? "en" : "vi"
        let appearance = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let tag = (environment["ATUM_CAPTURE_TAG"] ?? "capture") + "-\(locale)-\(appearance)"
        let expected = Self.words[locale]!

        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatEmpty)
            + (locale == "en" ? Self.english : Self.vietnamese)
            + ["-AtumScriptedSubscriptions", "ready", "-AtumScriptedTraining", "required"]
        app.launch()
        XCTAssertTrue(element(app, AccessibilityID.transcript).waitForExistence(timeout: 15), "no transcript")

        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: Self.waitSeconds))
        chip.tap()
        XCTAssertTrue(element(app, "composer.model.close").waitForExistence(timeout: Self.waitSeconds),
                      "the model sheet did not open")

        // 1. A ChatGPT pick shows the card; nothing is written.
        let mini = revealPlanModel(app)
        mini.tap()
        let card = element(app, "chatgpt.training")
        XCTAssertTrue(card.waitForExistence(timeout: Self.waitSeconds), "the ChatGPT pick did not ask")
        XCTAssertEqual(element(app, "chatgpt.training.title").label, expected.title)
        XCTAssertTrue(element(app, "chatgpt.training.helper").exists)
        XCTAssertTrue(element(app, "chatgpt.training.transfer").exists)
        let confirm = app.buttons.matching(identifier: "chatgpt.training.confirm").firstMatch
        XCTAssertEqual(confirm.label, expected.confirm)
        XCTAssertFalse(confirm.isEnabled, "Confirm must wait for the tick")
        keepEvidence("training-card-\(tag)", of: app)

        // 2. Keep leaves the saved model as it is.
        let keep = app.buttons.matching(identifier: "chatgpt.training.keep").firstMatch
        XCTAssertEqual(keep.label, expected.keep)
        keep.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: Self.waitSeconds), "Keep did not close the card")
        let kept = revealPlanModel(app)
        XCTAssertFalse(kept.isSelected, "Keep must not write the ChatGPT pick")

        // 3. Asked again: ticking enables Confirm, and Confirm writes the pick.
        kept.tap()
        XCTAssertTrue(card.waitForExistence(timeout: Self.waitSeconds), "the second pick did not ask")
        XCTAssertFalse(confirm.isEnabled)
        element(app, "chatgpt.training.checkbox").tap()
        // The Confirm and selection accessibility queries took 1.26 s and
        // 1.39 s on #73, compared with 0.20 s and 0.23 s on main.
        XCTAssertTrue(confirm.wait(for: \.isEnabled, toEqual: true, timeout: Self.waitSeconds),
                      "Confirm must enable after the tick")
        keepEvidence("training-card-ticked-\(tag)", of: app)
        confirm.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: Self.waitSeconds), "Confirm did not close the card")
        let picked = revealPlanModel(app)
        XCTAssertTrue(picked.wait(for: \.isSelected, toEqual: true, timeout: Self.waitSeconds),
                      "Confirm must select the ChatGPT model")
        keepEvidence("training-confirmed-\(tag)", of: app)
    }

    /// The sheet opens at the medium detent and the list is lazy: scroll inside
    /// it until the ChatGPT plan's second model is on screen.
    @MainActor
    private func revealPlanModel(_ app: XCUIApplication) -> XCUIElement {
        let mini = element(app, "phone.model.row.gpt-6.1-mini")
        var scrolls = 0
        while !mini.waitForExistence(timeout: 1) || !mini.isHittable, scrolls < 6 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            scrolls += 1
        }
        XCTAssertTrue(mini.exists, "no ChatGPT plan model")
        return mini
    }
}
