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
        state.finish(attempt, opened: false)
        XCTAssertFalse(state.isOpening(roomID: launch.roomID, companyID: "anka"))
        XCTAssertEqual(state.failedRoom(companyID: "anka"), launch.roomID)
        XCTAssertNil(state.failedRoom(companyID: "studio"), "shown only for its own company")
    }

    func testTryAgainClearsTheFailureAndASuccessKeepsItClear() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(launch), opened: false)
        let retry = state.begin(launch)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "the line goes while the room opens again")
        state.finish(retry, opened: true)
        XCTAssertNil(state.failedRoom(companyID: "anka"))
        XCTAssertNil(state.opening)
    }

    func testOnlyTheLatestOpenLands() {
        var state = CompanyChannelOpenState()
        let first = state.begin(launch)
        let second = state.begin(design)
        state.finish(first, opened: false)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "a replaced open cannot fail on screen")
        XCTAssertTrue(state.isOpening(roomID: design.roomID, companyID: "anka"))
        state.finish(second, opened: nil)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "no answer of its own is not a failure")
        XCTAssertNil(state.opening)
    }

    func testAnotherCompanyOnScreenClearsTheFailureAndDropsItsOpen() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(launch), opened: false)
        state.navigated(toCompany: "studio")
        XCTAssertNil(state.failedRoom(companyID: "anka"))

        let pending = state.begin(launch)
        state.navigated(toCompany: "studio")
        state.finish(pending, opened: false)
        XCTAssertNil(state.failedRoom(companyID: "anka"), "an open for a company no longer shown cannot land")
        XCTAssertNil(state.opening)
    }

    func testAnotherRoomOnScreenInTheSameCompanyKeepsItsOpen() {
        var state = CompanyChannelOpenState()
        state.finish(state.begin(design), opened: false)
        let pending = state.begin(launch)
        state.navigated(toCompany: "anka")
        XCTAssertNil(state.failedRoom(companyID: "anka"))
        state.finish(pending, opened: false)
        XCTAssertEqual(state.failedRoom(companyID: "anka"), launch.roomID)
    }
}
