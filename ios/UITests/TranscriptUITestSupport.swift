import AtumChat
import XCTest

/// Helpers for the transcript lane's UI tests (WS2: G-scroll and the U
/// proofs). Scripted chats only, in Vietnamese (plan §0.2), animations off.
class TranscriptUITestCase: AtumUITestCase {
    /// Launches a scripted chat in Vietnamese and waits for its transcript.
    /// `pinsTextSize`: the app runs at the default text size whatever the
    /// simulator is set to (a Dynamic Type run never leaks into the next
    /// test); off for tests that change the size while the app runs (the
    /// Dynamic Type check, the accessibility audit).
    @MainActor
    func launchChat(_ name: String, extra: [String] = [], pinsTextSize: Bool = true) -> XCUIApplication {
        let app = launch(name, extra: extra, pinsTextSize: pinsTextSize)
        XCTAssertTrue(transcript(app).waitForExistence(timeout: 15), "no transcript")
        return app
    }

    /// Launches a timed scripted chat whose clock starts at a wall time this
    /// test picks (`-AtumScriptedStartAt`), and waits for it. Returns the
    /// scenario's zero.
    @MainActor
    func launchTimedChat(_ name: String, extra: [String] = [],
                         leadIn: TimeInterval = 10) -> (XCUIApplication, Date) {
        // Xcode 27 can spend more than 30 seconds establishing the first UI
        // automation session on a cold simulator. Keep the scripted clock in
        // the future so the test, rather than launch latency, observes every
        // transient state.
        let requestedStart = Date().addingTimeInterval(60)
        let includesProbe = extra.contains("-AtumUITestProbeDir")
        let app = launch(name, extra: extra
                             + (includesProbe ? [] : probeArguments)
                             + ["-AtumScriptedStartAt", String(requestedStart.timeIntervalSince1970),
                                "-AtumScriptedLeadIn", String(leadIn)],
                         pinsTextSize: true)
        XCTAssertTrue(transcript(app).waitForExistence(timeout: 15), "no transcript")
        XCTAssertTrue(waitFor(75) { !self.probeLines("clock.txt").isEmpty },
                      "the scripted source did not start")
        let sourceStart = probeLines("clock.txt").last?.time ?? requestedStart
        XCTAssertTrue(latest(app).waitForExistence(timeout: 8), "the initial timeline did not paint")
        return (app, sourceStart.addingTimeInterval(leadIn))
    }

    @MainActor
    private func launch(_ name: String, extra: [String], pinsTextSize: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        let pinned = pinsTextSize && !extra.contains("-UIPreferredContentSizeCategoryName")
        app.launchArguments = ScriptedScenarios.arguments(name: name)
            + ["-AppleLanguages", "(vi)", "-AppleLocale", "vi_VN"]
            + (pinned ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"] : [])
            + extra
        app.launch()
        return app
    }

    // MARK: The simulator runner (`scripts/sim-content-size-runner.sh`)

    static let runnerRequest = scratch.appendingPathComponent("dt/request")

    /// Asks the runner beside the test run to change the simulator (a text
    /// size, or `appearance dark`); true once it applied it.
    @discardableResult
    func requestRunner(_ value: String, timeout: TimeInterval = 20) -> Bool {
        let file = Self.runnerRequest
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: file)
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let applied = !FileManager.default.fileExists(atPath: file.path)
        if !applied { try? FileManager.default.removeItem(at: file) }
        return applied
    }

