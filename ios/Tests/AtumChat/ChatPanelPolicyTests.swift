import XCTest
@testable import AtumChat

final class ChatPanelPolicyTests: XCTestCase {
    /// People, groups, apps and team spaces open with the chat still in view; the assistant card
    /// opens tall; an app page always fills the panel.
    func testOpeningHeightFollowsTheChatAndThePage() {
        for surface in [ChatPanelPolicy.Surface.person, .group, .app, .teamSpace] {
            XCTAssertEqual(ChatPanelPolicy.openingHeight(for: surface), .medium, "\(surface)")
            XCTAssertEqual(ChatPanelPolicy.openingHeight(for: surface, page: .members), .medium, "\(surface)")
            XCTAssertEqual(ChatPanelPolicy.openingHeight(for: surface, page: .appPage(routeID: "r")), .large)
        }
        XCTAssertEqual(ChatPanelPolicy.openingHeight(for: .assistant), .large)
    }

    /// Pushing a page keeps the person's height, except an app page, which raises it; nothing
    /// pushed ever lowers it.
    func testPushingAPageNeverShrinksThePanel() {
        for page in [ChatPanelPolicy.Page.members, .shared(.media), .shared(.links)] {
            XCTAssertEqual(ChatPanelPolicy.height(afterPushing: page, from: .medium), .medium)
            XCTAssertEqual(ChatPanelPolicy.height(afterPushing: page, from: .large), .large)
        }
        XCTAssertEqual(ChatPanelPolicy.height(afterPushing: .appPage(routeID: "r"), from: .medium), .large)
        XCTAssertEqual(ChatPanelPolicy.height(afterPushing: .appPage(routeID: "r"), from: .large), .large)
    }

    /// A panel belongs to one chat of one account: another room, another account or no session
    /// closes it.
    func testThePanelClosesWhenItsChatOrAccountChanges() {
        let here = ChatPanelPolicy.Scope(accountID: "@a:x", roomID: "!r:x")
        XCTAssertTrue(ChatPanelPolicy.staysOpen(from: here, to: here))
        XCTAssertFalse(ChatPanelPolicy.staysOpen(from: here, to: .init(accountID: "@a:x", roomID: "!s:x")))
        XCTAssertFalse(ChatPanelPolicy.staysOpen(from: here, to: .init(accountID: "@b:x", roomID: "!r:x")))
        XCTAssertFalse(ChatPanelPolicy.staysOpen(from: here, to: nil))
        XCTAssertFalse(ChatPanelPolicy.staysOpen(from: nil, to: here))
    }
}

final class ChatMemberModerationTests: XCTestCase {
    private let admin = ChatMemberModeration(ownPower: 100, kickLevel: 50, banLevel: 50)
    private let moderator = ChatMemberModeration(ownPower: 50, kickLevel: 50, banLevel: 50)
    private let member = ChatMemberModeration(ownPower: 0, kickLevel: 50, banLevel: 50)

    /// Matrix authorization: the action's level and more power than the target.
    func testRemoveAndBanNeedTheLevelAndMorePowerThanTheTarget() {
        XCTAssertTrue(admin.mayRemove(targetPower: 50, membership: .joined, isSelf: false))
        XCTAssertTrue(admin.mayBan(targetPower: 0, membership: .invited, isSelf: false))
        XCTAssertFalse(moderator.mayRemove(targetPower: 50, membership: .joined, isSelf: false), "equal power")
        XCTAssertTrue(moderator.mayRemove(targetPower: 0, membership: .joined, isSelf: false))
        XCTAssertFalse(member.mayRemove(targetPower: 0, membership: .joined, isSelf: false), "below kick level")
        XCTAssertFalse(member.mayBan(targetPower: -1, membership: .joined, isSelf: false), "below ban level")
        XCTAssertFalse(admin.mayRemove(targetPower: 0, membership: .joined, isSelf: true), "never yourself")
        XCTAssertFalse(admin.mayBan(targetPower: 0, membership: .banned, isSelf: false), "already banned")
    }

