import Foundation
import XCTest
@testable import AtumNativeAPI

/// W4-E7: the Team Space revamp's state rules, as desktop #114 (`fef8286c`) has them
/// in `company-workspace.tsx` and `company-board.tsx`.
final class TeamSpaceRevampPolicyTests: XCTestCase {
    // MARK: Header search

    func testMessageSearchNeedsTwoCodePointsAfterTrimming() {
        XCTAssertNil(TeamSpaceHeaderSearch.messageQuery(""))
        XCTAssertNil(TeamSpaceHeaderSearch.messageQuery("  a  "))
        XCTAssertEqual(TeamSpaceHeaderSearch.messageQuery("  ra mắt "), "ra mắt")
        XCTAssertEqual(TeamSpaceHeaderSearch.messageQuery("hi"), "hi")
        // One emoji made of two code points counts as two, as `[...string]` does.
        XCTAssertEqual(TeamSpaceHeaderSearch.messageQuery("👍🏽"), "👍🏽")
        // A single precomposed letter is one code point.
        XCTAssertNil(TeamSpaceHeaderSearch.messageQuery("\u{1EAF}"))
    }

    func testShortSearchClearsResultsAndDropsALatePage() throws {
        var state = TeamSpaceMessageSearchState()
        state.submit(" launch ")
        let initial = try XCTUnwrap(state.request)
        XCTAssertEqual(initial.term, "launch")
        state.finish(initial, answer: CompanySearchPage(results: [message("$first")], continuation: cursor))
        state.loadMore()
        let more = try XCTUnwrap(state.request)

        state.submit(" a ")
        state.finish(more, answer: CompanySearchPage(results: [message("$late")]))
        XCTAssertNil(state.request)
        XCTAssertNil(state.page)
        XCTAssertFalse(state.failed)
    }

    func testSearchFailureIsDistinctFromEmptyAndAnAppendCanRetry() throws {
        var state = TeamSpaceMessageSearchState()
        state.submit("launch")
        state.finish(try XCTUnwrap(state.request), answer: nil)
        XCTAssertTrue(state.failed)
        XCTAssertNil(state.page)

        state.submit("launch")
        state.finish(try XCTUnwrap(state.request), answer: CompanySearchPage())
        XCTAssertFalse(state.failed)
        XCTAssertEqual(state.page, CompanySearchPage())

        let first = message("$first")
        state.submit("launch")
        state.finish(try XCTUnwrap(state.request), answer: CompanySearchPage(results: [first], continuation: cursor))
        state.loadMore()
        let more = try XCTUnwrap(state.request)
        state.loadMore()
        XCTAssertEqual(state.request, more, "only one page request at a time")
        state.finish(more, answer: nil)
        XCTAssertTrue(state.failed)
        XCTAssertEqual(state.page?.results, [first])

        state.loadMore()
        let retry = try XCTUnwrap(state.request)
        XCTAssertEqual(retry.continuation, more.continuation)
        let second = message("$second")
        state.finish(retry, answer: CompanySearchPage(results: [first, second]))
        XCTAssertFalse(state.failed)
        XCTAssertEqual(state.page, CompanySearchPage(results: [first, second]))
    }

    private var cursor: CompanySearchCursor {
        CompanySearchCursor(token: "next", companyID: "anka", query: .parse("launch"),
                            channelsByRoom: ["!launch:atum.test": "launch"], senders: nil)
    }

    private func message(_ id: String) -> CompanySearchResult {
        CompanySearchResult(companyID: "anka", channelID: "launch", roomID: "!launch:atum.test",
                            channelName: "launch", eventID: id, sender: "@me:atum.test",
                            snippet: "launch", at: 0)
    }

    func testChannelsSaysNoMatchesOnlyWhileAQueryHidesLiveChannels() {
        XCTAssertEqual(CompanyChannelListNote.note(query: "zz", shown: 0, live: 3, archived: 0), .noMatches)
        XCTAssertEqual(CompanyChannelListNote.note(query: "  ", shown: 0, live: 3, archived: 0), .noChannels,
                       "a blank box is no query")
        XCTAssertEqual(CompanyChannelListNote.note(query: "zz", shown: 0, live: 0, archived: 0), .noChannels,
                       "with no channel at all it stays No channels")
        XCTAssertEqual(CompanyChannelListNote.note(query: "", shown: 0, live: 0, archived: 0), .noChannels)
        XCTAssertNil(CompanyChannelListNote.note(query: "zz", shown: 1, live: 3, archived: 0))
        XCTAssertNil(CompanyChannelListNote.note(query: "zz", shown: 0, live: 3, archived: 1),
                     "an archived channel keeps the section quiet")
    }

    // MARK: Settings sections

    func testSectionsKeepDesktopOrderAndAIIsAlwaysThere() {
        XCTAssertEqual(CompanySettingsSections.available(people: true, workspace: true, billing: true),
                       [.people, .workspace, .ai, .billing])
        XCTAssertEqual(CompanySettingsSections.available(people: true, workspace: false, billing: false),
                       [.people, .ai])
        XCTAssertEqual(CompanySettingsSections.available(people: false, workspace: false, billing: false), [.ai])
    }

    func testARoleChangeFallsBackToTheFirstSectionStillThere() {
        let member = CompanySettingsSections.available(people: true, workspace: false, billing: false)
        XCTAssertEqual(CompanySettingsSections.current(.billing, in: member), .people)
        XCTAssertEqual(CompanySettingsSections.current(.ai, in: member), .ai)
        XCTAssertEqual(CompanySettingsSections.current(.people, in: [.ai]), .ai)
        XCTAssertEqual(CompanySettingsSections.current(.people, in: []), .ai)
    }

