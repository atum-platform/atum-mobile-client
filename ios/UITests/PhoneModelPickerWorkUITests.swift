import AtumChat
import XCTest

/// W4-Y2: the assistant's Work (Mac plan) model on the phone, as desktop #143
/// shows it. Synthetic scripted data only (`-AtumScriptedSubscriptions ready`,
/// `-AtumScriptedConnections work`, `-AtumScriptedWork claude:claude-opus-5-5`).
///
/// - The composer chip and the card's Model row name the saved Work model
///   ("Claude Opus 5.5"), never Atum's line-up name.
/// - The picker lists the plan's Work models as real picks: the saved one is
///   checked and Current, and no cloud row is Current while it answers.
/// - Opening the chip, the card or the picker writes nothing. A Work pick
///   writes only the Work selection; a cloud row is written only when the
///   owner taps it, and that is what clears the Work choice.
///
/// `ATUM_PICKER_AX=1` runs at an accessibility text size; `ATUM_CAPTURE_TAG`
/// names the captures. Light or dark comes from the simulator.
final class PhoneModelPickerWorkUITests: TranscriptUITestCase {
    private let opus = "phone.model.work.claude-plan.model.claude-opus-5-5"
    private let sonnet = "phone.model.work.claude-plan.model.claude-sonnet-5-5"

    private var tag: String {
        let environment = ProcessInfo.processInfo.environment
        let appearance = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let size = environment["ATUM_PICKER_AX"] == "1" ? "-ax" : ""
        return (environment["ATUM_CAPTURE_TAG"] ?? "w4y2") + "-\(appearance)\(size)"
    }

    @MainActor
    func testChipAndPickerNameTheWorkModelAndAPickWritesOnlyWork() {
        let app = launch()
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(10) { chip.label.hasPrefix("Claude Opus 5.5") }, "chip: \(chip.label)")
        XCTAssertFalse(chip.label.contains("Nguyệt Thực"), chip.label)
        keepScreenshot("chip-\(tag)", of: app)

        chip.tap()
        let saved = reveal(app, opus)
        XCTAssertTrue(saved.isSelected, "the saved Work model must be checked")
        XCTAssertEqual(saved.value as? String, "Đang dùng")
        XCTAssertTrue(element(app, "phone.model.work.claude-plan").exists, "the plan's Work section")
        let atum = element(app, "phone.model.row.nguyet-thuc")
        if atum.exists {
            XCTAssertFalse(atum.isSelected, "no cloud row is Current while a Work model answers")
            XCTAssertEqual(atum.value as? String ?? "", "")
        }
        XCTAssertTrue(writes().isEmpty, "opening the chip and picker wrote: \(writes())")
        keepScreenshot("picker-work-\(tag)", of: app)

        reveal(app, sonnet).tap()
        XCTAssertTrue(waitFor(10) { self.writes().last == "work claude claude-sonnet-5-5 5" },
                      "the Work pick did not reach the scripted write: \(writes())")
        XCTAssertFalse(writes().contains { $0.hasPrefix("saved ") }, "a Work pick wrote a cloud choice")
        XCTAssertTrue(waitFor(10) { self.element(app, self.sonnet).isSelected })
        keepScreenshot("picker-work-picked-\(tag)", of: app)

        element(app, "composer.model.close").tap()
        XCTAssertTrue(waitFor(10) { chip.label.hasPrefix("Claude Sonnet 5.5") }, "chip: \(chip.label)")
        keepScreenshot("chip-picked-\(tag)", of: app)
    }

    @MainActor
    func testAnExplicitCloudPickIsTheOnlyWriteThatClearsWork() {
        let app = launch()
        let chip = element(app, AccessibilityID.composerModel)
        XCTAssertTrue(chip.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(10) { chip.label.hasPrefix("Claude Opus 5.5") }, "chip: \(chip.label)")
        chip.tap()
        let hard = reveal(app, "phone.model.row.nhat-thuc")
        XCTAssertTrue(writes().isEmpty, "opening the picker wrote: \(writes())")
        hard.tap()
        XCTAssertTrue(waitFor(10) { self.writes().contains { $0.hasPrefix("saved nhat-thuc") } },
                      "the owner's cloud pick was not written: \(writes())")
        XCTAssertTrue(waitFor(10) { self.writes().contains { $0.hasPrefix("work cleared") } })
        // The eligibility reread can briefly remove these lazy rows.
        let cleared = reveal(app, opus)
        XCTAssertTrue(waitFor(10) { cleared.exists && !cleared.isSelected },
                      "the cleared Work model still reads as Current")
        element(app, "composer.model.close").tap()
        XCTAssertTrue(waitFor(10) { !chip.label.hasPrefix("Claude Opus 5.5") }, "chip: \(chip.label)")
    }

    @MainActor
    func testCardModelRowNamesTheWorkModelWithoutWriting() {
        let app = launch()
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15)); title.tap()
        let model = app.buttons.matching(identifier: "assistant.card.model").firstMatch
        if !model.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(10) { model.label.contains("Claude Opus 5.5") }, "card: \(model.label)")
        XCTAssertFalse(model.label.contains("Nguyệt Thực"), model.label)
        keepScreenshot("card-\(tag)", of: app)
        model.tap()
        let saved = reveal(app, opus)
        XCTAssertTrue(saved.isSelected)
        XCTAssertTrue(writes().isEmpty, "opening the card and its picker wrote: \(writes())")
        keepScreenshot("card-picker-\(tag)", of: app)
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let size = ProcessInfo.processInfo.environment["ATUM_PICKER_AX"] == "1"
            ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .chatEmpty)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN", "-UIPreferredContentSizeCategoryName", size]
            + ["-AtumScriptedSubscriptions", "ready", "-AtumScriptedConnections", "work",
               "-AtumScriptedWork", "claude:claude-opus-5-5"]
            + probeArguments
        app.launch()
        return app
    }

    /// Every write the scripted host saw, cloud ("saved …") and Work ("work …").
    @MainActor
    private func writes() -> [String] { probeLines("model-choice.txt").map(\.text) }

    /// The sheet opens at the medium detent and the list is lazy: scroll until
    /// `identifier` is on screen and clear of the search bar at the foot.
    @MainActor
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        let barTop = app.frame.maxY * 0.86
        var scrolls = 0
        while !target.waitForExistence(timeout: 1) || !target.isHittable || target.frame.maxY > barTop,
              scrolls < 12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
            scrolls += 1
        }
        XCTAssertTrue(target.exists, "missing \(identifier)")
        return target
    }
}
