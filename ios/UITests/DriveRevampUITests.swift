import AtumChat
import XCTest

/// Drive's Finder revamp in iPhone form (docs/ports/drive-revamp.md) on the
/// real `DriveScreen` over the Debug scripted reader (`ScriptedDriveHost`,
/// `-AtumScriptedDrive`): the view switch, sort, Group By and their memory,
/// folder search with its scope line, the swipeable preview and Share.
final class DriveRevampUITests: AtumUITestCase {
    private struct Words {
        let list, icons, group, none, kind, size, driveName, search: String
    }

    private static let words: [String: Words] = [
        "en": Words(list: "List", icons: "Icons", group: "Group", none: "None", kind: "Kind", size: "Size",
                    driveName: "Atum Drive", search: "Search Drive"),
        "vi": Words(list: "Danh sách", icons: "Biểu tượng", group: "Nhóm", none: "Không nhóm",
                    kind: "Loại", size: "Kích thước", driveName: "Atum Drive", search: "Tìm trong Drive"),
    ]

    @MainActor
    private func launchDrive(language: String = "en", dark: Bool = false,
                             keep: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: .homeRoster)
            + ["-AtumDebugDrive", "-AtumScriptedDrive",
               "-AppleLanguages", "(\(language))",
               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
               "-atum.appearance", dark ? "dark" : "light"]
            + (keep ? ["-AtumScriptedDriveKeep"] : [])
        app.launch()
        // The "…" appears once the listing has items, whatever view was remembered.
        XCTAssertTrue(element(app, "drive.viewOptions").waitForExistence(timeout: 15), "Drive did not list")
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A grid cell or list row by the file's name (rows add size and date).
    @MainActor private func item(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@",
                                         name, name + ",")).firstMatch
    }

    @MainActor private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@",
                                         label, label + ",")).firstMatch
    }

    @MainActor private func openViewOptions(_ app: XCUIApplication) {
        let options = app.buttons["drive.viewOptions"].firstMatch
        XCTAssertTrue(options.wait(for: \.isHittable, toEqual: true, timeout: 15), "no tappable view options")
        options.tap()
    }

    @MainActor private func choose(_ app: XCUIApplication, _ label: String) {
        openViewOptions(app)
        let button = menuItem(app, label)
        XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 15), "no tappable menu item \(label)")
        button.tap()
    }

    @MainActor private func chooseGroup(_ app: XCUIApplication, _ label: String, words: Words) {
        openViewOptions(app)
        // iOS 27 exposes the submenu as a button with its localized title.
        let group = menuItem(app, words.group)
        XCTAssertTrue(group.wait(for: \.isHittable, toEqual: true, timeout: 15), "no tappable Group menu")
        let submenuItem = menuItem(app, words.none)
        group.tap()
        if !submenuItem.wait(for: \.isHittable, toEqual: true, timeout: 8),
           group.exists, group.isHittable {
            // The parent menu is still open. A slow menu can miss this tap.
            group.tap()
        }
        // None is unique to the submenu. Size also exists in the parent menu.
        XCTAssertTrue(submenuItem.wait(for: \.isHittable, toEqual: true, timeout: 15),
                      "Group menu did not open")
        let button = menuItem(app, label)
        XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 15), "no tappable group choice \(label)")
        button.tap()
    }

    @MainActor private func above(_ first: XCUIElement, _ second: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(first.waitForExistence(timeout: 3), "missing \(first)", file: file, line: line)
        XCTAssertTrue(second.waitForExistence(timeout: 3), "missing \(second)", file: file, line: line)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, file: file, line: line)
    }

    // MARK: Behaviour

    /// Icons by default; List, Size and Kind from the "…" menu; the view and
    /// Group By (and the folder sort) are still there after a relaunch.
    @MainActor
    func testViewSortAndGroupAreChosenAndRemembered() {
        var app = launchDrive()
        XCTAssertTrue(element(app, "drive.grid").exists, "Icons is the default view")
        let words = Self.words["en"]!
        element(app, "drive.destination").buttons[words.driveName].tap()
        choose(app, words.list)
        XCTAssertTrue(element(app, "drive.list").waitForExistence(timeout: 3))
        above(item(app, "Archive 2024.zip"), item(app, "Budget 2026.xlsx"))
        choose(app, words.size)
        above(item(app, "Team offsite.mov"), item(app, "Archive 2024.zip"))
        chooseGroup(app, words.kind, words: words)
        let folderGroup = element(app, "drive.group.kind:folder")
        XCTAssertTrue(folderGroup.waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "drive.group.kind:archive").exists)
        keepScreenshot("drive-behaviour-list-kind", of: app)

        app.terminate()
        app = launchDrive(keep: true)
        let restoredFolderGroup = element(app, "drive.group.kind:folder")
        XCTAssertTrue(element(app, "drive.list").waitForExistence(timeout: 15), "List was remembered")
        XCTAssertTrue(restoredFolderGroup.waitForExistence(timeout: 15), "Group By was remembered")
        chooseGroup(app, words.none, words: words)
        XCTAssertTrue(restoredFolderGroup.waitForNonExistence(timeout: 15), "None did not remove the Kind group")
        element(app, "drive.destination").buttons[words.driveName].tap()
        above(item(app, "Team offsite.mov"), item(app, "Archive 2024.zip"))
    }

    /// Search filters the folder's listing and says what it searched.
    @MainActor
    func testSearchFiltersTheFolderAndShowsItsScope() {
        let app = launchDrive()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("report")
        let scope = element(app, "drive.search.scope")
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        XCTAssertTrue(scope.label.contains("Atum Drive"), scope.label)
        XCTAssertTrue(item(app, "Report 2.pdf").exists)
        XCTAssertTrue(item(app, "Report 10.pdf").exists)
        XCTAssertTrue(item(app, "Q3 board report.pdf").exists)
        XCTAssertFalse(item(app, "Budget 2026.xlsx").exists)
        field.typeText("zzz")
        XCTAssertTrue(element(app, "drive.search.empty").waitForExistence(timeout: 3))
    }

    /// A picture opens the preview over the folder's pictures and PDFs; a
    /// swipe moves to the next, the strip jumps, and Share offers the sheet.
    @MainActor
    func testGallerySwipesThroughTheFolderAndShares() {
        let app = launchDrive()
        item(app, "Photos").tap()
        let sunrise = item(app, "Sunrise.jpg")
        XCTAssertTrue(sunrise.waitForExistence(timeout: 5))
        sunrise.tap()
        let caption = element(app, "drive.gallery.caption")
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "the preview did not open")
        XCTAssertTrue(caption.label.contains("Sunrise.jpg"), caption.label)
        XCTAssertTrue(element(app, "drive.gallery.image").waitForExistence(timeout: 10))
        turnPage(app, until: element(app, "drive.gallery.pdf"))
        XCTAssertTrue(waitFor(caption, toContain: "Ticket.pdf"), caption.label)
        XCTAssertTrue(element(app, "drive.gallery.pdf").waitForExistence(timeout: 10))
        // The strip: back to the first picture.
        let strip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "drive.gallery.strip."))
        XCTAssertEqual(strip.count, 5)
        strip.element(boundBy: 0).tap()
        XCTAssertTrue(waitFor(caption, toContain: "Hội An lanterns.png"), caption.label)

        let share = element(app, "drive.gallery.share")
        XCTAssertTrue(waitForEnabled(share))
        share.tap()
        XCTAssertTrue(shareSheetAppears(app), "no share sheet")
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("drive-behaviour-gallery-share", of: app)
    }

    /// Share from a row's menu downloads the file and offers the share sheet.
    @MainActor
    func testRowMenuShares() {
        let app = launchDrive()
        let words = Self.words["en"]!
        choose(app, words.list)
        let row = item(app, "Budget 2026.xlsx")
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.press(forDuration: 1.2)
        let share = menuItem(app, "Share")
        XCTAssertTrue(share.waitForExistence(timeout: 8), "the row menu did not open")
        share.tap()
        XCTAssertTrue(shareSheetAppears(app), "no share sheet")
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("drive-behaviour-row-share", of: app)
    }

    /// The system share sheet, however this iOS names its parts.
    @MainActor private func shareSheetAppears(_ app: XCUIApplication) -> Bool {
        let candidates = [
            app.otherElements["ActivityListView"],
            app.otherElements["UIActivityContentView"],
            app.navigationBars["UIActivityContentView"],
            app.cells["Copy"], app.buttons["Copy"],
            app.cells["Save to Files"], app.buttons["Save to Files"],
        ]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Drag most of the page's width to the left. XCUITest's `swipeLeft` is
    /// short, and on a loaded host it moves slowly, so the pager can settle
    /// back on the same page; past halfway it settles on the next one at any
    /// speed, as a person's drag does.
    @MainActor private func dragToNextPage(_ app: XCUIApplication) {
        let pages = element(app, "drive.gallery.pages")
        pages.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: pages.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)))
    }

    /// Turn to the next page, allowing one retry (see DRIVE-SWIPE-MISS).
    @MainActor private func turnPage(_ app: XCUIApplication, until target: XCUIElement,
                                     file: StaticString = #filePath, line: UInt = #line) {
        dragToNextPage(app)
        if !target.waitForExistence(timeout: 5) {
            print("DRIVE-SWIPE-MISS gallery-test")
            dragToNextPage(app)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the page did not turn", file: file, line: line)
    }

    @MainActor private func waitFor(_ element: XCUIElement, toContain text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    // MARK: Screenshots

    /// en/vi × light/dark: Icons (Recents), the view menu, List grouped by
    /// Kind, search, and the preview. Extracted to
    /// /Volumes/AtumTestFlight/drive-revamp-shots by the capture script.
    @MainActor
    func testCaptureDriveSurfaces() {
        for language in ["en", "vi"] {
            for dark in [false, true] {
                capture(language: language, dark: dark)
            }
        }
    }

    @MainActor private func capture(language: String, dark: Bool) {
        let words = Self.words[language]!
        let prefix = "drive-\(language)-\(dark ? "dark" : "light")"
        let app = launchDrive(language: language, dark: dark)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot(prefix + "-1-icons-recents", of: app)

        element(app, "drive.viewOptions").tap()
        XCTAssertTrue(menuItem(app, words.list).waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(prefix + "-2-view-menu", of: app)
        menuItem(app, words.list).tap()

        element(app, "drive.destination").buttons[words.driveName].tap()
        chooseGroup(app, words.kind, words: words)
        // Kind groups sort by their names, so which comes first depends on the language.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "drive.group.kind:"))
            .firstMatch.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(prefix + "-3-list-group-kind", of: app)

        choose(app, words.icons)
        chooseGroup(app, words.size, words: words)
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(prefix + "-4-icons-group-size", of: app)

        let field = app.searchFields.firstMatch
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        var focused = false
        // A loaded simulator can drop the tap before the field takes focus.
        for _ in 0..<3 where !focused {
            field.tap()
            let expectation = XCTNSPredicateExpectation(predicate: focusPredicate, object: field)
            focused = XCTWaiter().wait(for: [expectation], timeout: 8) == .completed
        }
        XCTAssertTrue(focused, "Drive search did not take keyboard focus")
        field.typeText("report")
        XCTAssertTrue(element(app, "drive.search.scope").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(prefix + "-5-search", of: app)
        // iOS 26 ends search with a close (X) beside the field.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@",
                                                     ["Close", "Đóng", "Cancel", "Hủy"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 2), "no search close")
        close.tap()

        chooseGroup(app, words.none, words: words)
        item(app, "Photos").tap()
        let photo = item(app, "Sunrise.jpg")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        keepScreenshot(prefix + "-6-folder-icons", of: app)
        photo.tap()
        XCTAssertTrue(element(app, "drive.gallery.image").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot(prefix + "-7-gallery-image", of: app)
        // Swipe once; a miss is logged (DRIVE-SWIPE-MISS, an open item in
        // docs/ports/drive-revamp.md) and the strip moves instead, so the capture
        // completes. The swipe itself is asserted in the gallery test.
        dragToNextPage(app)
        if !element(app, "drive.gallery.pdf").waitForExistence(timeout: 5) {
            print("DRIVE-SWIPE-MISS \(prefix)")
            app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "Ticket-pdf")).firstMatch.tap()
        }
        XCTAssertTrue(element(app, "drive.gallery.pdf").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot(prefix + "-8-gallery-pdf", of: app)
        app.terminate()
    }
}