    func testUnbanNeedsBothLevelsAndOnlyAppliesToTheBanned() {
        XCTAssertTrue(admin.mayUnban(targetPower: 0, membership: .banned, isSelf: false))
        XCTAssertFalse(admin.mayUnban(targetPower: 0, membership: .joined, isSelf: false))
        let banOnly = ChatMemberModeration(ownPower: 50, kickLevel: 75, banLevel: 50)
        XCTAssertFalse(banOnly.mayUnban(targetPower: 0, membership: .banned, isSelf: false), "kick level too")
        XCTAssertFalse(moderator.mayUnban(targetPower: 50, membership: .banned, isSelf: false))
    }

    /// The desktop's order: block first, then remove, ban, unban; a blocked person offers Unblock.
    func testActionsAreOrderedAndBlockReflectsTheIgnoreList() {
        XCTAssertEqual(admin.actions(targetPower: 0, membership: .joined, isSelf: false,
                                     mayBlock: true, isBlocked: false), [.block, .remove, .ban])
        XCTAssertEqual(admin.actions(targetPower: 0, membership: .joined, isSelf: false,
                                     mayBlock: true, isBlocked: true), [.unblock, .remove, .ban])
        XCTAssertEqual(member.actions(targetPower: 0, membership: .joined, isSelf: false,
                                      mayBlock: true, isBlocked: false), [.block])
        XCTAssertEqual(admin.actions(targetPower: 0, membership: .banned, isSelf: false,
                                     mayBlock: false, isBlocked: false), [.unban])
        XCTAssertEqual(admin.actions(targetPower: 100, membership: .joined, isSelf: true,
                                     mayBlock: true, isBlocked: false), [])
    }
}

final class RosterLowPriorityTests: XCTestCase {
    private func room(_ id: String, minutesAgo: Double, kind: RosterProjection.Room.Kind = .person,
                      low: Bool = false, pinned: Bool = false) -> RosterProjection.Room {
        .init(id: id, kind: kind, latestEventAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
              isFavourite: pinned, isLowPriority: low)
    }

    /// Low priority sinks below every other ordinary chat, newest first among themselves; pins
    /// and the Founder keep their own places.
    func testLowPriorityChatsSinkBelowOrdinaryChats() {
        let rooms = [room("!lowNew", minutesAgo: 1, low: true), room("!old", minutesAgo: 90),
                     room("!lowOld", minutesAgo: 60, low: true), room("!new", minutesAgo: 5, kind: .group),
                     room("!pin", minutesAgo: 500, low: true, pinned: true)]
        let output = RosterProjection.project(.init(assistants: [], rooms: rooms, apps: []))
        XCTAssertEqual(output.chats.map(\.roomID), ["!pin", "!new", "!old", "!lowNew", "!lowOld"])
    }

    func testOnlyOrdinaryJoinedPersonAndGroupChatsOfferLowPriority() {
        let rooms = [room("!p", minutesAgo: 1), room("!g", minutesAgo: 1, kind: .group),
                     room("!pin", minutesAgo: 1, pinned: true), room("!f", minutesAgo: 1),
                     room("!a", minutesAgo: 1, kind: .assistant(agentID: "a")),
                     room("!app", minutesAgo: 1, kind: .app(appID: "unknown-orchid")),
                     .init(id: "!inv", kind: .person, membership: .invited)]
        func offers(_ id: String) -> Bool {
            RosterProjection.offersLowPriority(roomID: id, rooms: rooms, founderRoomID: "!f")
        }
        XCTAssertTrue(offers("!p"))
        XCTAssertTrue(offers("!g"))
        for id in ["!pin", "!f", "!a", "!app", "!inv", "!missing"] { XCTAssertFalse(offers(id), id) }
    }
}