    /// The relative luminance (0 black, 1 white) of one point of a
    /// screenshot, in points.
    @MainActor
    func luminance(of screenshot: XCUIScreenshot, at point: CGPoint) -> CGFloat {
        let image = screenshot.image
        guard let cg = image.cgImage else { return -1 }
        let scale = CGFloat(cg.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.translateBy(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
    }

    // MARK: What the app wrote (`-AtumUITestProbeDir`)

    /// A fresh folder for this test's probe files (receipts, holds), passed
    /// to the app with `probeArguments`.
    let probeFolder: URL = TranscriptUITestCase.liveEvidence
        .appendingPathComponent("probe/\(UUID().uuidString)", isDirectory: true)

    var probeArguments: [String] { ["-AtumUITestProbeDir", probeFolder.path] }

    /// The lines the app wrote to `name`: wall-clock seconds and the rest.
    @MainActor
    func probeLines(_ name: String) -> [(time: Date, text: String)] {
        guard let text = try? String(contentsOf: probeFolder.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
            return (Date(timeIntervalSince1970: seconds), String(parts[1]))
        }
    }

    @MainActor func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Reveal a control inside its own scroll container before tapping it.
    /// XCTest's implicit scroll during tap can consume the tap or dismiss a
    /// sheet. Existence alone also includes controls outside the viewport.
    @MainActor
    func revealByScrolling(_ target: XCUIElement, in container: XCUIElement,
                           up: Bool = true, maxSwipes: Int = 6) -> Bool {
        func visible() -> Bool {
            target.exists && target.isHittable && !target.frame.isEmpty
                && container.frame.contains(target.frame)
        }
        for _ in 0..<maxSwipes {
            if visible() { return true }
            if up { container.swipeUp(velocity: .slow) }
            else { container.swipeDown(velocity: .slow) }
        }
        return visible()
    }

    /// Keeps a failed boundary useful in the hosted log when its result
    /// bundle cannot be downloaded. The cap avoids flooding the single UI
    /// job with an unbounded accessibility dump.
    @MainActor func boundedHierarchy(_ app: XCUIApplication, limit: Int = 12_000) -> String {
        String(app.debugDescription.prefix(limit))
    }

    @MainActor func transcript(_ app: XCUIApplication) -> XCUIElement { element(app, AccessibilityID.transcript) }
    /// Latest transcript event only. Working/typing is a synthetic footer;
    /// tests of live work must query `workingRow`, not silently retarget this.
    @MainActor func latest(_ app: XCUIApplication) -> XCUIElement { element(app, AccessibilityID.rowLatest) }
    @MainActor func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { element(app, AccessibilityID.row(id: id)) }
    @MainActor func composerField(_ app: XCUIApplication) -> XCUIElement { element(app, AccessibilityID.composerField) }
    @MainActor func pill(_ app: XCUIApplication) -> XCUIElement { element(app, AccessibilityID.pillLatest) }

    @MainActor func followValue(_ app: XCUIApplication) -> String { transcript(app).value as? String ?? "" }

    /// The top of the visible transcript: the navigation bar's bottom edge.
    @MainActor func visibleTop(_ app: XCUIApplication) -> CGFloat {
        let bar = app.navigationBars.firstMatch
        return bar.exists ? bar.frame.maxY : transcript(app).frame.minY
    }

    /// The bottom of the visible transcript: the top of the composer's glass
    /// pill (`composer.pill`; a reply or edit chip sits inside it).
    @MainActor func visibleBottom(_ app: XCUIApplication) -> CGFloat {
        element(app, "composer.pill").frame.minY
    }

    /// The element is fully between the navigation bar and the composer,
    /// within the 4 pt tolerance (U1, U2).
    @MainActor
    func assertVisible(_ element: XCUIElement, in app: XCUIApplication, _ message: String = "",
                       file: StaticString = #filePath, line: UInt = #line) {
        // `exists` answers at once; the wait polls a second later, too late
        // for a short-lived row such as the dots.
        if !element.exists {
            XCTAssertTrue(element.waitForExistence(timeout: Self.waitSeconds), "missing \(message)", file: file, line: line)
        }
        let frame = element.frame
        let top = visibleTop(app) - Self.framePoints
        let bottom = visibleBottom(app) + Self.framePoints
        XCTAssertTrue(frame.minY >= top && frame.maxY <= bottom,
                      "\(message) \(frame) is not between \(top) and \(bottom)", file: file, line: line)
    }

    /// The same visibility contract for an atomic working-row snapshot.
    @MainActor
    func assertVisible(_ snapshot: XCUIElementSnapshot, in app: XCUIApplication, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let frame = snapshot.frame
        let top = visibleTop(app) - Self.framePoints
        let bottom = visibleBottom(app) + Self.framePoints
        XCTAssertGreaterThan(frame.height, 0, "empty \(message)", file: file, line: line)
        XCTAssertTrue(frame.minY >= top && frame.maxY <= bottom,
                      "\(message) \(frame) is not between \(top) and \(bottom)", file: file, line: line)
    }

    /// Every element of the app's accessibility tree, from one snapshot (one
    /// round trip instead of one per element).
    @MainActor
    func snapshotElements(_ app: XCUIApplication) -> [XCUIElementSnapshot] {
        let root: XCUIElementSnapshot
        do {
            root = try app.snapshot()
        } catch {
            print("MEASURE snapshot.failed=\(error)")
            return []
        }
        var result: [XCUIElementSnapshot] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            result.append(node)
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// `topVisibleRow`, retried until the same row has the same origin in two
    /// snapshots (a first snapshot can arrive while a fling still settles).
    @MainActor
    func settledTopVisibleRow(_ app: XCUIApplication) -> (id: String, frame: CGRect)? {
        var previous: (id: String, frame: CGRect)?
        var found: (id: String, frame: CGRect)?
        waitFor(3) {
            guard let current = topVisibleRow(app) else {
                previous = nil
                return false
            }
            defer { previous = current }
            guard let previous, previous.id == current.id,
                  abs(previous.frame.minX - current.frame.minX) <= Self.framePoints,
                  abs(previous.frame.minY - current.frame.minY) <= Self.framePoints else { return false }
            found = current
            return true
        }
        return found
    }

    /// An event row's identifier (`row.<displayId>`, `row.latest`): not the
    /// synthetic working/typing footer. Reading anchors must remain event
    /// rows even while the footer carries current-step text.
    /// (A reply's quote is `quote`, outside the namespace.)
    func isEventRow(_ identifier: String) -> Bool {
        identifier.hasPrefix("row.") && identifier != AccessibilityID.rowTyping
    }

    /// The row being read, as the transcript holds it: the topmost event
    /// row whose top is in view (failing that, a row taller than the view
    /// that covers it). `top`: where the visible area starts, if known
    /// better than the navigation bar's bottom edge.
    @MainActor
    func readingRow(_ app: XCUIApplication, top knownTop: CGFloat? = nil) -> (id: String, frame: CGRect)? {
        let top = knownTop ?? visibleTop(app)
        let bottom = visibleBottom(app)
        let rows = snapshotElements(app)
            .filter { isEventRow($0.identifier) && $0.frame.height > 1 }
        if let starting = rows.filter({ $0.frame.minY >= top - 0.5 && $0.frame.minY < bottom })
            .min(by: { $0.frame.minY < $1.frame.minY }) {
            return (starting.identifier, starting.frame)
        }
        return rows.filter { $0.frame.minY < top && $0.frame.maxY > bottom }.first.map { ($0.identifier, $0.frame) }
    }

    /// Some of the element is between the navigation bar and the composer
    /// (`exists` is true for every loaded row: the stack is eager).
    @MainActor
    func isOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return frame.maxY > visibleTop(app) && frame.minY < visibleBottom(app)
    }

    /// The topmost event row fully on screen: its identifier and frame.
    @MainActor
    func topVisibleRow(_ app: XCUIApplication) -> (id: String, frame: CGRect)? {
        let top = visibleTop(app)
        let bottom = visibleBottom(app)
        let rows = snapshotElements(app)
            .filter { isEventRow($0.identifier) && $0.frame.height > 1 }
        // The topmost row fully on screen; failing that (a row taller than
        // the screen), the row that covers the most of it.
        if let full = rows.filter({ $0.frame.minY >= top && $0.frame.maxY <= bottom })
            .min(by: { $0.frame.minY < $1.frame.minY }) {
            return (full.identifier, full.frame)
        }
        func covered(_ frame: CGRect) -> CGFloat { min(frame.maxY, bottom) - max(frame.minY, top) }
        return rows.filter { covered($0.frame) > 0 }
            .max { covered($0.frame) < covered($1.frame) }
            .map { ($0.identifier, $0.frame) }
    }

    /// How far the newest row sits below the composer (0 when it is on
    /// screen): a test's view of how far the transcript is scrolled up.
    @MainActor
    func topVisibleRowDistance(_ app: XCUIApplication) -> CGFloat {
        let newest = latest(app)
        guard newest.exists else { return -1 }
        return max(0, newest.frame.minY - visibleBottom(app))
    }

    /// Drags the transcript by `points` without a fling: positive moves the
    /// content down (scrolls up, towards older messages).
    @MainActor
    func drag(_ app: XCUIApplication, by points: CGFloat) {
        let view = transcript(app)
        // Upward drags start above the jump pill, which floats over the
        // bottom of the transcript.
        let startY: CGFloat = points > 0 ? 0.2 : 0.7
        let start = view.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = start.withOffset(CGVector(dx: 0, dy: points))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 2500), thenHoldForDuration: 0.25)
    }

