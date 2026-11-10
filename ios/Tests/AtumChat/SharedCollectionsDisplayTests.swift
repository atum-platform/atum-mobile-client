import Foundation
import XCTest
@testable import AtumChat

/// The Shared section's states, driven through the real `SharedCollectionsModel`
/// on the scripted host's synthetic source (the same data the UI tests see).
@available(macOS 14.0, *)
@MainActor
final class SharedCollectionsDisplayTests: XCTestCase {
    private func model(_ section: SharedCollectionSection,
                       _ mode: ScriptedSharedCollections.Mode) -> (SharedCollectionsModel, ScriptedSharedCollectionSource) {
        let source = ScriptedSharedCollectionSource(section: section, mode: mode)
        return (SharedCollectionsModel(section: section, source: source), source)
    }

    private func items(_ body: SharedCollectionsDisplay.Body) -> [SharedCollectionItem] {
        if case let .items(values) = body { return values }
        return []
    }

    func testBeforeTheFirstReadEverySectionIsLoading() {
        for section in SharedCollectionSection.allCases {
            let (model, _) = model(section, .ready)
            let display = SharedCollectionsDisplay(model: model, preview: true)
            XCTAssertEqual(display.body, .loading)
            XCTAssertFalse(display.showsSeeAll)
            XCTAssertFalse(display.showsLoadMore)
        }
    }

    func testReadyPreviewsAreSixThreeThreeWithSeeAll() async {
        for (section, count) in [(SharedCollectionSection.media, 6), (.files, 3), (.links, 3)] {
            let (model, _) = model(section, .ready)
            await model.loadPreview()
            let display = SharedCollectionsDisplay(model: model, preview: true)
            XCTAssertEqual(items(display.body).count, count, "\(section)")
            XCTAssertTrue(display.showsSeeAll)
            XCTAssertFalse(display.showsLoadMore, "a preview with rows offers See all, not Load more")
            XCTAssertFalse(display.showsOffline)
        }
    }

    func testSeeAllPagesThirtyThenLoadMoreReachesTheRoomStart() async {
        let (model, _) = model(.media, .ready)
        await model.loadPreview()
        await model.seeAll()
        var page = SharedCollectionsDisplay(model: model, preview: false)
        XCTAssertEqual(items(page.body).count, 30)
        XCTAssertEqual(model.state, .partial)
        XCTAssertTrue(page.showsLoadMore)
        XCTAssertFalse(page.showsSeeAll)

        await model.loadMore()
        page = SharedCollectionsDisplay(model: model, preview: false)
        XCTAssertEqual(items(page.body).count, 36)
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(page.showsLoadMore, "the room start leaves nothing more to read")
    }

    func testEmptyIsClaimedOnlyAtTheRoomStart() async {
        let (model, source) = model(.links, .empty)
        await model.loadPreview()
        let display = SharedCollectionsDisplay(model: model, preview: true)
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(display.body, .empty)
        XCTAssertFalse(display.showsSeeAll)
        XCTAssertFalse(display.showsLoadMore)
        XCTAssertEqual(source.paginateCount, 0)
    }

    func testPartialWithNothingRecentIsNotEmptyAndOffersMore() async {
        let (links, _) = model(.links, .partial)
        await links.loadPreview()
        let preview = SharedCollectionsDisplay(model: links, preview: true)
        XCTAssertEqual(links.state, .partial)
        XCTAssertEqual(preview.body, .noneRecent)
        XCTAssertTrue(preview.showsLoadMore)
        XCTAssertFalse(preview.showsSeeAll, "Load more is already inline")

        let (files, _) = model(.files, .partial)
        await files.seeAll()
        let page = SharedCollectionsDisplay(model: files, preview: false)
        XCTAssertEqual(items(page.body).count, 2)
        XCTAssertTrue(page.showsLoadMore, "partial rows say there may be more")
    }

    func testFailedReadRetriesTheSameReader() async {
        let (model, source) = model(.files, .failed)
        await model.loadPreview()
        var display = SharedCollectionsDisplay(model: model, preview: true)
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(display.body, .failed)
        XCTAssertEqual(display.retry, .model)
        XCTAssertFalse(display.showsSeeAll)

        await model.retry()
        display = SharedCollectionsDisplay(model: model, preview: true)
        XCTAssertEqual(items(display.body).count, 3)
        XCTAssertFalse(display.showsFailure)
        XCTAssertGreaterThan(source.paginateCount, 1)
    }

    func testFailureBelowCachedRowsKeepsTheRows() {
        let rows = ScriptedSharedCollections.items(.files, count: 2)
        let display = SharedCollectionsDisplay(state: .failed, items: rows, isReading: false, canLoadMore: true,
                                               requiresReopen: true, previewCount: nil)
        XCTAssertEqual(display.body, .items(rows))
        XCTAssertTrue(display.showsFailure)
        XCTAssertFalse(display.showsLoadMore, "Retry replaces Load more while a read is failing")
        XCTAssertEqual(display.retry, .reopenScope)
    }

    func testOfflineShowsCachedRowsWithoutReadingHistory() async {
        let (media, mediaSource) = model(.media, .offline)
        media.setOffline(true)
        await media.seeAll()
        let page = SharedCollectionsDisplay(model: media, preview: false)
        XCTAssertEqual(media.state, .offline)
        XCTAssertEqual(items(page.body).count, 3)
        XCTAssertTrue(page.showsOffline)
        XCTAssertFalse(page.showsLoadMore)
        XCTAssertEqual(mediaSource.paginateCount, 0)

        let (links, _) = model(.links, .offline)
        links.setOffline(true)
        await links.loadPreview()
        XCTAssertEqual(SharedCollectionsDisplay(model: links, preview: true).body, .offlineNothingCached)
    }

    func testReadingMoreKeepsRowsAndHidesTheButton() {
        let rows = ScriptedSharedCollections.items(.links, count: 4)
        let page = SharedCollectionsDisplay(state: .loading, items: rows, isReading: true, canLoadMore: true,
                                            requiresReopen: false, previewCount: nil)
        XCTAssertEqual(page.body, .items(rows))
        XCTAssertTrue(page.showsReadingMore)
        XCTAssertFalse(page.showsLoadMore)
    }

    func testScriptedHistoryUsesSyntheticIdentitiesAndAllowedLinks() {
        for mode in ScriptedSharedCollections.Mode.allCases {
            for section in SharedCollectionSection.allCases {
                for item in ScriptedSharedCollections.history(section, mode: mode) {
                    XCTAssertTrue(item.sender.hasSuffix(":atum.test"))
                    XCTAssertTrue(item.eventID.hasPrefix("$"))
                    if section == .links {
                        XCTAssertNotEqual(item.linkDecision, .refuse, item.url ?? "")
                    }
                }
            }
        }
        XCTAssertEqual(ScriptedSharedCollections.mode(arguments: ["-AtumScriptedShared", "partial"]), .partial)
        XCTAssertEqual(ScriptedSharedCollections.mode(arguments: ["-AtumScriptedShared"]), .ready)
        XCTAssertNil(ScriptedSharedCollections.mode(arguments: []))
    }
}
