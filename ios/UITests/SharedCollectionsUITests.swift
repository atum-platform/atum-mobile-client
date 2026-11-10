import AtumChat
import XCTest

/// The chat info sheet's Shared section on synthetic rows
/// (`-AtumScriptedShared <mode>`, `ScriptedSharedCollectionSource`):
/// previews, See all, the photo viewer, and the honest empty, partial,
/// failed → retry and offline states.
final class SharedCollectionsUITests: TranscriptUITestCase {
    @MainActor
    private func openInfo(_ scenario: ScriptedScenario, mode: String,
                          extra: [String] = []) -> XCUIApplication {
        let app = launchChat(scenario.rawValue, extra: ["-AtumScriptedShared", mode] + extra)
        let title = element(app, "chat.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(element(app, "info.sheet").waitForExistence(timeout: 5))
        return app
    }

    /// Scrolls the panel until `target` sits clear of the bar and the bottom
    /// edge (a tap at the very edge can miss), in either direction.
    /// `above`: the target was scrolled past, so a lazy list may have dropped
    /// it from the hierarchy; look upwards while it doesn't exist.
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication, above: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        func clear() -> Bool {
            target.exists && target.isHittable
                && target.frame.minY > window.minY + 160 && target.frame.maxY < window.maxY - 140
        }
        var last: CGRect?
        var settled = false
        for _ in 0..<(above ? 16 : 10) where !clear() {
            // The scroll hit its end with the target in view but near an edge
            // (e.g. Load more under the last row): good enough to tap.
            if target.exists, target.isHittable, target.frame == last { settled = true; break }
            last = target.exists ? target.frame : nil
            let isAbove = above
                ? !target.exists || target.frame.minY <= window.minY + 160
                : target.exists && target.frame.maxY > 0 && target.frame.minY <= window.minY + 160
            if isAbove {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(clear() || settled, "not revealed: \(target)", file: file, line: line)
    }

    /// Rows of one kind: `info.shared-file.$shared-files-<n>`, not their Share buttons.
    @MainActor
    private func count(_ app: XCUIApplication, prefix: String) -> Int {
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + "[0-9]+"
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier MATCHES %@", pattern)).count
    }

    @MainActor
    func testPersonPreviewSeeAllAndPhotoViewer() {
        let app = openInfo(.chatPeople, mode: "ready")
        let media = element(app, "info.shared-media.$shared-media-1")
        reveal(media, in: app)
        XCTAssertEqual(count(app, prefix: "info.shared-media.$shared-media-"), 6)
        keepScreenshot("shared-preview-media", of: app)

        let file = element(app, "info.shared-file.$shared-files-1")
        reveal(file, in: app)
        XCTAssertEqual(count(app, prefix: "info.shared-file.$shared-files-"), 3)
        reveal(element(app, "info.shared-link.$shared-links-3"), in: app)
        XCTAssertFalse(element(app, "info.shared-link.$shared-links-4").exists, "a preview holds three links")
        keepScreenshot("shared-preview-files-links", of: app)

        let seeAll = element(app, "info.shared-media.see-all")
        reveal(seeAll, in: app, above: true)
        seeAll.tap()
        XCTAssertTrue(element(app, "info.shared-page.media").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "info.shared-media.$shared-media-12").waitForExistence(timeout: 5))
        keepScreenshot("shared-all-media", of: app)

        let loadMore = element(app, "info.shared-media.load-more")
        reveal(loadMore, in: app)
        loadMore.tap()
        let last = element(app, "info.shared-media.$shared-media-36")
        reveal(last, in: app)
        XCTAssertFalse(element(app, "info.shared-media.load-more").exists, "the room start ends Load more")

        last.tap()
        XCTAssertTrue(element(app, AccessibilityID.mediaViewer).waitForExistence(timeout: 5))
        keepScreenshot("shared-viewer", of: app)
    }

    @MainActor
    func testGroupEmptyClaimsNothingShared() {
        let app = openInfo(.chatMedia, mode: "empty")
        let empty = element(app, "info.shared-links.empty")
        reveal(empty, in: app)
        XCTAssertTrue(element(app, "info.shared-media.empty").exists)
        XCTAssertTrue(element(app, "info.shared-files.empty").exists)
        XCTAssertFalse(element(app, "info.shared-media.see-all").exists)
        keepScreenshot("shared-empty", of: app)
    }

    @MainActor
    func testPartialOffersMoreInsteadOfEmpty() {
        let app = openInfo(.chatPeople, mode: "partial")
        let more = element(app, "info.shared-links.load-more")
        reveal(more, in: app)
        XCTAssertFalse(element(app, "info.shared-links.empty").exists, "partial is never the empty line")
        keepScreenshot("shared-partial", of: app)
        let seeAll = element(app, "info.shared-files.see-all")
        reveal(seeAll, in: app)
        seeAll.tap()
        XCTAssertTrue(element(app, "info.shared-page.files").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "info.shared-files.load-more").waitForExistence(timeout: 5))
        keepScreenshot("shared-partial-files-page", of: app)
    }

    @MainActor
    func testFailedReadRetriesIntoRows() {
        let app = openInfo(.chatPeople, mode: "failed")
        let retry = element(app, "info.shared-files.retry")
        reveal(retry, in: app)
        keepScreenshot("shared-failed", of: app)
        retry.tap()
        XCTAssertTrue(element(app, "info.shared-file.$shared-files-1").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "info.shared-files.retry").exists)
    }

    @MainActor
    func testOfflineKeepsCachedRows() {
        let app = openInfo(.chatPeople, mode: "offline")
        let offline = element(app, "info.shared-media.offline")
        reveal(offline, in: app)
        XCTAssertTrue(element(app, "info.shared-media.$shared-media-3").exists)
        XCTAssertTrue(element(app, "info.shared-links.offline").exists, "no cached links: offline, not empty")
        XCTAssertFalse(element(app, "info.shared-links.empty").exists)
        keepScreenshot("shared-offline", of: app)
    }
}
