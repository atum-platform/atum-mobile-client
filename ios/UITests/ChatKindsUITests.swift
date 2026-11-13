import AtumChat
import XCTest

/// `chat.kinds` (B19): every placeholder, image boxes and file rows, in a
/// group with "Đã xem · 2", a quote, an edit and the read marker. And links
/// (B17, §4.2 item 6): a PayOS link shows the held-link line, an ordinary
/// link opens in the app.
final class ChatKindsUITests: TranscriptUITestCase {
    @MainActor
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
    }

    /// B13: the system context menu is a real presentation over the chat.
    /// Moon's later answer lands while it is open; no private receipt may go
    /// out until the preview disappears and the transcript is visible again.
    @MainActor
    func testContextMenuPreventsReadReceiptUntilDismissed() {
        let (app, start) = launchTimedChat(ScriptedScenario.botMoonNotice.rawValue,
                                           extra: probeArguments, leadIn: 35)
        let target = labelled(app, "mình là Moon").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "the menu target did not appear")
        target.press(forDuration: 1.2)
        let copy = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@",
                                                    "Sao chép", "answer.copy")).firstMatch
        if !copy.waitForExistence(timeout: 5) {
            // Xcode 27 occasionally drops the first synthetic long press.
            // One bounded retry distinguishes that from a missing menu.
            target.press(forDuration: 1.2)
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the context menu did not open")
        let coveredAt = Date()

        wait(until: start.addingTimeInterval(8))
        XCTAssertTrue(copy.exists, "the menu disappeared before the scripted answer arrived")
        let whileCovered = probeLines("receipts.txt").filter { $0.text.contains("receipt read") }
        XCTAssertTrue(whileCovered.allSatisfy { $0.time < coveredAt },
                      "B13: a receipt went out while the context menu covered the chat")

        let dismissStartedAt = Date()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        let dismissDeadline = Date().addingTimeInterval(3)
        while copy.exists, Date() < dismissDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(copy.exists, "the context menu did not dismiss")
        XCTAssertTrue(waitFor(5) { self.transcript(app).isHittable },
                      "the transcript did not become active after the menu closed")
        XCTAssertTrue(waitFor(12) {
            self.probeLines("receipts.txt").contains {
                $0.text.contains("receipt read") && $0.time >= dismissStartedAt
            }
        }, "B13: no receipt went out after the context menu closed")
        let afterDismiss = probeLines("receipts.txt").filter { $0.text.contains("receipt read") }
        XCTAssertTrue(afterDismiss.contains { $0.time >= dismissStartedAt },
                      "B13: no receipt went out after the context menu closed")
    }

    @MainActor
    func testEveryKindShows() {
        let app = launchChat(ScriptedScenarios.chatKinds)
        wait(1)
        keepScreenshot("kinds-bottom", of: app)
        for text in ["Tin nhắn đã bị xóa.", "Tin nhắn cũ không có trên iPhone này.", "Không mở được tin nhắn này.",
                     "Chưa hiển thị được loại tin nhắn này.", "Đã xem · 2", "đã sửa", "Tin nhắn mới"] {
            XCTAssertTrue(labelled(app, text).firstMatch.exists, "missing \(text)")
        }
        // One bubble says "unsupported" (its label also names the sender and
        // the time): the room-state events stay hidden.
        let unsupported = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS ', '", "Chưa hiển thị được loại tin nhắn này."))
        XCTAssertEqual(unsupported.count, 1, "room state must stay hidden, not show as unsupported")
        // Yesterday's rows: images and files, at the top.
        for _ in 0..<4 { transcript(app).swipeDown(velocity: .fast) }
        wait(1)
        keepScreenshot("kinds-top", of: app)
        for name in ["bao-cao-quy-3.pdf", "clip-buoi-hop.mp4", "ghi-am.m4a"] {
            XCTAssertTrue(labelled(app, name).firstMatch.exists, "missing file row \(name)")
        }
        // Image boxes: the bubbles whose label (sender, time, content) says
        // "Ảnh".
        let photos = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS ', '", "Ảnh"))
        XCTAssertGreaterThanOrEqual(photos.count, 2, "missing image boxes")
        for index in 0..<photos.count {
            let frame = photos.element(boundBy: index).frame
            record("kinds.imageBox\(index)", "\(Int(frame.width))x\(Int(frame.height))")
            XCTAssertEqual(frame.width, 240, accuracy: 1)
            XCTAssertEqual(frame.height, 180, accuracy: 1)
        }
        assertNoBannedWords(app)
    }

    /// Quote ink (owner, 13 Nov; `docs/ports/quote-contrast.md`): a quote in
    /// someone else's bubble (Lan's reply to me) and one in my own bubble (my
    /// reply to Lan) are drawn at WCAG AA (4.5:1) against their bubble, in
    /// whichever appearance the simulator is in (the local run does light,
    /// then dark). Measured from the screenshot: Xcode 27's contrast audit
    /// flags this footnote text even in the darkest exported ink, and flags
    /// plain body text and names in the same pass, so it can't judge it.
    @MainActor
    func testQuotesInBothBubblesMeetContrast() throws {
        let app = launchChat(ScriptedScenarios.chatKinds)
        let target = labelled(app, "Ok, 12 giờ.").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Lan's reply is missing")
        let reply = app.buttons.matching(NSPredicate(format: "label == %@", "Trả lời")).firstMatch
        for _ in 0..<3 where !reply.exists {
            target.press(forDuration: 1.2)
            _ = reply.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(reply.exists, "the message menu did not open")
        reply.tap()
        XCTAssertTrue(element(app, "composer.reply").waitForExistence(timeout: 5), "the reply chip shows")
        let field = element(app, AccessibilityID.composerField)
        // Focus can lag the chip: tap the field (harmless when focused) first.
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        field.typeText("Ok, mình đặt bàn.")
        element(app, AccessibilityID.composerSend).tap()
        let mine = latest(app).descendants(matching: .any)["quote"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5), "my reply shows its quote")
        // Hide the keyboard as a person does: a slow drag from above the pill
        // into the keyboard (`.scrollDismissesKeyboard(.interactively)`).
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let window = app.windows.firstMatch
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: window.frame.midX,
                                                  dy: element(app, "composer.pill").frame.minY - 10))
            let to = origin.withOffset(CGVector(dx: window.frame.midX, dy: keyboard.frame.midY + 40))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(waitFor(3) { !app.keyboards.firstMatch.exists }, "the keyboard did not hide")
        }
        wait(1)
        // The drag can scroll the transcript up: back to the newest rows.
        for _ in 0..<4 where !(mine.exists && mine.isHittable) {
            transcript(app).swipeUp(velocity: .slow)
            wait(0.5)
        }
        let theirs = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@", "quote", "hẹn 12 giờ")).firstMatch
        XCTAssertTrue(theirs.exists, "Lan's reply shows its quote")
        XCTAssertTrue(mine.isHittable && theirs.isHittable, "both quotes are on screen")
        let tag = XCUIDevice.shared.appearance == .dark ? "dark" : "light"
        let screenshot = app.screenshot()
        keepScreenshot("quote-bubbles-\(tag)", of: app)
        for (name, quote) in [("mine", mine), ("theirs", theirs)] {
            // Right of the 2 pt rule and its 8 pt gap: the name and the words.
            let frame = quote.frame
            guard frame.width > 10, frame.height > 0, frame.minY >= 0 else {
                XCTFail("\(name) quote has no visible frame: \(frame)"); continue
            }
            let text = CGRect(x: frame.minX + 10, y: frame.minY, width: frame.width - 10, height: frame.height)
            let ratio = Self.inkContrast(screenshot, in: text)
            record("quote.contrast.\(name).\(tag)", String(format: "%.2f", ratio))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) quote ink is below AA in \(tag)")
        }
    }

    /// The WCAG contrast between the region's ground (its most common
    /// colour) and its ink (the pixel furthest from that ground), from a
    /// screenshot. Glyph cores reach the drawn colour at 3x.
    @MainActor
    static func inkContrast(_ screenshot: XCUIScreenshot, in rect: CGRect) -> Double {
        guard let cg = screenshot.image.cgImage else { return 0 }
        let scale = CGFloat(cg.width) / screenshot.image.size.width
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                         width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = cg.cropping(to: box) else { return 0 }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var counts: [UInt32: Int] = [:]
        var luminance: [UInt32: Double] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let key = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
            counts[key, default: 0] += 1
            if luminance[key] == nil {
                luminance[key] = 0.2126 * linear(pixels[index]) + 0.7152 * linear(pixels[index + 1])
                    + 0.0722 * linear(pixels[index + 2])
            }
        }
        guard let ground = counts.max(by: { $0.value < $1.value })?.key, let groundL = luminance[ground] else { return 0 }
        let inkL = luminance.values.max { abs($0 - groundL) < abs($1 - groundL) } ?? groundL
        return (max(inkL, groundL) + 0.05) / (min(inkL, groundL) + 0.05)
    }

    @MainActor
    func testAccessibilityAuditKinds() throws {
        let app = launchChat(ScriptedScenarios.chatKinds, pinsTextSize: false)
        wait(1)
        try auditIgnoringScrollEdges(app)
    }

    /// Links (B17, §4.2 item 6) and B13 "nothing is read while the chat is
    /// covered": a PayOS link shows "Liên kết này chưa mở được trên iPhone."
    /// and never opens; an ordinary link opens in `SFSafariViewController`
    /// inside the app; Moon's answer arrives at 5 s while that page covers
    /// the chat, and no receipt goes out until the page is closed.
    @MainActor
    func testLinksGoThroughLinkPolicyAndNothingIsReadWhileCovered() {
        let (app, start) = launchTimedChat(ScriptedScenario.botMoonNotice.rawValue,
                                           extra: probeArguments, leadIn: 35)
        let payos = app.links.matching(NSPredicate(format: "label CONTAINS 'payos'")).firstMatch
        XCTAssertTrue(payos.waitForExistence(timeout: 15), "no PayOS link in the answer")
        payos.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "no held-link line")
        XCTAssertTrue(alert.label.contains("Liên kết này chưa mở được trên iPhone."), alert.label)
        keepScreenshot("link-held", of: app)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(waitFor(3) { !app.alerts.firstMatch.exists })
        wait(0.5)

        let page = app.links.matching(NSPredicate(format: "label CONTAINS 'atumplatform.com/moon'")).firstMatch
        XCTAssertTrue(page.exists, "no ordinary link in the answer")
        XCTAssertTrue(waitFor(3) { page.isHittable }, "the ordinary link is not tappable")
        let coveredAt = Date()
        XCTAssertLessThan(coveredAt, start.addingTimeInterval(4.5), "too late to cover the chat before the answer")
        page.tap()
        // The Safari page's own controls: its close button.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Đóng", "Close", "Xong", "Done"])).firstMatch
        guard close.waitForExistence(timeout: 20) else {
            for node in snapshotElements(app) where !node.label.isEmpty || !node.identifier.isEmpty {
                print("MEASURE link.safari.element \(node.elementType.rawValue) \(node.identifier) \(node.label)")
            }
            return XCTFail("the in-app Safari page did not show")
        }
        XCTAssertFalse(transcript(app).isHittable, "the page does not cover the chat")
        XCTAssertEqual(app.state, .runningForeground, "the link left the app")
        wait(2) // the page's content
        keepScreenshot("link-in-app", of: app)
        // The answer lands at 5 s; a receipt would follow 0.3–2 s later.
        wait(until: start.addingTimeInterval(8))
        let closedAt = Date()
        close.tap()
        XCTAssertTrue(waitFor(5) { self.transcript(app).isHittable }, "the page did not close")
        wait(3)
        let receipts = probeLines("receipts.txt").filter { $0.text.contains("receipt read") }
        for receipt in receipts {
            record("b13.receiptAtSecond", String(format: "%.2f", receipt.time.timeIntervalSince(start)))
        }
        record("b13.coveredFromTo", String(format: "%.2f-%.2f", coveredAt.timeIntervalSince(start),
                                           closedAt.timeIntervalSince(start)))
        XCTAssertTrue(receipts.allSatisfy { $0.time < coveredAt || $0.time >= closedAt },
                      "B13: a receipt went out while the chat was covered")
        XCTAssertTrue(receipts.contains { $0.time >= closedAt }, "B13: no receipt once the chat was back at the bottom")
        keepScreenshot("link-closed-answer", of: app)
    }
}
