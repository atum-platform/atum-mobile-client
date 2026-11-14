@testable import AtumMobile
import AtumNativeAPI
import XCTest

/// Home search's Channels, Messages and Files (desktop roster global search,
/// `apps/desktop/src/matrix/app.tsx` `MatrixAccountView`).
final class HomeGlobalSearchPolicyTests: XCTestCase {
    private let rooms = [
        HomeSearchChannel(roomID: "!launch:atum.test", name: "launch"),
        HomeSearchChannel(roomID: "!dalat:atum.test", name: "Đà  Lạt team"),
        HomeSearchChannel(roomID: "!general:atum.test", name: "general"),
        HomeSearchChannel(roomID: "!launch:atum.test", name: "launch"),
    ]

    /// Desktop `globalChannels`: a Team Space room whose name holds the
    /// query, folded as `normalizeMatrixRosterQuery`, in the room list's
    /// order, and only while the query is long enough for the block.
    func testChannelsMatchTheRoomNameFoldedAndOnlyFromTwoCharacters() {
        XCTAssertEqual(HomeGlobalSearchPolicy.normalize("  Đà   LẠT "), "da lat")
        XCTAssertEqual(HomeGlobalSearchPolicy.channels(rooms, query: "l"), [])
        XCTAssertEqual(HomeGlobalSearchPolicy.channels(rooms, query: " da lat ").map(\.roomID), ["!dalat:atum.test"])
        XCTAssertEqual(HomeGlobalSearchPolicy.channels(rooms, query: "LAUNCH").map(\.roomID), ["!launch:atum.test"])
        XCTAssertEqual(HomeGlobalSearchPolicy.channels(rooms, query: "a").map(\.roomID), [])
        XCTAssertEqual(HomeGlobalSearchPolicy.channels(rooms, query: "al").map(\.roomID), ["!general:atum.test"])
    }

    /// Desktop asks Messages and Files once per query and set of companies,
    /// and not at all without a company or before two characters.
    func testMessagesAndFilesAskPerQueryAndCompanySet() {
        XCTAssertNil(HomeGlobalSearchPolicy.companyKey(term: "launch", companyIDs: []))
        XCTAssertNil(HomeGlobalSearchPolicy.companyKey(term: HomePeopleSearchPolicy.term("l"), companyIDs: ["a"]))
        XCTAssertEqual(HomeGlobalSearchPolicy.companyKey(term: "launch", companyIDs: ["b", "a", "b"]),
                       HomeGlobalSearchPolicy.companyKey(term: "launch", companyIDs: ["a", "b"]))
        XCTAssertNotEqual(HomeGlobalSearchPolicy.companyKey(term: "launch", companyIDs: ["a"]),
                          HomeGlobalSearchPolicy.companyKey(term: "launch", companyIDs: ["a", "b"]))
    }

    /// Desktop's order: People, Channels, Messages, Files (then the roster's
    /// own matches, drawn by `HomeScreen` after this block). Empty ones are
    /// left out.
    func testSectionsKeepDesktopOrderAndSkipEmptyOnes() {
        XCTAssertEqual(HomeGlobalSearchPolicy.sections(people: 2, channels: 1, messages: 3, files: 1),
                       [.people, .channels, .messages, .files])
        XCTAssertEqual(HomeGlobalSearchPolicy.sections(people: 0, channels: 0, messages: 1, files: 2),
                       [.messages, .files])
        XCTAssertEqual(HomeGlobalSearchPolicy.sections(people: 1, channels: 0, messages: 0, files: 1),
                       [.people, .files])
        XCTAssertEqual(HomeGlobalSearchPolicy.sections(people: 0, channels: 0, messages: 0, files: 0), [])
    }

    /// Desktop's "No results found" waits for every source and counts the
    /// roster's own matches too.
    func testNoResultsOnlyOnceEverySourceAnsweredEmpty() {
        XCTAssertFalse(HomeGlobalSearchPolicy.showsNoResults(searching: true, globalCount: 0, rosterCount: 0))
        XCTAssertFalse(HomeGlobalSearchPolicy.showsNoResults(searching: false, globalCount: 1, rosterCount: 0))
        XCTAssertFalse(HomeGlobalSearchPolicy.showsNoResults(searching: false, globalCount: 0, rosterCount: 1))
        XCTAssertTrue(HomeGlobalSearchPolicy.showsNoResults(searching: false, globalCount: 0, rosterCount: 0))
    }
}
