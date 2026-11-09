import XCTest

/// Settings is an index of nine pages in three groups (the desktop's order), and
/// a setting lives on its page: General holds language and notifications, Help
/// holds Legal, Privacy holds the recovery key, Account holds Sign out, Protons
/// holds the Store. These helpers walk the index the way a person does.
extension TranscriptUITestCase {
    /// Scrolls the current list until `target` can be tapped.
    @MainActor
    @discardableResult
    func scrollSettingsList(to target: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        // Account holds Protons and Privacy too (the desktop's pages), so at
        // AX5 its last row, Sign out, is more than eight swipes down.
        for _ in 0..<16 {
            if target.exists && target.isHittable { return true }
            list.swipeUp()
        }
        for _ in 0..<16 {
            if target.exists && target.isHittable { return true }
            list.swipeDown()
        }
        return target.exists && target.isHittable
    }

    /// The desktop's six pages hold the three folded destinations: Protons
    /// and Privacy are sections of Account, this phone is a section of
    /// Connections. Each maps to its page and a row that starts its section.
    static let foldedPages: [String: (page: String, anchor: String)] = [
        "protons": ("account", "account.settings.protons.balance"),
        "privacy": ("account", "account.settings.privacy.devices.current"),
        "devices": ("connections", "account.settings.devices.current"),
    ]

    /// Taps a page's row on the Settings index and waits for the page; a
    /// folded destination opens its page and scrolls to its section.
    /// `page` is a destination id: account, assistants, protons, general,
    /// connections, devices, privacy, help or advanced.
    @MainActor
    func openSettingsPage(_ page: String, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) {
        let folded = Self.foldedPages[page]
        let host = folded?.page ?? page
        let row = element(app, "account.settings.index." + host)
        XCTAssertTrue(scrollSettingsList(to: row, in: app),
                      "the Settings index has no \(host) row", file: file, line: line)
        row.tap()
        XCTAssertTrue(element(app, "account.settings." + host).waitForExistence(timeout: 3),
                      "the \(host) page did not open", file: file, line: line)
        if let folded {
            XCTAssertTrue(scrollSettingsList(to: element(app, folded.anchor), in: app),
                          "the \(host) page has no \(page) section", file: file, line: line)
        }
    }

    /// Back to the Settings index from a page.
    @MainActor
    func closeSettingsPage(in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 3),
                      "Back did not return to the Settings index", file: file, line: line)
    }
}
