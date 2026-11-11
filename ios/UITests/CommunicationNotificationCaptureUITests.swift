import XCTest

/// Grants notification permission on a simulator so `xcrun simctl push` can
/// show communication notifications (docs/ports/communication-notifications.md).
/// `simctl privacy` has no notifications service, so the app asks (Debug
/// simulator flag) and this taps Allow. Skipped unless the runner sets
/// `ATUM_CAPTURE_NOTIFICATIONS=1` (`TEST_RUNNER_ATUM_CAPTURE_NOTIFICATIONS=1`).
final class CommunicationNotificationCaptureUITests: XCTestCase {
    @MainActor
    func testGrantNotificationPermissionForSimulatorCapture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATUM_CAPTURE_NOTIFICATIONS"] == "1",
                          "only for the communication-notification simulator capture")
        let app = XCUIApplication()
        app.launchArguments = ["-AtumRequestNotificationAuthorization"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 15) { allow.tap() }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
    }
}
