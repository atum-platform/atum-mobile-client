import AtumChat
import XCTest

/// G-scroll check 6: a Dynamic Type change to AX XXL keeps the position, at
/// the bottom and scrolled up. The size changes on the running simulator
/// (`xcrun simctl ui <device> content_size`), which a test cannot do: the
/// test asks `scripts/sim-content-size-runner.sh` through a request file in
/// the worktree's `.scratch/dt/`, and skips when no runner answers. The
/// runner deletes the request once applied. Check 5 (the keyboard) is
/// `TranscriptUITests.testU7KeyboardKeepsTheLastRowVisible`.
final class GScrollDynamicTypeUITests: TranscriptUITestCase {
    private func request(_ size: String) {
        let file = Self.runnerRequest
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(size.utf8).write(to: file)
    }

    /// The simulator goes back to the default size, so no later test starts
    /// at AX XXL.
    override func tearDown() {
        requestRunner("large")
        super.tearDown()
    }

    @MainActor
    func testDynamicTypeChangeKeepsThePosition() throws {
        let app = launchChat(ScriptedScenario.chatKeyboard.rawValue, extra: probeArguments, pinsTextSize: false)
        wait(1)
        let before = latest(app).frame
        request("accessibility-extra-extra-large")
        guard waitFor(25, { abs(self.latest(app).frame.height - before.height) > 4 }) else {
            throw XCTSkip("no runner changed the content size (.scratch/dt)")
        }
        wait(1.5)
        assertVisible(latest(app), in: app, "check 6 latest at AX XXL")
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("g6-axxxl-bottom", of: app)

        let screen = visibleBottom(app) - visibleTop(app)
        for _ in 0..<8 where topVisibleRowDistance(app) < screen * 2 {
            drag(app, by: screen * 0.8)
            wait(0.5)
        }
        // A single very tall row can still cover the entire viewport. Move
        // past it so the anchor's top is actually visible; otherwise a large
        // shrink can only clamp at the bottom, making the requested top
        // geometrically impossible.
        for _ in 0..<8 {
            guard let candidate = readingRow(app) else { break }
            if candidate.frame.minY >= visibleTop(app) - 0.5 { break }
            drag(app, by: screen * 0.8)
            wait(0.5)
        }
        keepScreenshot("g6-axxxl-detached", of: app)
        XCTAssertTrue(followValue(app).hasPrefix("detached"), "check 6: not detached after scrolling up (\(followValue(app)))")
        XCTAssertGreaterThanOrEqual(topVisibleRowDistance(app), screen * 2,
                                   "check 6: not far enough from the bottom to hold a shrinking row")
        XCTAssertGreaterThanOrEqual(readingRow(app)?.frame.minY ?? -.infinity, visibleTop(app) - 0.5,
                                    "check 6: the anchor row still starts above the viewport")
        // Scrolled up, back to the default size and up to AX XXL again: the
        // row being read keeps its top where it was each time (§2.10: 4 pt).
        try holdsTheRowBeingRead(app, changingTo: "large", name: "g6-default-detached", measure: "g6.shrinkMoved")
        try holdsTheRowBeingRead(app, changingTo: "accessibility-extra-extra-large", name: "g6-axxxl-detached-again",
                                 measure: "g6.growMoved")
        XCTAssertTrue(followValue(app).hasPrefix("detached"))
    }

    @MainActor
    private func holdsTheRowBeingRead(_ app: XCUIApplication, changingTo size: String, name: String,
                                      measure: String) throws {
        // The row being read as the transcript picks it: the topmost row
        // whose top is in the transcript's visible area, which starts at the
        // scroll view's top inset (`geometry.txt`), a few points below the
        // navigation bar's frame. A row whose top sits in between is above
        // the visible area for the transcript, and the row below it is held.
        let insetTop = probeLines("geometry.txt").last { $0.text.hasPrefix("insetTop=") }
            .flatMap { Double($0.text.replacingOccurrences(of: "insetTop=", with: "")) }
        let top = insetTop.map { transcript(app).frame.minY + CGFloat($0) }
        record("g6.visibleTop", "\(visibleTop(app)) bar, \(top.map { "\($0)" } ?? "-") inset")
        let beforeFrames = snapshotElements(app).reduce(into: [String: CGRect]()) { frames, node in
            guard isEventRow(node.identifier), node.frame.maxY > visibleTop(app),
                  node.frame.minY < visibleBottom(app) else { return }
            frames[node.identifier] = node.frame
        }
        var reading: (id: String, frame: CGRect)?
        if let held = probeLines("geometry.txt").last(where: { $0.text.hasPrefix("held row=") })?.text
            .replacingOccurrences(of: "held row=", with: "") {
            let heldRow = row(app, held)
            if heldRow.exists, isOnScreen(heldRow, in: app) {
                reading = ("row." + held, heldRow.frame)
            }
        }
        if reading == nil {
            waitFor(2) {
                reading = readingRow(app, top: top)
                return reading != nil
            }
        }
        guard let anchor = reading else {
            print("MEASURE g6.edges=\(visibleTop(app)) \(visibleBottom(app))")
            for node in snapshotElements(app) where node.identifier.hasPrefix("row.") {
                print("MEASURE g6.row \(node.identifier) \(node.frame)")
            }
            return XCTFail("check 6: no row being read")
        }
        let anchorRow = row(app, String(anchor.id.dropFirst(4)))
        request(size)
        XCTAssertTrue(waitFor(25) { abs(anchorRow.frame.height - anchor.frame.height) > 4 }, "the size did not change to \(size)")
        wait(1.5)
        // The row the transcript held during this change (`geometry.txt`).
        let held = probeLines("geometry.txt").last { $0.text.hasPrefix("held row=") }?.text
            .replacingOccurrences(of: "held row=", with: "")
        let measuredID = held.map { "row." + $0 }
        let measuredBefore = measuredID.flatMap { beforeFrames[$0] } ?? anchor.frame
        let measuredRow = held.map { row(app, $0) } ?? anchorRow
        let frame = measuredRow.frame
        record(measure + ".rows", "test \(anchor.id), held \(measuredID ?? "-")")
        keepScreenshot(name, of: app)
        record(measure, frame.minY - measuredBefore.minY)
        XCTAssertEqual(frame.minY, measuredBefore.minY, accuracy: Self.framePoints,
                       "check 6: the held row moved going to \(size) (\(measuredBefore) → \(frame))")
    }
}
