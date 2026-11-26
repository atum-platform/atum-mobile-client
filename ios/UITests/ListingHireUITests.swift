import AtumChat
import XCTest

/// W4-E1: hire the Researcher from the New assistant sheet (desktop PR #100),
/// walked on the scripted Home in English and Vietnamese, light and dark.
/// `-AtumScriptedHire retry` fails the first hire so Retry is walked too;
/// `paid` is the third+ assistant, whose price shows once and whose Hire
/// waits for open checkout (none on the scripted host); `capacity` is a
/// hire whose chat is still being set up, so the sheet doesn't say it's there.
final class ListingHireUITests: TranscriptUITestCase {
    private struct Words {
        let title, hiring, failed, hired, price, settingUp: String
    }

    private static let words: [String: Words] = [
        "en": Words(title: "Researcher", hiring: "Hiring Researcher…",
                    failed: "Couldn't hire Researcher. Try again.",
                    hired: "Researcher is in your chats.", price: "60,000 Protons/month",
                    settingUp: "Researcher is getting ready…"),
        "vi": Words(title: "Nhà nghiên cứu", hiring: "Đang thuê Nhà nghiên cứu…",
                    failed: "Chưa thuê được Nhà nghiên cứu. Hãy thử lại.",
                    hired: "Nhà nghiên cứu đã có trong danh sách trò chuyện.", price: "60.000 Proton/tháng",
                    settingUp: "Nhà nghiên cứu đang khởi động…"),
    ]

