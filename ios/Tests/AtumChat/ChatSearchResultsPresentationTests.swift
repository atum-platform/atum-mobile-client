import XCTest
@testable import AtumChat

final class ChatSearchResultsPresentationTests: XCTestCase {
    private func hit(_ room: String, _ event: String, _ at: Int64, body: String = "invoice",
                     thread: String? = nil) -> GlobalChatSearchHit {
        GlobalChatSearchHit(target: ChatSearchEventTarget(roomID: room, eventID: event, threadRootID: thread),
                            roomName: room, senderID: "@a:x", snippet: body, timestamp: at)
    }

    func testGroupsByRoomNewestFirstAndKeepsDuplicateBodiesAsDistinctEvents() {
        let groups = ChatSearchResultGrouping.groups([
            hit("!design", "$old", 10), hit("!linh", "$a", 50), hit("!design", "$new", 40),
            hit("!design", "$dup", 40, body: "invoice"), hit("!hoa", "$h", 5),
            // The same event delivered twice by a source appears once.
            hit("!linh", "$a", 50),
        ])
        XCTAssertEqual(groups.map(\.roomID), ["!linh", "!design", "!hoa"])
        XCTAssertEqual(groups[1].hits.map(\.id.eventID), ["$new", "$dup", "$old"])
        XCTAssertEqual(groups[0].hits.count, 1)
    }

    func testThreadReplyKeepsReplyIDAndRootSeparately() {
        let group = ChatSearchResultGrouping.groups([hit("!g", "$reply", 1, thread: "$root")])
        XCTAssertEqual(group[0].hits[0].id.eventID, "$reply")
        XCTAssertEqual(group[0].hits[0].id.threadRootID, "$root")
    }

    func testSnippetMarksFoldCaseAndMarksWithoutChangingTheText() {
        let snippet = "September Invoices and the đà lạt invoice"
        let marks = ChatSearchSnippetMarks.ranges(in: snippet, query: "invoice")
        XCTAssertEqual(marks.map { String(snippet[$0]) }, ["Invoice", "invoice"])
        let vietnamese = ChatSearchSnippetMarks.ranges(in: snippet, query: "da lat")
        XCTAssertEqual(vietnamese.map { String(snippet[$0]) }, ["đà lạt"])
        XCTAssertTrue(ChatSearchSnippetMarks.ranges(in: snippet, query: " ").isEmpty)
        XCTAssertTrue(ChatSearchSnippetMarks.ranges(in: snippet, query: "absent").isEmpty)
    }

    func testPlainCoverageCountsMeasuredRoomsAndSkippedPrivateChats() {
        let line = ChatSearchCoverageLine.plain(personalSearched: 40, personalEncrypted: 3, personalTruncated: true,
                                                companyRooms: 2, failed: false)
        XCTAssertEqual(line, .plain(searched: 42, privateSkipped: 3, partial: true))
        XCTAssertEqual(line.text(word: { ChatSearchPendingCopy.text($0, locale: "en") }, day: { _ in "" }),
                       "Searched 42 chats · 3 private not searched · Partial results")
        let one = ChatSearchCoverageLine.plain(personalSearched: 1, personalEncrypted: 0, personalTruncated: false,
                                               companyRooms: 0, failed: false)
        XCTAssertEqual(one.text(word: { ChatSearchPendingCopy.text($0, locale: "en") }, day: { _ in "" }),
                       "Searched 1 chat")
        let failed = ChatSearchCoverageLine.plain(personalSearched: nil, personalEncrypted: 0,
                                                  personalTruncated: false, companyRooms: 4, failed: true)
        XCTAssertEqual(failed, .plainFailed(searched: 4))
    }

    func testDeviceCoverageNeverClaimsAnIndexWatermark() {
        let line = ChatSearchCoverageLine.device(privateChats: 3, earliestMatch: 1_700_000_000_000, partial: false)
        let text = line.text(word: { ChatSearchPendingCopy.text($0, locale: "en") }, day: { _ in "12 Oct" })
        XCTAssertEqual(text, "3 private chats on this device · earliest match 12 Oct · older messages may not be indexed yet")
        XCTAssertFalse(text.contains("indexed up to"))
        let empty = ChatSearchCoverageLine.device(privateChats: 1, earliestMatch: nil, partial: false)
            .text(word: { ChatSearchPendingCopy.text($0, locale: "en") }, day: { _ in "never" })
        XCTAssertEqual(empty, "1 private chat on this device · older messages may not be indexed yet")
        XCTAssertNotEqual(ChatSearchCoverageLine.deviceUnavailable,
                          .device(privateChats: 0, earliestMatch: nil, partial: false))
    }

