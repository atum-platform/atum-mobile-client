import AtumChat
import XCTest

/// Phone approvals slice 2b: Settings › Your devices › Approve on this iPhone,
/// over the DEBUG in-memory registry and software keys (`approvals.*` scripted
/// scenarios). Real Face ID, the passcode screen and the Secure Enclave are
/// the owner's on-device checks (docs/ports/phone-approvals-2b.md).
final class PhoneApprovalsUITests: TranscriptUITestCase {
    private static let defaultSize = "UICTContentSizeCategoryL"
    private static let ax5Size = "UICTContentSizeCategoryAccessibilityXXXL"

    /// `dark` is forced through the app's own appearance preference
    /// (`-atum.appearance`), so a preference left in the shared simulator by
    /// another run cannot keep the capture light.
    @MainActor
    private func launchApprovals(_ scenario: String, language: String = "en", dark: Bool = false,
                                 contentSize: String = PhoneApprovalsUITests.defaultSize) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [AtumLaunchArguments.noAnimationsFlag, AtumLaunchArguments.scriptedFlag, scenario,
                               "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "vi" ? "vi_VN" : "en_US",
                               "-atum.appearance", dark ? "dark" : "light",
                               "-UIPreferredContentSizeCategoryName", contentSize]
        app.launch()
        XCTAssertTrue(element(app, "account.screen").waitForExistence(timeout: 20), "no Settings")
        return app
    }

    /// The left edge's luminance (0 black … 1 white): the page ground.
    @MainActor
    private func groundLuminance(_ app: XCUIApplication) -> Double {
        guard let image = app.screenshot().image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let offset = (image.height / 2) * image.bytesPerRow + 4 * (image.bitsPerPixel / 8)
        let r = Double(bytes[offset]), g = Double(bytes[offset + 1]), b = Double(bytes[offset + 2])
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    }

    /// Opens Your devices and waits for the Approve on this iPhone row.
    @MainActor
    @discardableResult
    private func openRow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        openSettingsPage("devices", in: app, file: file, line: line)
        let row = element(app, "approvals.settings.row")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Approve on this iPhone row", file: file, line: line)
        XCTAssertTrue(scrollSettingsList(to: row, in: app), file: file, line: line)
        return row
    }

    @MainActor
    private func openPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openRow(app, file: file, line: line).tap()
        XCTAssertTrue(element(app, "approvals.settings.page").waitForExistence(timeout: 5),
                      "the page did not open", file: file, line: line)
    }

    @MainActor
    private func status(_ app: XCUIApplication) -> String { element(app, "approvals.settings.status").label }

    // MARK: Flows

    @MainActor
    func testSetUpWithFaceIDThenRemove() {
        let app = launchApprovals("approvals.off")
        let row = openRow(app)
        XCTAssertTrue(row.label.contains("Approve on this iPhone"))
        XCTAssertTrue(row.label.contains("Not set up"))
        row.tap()
        XCTAssertTrue(element(app, "approvals.settings.page").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "approvals.settings.help").label
            .contains("Answer your assistants’ requests with Face ID"))
        let setUp = element(app, "approvals.settings.setup")
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        XCTAssertEqual(setUp.label, "Set up with Face ID")
        setUp.tap()
        XCTAssertTrue(waitFor(3) { setUp.label.contains("Setting up") }, "no Setting up…")
        keepScreenshot("approvals-setting-up-en-light", of: app)
        XCTAssertTrue(waitFor(10) { self.status(app).contains("On · since") }, "not on: \(status(app))")
        XCTAssertFalse(setUp.exists, "set up stays offered once on")
        let remove = element(app, "approvals.settings.remove")
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        let confirm = element(app, "approvals.settings.confirm-remove")
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Remove approvals from this iPhone?"].exists)
        XCTAssertTrue(app.staticTexts["This iPhone will no longer be able to approve. You can still answer on your other devices."].exists)
        keepScreenshot("approvals-remove-confirm-en-light", of: app)
        confirm.tap()
        XCTAssertTrue(waitFor(5) { self.status(app).contains("Not set up") }, "still on: \(status(app))")
        XCTAssertTrue(element(app, "approvals.settings.setup").waitForExistence(timeout: 3))
        // Back on Your devices the row says so too.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(5) { self.element(app, "approvals.settings.row").label.contains("Not set up") })
    }

    @MainActor
    func testCancellingFaceIDOnlyMeansNotSetUp() {
        let app = launchApprovals("approvals.cancel")
        openPage(app)
        element(app, "approvals.settings.setup").tap()
        let failure = element(app, "approvals.settings.failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertEqual(failure.label, "Face ID was cancelled, so this iPhone wasn’t set up. Try again when you’re ready.")
        XCTAssertTrue(status(app).contains("Not set up"))
        XCTAssertTrue(element(app, "approvals.settings.setup").isEnabled, "try again stays available")
    }

    @MainActor
    func testNoPasscodeHidesSetUpAndSaysWhy() {
        let app = launchApprovals("approvals.no-passcode")
        openPage(app)
        let notice = element(app, "approvals.settings.notice.no-passcode")
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Set a passcode on this iPhone to approve here."))
        XCTAssertTrue(notice.label.contains("In Settings, open Face ID & Passcode and turn on a passcode."))
        XCTAssertFalse(element(app, "approvals.settings.setup").exists)
    }

    @MainActor
    func testPasscodeOnlyUsesThePasscodeAndNudgesFaceID() {
        let app = launchApprovals("approvals.passcode-only")
        openPage(app)
        let setUp = element(app, "approvals.settings.setup")
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        XCTAssertEqual(setUp.label, "Set up with passcode")
        XCTAssertTrue(element(app, "approvals.settings.help").label
            .contains("You can approve with your passcode, or set up Face ID in Settings."))
        setUp.tap()
        XCTAssertTrue(waitFor(10) { self.status(app).contains("On · since") })
    }

    @MainActor
    func testKeyLossAsksToSetUpAgainAndSetsUpAFreshRegistration() {
        let app = launchApprovals("approvals.key-missing")
        openPage(app)
        let notice = element(app, "approvals.settings.notice.key-missing")
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Approvals need setting up again on this iPhone."))
        let again = element(app, "approvals.settings.setup")
        XCTAssertEqual(again.label, "Set up again")
        again.tap()
        XCTAssertTrue(waitFor(10) { self.status(app).contains("On · since") })
        XCTAssertFalse(notice.exists)
    }

    @MainActor
    func testOfflineSetUpSaysSo() {
        let app = launchApprovals("approvals.offline")
        openPage(app)
        element(app, "approvals.settings.setup").tap()
        let failure = element(app, "approvals.settings.failure")
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertEqual(failure.label, "Could not reach Atum’s cloud. Check your internet connection and try again.")
        XCTAssertTrue(status(app).contains("Not set up"))
    }

    @MainActor
    func testAServerWithoutPhoneRegistryShowsNoRow() {
        let app = launchApprovals("approvals.legacy")
        openSettingsPage("devices", in: app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(element(app, "approvals.settings.row").exists, "the row must fail closed")
    }

    // MARK: Evidence

    /// The page's states in en and vi, light and dark.
    @MainActor
    func testApprovalStatesAppearances() {
        let states = ["approvals.off", "approvals.on", "approvals.cancel", "approvals.no-passcode",
                      "approvals.key-missing", "approvals.passcode-only"]
        for language in ["en", "vi"] {
            for dark in [false, true] {
                let tone = dark ? "dark" : "light"
                for state in states {
                    let app = launchApprovals(state, language: language, dark: dark)
                    if state == "approvals.off" {
                        openRow(app)
                        keepScreenshot("approvals-row-\(language)-\(tone)", of: app)
                        element(app, "approvals.settings.row").tap()
                        XCTAssertTrue(element(app, "approvals.settings.page").waitForExistence(timeout: 5))
                    } else {
                        openPage(app)
                    }
                    if state == "approvals.cancel" {
                        element(app, "approvals.settings.setup").tap()
                        XCTAssertTrue(element(app, "approvals.settings.failure").waitForExistence(timeout: 10))
                    }
                    let ground = groundLuminance(app)
                    XCTAssertEqual(ground < 0.35, dark, "\(state) \(language) rendered \(ground), wanted \(tone)")
                    let name = state.replacingOccurrences(of: "approvals.", with: "")
                    keepScreenshot("approvals-\(name)-\(language)-\(tone)", of: app)
                    app.terminate()
                    XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
                }
            }
        }
    }

    /// The fullest page (key missing) at the largest text size, and its audit.
    @MainActor
    func testApprovalsAtAccessibilitySizes() throws {
        let app = launchApprovals("approvals.key-missing", contentSize: Self.ax5Size)
        openPage(app)
        XCTAssertTrue(element(app, "approvals.settings.notice.key-missing").waitForExistence(timeout: 5))
        keepScreenshot("approvals-key-missing-en-light-ax5", of: app)
        try auditIgnoringScrollEdges(app)
    }
}
