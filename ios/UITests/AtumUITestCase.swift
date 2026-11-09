import AtumChat
import XCTest

/// Base for the revamp's XCUITests (plan §2.10). They run on the iOS
/// Simulator against scripted scenarios (S0 part B adds the data); there is no
/// device test runner profile (coordinator default C3). Agents never sign in
/// to a live account here.
///
/// Stability rules: animations off through `-AtumUITestNoAnimations`, frame
/// checks within 4 pt, waits of 2 s, the keyboard checked as
/// `app.keyboards.firstMatch.exists`, and focus by typing more text.
class AtumUITestCase: XCTestCase {
    /// §2.10: frame checks allow 4 pt.
    static let framePoints: CGFloat = 4
    /// §2.10: `waitForExistence(timeout: 2)`.
    static let waitSeconds: TimeInterval = 2

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches the app with animations off and, when given, a scenario.
    @MainActor
    func launch(_ scenario: ScriptedScenario? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = AtumLaunchArguments.arguments(scenario: scenario)
        app.launch()
        return app
    }

    /// The element exists within the wait and its frame lies inside the
    /// container's, within the 4 pt tolerance (U1, U2).
    @MainActor
    func assertFullyInside(_ element: XCUIElement, _ container: XCUIElement,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.waitSeconds), "missing \(element)", file: file, line: line)
        let inner = element.frame
        let outer = container.frame.insetBy(dx: -Self.framePoints, dy: -Self.framePoints)
        XCTAssertTrue(outer.contains(inner), "\(inner) is not inside \(container.frame)", file: file, line: line)
    }

    /// Keeps a screenshot in the result bundle; the extraction step copies it
    /// into .
    @MainActor
    func keepScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
