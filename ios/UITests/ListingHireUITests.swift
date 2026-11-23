import AtumChat
import XCTest

/// W4-E1: hire the Researcher from the New assistant sheet (desktop PR #100),
/// walked on the scripted Home in English and Vietnamese, light and dark.
/// `-AtumScriptedHire retry` fails the first hire so Retry is walked too;
/// `paid` is the third+ assistant, whose price shows once and whose Hire
/// waits for open checkout (none on the scripted host).
final class ListingHireUITests: TranscriptUITestCase {
    private struct Words {
        let title, hiring, failed, hired, price: String
    }

    private static let words: [String: Words] = [
        "en": Words(title: "Researcher", hiring: "Hiring Researcher…",
                    failed: "Couldn't hire Researcher. Try again.",
                    hired: "Researcher is in your chats.", price: "60,000 Protons/month"),
        "vi": Words(title: "Nhà nghiên cứu", hiring: "Đang thuê Nhà nghiên cứu…",
                    failed: "Chưa thuê được Nhà nghiên cứu. Hãy thử lại.",
                    hired: "Nhà nghiên cứu đã có trong danh sách trò chuyện.", price: "60.000 Proton/tháng"),
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
    }
}