    @MainActor
    private func launch(mode: String, language: String, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumScriptedHire", mode,
               "-AppleLanguages", "(\(language))",
               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-atum.appearance", dark ? "dark" : "light",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    @MainActor
    private func openNewAssistant(_ app: XCUIApplication) -> XCUIElement {
        let create = app.buttons.matching(identifier: "home.create").firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 40))
        create.tap()
        let newAssistant = app.buttons.matching(identifier: "home.startChat.newAssistant").firstMatch
        XCTAssertTrue(newAssistant.waitForExistence(timeout: 15))
        newAssistant.tap()
        let hire = app.buttons.matching(identifier: "home.newAssistant.listing.hire").firstMatch
        XCTAssertTrue(hire.waitForExistence(timeout: 20), "no Ready to hire shelf")
        return hire
    }

    @MainActor
    private func waitFor(_ app: XCUIApplication, _ identifier: String, label: String,
                         timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, identifier)
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(identifier) never read \(label); it reads \(target.exists ? target.label : "nothing")",
                       file: file, line: line)
    }

    /// W4-Z2 (desktop #132): without beta features Ready to hire still shows
    /// the Researcher, its button reads "Coming soon", is disabled and sends
    /// no hire; Make your own still works. Light and dark, default and AX5.
    @MainActor
    func testWithoutBetaFeaturesTheResearcherIsComingSoonAndMakeYourOwnWorks() {
        let soonWords = ["en": "Coming soon", "vi": "Sắp có"]
        for language in ["en", "vi"] {
            for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
                for dark in [false, true] {
                    if language == "vi" && size != "UICTContentSizeCategoryL" { continue }
                    let words = Self.words[language]!
                    let suffix = "\(language)-\(dark ? "dark" : "light")-\(size.hasSuffix("XXXL") ? "ax5" : "default")"
                    let app = XCUIApplication()
                    app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
                        + ["-AtumScriptedHire", "free", "-AtumScriptedBetaFeatures", "NO",
                           "-AppleLanguages", "(\(language))",
                           "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
                           "-atum.appearance", dark ? "dark" : "light",
                           "-UIPreferredContentSizeCategoryName", size] + probeArguments
                    app.launch()
                    let create = app.buttons.matching(identifier: "home.create").firstMatch
                    XCTAssertTrue(create.waitForExistence(timeout: 40))
                    create.tap()
                    let newAssistant = app.buttons.matching(identifier: "home.startChat.newAssistant").firstMatch
                    XCTAssertTrue(newAssistant.waitForExistence(timeout: 15))
                    newAssistant.tap()
                    let soon = app.buttons.matching(identifier: "home.newAssistant.listing.soon").firstMatch
                    XCTAssertTrue(soon.waitForExistence(timeout: 20), "no Coming soon on the shelf")
                    // At AX5 the sheet opens at its medium height with the shelf below the fold.
                    if size.hasSuffix("XXXL") {
                        for _ in 0..<6 where !sheetShows(soon, in: app) { dragSheetUp(app) }
                        XCTAssertTrue(sheetShows(soon, in: app), "Coming soon is clipped by the sheet")
                    }
                    XCTAssertEqual(soon.label, "\(soonWords[language]!) \(words.title)")
                    XCTAssertFalse(soon.isEnabled, "Coming soon is pressable")
                    XCTAssertTrue(element(app, "home.newAssistant.readyToHire").exists)
                    XCTAssertTrue(app.staticTexts[words.title].exists, "the listing is gone")
                    XCTAssertFalse(app.buttons.matching(identifier: "home.newAssistant.listing.hire").firstMatch.exists,
                                   "a Hire button without beta features")
                    keepScreenshot("hire-soon-\(suffix)", of: app)

                    soon.tap()
                    XCTAssertFalse(element(app, "home.newAssistant.hire.status").waitForExistence(timeout: 2),
                                   "a hire started without beta features")
                    XCTAssertFalse(probeLines("home-actions.txt").contains { $0.text.hasPrefix("hire ") },
                                   "a hire request went out without beta features")
                    // Make your own never waits for beta. At AX5 it sits below the shelf.
                    let name = element(app, "home.newAssistant.name")
                    for _ in 0..<8 where !name.exists { dragSheetUp(app) }
                    XCTAssertTrue(name.exists, "the make-your-own form is gone")
                    XCTAssertTrue(name.isEnabled, "Make your own is disabled")
                    XCTAssertTrue(element(app, "home.newAssistant.own").exists)
                    app.terminate()
                }
            }
        }
    }

    @MainActor
    func testRevokingBetaWhileResearcherConfirmationIsOpenRemovesHire() throws {
        try FileManager.default.createDirectory(at: probeFolder, withIntermediateDirectories: true)
        let revoke = probeFolder.appendingPathComponent("revoke-beta")
        let app = XCUIApplication()
        app.launchArguments = ScriptedScenarios.arguments(name: ScriptedScenario.homeRoster.rawValue)
            + ["-AtumScriptedHire", "paid", "-AtumUITestBetaRevocationFile", revoke.path,
               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"] + probeArguments
        app.launch()
        openNewAssistant(app).tap()
        let confirm = element(app, "home.newAssistant.hire.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isEnabled)

        try Data().write(to: revoke, options: .atomic)
        let soon = app.buttons.matching(identifier: "home.newAssistant.listing.soon").firstMatch
        XCTAssertTrue(soon.waitForExistence(timeout: 10))
        XCTAssertEqual(soon.label, "Coming soon")
        XCTAssertFalse(soon.isEnabled)
        XCTAssertFalse(confirm.exists)
        XCTAssertFalse(element(app, "home.newAssistant.hire.retry").exists)
        XCTAssertFalse(element(app, "topup.entry").exists)
        element(app, "home.newAssistant.hire.back").tap()
        XCTAssertTrue(element(app, "home.newAssistant.readyToHire").waitForExistence(timeout: 5))
        XCTAssertFalse(probeLines("home-actions.txt").contains { $0.text.hasPrefix("hire ") })
    }

    @MainActor
    private func sheetShows(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        let form = app.collectionViews.containing(.button, identifier: button.identifier).firstMatch
        let bar = element(app, "home.newAssistant.create")
        guard form.exists, bar.exists else { return false }
        let frame = button.frame
        return !frame.isEmpty && form.frame.intersection(app.frame).contains(frame)
            && frame.maxY <= bar.frame.minY
    }

    /// Drags the sheet's content up from its lower half (the Home list behind
    /// it is a list too, so no element query picks the sheet's own).
    @MainActor
    private func dragSheetUp(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    }

    @MainActor
    func testHireTheResearcherInEnglishAndVietnameseLightAndDark() {
        for language in ["en", "vi"] {
            for dark in [false, true] {
                walk(language: language, dark: dark)
            }
        }
    }

    @MainActor
    private func walk(language: String, dark: Bool) {
        let words = Self.words[language]!
        let prefix = "hire-\(language)-\(dark ? "dark" : "light")"

        // A free seat: one press, a lost answer, Retry, then done.
        var app = launch(mode: "retry", language: language, dark: dark)
        var hire = openNewAssistant(app)
        XCTAssertTrue(app.staticTexts[words.title].exists, "the listing's title is not \(words.title)")
        XCTAssertTrue(element(app, "home.newAssistant.readyToHire").exists)
        XCTAssertTrue(element(app, "home.newAssistant.own").exists)
        XCTAssertTrue(element(app, "home.newAssistant.name").exists, "the make-your-own form is gone")
        keepScreenshot(prefix + "-1-list", of: app)

        hire.tap()
        waitFor(app, "home.newAssistant.hire.status", label: words.hiring, timeout: 5)
        XCTAssertFalse(element(app, "home.newAssistant.hire.price").exists, "a free seat shows a price")
        keepScreenshot(prefix + "-2-hiring", of: app)

        waitFor(app, "home.newAssistant.hire.notice", label: words.failed)
        keepScreenshot(prefix + "-3-error", of: app)
        element(app, "home.newAssistant.hire.retry").tap()

        waitFor(app, "home.newAssistant.hire.status", label: words.hired)
        XCTAssertEqual(element(app, "home.newAssistant.hire.name").label.contains(words.title), true)
        keepScreenshot(prefix + "-4-done", of: app)
        element(app, "home.newAssistant.hire.done").tap()
        XCTAssertTrue(app.buttons.matching(identifier: "home.create").firstMatch.waitForExistence(timeout: 20),
                      "Done did not close the sheet")
        XCTAssertFalse(element(app, "home.newAssistant.hire.status").exists)
        app.terminate()

        // The third+ assistant: the price once, in Protons; no Hire while
        // checkout is closed; Back returns to the shelf.
        app = launch(mode: "paid", language: language, dark: dark)
        hire = openNewAssistant(app)
        hire.tap()
        waitFor(app, "home.newAssistant.hire.price", label: words.price, timeout: 15)
        XCTAssertTrue(element(app, "home.newAssistant.hire.closed").exists, "no closed-checkout line")
        XCTAssertFalse(element(app, "home.newAssistant.hire.confirm").exists, "a priced Hire with checkout closed")
        keepScreenshot(prefix + "-5-confirm", of: app)
        element(app, "home.newAssistant.hire.back").tap()
        XCTAssertTrue(app.buttons.matching(identifier: "home.newAssistant.listing.hire").firstMatch
            .waitForExistence(timeout: 15), "Back did not return to the shelf")
        app.terminate()

        // Hired, but the platform placed it as `capacity`: no "in your chats"
        // until its chat opens; Done still closes the sheet.
        app = launch(mode: "capacity", language: language, dark: dark)
        hire = openNewAssistant(app)
        hire.tap()
        waitFor(app, "home.newAssistant.hire.status", label: words.settingUp)
        XCTAssertFalse(app.staticTexts[words.hired].exists, "a hire still setting up says it is in the chats")
        keepScreenshot(prefix + "-6-setting-up", of: app)
        element(app, "home.newAssistant.hire.done").tap()
        XCTAssertTrue(app.buttons.matching(identifier: "home.create").firstMatch.waitForExistence(timeout: 20),
                      "Done did not close the sheet")
        app.terminate()
    }
}