    func testExportWordsWinOverPendingTables() {
        let line = ChatSearchCoverageLine.plain(searched: 2, privateSkipped: 0, partial: false)
        let text = line.text(word: { $0 == .searchedOther ? "Exported %d" : ChatSearchPendingCopy.text($0, locale: "vi") },
                             day: { _ in "" })
        XCTAssertEqual(text, "Exported 2")
    }

    func testEveryPendingKeyHasAllFiveLocales() {
        for key in ChatSearchCopyKey.allCases {
            let table = ChatSearchPendingCopy.tables[key.rawValue]
            XCTAssertNotNil(table, key.rawValue)
            for locale in ChatSearchPendingCopy.locales {
                XCTAssertFalse((table?[locale] ?? "").isEmpty, "\(key.rawValue) \(locale)")
            }
        }
        // Placeholders survive translation so `format` can fill them.
        for key in [ChatSearchCopyKey.searchedOther, .skipped, .phoneDeviceChatsOther] {
            for locale in ChatSearchPendingCopy.locales {
                XCTAssertTrue(ChatSearchPendingCopy.text(key, locale: locale).contains("%d"), "\(key) \(locale)")
            }
        }
        for locale in ChatSearchPendingCopy.locales {
            XCTAssertTrue(ChatSearchPendingCopy.text(.phoneEarliestMatch, locale: locale).contains("%@"))
        }
    }
}

final class ChatRoomListFilterSessionTests: XCTestCase {
    private struct Row: Equatable {
        let id: String
        let unread: Bool
        let favourite: Bool
        var filterRow: ChatRoomListFilter.Row {
            .init(hasRoom: true, badge: .init(isMarkedUnread: unread), isFavourite: favourite)
        }
    }

    private let sections = [
        ChatRoomListSection(id: "assistants", rows: [Row(id: "atum", unread: false, favourite: true),
                                                     Row(id: "lan", unread: true, favourite: false)]),
        ChatRoomListSection(id: "chats", rows: [Row(id: "linh", unread: true, favourite: true),
                                                Row(id: "hoa", unread: false, favourite: false),
                                                Row(id: "design", unread: true, favourite: false)]),
    ]

    private var available: [ChatRoomListFilter] {
        ChatRoomListFilter.available(in: sections.flatMap(\.rows).map(\.filterRow))
    }

    func testFilterKeepsSectionIDsAndOrder() {
        var session = ChatRoomListFilterSession()
        _ = session.select(.unread, available: available, visibleAnchor: "linh")
        let filtered = session.sections(sections, available: available, row: \.filterRow)
        XCTAssertEqual(filtered.map(\.id), ["assistants", "chats"])
        XCTAssertEqual(filtered.map { $0.rows.map(\.id) }, [["lan"], ["linh", "design"]])
        _ = session.select(.favourites, available: available, visibleAnchor: "lan")
        XCTAssertEqual(session.sections(sections, available: available, row: \.filterRow).map { $0.rows.map(\.id) },
                       [["atum"], ["linh"]])
    }

    func testReturningToAllRestoresTheUnfilteredAnchorOnce() {
        var session = ChatRoomListFilterSession()
        XCTAssertEqual(session.select(.unread, available: available, visibleAnchor: "hoa"), .top)
        // Switching between filters keeps the anchor captured from All.
        XCTAssertEqual(session.select(.favourites, available: available, visibleAnchor: "linh"), .top)
        XCTAssertEqual(session.select(.all, available: available, visibleAnchor: "atum"), .restore(rowID: "hoa"))
        XCTAssertNil(session.allAnchor)
        XCTAssertEqual(session.select(.all, available: available, visibleAnchor: "atum"), .none)
        XCTAssertEqual(session.sections(sections, available: available, row: \.filterRow), sections)
    }

    func testStaleChoiceReadsAsAllWithoutLosingRows() {
        var session = ChatRoomListFilterSession()
        _ = session.select(.unread, available: available, visibleAnchor: nil)
        let nothingUnread: [ChatRoomListFilter] = [.all, .favourites]
        XCTAssertEqual(session.effective(in: nothingUnread), .all)
        XCTAssertEqual(session.sections(sections, available: nothingUnread, row: \.filterRow), sections)
        XCTAssertEqual(session.select(.unread, available: nothingUnread, visibleAnchor: "atum"), .none)
        XCTAssertEqual(session.selection, .all)
    }
}
