import AtumChat
import XCTest

/// The share extension's picker on the Debug scripted host (`-AtumScriptedShare`):
/// the real view, model, queue and item loader on synthetic chats and items. The
/// real share sheet, App Group and Share Suggestions are the owner's device check.
final class SharePickerUITests: AtumUITestCase {
    private static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    private static let design = "share.chat.!design:scripted.atum"
    private static let lanAnh = "share.chat.!lan:scripted.atum"
    private static let climbers = "share.chat.!climb:scripted.atum"

    @MainActor
    private func launchShare(_ scenario: String, _ extra: [String] = english) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, "-AtumScriptedShare", scenario] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func waitUntil(_ seconds: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    @MainActor
    private func title(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Share to Atum"))
            .firstMatch.label
    }

    /// A Share Suggestion's chat arrives selected at the top of Recent; search keeps
    /// the selection; a caption and Send queue it; Done closes the sheet.
    @MainActor
    func testSuggestionSearchCaptionQueueAndDone() {
        let app = launchShare("suggested")
        let design = element(app, Self.design)
        XCTAssertTrue(design.waitForExistence(timeout: 15), "the picker did not open")
        XCTAssertTrue(design.isSelected, "the suggestion is preselected")
        XCTAssertTrue(element(app, "share.section.recent").exists)
        XCTAssertEqual(design.label, "Design team")
        let diagnostic = element(app, "share.host.diagnostic")
        XCTAssertTrue(waitUntil(15) { diagnostic.label != "pending" })
        XCTAssertEqual(diagnostic.label, "ok", "the loader rejected a scripted item")
        let send = app.buttons["share.send"]
        XCTAssertTrue(waitUntil { send.isEnabled }, "Send waits for intake, then enables")
        XCTAssertTrue(title(app).contains("1 selected"), title(app))

        // The preview strip names every kind for VoiceOver.
        for label in ["Photo", "Video", "File, Quarterly plan.pdf", "Link, atum.chat"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                .firstMatch.exists, "no preview tile labelled \(label)")
        }

        element(app, Self.lanAnh).tap()
        XCTAssertTrue(waitUntil(3) { self.element(app, Self.lanAnh).isSelected })
        XCTAssertTrue(title(app).contains("2 selected"), title(app))

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: Self.waitSeconds))
        search.tap()
        search.typeText("clim")
        let climbers = element(app, Self.climbers)
        XCTAssertTrue(climbers.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(3) { !self.element(app, Self.lanAnh).exists }, "search lists matches only")
        climbers.tap()
        XCTAssertTrue(waitUntil(3) { self.element(app, Self.climbers).isSelected })
        search.typeText("zzz")
        XCTAssertTrue(element(app, "share.searchEmpty").waitForExistence(timeout: 3))
        keepScreenshot("share-search-empty", of: app)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        XCTAssertTrue(element(app, Self.lanAnh).waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, Self.lanAnh).isSelected, "selection survives the search")
        // iOS 26 hides the bar's items behind Close while search is active.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(waitUntil(3) { app.buttons["share.send"].exists })
        XCTAssertTrue(title(app).contains("3 selected"), title(app))

        let caption = element(app, "share.caption")
        caption.tap()
        caption.typeText("For the weekend")
        send.tap()
        let queued = element(app, "share.queued")
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "no queued confirmation")
        XCTAssertEqual(queued.label, "Queued. Open Atum to send.")
        XCTAssertFalse(app.buttons["share.cancel"].exists, "no Cancel after queueing")
        keepScreenshot("share-queued-light", of: app)
        element(app, "share.done").tap()
        XCTAssertTrue(waitUntil(5) { self.element(app, "share.host.outcome").label == "finished" })
    }

    /// The Atum icon path: nothing preselected, Send stays disabled, Cancel closes.
    @MainActor
    func testPlainShareNeedsAChatAndCancelCloses() {
        let app = launchShare("plain")
        // Without a suggestion Recent is simply the newest chats; Design team is further down.
        XCTAssertTrue(element(app, Self.lanAnh).waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, Self.lanAnh).isSelected)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "selected == true"))
            .matching(NSPredicate(format: "identifier BEGINSWITH 'share.chat.'")).firstMatch.exists, "nothing preselected")
        XCTAssertTrue(element(app, "share.section.chats").exists)
        let send = app.buttons["share.send"]
        XCTAssertTrue(element(app, "share.preview").waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "no chat chosen")
        element(app, Self.lanAnh).tap()
        XCTAssertTrue(waitUntil { send.isEnabled })
        element(app, Self.lanAnh).tap()
        XCTAssertTrue(waitUntil(3) { !send.isEnabled }, "deselecting the only chat disables Send")
        app.buttons["share.cancel"].tap()
        XCTAssertTrue(waitUntil(5) { self.element(app, "share.host.outcome").label == "cancelled" })
    }

    /// Choosing chats while a slow item copies; the empty and failed states.
    @MainActor
    func testLoadingEmptyAndFailedStates() {
        var app = launchShare("loading")
        XCTAssertTrue(element(app, "share.loading").waitForExistence(timeout: 15))
        element(app, Self.lanAnh).tap()
        XCTAssertTrue(waitUntil(3) { self.element(app, Self.lanAnh).isSelected }, "chats can be chosen during intake")
        XCTAssertFalse(app.buttons["share.send"].isEnabled, "Send waits for every item")
        keepScreenshot("share-loading-light", of: app)
        app.terminate()

        app = launchShare("empty")
        XCTAssertTrue(element(app, "share.noChats").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["share.send"].isEnabled)
        keepScreenshot("share-empty-light", of: app)
        app.terminate()

        app = launchShare("failed")
        XCTAssertTrue(element(app, "share.error").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["share.cancel"].exists, "a failed intake can still be cancelled")
        XCTAssertFalse(element(app, "share.noChats").exists, "one notice, not the empty-chats one too")
        keepScreenshot("share-failed-light", of: app)
    }

    /// Light and dark at the default and an accessibility text size, plus Vietnamese.
    @MainActor
    func testCaptureAppearancesAndTextSizes() {
        let sizes = [("default", "UICTContentSizeCategoryL"), ("ax3", "UICTContentSizeCategoryAccessibilityXL"),
                     ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for scheme in ["light", "dark"] {
            for (name, size) in sizes {
                let app = launchShare("suggested", Self.english + ["-AtumScriptedShareScheme", scheme,
                                                                   "-UIPreferredContentSizeCategoryName", size])
                XCTAssertTrue(element(app, Self.design).waitForExistence(timeout: 15))
                XCTAssertTrue(waitUntil { app.buttons["share.send"].isEnabled })
                Thread.sleep(forTimeInterval: 1)
                keepScreenshot("share-picker-\(scheme)-\(name)", of: app)
                if name != "default" {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 1)
                    keepScreenshot("share-picker-\(scheme)-\(name)-scrolled", of: app)
                }
                if name == "default" && scheme == "dark" {
                    app.buttons["share.send"].tap()
                    XCTAssertTrue(element(app, "share.queued").waitForExistence(timeout: 5))
                    keepScreenshot("share-queued-dark", of: app)
                }
                app.terminate()
            }
        }
        let app = launchShare("suggested", ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"])
        XCTAssertTrue(element(app, Self.design).waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil { app.buttons["share.send"].isEnabled })
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("share-picker-light-vi", of: app)
    }
}