    func testSettingsOpensOnWorkspaceAndTheOverviewOnPeople() {
        XCTAssertEqual(CompanySettingsSections.initial(fromSettings: true), .workspace)
        XCTAssertEqual(CompanySettingsSections.initial(fromSettings: false), .people)
        // Without a Workspace section the settings entry lands on the first one there.
        let sections = CompanySettingsSections.available(people: true, workspace: false, billing: false)
        XCTAssertEqual(CompanySettingsSections.current(.workspace, in: sections), .people)
    }

    func testThePickerIsDrawnOnlyWithAChoice() {
        XCTAssertFalse(CompanySettingsSections.showsPicker([.ai]))
        XCTAssertTrue(CompanySettingsSections.showsPicker([.people, .ai]))
    }

    // MARK: Board views and Mine

    func testBoardAndListWithMineOverEither() {
        var preference = CompanyBoardPreference()
        XCTAssertEqual(preference.view, .board)
        XCTAssertFalse(preference.mineOn(viewer: "m1"))

        preference = preference.togglingMine(viewer: "m1")
        XCTAssertEqual(preference.view, .board, "Mine keeps the view")
        XCTAssertTrue(preference.mineOn(viewer: "m1"))
        XCTAssertEqual(preference.ownerMemberRef, "m1")

        preference = preference.selecting(.list)
        XCTAssertEqual(preference.view, .list)
        XCTAssertTrue(preference.mineOn(viewer: "m1"), "the view keeps Mine")

        preference = preference.togglingMine(viewer: "m1")
        XCTAssertFalse(preference.mineOn(viewer: "m1"))
        XCTAssertNil(preference.ownerMemberRef)
        XCTAssertEqual(preference.view, .list)
    }

    func testMineNeedsAKnownViewer() {
        let preference = CompanyBoardPreference()
        XCTAssertEqual(preference.togglingMine(viewer: nil), preference)
        XCTAssertFalse(CompanyBoardPreference(ownerMemberRef: "m1").mineOn(viewer: nil))
        // Another person's owner filter is not Mine, and Mine replaces it.
        let other = CompanyBoardPreference(view: .list, ownerMemberRef: "m2")
        XCTAssertFalse(other.mineOn(viewer: "m1"))
        XCTAssertEqual(other.togglingMine(viewer: "m1"), CompanyBoardPreference(view: .list, ownerMemberRef: "m1"))
    }

    // MARK: Channel opening

    private let launch = CompanyChannelOpenState.Target(companyID: "anka", roomID: "!launch:atum.test")
    private let design = CompanyChannelOpenState.Target(companyID: "anka", roomID: "!design:atum.test")

    func testAFailedOpenIsHeldWithItsCompanyAndRoom() {
        var state = CompanyChannelOpenState()
        let attempt = state.begin(launch)
        XCTAssertTrue(state.isOpening(roomID: launch.roomID, companyID: "anka"))
        state.finish(attempt, result: .failed)
        XCTAssertFalse(state.isOpening(roomID: launch.roomID, companyID: "anka"))
        XCTAssertEqual(state.failedRoom(companyID: "anka"), launch.roomID)
        XCTAssertNil(state.failedRoom(companyID: "studio"), "shown only for its own company")
    }

    func testTryAgainClearsTheFailureAndASuccessKeepsItClear() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(launch), result: .failed)
        let retry = state.begin(launch)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "the line goes while the room opens again")
        state.finish(retry, result: .opened)
        XCTAssertNil(state.failedRoom(companyID: "anka"))
        XCTAssertNil(state.opening)
    }

    func testOnlyTheLatestOpenLands() {
        var state = CompanyChannelOpenState()
        let first = state.begin(launch)
        let second = state.begin(design)
        state.finish(first, result: .failed)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "a replaced open cannot fail on screen")
        XCTAssertTrue(state.isOpening(roomID: design.roomID, companyID: "anka"))
        state.finish(second, result: .superseded)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "no answer of its own is not a failure")
        XCTAssertNil(state.opening)
    }

    func testASupersededOpenClearsTheSpinnerAndAllowsARetry() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(launch), result: .superseded)
        XCTAssertNil(state.opening)
        XCTAssertNil(state.failure)

        state.finish(state.begin(launch), result: .failed)
        XCTAssertEqual(state.failure, launch)
    }

    func testAnotherCompanyOnScreenClearsTheFailureAndDropsItsOpen() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(launch), result: .failed)
        state.navigated(toCompany: "studio")
        XCTAssertNil(state.failedRoom(companyID: "anka"))

        let pending = state.begin(launch)
        state.navigated(toCompany: "studio")
        state.finish(pending, result: .failed)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "an open for a company no longer shown cannot land")
        XCTAssertNil(state.opening)
    }

    func testAnyRoomComingOnScreenClearsTheFailure() {
        // Desktop clears it on `activeRoomId` as well as on the company: a push or a
        // search result opening another room is a successful navigation.
        var state = CompanyChannelOpenState()
        state.finish(state.begin(design), result: .failed)
        XCTAssertEqual(state.failedRoom(companyID: "anka"), design.roomID)
        state.navigated(toCompany: "anka")
        XCTAssertNil(state.failedRoom(companyID: "anka"))
        XCTAssertNil(state.opening)
    }

    func testAnotherRoomOnScreenInTheSameCompanyKeepsItsOpen() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(design), result: .failed)
        let pending = state.begin(launch)
        state.navigated(toCompany: "anka")
        XCTAssertNil(state.failedRoom(companyID: "anka"))
        state.finish(pending, result: .failed)
        XCTAssertEqual(state.failedRoom(companyID: "anka"), launch.roomID)
    }
}
