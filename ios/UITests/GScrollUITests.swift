import AtumChat
import XCTest

/// Gate G-scroll (plan §2.4): checks 1–9 on the scripted `chat.long`, with
/// screenshots and measured numbers, under both pinning mechanisms; check 10
/// (memory) is read from the probe log after the fling to the top. The
/// decision record is `docs/decisions/2026-10-11-g-scroll.md`.
///
/// `chat.long`'s clock (seconds after the open, `ScriptedChats.chatLong`):
/// dots at 4 s and an answer at 6 s; three messages at 20–22 s and dots at
/// 23–30 s; my message from the Mac at 38 s, a working line at 40 s edited at
/// 43 s, the answer at 46 s; my message at 58 s, dots at 60 s and an answer
/// two screens tall at 62 s.
final class GScrollUITests: TranscriptUITestCase {
    @MainActor func testChatLongMechanismA() { runChatLong(mechanism: "a") }
    @MainActor func testChatLongMechanismB() { runChatLong(mechanism: "b") }

    @MainActor
    private func runChatLong(mechanism: String) {
        let tag = "mech-" + mechanism
        let (app, start) = launchTimedChat(ScriptedScenario.chatLong.rawValue,
                                           extra: ["-AtumTranscriptMechanism", mechanism] + probeArguments
                                               + (ProcessInfo.processInfo.environment["WS2_EXTRA"].map { [$0] } ?? []))
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        // Check 1: open lands at the bottom with no visible jump (0 s vs 1 s).
        XCTAssertTrue(latest(app).waitForExistence(timeout: 2))
        let open0 = latest(app).frame
        let open0Label = latest(app).label
        keepScreenshot("g1-open-0s-\(tag)", of: app)
        assertVisible(latest(app), in: app, "check 1 latest at 0 s")
        wait(until: at(1.2))
        let open1 = latest(app).frame
        keepScreenshot("g1-open-1s-\(tag)", of: app)
        XCTAssertEqual(latest(app).label, open0Label, "check 1: the newest row changed before 1 s")
        record("g1.latestMoved.\(tag)", abs(open1.minY - open0.minY))
        XCTAssertEqual(open1.minY, open0.minY, accuracy: Self.framePoints, "check 1: the view moved after open")
        XCTAssertEqual(followValue(app), "following")

        // Check 2: dots, then the answer fully visible; no pill. The
        // screenshot first: the frame queries take long enough for the
        // answer to land.
        wait(until: at(4.1))
        let typing = element(app, AccessibilityID.rowTyping)
        if typing.waitForExistence(timeout: 1.2) {
            record("g2.typingObserved.\(tag)", true)
            keepScreenshot("g2-dots-\(tag)", of: app)
        } else {
            XCTAssertGreaterThanOrEqual(Date(), at(6), "check 2 typing row never appeared")
            record("g2.typingWindowMissed.\(tag)", true)
        }
        wait(until: at(6.6))
        assertVisible(latest(app), in: app, "check 2 answer")
        XCTAssertFalse(pill(app).exists, "check 2: pill while following")
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("g2-answer-\(tag)", of: app)

        // Check 3: scrolled up three screens, three messages and the dots
        // arrive; the top visible row moves 4 pt or less; the pill reads 3.
        let screen = visibleBottom(app) - visibleTop(app)
        // One moderate fling, about three screens: XCUITest needs about 3.5 s
        // per slow drag, too slow for the scenario clock, and a fast fling
        // goes too far to come back by 38 s.
        for _ in 0..<2 where !followValue(app).hasPrefix("detached") {
            drag(app, by: screen * 0.9)
            wait(0.5)
        }
        record("g3.scrolledUpScreens.\(tag)", (topVisibleRowDistance(app) / screen).rounded())
        XCTAssertTrue(followValue(app).hasPrefix("detached"), "check 3: not detached after scrolling up")
        guard let anchor = topVisibleRow(app) else { return XCTFail("check 3: no visible row") }
        keepScreenshot("g3-before-\(tag)", of: app)
        let detachedBeforePhase = Date() < at(19.5)
        record("g3.detachedBeforePhase.\(tag)", detachedBeforePhase)
        if mechanism == "a" {
            XCTAssertTrue(detachedBeforePhase, "check 3: scrolling up took too long for the scenario clock")
        }
        wait(until: at(24.5))
        let moved3 = abs(row(app, String(anchor.id.dropFirst(4))).frame.minY - anchor.frame.minY)
        record("g3.topRowMoved.\(tag)", moved3)
        XCTAssertLessThanOrEqual(moved3, Self.framePoints, "check 3: the top visible row moved")
        XCTAssertTrue(pill(app).exists, "check 3: no pill")
        XCTAssertTrue(pill(app).label.contains("3"), "check 3: pill reads \(pill(app).label)")
        XCTAssertEqual(followValue(app), "detached:3")
        keepScreenshot("g3-after-\(tag)", of: app)

        // Check 9: while detached the content changed size (three messages
        // and the typing row at 20–23 s) and the view did not move (above);
        // now re-attach by scrolling down: the follow state switches back
        // and the view stays put on its own.
        record("g9.detachedSizeChangeMoved.\(tag)", moved3)
        for _ in 0..<3 where followValue(app) != "following" {
            drag(app, by: -screen * 0.9)
            wait(0.5)
        }
        XCTAssertTrue(waitFor(3) { followValue(app) == "following" }, "check 9: did not re-attach")
        wait(0.8)
        // The typing row (23–30 s) leaves below the newest row; while
        // following, that rightly moves it by the row's height. A short
        // transcript (folded long answers) can re-attach before 30 s, so the
        // view is measured once the scenario is quiet.
        if Date() < at(30.5) { wait(until: at(30.5)) }
        let reattached = latest(app).frame
        wait(1)
        let moved9b = abs(latest(app).frame.minY - reattached.minY)
        record("g9.afterReattachMoved.\(tag)", moved9b)
        XCTAssertLessThanOrEqual(moved9b, Self.framePoints, "check 9: the view moved after re-attaching")
        assertVisible(latest(app), in: app, "check 9 latest after re-attach")
        XCTAssertFalse(pill(app).exists, "check 9: pill after re-attaching")
        keepScreenshot("g9-reattached-\(tag)", of: app)
        record("g9.reattachedAtSecond.\(tag)", Int(Date().timeIntervalSince(start)))
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Đang xử lý'")
        ).firstMatch.exists, "check 9: re-attaching did not finish before the next scenario phase")

        // Check 7: a status line edited in place at the bottom stays pinned.
        wait(until: at(41))
        if let footer = assertSingleWorkingRow(app, containing: ["Đang xử lý"]) {
            assertVisible(footer, in: app, "check 7 working line")
        }
        keepScreenshot("g7-working-\(tag)", of: app)
        wait(until: at(44))
        if let footer = assertSingleWorkingRow(app, containing: ["Đang xử lý", "sắp xong"]) {
            assertVisible(footer, in: app, "check 7 edited line")
        }
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("g7-edited-\(tag)", of: app)
        wait(until: at(47.5))
        assertVisible(latest(app), in: app, "check 7 answer")
        XCTAssertFalse(workingRow(app).exists, "the working footer must disappear when the turn ends")
        XCTAssertFalse(row(app, "chat.long.step-06").exists, "progress is never its own transcript row")
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("g7-answer-\(tag)", of: app)

        // Check 8: an answer two screens tall arrives at the bottom; the view
        // stays pinned to its end; no pill.
        wait(until: at(64))
        let tall = latest(app).frame
        let bottom = visibleBottom(app)
        record("g8.tallAnswerHeight.\(tag)", tall.height)
        record("g8.endToComposer.\(tag)", bottom - tall.maxY)
        XCTAssertGreaterThan(tall.height, screen, "check 8: the answer is not taller than the screen")
        XCTAssertLessThanOrEqual(tall.maxY, bottom + Self.framePoints, "check 8: the answer's end is under the composer")
        XCTAssertGreaterThanOrEqual(tall.maxY, bottom - 48, "check 8: the view is not at the answer's end")
        XCTAssertFalse(pill(app).exists, "check 8: pill for an incoming answer while following")
        XCTAssertEqual(followValue(app), "following")
        keepScreenshot("g8-tall-answer-\(tag)", of: app)

        // Check 4: older pages load as the person scrolls up; the row being
        // read stays put. Measured in windows after slow drags near the top
        // of the loaded history, where each drag asks for a page. Pages that
        // land mid-fling are measured by the app below (check 10's flings).
        var worst: CGFloat = 0
        var windows = 0
        for _ in 0..<20 {
            drag(app, by: screen * 0.8)
            guard let reading = topVisibleRow(app) else { continue }
            wait(1.2) // a scripted page takes 0.4 s
            let now = row(app, String(reading.id.dropFirst(4)))
            guard now.exists else { continue }
            worst = max(worst, abs(now.frame.minY - reading.frame.minY))
            print("MEASURE g4.window \(windows) \(reading.id) moved \(now.frame.minY - reading.frame.minY)")
            windows += 1
            if windows == 12 { keepScreenshot("g4-paging-\(tag)", of: app) }
        }
        record("g4.windows.\(tag)", windows)
        record("g4.rowMovedMax.\(tag)", worst)
        XCTAssertLessThanOrEqual(worst, Self.framePoints, "check 4: the row being read moved when a page landed")

        // Check 10 (recorded, not a gate): fling through the rest to the start
        // of the room; the app records its memory footprint there.
        var flings = 0
        func startOnScreen() -> Bool {
            isOnScreen(row(app, "chat.long.0001"), in: app) || isOnScreen(row(app, "chat.long.0002"), in: app)
        }
        while flings < 120, !startOnScreen() {
            transcript(app).swipeDown(velocity: .fast)
            flings += 1
        }
        record("g10.flingsToStart.\(tag)", flings)
        wait(2)
        let reachedStart = startOnScreen()
        record("g10.reachedStart.\(tag)", reachedStart)
        keepScreenshot(reachedStart ? "g10-start-\(tag)" : "g10-cap-\(tag)", of: app)

        // Check 4, flinging: the flings above asked for page after page.
        // While a detached chat moves, the rows on screen do not change
        // (`TranscriptView.heldRows`); what arrived lands when the scroll
        // stops, and the row being read is held then. For every hold the
        // app wrote how the next frame landed (`HoldProbe`): exactly where it
        // was put, or (if the scroll was still moving) moved on only by the
        // fling's own motion. A hold the scroll view ignored would be off by
        // the height that landed.
        let holds = probeLines("holds.txt")
        let missed = holds.filter { !$0.text.contains("kept=1") }
        record("g4.holds.\(tag)", holds.count)
        record("g4.holdsWhileMoving.\(tag)", holds.filter { $0.text.contains("moving=1") }.count)
        for line in holds { print("MEASURE g4.hold \(line.text)") }
        XCTAssertGreaterThan(holds.count, 0, "check 4: no page landed above the row being read")
        XCTAssertTrue(missed.isEmpty, "check 4: holds that did not land: \(missed.map(\.text))")
    }
}
