import XCTest
@testable import AtumChat

final class ChatRoomListFilterTests: XCTestCase {
    func testUnreadUsesCurrentBadgeIncludingQuietAndManualUnread() {
        typealias Filter = ChatRoomListFilter
        for badge in [Badge.Input(highlights: 1), .init(notifications: 1),
                      .init(hasUnreadActivity: true, isMuted: true), .init(isMarkedUnread: true)] {
            XCTAssertTrue(Filter.unread.includes(.init(hasRoom: true, badge: badge, isFavourite: false)))
        }
        XCTAssertFalse(Filter.unread.includes(.init(hasRoom: true, badge: .init(isMuted: true), isFavourite: false)))
        XCTAssertFalse(Filter.unread.includes(.init(hasRoom: false, badge: .init(notifications: 1), isFavourite: true)))
    }

    func testFavouritesAndFallbackKeepExistingSectionOrder() {
        typealias Filter = ChatRoomListFilter
        let rows: [Filter.Row] = [
            .init(hasRoom: true, badge: .init(), isFavourite: true),
            .init(hasRoom: false, badge: .init(), isFavourite: true),
            .init(hasRoom: true, badge: .init(isMarkedUnread: true), isFavourite: false),
            .init(hasRoom: true, badge: .init(isMarkedUnread: true), isFavourite: true),
        ]
        XCTAssertEqual(Filter.available(in: rows), [.all, .unread, .favourites])
        XCTAssertEqual(rows.indices.filter { Filter.favourites.includes(rows[$0]) }, [0, 3])
        XCTAssertEqual(rows.indices.filter { Filter.all.includes(rows[$0]) }, [0, 1, 2, 3])
        XCTAssertEqual(Filter.unread.effective(in: Filter.available(in: Array(rows.prefix(2)))), .all)
        XCTAssertEqual(Filter.favourites.effective(in: Filter.available(in: rows)), .favourites)
    }
}