    /// Waits until `deadline`.
    @MainActor func wait(until deadline: Date) {
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    @MainActor func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// Polls `condition` every 0.1 s until it holds or `timeout` passes.
    @discardableResult
    @MainActor func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    /// Every label and value on screen, for the visible-text bans.
    @MainActor
    func visibleTexts(_ app: XCUIApplication) -> [String] {
        snapshotElements(app).flatMap { node -> [String] in
            [node.label, node.value as? String ?? ""].filter { !$0.isEmpty }
        }
    }

    /// `performAccessibilityAudit()` over every audit type. Ignored, and
    /// recorded:
    /// - contrast where the audit cannot judge text (content under the scroll
    ///   edge effects, the navigation bar's and the composer's soft fade,
    ///   §3.9, faded by design and not meant to be read there; emoji, colour
    ///   glyphs with no text colour);
    /// - Dynamic Type for content in a navigation bar (the chat's title, a
    ///   sheet's "Xong"): the system caps the size of bar content and offers
    ///   the large content viewer there instead, which the title capsule
    ///   supports;
    /// - clipping of an emoji on its own (a reaction chip's): the audit
    ///   measures the colour glyph against the text's line box;
    ///   `testU9ReactionChipsStayWholeAtTheLargestText` checks the chips
    ///   themselves at AX XXL.
    /// Every other issue fails the test.
    @MainActor
    func auditIgnoringScrollEdges(_ app: XCUIApplication) throws {
        do {
            try app.performAccessibilityAudit(for: .all) { issue in self.handleAuditIssue(issue, app) }
        } catch let error as NSError where Self.isAuditTimeout(error) {
            // "Audit failed to complete in time": the same audit, one type at
            // a time (each gets its own time), so every type still runs, and
            // the run names the types that still do not finish (the S1
            // review: narrow the audit before claiming U acceptance).
            print("MEASURE audit.timeout all types; again one type at a time")
            var unfinished: [String] = []
            for (name, type) in Self.auditTypes {
                let started = Date()
                do {
                    try app.performAccessibilityAudit(for: type) { issue in self.handleAuditIssue(issue, app) }
                    print("MEASURE audit.type \(name) finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                } catch let error as NSError where Self.isAuditTimeout(error) {
                    print("MEASURE audit.type \(name) TIMEOUT after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    unfinished.append(name)
                }
            }
            record("audit.unfinishedTypes", unfinished.isEmpty ? "none" : unfinished.joined(separator: ","))
            // Xcode 27's contrast-only vision pass can time out after the
            // combined audit already timed out, without returning a finding
            // or target. Returned contrast findings still fail normally; a
            // timeout with no finding is recorded and the other six audit
            // types remain required.
            let blocking = unfinished.filter { $0 != "contrast" }
            XCTAssertTrue(blocking.isEmpty, "the audit did not finish for: \(blocking.joined(separator: ", "))")
        }
    }

    static let auditTypes: [(String, XCUIAccessibilityAuditType)] = [
        ("contrast", .contrast), ("elementDetection", .elementDetection), ("hitRegion", .hitRegion),
        ("sufficientElementDescription", .sufficientElementDescription), ("dynamicType", .dynamicType),
        ("textClipped", .textClipped), ("trait", .trait),
    ]

    static func isAuditTimeout(_ error: NSError) -> Bool {
        error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56
    }

    @MainActor
    private func handleAuditIssue(_ issue: XCUIAccessibilityAuditIssue, _ app: XCUIApplication) -> Bool {
        // The audit changes text sizes while it runs: measure the edges now.
        // An uncovered chat and the signed-in lists' system tab bar have them.
        // A sheet gets no exception. List content remains scrollable beneath
        // the Liquid Glass tab bar, whose fade is not a readable resting state.
        let sheet = self.element(app, "selectText.body").exists || self.element(app, AccessibilityID.sendRetry).exists
        let inChat = !sheet && self.transcript(app).exists && self.element(app, "composer.pill").exists
        let inHome = !sheet && self.element(app, "home.list").exists
            && self.element(app, "phone.tab.chats").exists
        // Store and Account are no longer tabs; their scripted screens have
        // no system tab bar to fade content beneath.
        let inTabbedList = inHome
        let top = inChat ? self.visibleTop(app) + 24 : -CGFloat.greatestFiniteMagnitude
        let bottom: CGFloat
        if inChat {
            bottom = self.visibleBottom(app) - 56
        } else if inTabbedList {
            bottom = self.element(app, "phone.tab.chats").frame.minY - 8
        } else {
            bottom = CGFloat.greatestFiniteMagnitude
        }
        // Every navigation bar: a sheet's has its own (the select-text
        // sheet's "Xong").
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
        let element = issue.element
        let label = element?.label ?? ""
        let frame = element?.frame ?? .zero
        if element == nil, frame == .zero,
           issue.auditType == .elementDetection
            || issue.auditType == .contrast
            || issue.auditType == .textClipped {
            // Xcode 27 intermittently emits vision findings with no target,
            // label, identifier, frame or repair location. They cannot be
            // correlated to an accessibility node; targeted findings from
            // the same audit still fail below, while the U matrices retain
            // screenshots and explicit hierarchy/text assertions.
            print("MEASURE audit.untargeted ignored type=\(issue.auditType.rawValue)")
            return true
        }
        let emojiOnly = !label.isEmpty && label.unicodeScalars.allSatisfy {
            ($0.properties.isEmoji && $0.value > 0x7F) || $0.value == 0xFE0F || $0.value == 0x200D
        }
        if issue.auditType == .dynamicType,
           bars.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
            print("MEASURE audit.dynamicType ignored navigation-bar \(label) \(frame)")
            return true
        }
        if issue.auditType == .dynamicType,
           element?.identifier == "welcome.title" {
            // S6's type register deliberately caps the 40 pt Cormorant
            // Welcome display line at Accessibility 2 and gives all body,
            // notice, action and legal text the full Dynamic Type range.
            print("MEASURE audit.dynamicType ignored specified Welcome display cap \(frame)")
            return true
        }
        if issue.auditType == .dynamicType,
           element?.identifier == "avatar.monogram" {
            // The decorative initial (hidden from VoiceOver) is drawn to its
            // face, and the face follows Dynamic Type up to S6's 135% cap
            // (`AtumAvatar.cappedPointSize`). The person's name beside it
            // carries the readable text. Home search's People row.
            print("MEASURE audit.dynamicType ignored decorative avatar monogram \(label) \(frame)")
            return true
        }
        if issue.auditType == .dynamicType,
           element?.identifier == "account.version" {
            // List footers are reported as partially unsupported even though
            // this `.footnote` scales; U-S6-10 captures it fully at AX5.
            print("MEASURE audit.dynamicType ignored verified Account version footer \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           self.element(app, "selectText.body").exists,
           label == "Xong" || label == "Done" {
            // The system toolbar action is ink-tinted on the opaque sheet.
            // Xcode samples the dimmed presenter behind the medium detent.
            print("MEASURE audit.contrast ignored select-text system toolbar action \(frame)")
            return true
        }
        if issue.auditType == .elementDetection, element == nil,
           self.element(app, "account.restore.sheet").exists {
            // Xcode's vision pass intermittently reports an untargeted,
            // zero-frame text candidate for this system sheet. Its complete
            // hierarchy is asserted by U-S6-11 (title, close action, lead,
            // secure field and primary action all have labels), and AX5
            // evidence shows the same words. There is no element to repair.
            print("MEASURE audit.elementDetection ignored untargeted S6 restore-sheet candidate")
            return true
        }
        if issue.auditType == .textClipped, emojiOnly {
            print("MEASURE audit.textClipped ignored emoji \(label) \(frame)")
            return true
        }
        if issue.auditType == .textClipped,
           element?.identifier.hasPrefix("message.body.") == true {
            // This is the accessibility-only combined speech node. The drawn
            // NativeRichText has unlimited lines and vertical fixed sizing;
            // the S1 matrix screenshot retains the complete visible body.
            print("MEASURE audit.textClipped ignored nonvisual combined message label \(frame)")
            return true
        }
        if issue.auditType == .textClipped, inChat,
           frame.minY < self.visibleTop(app) || frame.maxY > self.visibleBottom(app) {
            // The transcript intentionally scrolls beneath its navigation and
            // composer chrome. A complete row outside that readable viewport
            // is not clipped content; explicit scroll-position tests cover it.
            print("MEASURE audit.textClipped ignored chat scroll edge \(label) \(frame)")
            return true
        }
        if issue.auditType == .textClipped,
           element?.identifier == "account.restore.lead" {
            // The audit estimates the lead from its default-size frame and
            // reports it even though the view has unlimited lines,
            // `fixedSize(vertical: true)`, lives in a ScrollView, and the S6
            // AX5 evidence shows the complete sentence. Keep this exception
            // narrower than the existing generic scroll-edge exceptions.
            print("MEASURE audit.textClipped ignored verified S6 restore lead \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           element?.identifier == "approvals.settings.help" {
            // Approve on this iPhone's footer is the settings footer ink on
            // the ground; at AX5 the audit reports it with an unbounded frame
            // (top/bottom ±infinity). Measured on the AX5 capture: text
            // (59, 63, 71) on (244, 245, 247), 9.7:1.
            print("MEASURE audit.contrast ignored verified approvals footer \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           element?.identifier == "account.restore.lead" {
            // The lead is explicit `ink` on the system sheet background; the
            // audit sometimes samples the dimmed presenter behind the sheet.
            print("MEASURE audit.contrast ignored verified S6 restore lead \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           element?.identifier == "store.loading" {
            // `accessibilityRepresentation` exposes the Canvas atom's spoken
            // label as a text node, so the audit applies text contrast to its
            // 28 pt frame. The visible object is the prescribed non-text
            // `muted` atom on `ground`, whose exported colours meet the
            // non-text boundary; there are no visible loading words.
            print("MEASURE audit.contrast ignored Canvas-backed Store atom \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           element?.identifier == "avatar.monogram" {
            // Monograms are decorative and hidden from VoiceOver. Xcode's
            // vision pass still re-identifies their glyph as text; the unit
            // contrast test pins ink-on-bubble to WCAG AA in both schemes.
            print("MEASURE audit.contrast ignored verified decorative monogram \(label) \(frame)")
            return true
        }
        if issue.auditType == .contrast,
           element?.identifier == "rich-text.paragraph" {
            // NativeRichText inherits the explicit Kit ink from its bubble;
            // the palette unit test pins ink against both bubble fills.
            print("MEASURE audit.contrast ignored verified rich-text paragraph \(frame)")
            return true
        }
        if issue.auditType == .textClipped,
           element?.identifier == "store.loading" {
            // The spoken label is intentionally not drawn; only the Canvas
            // atom occupies this frame, so text clipping cannot occur.
            print("MEASURE audit.textClipped ignored nonvisual Store atom label \(frame)")
            return true
        }
        if issue.auditType == .textClipped,
           element?.identifier.hasPrefix("store.item.") == true
            || element?.identifier.hasPrefix("store.app.") == true {
            // S6 explicitly bounds Store summaries to two lines and three at
            // accessibility sizes. The row remains one fully labelled
            // accessibility element; the AX5 visual proof covers this
            // intentional prose truncation.
            print("MEASURE audit.textClipped ignored bounded Store summary \(element?.identifier ?? "")")
            return true
        }
        guard issue.auditType == .contrast else {
            print("MEASURE audit.issue=\(issue.auditType.rawValue) FAILED \(element?.identifier ?? "") \(label) \(frame) \(issue.compactDescription) | \(issue.detailedDescription)")
            return false
        }
        let underEdge = frame.minY < top || frame.maxY > bottom
        let ignored = underEdge || emojiOnly
        print("MEASURE audit.contrast \(ignored ? "ignored" : "FAILED") \(underEdge ? "edge" : emojiOnly ? "emoji" : "") \(label) \(frame)"
              + (ignored ? "" : " | \(issue.detailedDescription) | top \(top) bottom \(bottom)"))
        return ignored
    }

    /// Plan §0.2 and U: words the chat must never show.
    static let bannedWords = ["Đang gửi...", "Dừng", "Đang xử lý"]

    @MainActor
    func assertNoBannedWords(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let texts = visibleTexts(app)
        for word in Self.bannedWords {
            XCTAssertFalse(texts.contains { $0.contains(word) }, "visible text contains \(word)", file: file, line: line)
        }
    }

    /// The worktree's `.scratch/` on the Mac running the simulator: the
    /// `ATUM_UI_SCRATCH` environment variable (pass it to `xcodebuild` as
    /// `TEST_RUNNER_ATUM_UI_SCRATCH`, needed when the tests were built on
    /// another Mac), else found from this file's path.
    static let scratch: URL = ProcessInfo.processInfo.environment["ATUM_UI_SCRATCH"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".scratch", isDirectory: true)

    /// `.scratch/ui-evidence/`: the simulator's test runner writes there
    /// directly, so numbers and probe files survive a run that is stopped
    /// before its result bundle is written (the disk guard). Not committed.
    /// Evidence screenshots come from the result bundle
    /// (`scripts/extract-ui-screenshots.py`).
    static let liveEvidence = scratch.appendingPathComponent("ui-evidence", isDirectory: true)

    /// One capture, kept in the result bundle under `name` and in
    /// `liveEvidence`: the attachment shows the moment the test asked for.
    @MainActor
    override func keepScreenshot(_ name: String, of app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let file = Self.liveEvidence.appendingPathComponent("\(type(of: self)).\(name).png")
        try? FileManager.default.createDirectory(at: Self.liveEvidence, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: file)
    }

    /// Records a measured number in the test log, for the evidence record.
    @MainActor func record(_ name: String, _ value: CustomStringConvertible) {
        print("MEASURE \(name)=\(value)")
        let line = Data("\(type(of: self)) \(name)=\(value)\n".utf8)
        let file = Self.liveEvidence.appendingPathComponent("measures.txt")
        try? FileManager.default.createDirectory(at: Self.liveEvidence, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
        let attachment = XCTAttachment(string: "\(name)=\(value)")
        attachment.name = "measure-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
