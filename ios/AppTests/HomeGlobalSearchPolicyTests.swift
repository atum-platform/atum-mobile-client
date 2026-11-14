@testable import AtumMobile
import AtumDesign
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

    /// Review blocker 1, on screen: a completed answer keeps only rows whose
    /// room is still eligible, so leaving a room hides its rows at once.
    func testShownResultsFollowCurrentEligibility() {
        func result(_ room: String, _ id: String) -> CompanySearchResult {
            CompanySearchResult(companyID: "c", channelID: "ch-" + room, roomID: room, channelName: room,
                                eventID: id, sender: "@s:atum.test", snippet: "launch", at: 0)
        }
        let answer = [result("!a:atum.test", "$a"), result("!b:atum.test", "$b")]
        let both = CompanySearchEligibility(bindings: ["c": ["!a:atum.test": "ch-!a:atum.test",
                                                            "!b:atum.test": "ch-!b:atum.test"]])
        XCTAssertEqual(HomeGlobalSearchPolicy.visible(answer, eligibility: both).map(\.eventID), ["$a", "$b"])
        let leftA = CompanySearchEligibility(bindings: ["c": ["!b:atum.test": "ch-!b:atum.test"]])
        XCTAssertEqual(HomeGlobalSearchPolicy.visible(answer, eligibility: leftA).map(\.eventID), ["$b"])
        XCTAssertEqual(HomeGlobalSearchPolicy.visible(answer, eligibility: CompanySearchEligibility()), [])
    }

    /// Review round 2: `homeCompanySearch` serves both tabs from this one
    /// service, so both share its one queue (four at a time) and its one
    /// transport (one URL session). The service's own tests prove it builds
    /// each once and runs both tabs through them.
    @MainActor
    func testHomeSearchTabsShareOneServiceQueueAndSession() {
        let service = LiveAppModel.homeCompanySearchService
        XCTAssertTrue(service === LiveAppModel.homeCompanySearchService)
        XCTAssertEqual(service.limiter.limit, 4)
        XCTAssertTrue(service.transport is LiveCompanySearchTransport)
    }

    /// atum-desktop#48: the field reads just "Search" in every locale while
    /// the pinned export still has the retired long words; anything else the
    /// export carries wins, so a repin needs no code change.
    func testThePlaceholderIsDesktopsShortSearchUntilTheExportCarriesIt() {
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "en", exported: "Search chats, people, apps…"), "Search")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "vi",
                                                        exported: "Tìm cuộc trò chuyện, người và ứng dụng…"),
                       "Tìm kiếm")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "ja", exported: nil), "検索")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "zh", exported: ""), "搜索")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "zh-Hant", exported: "搜尋聊天、聯絡人和應用程式…"), "搜尋")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "en", exported: "Find"), "Find")
        XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: "xx", exported: nil), "Search")
    }

    /// The pinned export's own words for the key resolve to desktop's short
    /// ones in all five locales, and the spoken name is still exported.
    func testThePinnedExportResolvesToTheShortPlaceholder() throws {
        let copy = try AtumCopy()
        let key = HomeSearchPromptCopy.placeholderKey
        XCTAssertTrue(copy.contains(key))
        XCTAssertTrue(copy.contains("desktop.atum.roster.search"))
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            let exported = try copy.text(key, locale: locale)
            XCTAssertEqual(HomeSearchPromptCopy.placeholder(locale: locale, exported: exported),
                           HomeSearchPromptCopy.current[locale], locale)
        }
    }
}
