@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import XCTest

/// ML3 S1/S2/S16 Home search controller and filter rows (mockup M1).
@MainActor
final class HomeSearchControllerTests: XCTestCase {
    private func hit(_ room: String, _ event: String, _ at: Int64, thread: String? = nil) -> GlobalChatSearchHit {
        GlobalChatSearchHit(target: ChatSearchEventTarget(roomID: room, eventID: event, threadRootID: thread),
                            roomName: room, senderID: "@linh:atum.test", snippet: "invoice 1042", timestamp: at)
    }

    private func company(_ room: String, _ event: String, _ at: Int64) -> CompanySearchResult {
        CompanySearchResult(companyID: "studio", channelID: "finance", roomID: room, channelName: "finance",
                            eventID: event, sender: "@thao:atum.test", snippet: "invoices paid", at: at)
    }

    private func settle(_ controller: HomeSearchController, until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Plain scope merges personal and company hits into one card per chat,
    /// newest first, labels only company chats, and measures coverage.
    func testPlainResultsGroupByChatWithCompanyOnlyLabels() async {
        var sources = HomeSearchSources()
        sources.personal = { _, _ in
            PersonalMessageSearch.Page(
                results: [self.hit("!linh", "$a", 50), self.hit("!design", "$b", 40), self.hit("!design", "$c", 10)],
                coverage: .init(eligibleRooms: 43, searchedRooms: 40, encryptedRooms: 3, truncated: false))
        }
        sources.personalRetained = { $0 }
        sources.company = { _, tab in tab == .messages ? [self.company("!finance", "$f", 45)] : [] }
        sources.companyRooms = { 2 }
        sources.companyLabel = { room, company in company == nil ? nil : "Atum Studio \(room)" }
        let controller = HomeSearchController(sources: sources, debounce: .zero)
        controller.text.wrappedValue = "invoice"
        await settle(controller) { controller.shown.coverage != nil }

        let groups = controller.shown.messages
        XCTAssertEqual(groups.map(\.roomID), ["!linh", "!finance", "!design"])
        XCTAssertEqual(groups[2].hits.map(\.target.eventID), ["$b", "$c"])
        XCTAssertNil(groups[0].hits[0].companyLabel)
        XCTAssertEqual(groups[1].hits[0].companyLabel, "Atum Studio !finance")
        XCTAssertFalse(groups.flatMap(\.hits).contains(where: \.isPrivate))
        XCTAssertEqual(controller.shown.coverage, .plain(searched: 42, privateSkipped: 3, partial: false))
    }

    /// A private term reaches only the device closure, never People, company
    /// or personal server search; its hits carry the lock and device coverage.
    func testDeviceScopeTermReachesOnlyTheLocalIndex() async {
        var remote = [String]()
        var local = [String]()
        var backfill = [String]()
        var sources = HomeSearchSources()
        sources.people = { remote.append("people \($0)"); return [] }
        sources.company = { term, _ in remote.append("company \(term)"); return [] }
        sources.companyRooms = { 1 }
        sources.personal = { term, _ in
            remote.append("personal \(term)")
            return PersonalMessageSearch.Page(results: [], coverage: .init(eligibleRooms: 0, searchedRooms: 0,
                                                                           encryptedRooms: 0, truncated: false))
        }
        sources.device = HomeSearchSources.Device(
            search: { term, _ in
                local.append(term)
                return LocalSearchSource.Page(results: [self.hit("!hoa", "$p", 7)], eligibleRooms: 3,
                                              roomsWithMatches: 1, oldestMatchTimestamp: 7, truncated: false)
            },
            retained: { $0 },
            startBackfill: { backfill.append("start") },
            stopBackfill: { backfill.append("stop") },
            observeRedactions: { _, _ in },
            stopObservingRedactions: {})
        let controller = HomeSearchController(sources: sources, debounce: .zero)
        XCTAssertTrue(controller.offersDeviceScope)
        // A binding made in the plain scope is dead after the scope changes.
        let stale = controller.text
        controller.select(.deviceOnly)
        XCTAssertEqual(backfill, ["start"])
        stale.wrappedValue = "canary-plain"
        XCTAssertEqual(controller.query, "")
        controller.text.wrappedValue = "canary"
        await settle(controller) { controller.shown.coverage != nil }

        XCTAssertEqual(local, ["canary"])
        XCTAssertEqual(remote, [])
        XCTAssertEqual(controller.shown.messages.first?.hits.first?.isPrivate, true)
        XCTAssertEqual(controller.shown.coverage, .device(privateChats: 3, earliestMatch: 7, partial: false))
        controller.dismiss()
        XCTAssertEqual(backfill, ["start", "stop"])
        XCTAssertEqual(controller.scope, .plain)
        XCTAssertEqual(controller.query, "")
    }

    /// A failed device index is "unavailable", not an empty success; a failed
    /// plain source keeps what answered and says some chats were not searched.
    func testFailuresAreDistinctFromEmptyResults() async {
        var sources = HomeSearchSources()
        sources.personal = { _, _ in throw URLError(.timedOut) }
        sources.company = { _, _ in [] }
        sources.companyRooms = { 4 }
        sources.device = HomeSearchSources.Device(
            search: { _, _ in throw URLError(.cannotOpenFile) }, retained: { $0 }, startBackfill: {},
            stopBackfill: {}, observeRedactions: { _, _ in }, stopObservingRedactions: {})
        let controller = HomeSearchController(sources: sources, debounce: .zero)
        controller.text.wrappedValue = "invoice"
        await settle(controller) { controller.shown.coverage != nil }
        XCTAssertEqual(controller.shown.coverage, .plainFailed(searched: 4))

        controller.select(.deviceOnly)
        XCTAssertNil(controller.shown.coverage)
        controller.text.wrappedValue = "invoice"
        await settle(controller) { controller.shown.coverage != nil }
        XCTAssertEqual(controller.shown.coverage, .deviceUnavailable)
    }

    /// Revalidation drops a hit whose room left the personal gate, without
    /// asking the server again.
    func testRevalidateDropsHitsWhoseRoomLeft() async {
        var allowed: Set<String> = ["!linh", "!design"]
        var asked = 0
        var sources = HomeSearchSources()
        sources.personal = { _, _ in
            asked += 1
            return PersonalMessageSearch.Page(results: [self.hit("!linh", "$a", 5), self.hit("!design", "$b", 4)],
                                              coverage: .init(eligibleRooms: 2, searchedRooms: 2, encryptedRooms: 0,
                                                              truncated: false))
        }
        sources.personalRetained = { hits in hits.filter { allowed.contains($0.id.roomID) } }
        let controller = HomeSearchController(sources: sources, debounce: .zero)
        controller.text.wrappedValue = "invoice"
        await settle(controller) { controller.shown.coverage != nil }
        XCTAssertEqual(controller.shown.messages.map(\.roomID), ["!linh", "!design"])
        allowed.remove("!design")
        controller.revalidate()
        XCTAssertEqual(controller.shown.messages.map(\.roomID), ["!linh"])
        XCTAssertEqual(asked, 1)
    }

    /// Sender names come from the member cache after the page lands.
    func testSenderNamesFillInAfterThePageLands() async {
        var sources = HomeSearchSources()
        sources.personal = { _, _ in
            PersonalMessageSearch.Page(results: [self.hit("!linh", "$a", 5)],
                                       coverage: .init(eligibleRooms: 1, searchedRooms: 1, encryptedRooms: 0,
                                                       truncated: false))
        }
        sources.personalRetained = { $0 }
        sources.senderName = { _, user in user == "@linh:atum.test" ? "Linh" : nil }
        let controller = HomeSearchController(sources: sources, debounce: .zero)
        controller.text.wrappedValue = "invoice"
        await settle(controller) { controller.shown.messages.first?.hits.first?.senderName != nil }
        XCTAssertEqual(controller.shown.messages.first?.hits.first?.senderName, "Linh")
    }

    /// S16 reads a row's real room, badge and favourite tag; placeholders and
    /// invitations never match Unread or Favourites.
    func testFilterRowsUseRealRoomsBadgesAndFavourites() {
        let unread = HomeRow(id: "!a", kind: .person, name: "Linh", badgeInput: .init(isMarkedUnread: true))
        let favourite = HomeRow(id: "!b", kind: .group, name: "Design", isPinned: true)
        let invite = HomeRow(id: "!c", kind: .invitation, name: "Hoa", badgeInput: .init(isMarkedUnread: true),
                             isPinned: true)
        let waiting = HomeRow(id: "!d", kind: .assistant, name: "Lan", badgeInput: .init(isMarkedUnread: true),
                              isWaitingForRoom: true)
        XCTAssertTrue(ChatRoomListFilter.unread.includes(unread.filterRow))
        XCTAssertFalse(ChatRoomListFilter.unread.includes(favourite.filterRow))
        XCTAssertTrue(ChatRoomListFilter.favourites.includes(favourite.filterRow))
        XCTAssertFalse(ChatRoomListFilter.unread.includes(invite.filterRow))
        XCTAssertFalse(ChatRoomListFilter.favourites.includes(invite.filterRow))
        XCTAssertFalse(ChatRoomListFilter.unread.includes(waiting.filterRow))
        XCTAssertEqual(ChatRoomListFilter.available(in: [invite, waiting].map(\.filterRow)), [.all])
    }

    func testRowVisibilityAnchorIsTheFirstVisibleRowInListOrder() {
        let visibility = HomeRowVisibility()
        visibility.visible = ["c", "b"]
        XCTAssertEqual(visibility.first(in: ["a", "b", "c"]), "b")
        visibility.visible = []
        XCTAssertNil(visibility.first(in: ["a"]))
    }
}
