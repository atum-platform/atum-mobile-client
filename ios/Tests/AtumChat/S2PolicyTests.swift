import XCTest
@testable import AtumChat

final class S2PolicyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: RosterProjection

    func testRosterOrdersAssistantsAndMixesAppChatsWithChatsByRecency() {
        let now = date(11)
        let projection = RosterProjection.project(.init(
            assistants: [
                .init(id: "second", conversationRoomID: "assistant-2", agentOrder: 1),
                .init(id: "primary", conversationRoomID: "assistant-primary", isPrimary: true, agentOrder: 9),
                .init(id: "pinned", conversationRoomID: "assistant-pinned", agentOrder: 0),
                .init(id: "missing", conversationRoomID: nil, agentOrder: 2),
            ],
            rooms: [
                room("assistant-primary", .assistant(agentID: "primary"), at: now.addingTimeInterval(-20)),
                room("assistant-pinned", .assistant(agentID: "pinned"), at: now.addingTimeInterval(-10), favourite: true, tag: 2),
                room("assistant-2", .assistant(agentID: "second"), at: now, favourite: true, tag: 1),
                room("founder", .person, at: now.addingTimeInterval(-600)),
                room("pin-new", .person, at: now.addingTimeInterval(-30), favourite: true),
                room("pin-old", .group, at: now.addingTimeInterval(-120), favourite: true, tag: 9),
                room("recent", .person, at: now.addingTimeInterval(-1)),
                room("invite", .person, membership: .invited, at: now.addingTimeInterval(-2)),
                room("moon", .app(appID: "moon"), at: now),
                room("andy", .app(appID: "andy"), at: now.addingTimeInterval(-1)),
            ],
            apps: [.init(id: "andy", rosterOrder: 2, conversationRoomID: "andy"),
                   .init(id: "moon", rosterOrder: 1, conversationRoomID: "moon")],
            founderRoomID: "founder"
        ))

        XCTAssertEqual(projection.assistants.map(\.roomID), ["assistant-primary", "assistant-pinned", "assistant-2"],
                       "primary, then /agents order; a pin never moves an assistant (desktop roster-model)")
        XCTAssertEqual(projection.chats.map(\.roomID),
                       ["founder", "pin-old", "pin-new", "moon", "andy", "recent", "invite"],
                       "Founder, pins, then one recency sort over chats and app chats (desktop sortConversations)")
        XCTAssertEqual(projection.chats[3].kind, .app(appID: "moon", reopensHiddenRoom: false))
    }

    func testAppChatsInterleaveWithPeopleAndGroupsByRecency() {
        let now = date(11)
        let projection = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("alice", .person, at: now.addingTimeInterval(-10)),
                room("team", .group, at: now.addingTimeInterval(-300)),
                room("bob", .person, at: now.addingTimeInterval(-900)),
                room("moon", .app(appID: "moon"), at: now.addingTimeInterval(-60)),
                room("andy", .app(appID: "andy"), at: now.addingTimeInterval(-600)),
            ],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "moon"),
                   .init(id: "andy", rosterOrder: 1, conversationRoomID: "andy")]
        ))
        XCTAssertEqual(projection.chats.map(\.roomID), ["alice", "moon", "team", "andy", "bob"],
                       "a bot with a newer message than a person chat sits above it")
    }

    func testAppsWithoutAChatFollowEveryChatThenPlaceholdersInCatalogOrder() {
        let now = date(11)
        let projection = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("old-chat", .person, at: now.addingTimeInterval(-86_400 * 30)),
                room("quiet", .person),
                room("app:soon", .app(appID: "soon")),
                room("app:andy", .app(appID: "andy")),
                room("app:vneid", .app(appID: "vneid")),
                room("moon", .app(appID: "moon"), at: now),
            ],
            apps: [.init(id: "soon", rosterOrder: 0, isPresentationOnly: true),
                   .init(id: "vneid", rosterOrder: 1, conversationRoomID: "app:vneid", hasChat: false),
                   .init(id: "andy", rosterOrder: 2, conversationRoomID: "app:andy", hasChat: false),
                   .init(id: "moon", rosterOrder: 3, conversationRoomID: "moon")]
        ))
        XCTAssertEqual(projection.chats.map(\.roomID),
                       ["moon", "old-chat", "quiet", "app:vneid", "app:andy", "app:soon"],
                       "chats by recency, then apps without a chat, then coming-soon placeholders")
    }

    func testPinnedAppChatSortsWithPinsAndLowPriorityAppChatSinks() {
        let now = date(11)
        let projection = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("pin-person", .person, at: now.addingTimeInterval(-60), favourite: true),
                room("moon", .app(appID: "moon"), at: now.addingTimeInterval(-600), favourite: true),
                room("recent", .person, at: now),
                .init(id: "andy", kind: .app(appID: "andy"), latestEventAt: now.addingTimeInterval(-1),
                      isLowPriority: true),
                .init(id: "muted-group", kind: .group, latestEventAt: now.addingTimeInterval(-2),
                      isLowPriority: true),
                room("older", .group, at: now.addingTimeInterval(-3_600)),
            ],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "moon"),
                   .init(id: "andy", rosterOrder: 1, conversationRoomID: "andy")]
        ))
        XCTAssertEqual(projection.chats.map(\.roomID),
                       ["pin-person", "moon", "recent", "older", "andy", "muted-group"],
                       "a pinned app is a pin; low priority sinks an app chat like any other chat")
    }

    func testDeletedAppChatKeepsItsPlaceByRecency() {
        let now = date(11)
        let projection = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("recent", .person, at: now),
                room("hidden-moon", .app(appID: "moon"), at: now.addingTimeInterval(-10), hidden: true),
                room("older", .person, at: now.addingTimeInterval(-60)),
            ],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "hidden-moon")]
        ))
        XCTAssertEqual(projection.chats.map(\.roomID), ["recent", "hidden-moon", "older"],
                       "desktop keeps a deleted bot chat on its row (appBot.hidden), so it still dates the row")
        XCTAssertEqual(projection.chats[1].kind, .app(appID: "moon", reopensHiddenRoom: true))
    }

    func testPinnedAssistantDoesNotJumpAboveServerOrder() {
        let projection = RosterProjection.project(.init(
            assistants: [
                .init(id: "primary", conversationRoomID: "p", isPrimary: true, agentOrder: 5),
                .init(id: "first", conversationRoomID: "a", agentOrder: 0),
                .init(id: "second", conversationRoomID: "b", agentOrder: 1),
            ],
            rooms: [
                room("p", .assistant(agentID: "primary")),
                room("a", .assistant(agentID: "first")),
                room("b", .assistant(agentID: "second"), favourite: true, tag: 0),
            ],
            apps: []
        ))
        XCTAssertEqual(projection.assistants.map(\.roomID), ["p", "a", "b"])
    }

    func testRosterUsesAppRowForHiddenRoomAndRejectsDuplicateAndLegacyRows() {
        let output = RosterProjection.project(.init(
            assistants: [.init(id: "a", conversationRoomID: "legacy", isPrimary: true, agentOrder: 0)],
            rooms: [
                room("legacy", .assistant(agentID: "a"), legacy: true),
                room("same", .person), room("same", .group),
                room("hidden", .app(appID: "moon"), hidden: true),
                room("old-app", .app(appID: "moon"), legacy: true),
            ], apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "hidden"),
                      .init(id: "moon", rosterOrder: 1, conversationRoomID: "old-app")]
        ))
        XCTAssertTrue(output.assistants.isEmpty)
        XCTAssertEqual(output.chats.map(\.roomID), ["hidden", "same"],
                       "neither has a message, so the app chat and the person chat tie on recency and sort by ID")
        XCTAssertEqual(output.chats.first?.kind, .app(appID: "moon", reopensHiddenRoom: true))
    }

    func testPresentationOnlyCatalogAppsKeepOneInertRowWithoutAConversation() {
        let output = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("!moon", .app(appID: "moon")),
                room("app:coming", .app(appID: "coming")),
            ],
            apps: [
                .init(id: "moon", rosterOrder: 0, conversationRoomID: "!moon"),
                .init(id: "coming", rosterOrder: 1, isPresentationOnly: true),
            ]
        ))

        XCTAssertEqual(output.chats.map(\.roomID), ["!moon", "app:coming"],
                       "a coming-soon entry follows the catalog order with the other app rows")
        XCTAssertEqual(output.chats.last?.kind,
                       .app(appID: "coming", reopensHiddenRoom: false),
                       "presentation-only is a row, never a chosen conversation")
    }

    func testPresentationOnlyCatalogAppsAreDroppedWithoutTheirProjectedRow() {
        let output = RosterProjection.project(.init(
            assistants: [],
            rooms: [],
            apps: [.init(id: "coming", rosterOrder: 0, isPresentationOnly: true)]
        ))
        XCTAssertTrue(output.chats.isEmpty)
    }

    func testPinnedAssistantsWithoutTagOrderKeepServerOrderNotRecency() {
        let projection = RosterProjection.project(.init(
            assistants: [
                .init(id: "first", conversationRoomID: "first-room", agentOrder: 0),
                .init(id: "second", conversationRoomID: "second-room", agentOrder: 1),
            ],
            rooms: [
                room("first-room", .assistant(agentID: "first"), at: date(1), favourite: true),
                room("second-room", .assistant(agentID: "second"), at: date(11), favourite: true),
            ],
            apps: []
        ))

        XCTAssertEqual(projection.assistants.map(\.roomID), ["first-room", "second-room"])
    }

    func testRosterUsesTheAppPolicyChoiceInsteadOfGuessingAmongCandidateRooms() {
        let output = RosterProjection.project(.init(
            assistants: [],
            rooms: [
                room("!aaa-hidden", .app(appID: "moon"), hidden: true),
                room("!zzz-chosen", .app(appID: "moon")),
            ],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "!zzz-chosen")]
        ))
        XCTAssertEqual(output.chats.map(\.roomID), ["!zzz-chosen"])
        XCTAssertEqual(output.chats.first?.kind, .app(appID: "moon", reopensHiddenRoom: false))
    }

    func testPinnedChosenAppIsListedOnceAndAnInvitedAppWaitsForAutoAccept() {
        let pinned = RosterProjection.project(.init(
            assistants: [],
            rooms: [room("!hidden", .app(appID: "moon"), hidden: true),
                    room("!visible", .app(appID: "moon"), favourite: true)],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "!visible")]
        ))
        XCTAssertEqual(pinned.chats.map(\.roomID), ["!visible"])

        let invited = RosterProjection.project(.init(
            assistants: [],
            rooms: [room("!invite", .app(appID: "moon"), membership: .invited)],
            apps: [.init(id: "moon", rosterOrder: 0, conversationRoomID: "!invite")]
        ))
        XCTAssertTrue(invited.chats.isEmpty)
    }

    func testPinLimitCountsDistinctJoinedFavouriteRoomsAndExcludesAlreadyPinnedOrHiddenTargets() {
        let rooms = (0..<5).map { room("p\($0)", .person, favourite: true) } + [
            room("candidate", .person), room("already", .person, favourite: true),
            room("hidden", .person, hidden: true), room("invite", .person, membership: .invited),
            room("p0", .group, favourite: true),
        ]
        XCTAssertEqual(RosterProjection.joinedFavouriteCount(rooms), 6, "duplicate p0 does not add, already does")
        XCTAssertFalse(RosterProjection.canPin(roomID: "candidate", rooms: rooms))
        XCTAssertFalse(RosterProjection.canPin(roomID: "already", rooms: rooms))
        XCTAssertFalse(RosterProjection.canPin(roomID: "hidden", rooms: rooms))
        XCTAssertFalse(RosterProjection.canPin(roomID: "invite", rooms: rooms))
        XCTAssertTrue(RosterProjection.canPin(roomID: "candidate", rooms: Array(rooms.prefix(4)) + [room("candidate", .person)]))
        XCTAssertEqual(RosterProjection.joinedFavouriteCount(
            rooms + [room("hidden-pin", .person, favourite: true, hidden: true)]), 7,
            "phone-hidden rooms keep their server-side pin budget")
    }

    // MARK: Badge

    func testBadgeTableAndAppIconCount() {
        let cases: [(Badge.Input, Badge)] = [
            (.init(highlights: 2, notifications: 5, hasUnreadActivity: true), .mention(5)),
            (.init(highlights: 4, notifications: 1, isMuted: true), .mention(4)),
            (.init(notifications: 2), .count(2)),
            (.init(notifications: 3, isMuted: true), .quietDot),
            (.init(isMarkedUnread: true), .dot),
            (.init(hasUnreadActivity: true, isMarkedUnread: true, isMuted: true), .dot),
            (.init(hasUnreadActivity: true), .quietDot),
            (.init(), .none),
        ]
        for (input, expected) in cases { XCTAssertEqual(Badge.mark(for: input), expected) }
        XCTAssertEqual(Badge.mark(for: .init(notifications: 150)), .count(150))
        XCTAssertFalse(Badge.mark(for: .init(notifications: 99)).isCapped)
        XCTAssertTrue(Badge.mark(for: .init(notifications: 100)).isCapped)
        XCTAssertTrue(Badge.mark(for: .init(notifications: 150)).isCapped)

        let rows: [Badge.AppIconRow] = [
            .init(input: .init(highlights: 3, notifications: 5)), // 5
            .init(input: .init(notifications: 2)), // 2
            .init(input: .init(isMarkedUnread: true)), // 1
            .init(input: .init(notifications: 8, isMuted: true)),
            .init(input: .init(highlights: 4, notifications: 4, isMuted: true)),
            .init(input: .init(notifications: 6), isHidden: true),
            .init(input: .init(notifications: 7), isJoined: false),
        ]
        XCTAssertEqual(Badge.appIconCount(rows), 8)
    }

    // MARK: RowPreview

    func testRowPreviewTable() {
        let vi = Locale(identifier: "vi")
        let group = RoomKind.group
        let cases: [(RowPreview.Event, RowPreview.Display)] = [
            (.init(content: .text("**Hello**\nworld"), isOwn: true, roomKind: .person),
             .init(prefix: .currentUser, value: .text("Hello world"), sendState: .sent)),
            (.init(content: .text("hi"), senderName: "Lan", roomKind: group),
             .init(prefix: .sender("Lan"), value: .text("hi"), sendState: .sent)),
            (.init(content: .text("hi"), senderName: "Lan", roomKind: .person),
             .init(prefix: .none, value: .text("hi"), sendState: .sent)),
            (.init(content: .image, roomKind: .person), .init(prefix: .none, value: .photo, sendState: .sent)),
            (.init(content: .video, roomKind: .person), .init(prefix: .none, value: .video, sendState: .sent)),
            (.init(content: .audio, roomKind: .person), .init(prefix: .none, value: .audio, sendState: .sent)),
            (.init(content: .file(name: "x.pdf"), roomKind: .person), .init(prefix: .none, value: .file(name: "x.pdf"), sendState: .sent)),
            (.init(content: .file(name: nil), roomKind: .person), .init(prefix: .none, value: .file(name: nil), sendState: .sent)),
            (.init(content: .sticker, roomKind: .person), .init(prefix: .none, value: .sticker, sendState: .sent)),
            (.init(content: .redacted, isOwn: true, roomKind: .group), .init(prefix: .none, value: .redacted, sendState: .sent)),
            (.init(content: .undecryptable, roomKind: .group), .init(prefix: .none, value: .waitingForDecryption, sendState: .sent)),
            (.init(content: .none, roomKind: .person), .init(prefix: .none, value: .empty, sendState: .sent)),
            (.init(content: .text("ignored"), roomKind: .person, isInvitation: true), .init(prefix: .none, value: .invitation, sendState: .sent)),
            (.init(content: .text("queued"), roomKind: .person, sendState: .sending), .init(prefix: .none, value: .text("queued"), sendState: .sending)),
            (.init(content: .text("failed"), roomKind: .person, sendState: .cannotBeSent), .init(prefix: .none, value: .text("failed"), sendState: .cannotBeSent)),
        ]
        for (event, expected) in cases { XCTAssertEqual(RowPreview.display(for: event, locale: vi), expected) }
        let notice = RowPreview.Event(content: .appNotice([
            .init(localeIdentifier: "en", text: "English"), .init(localeIdentifier: "vi", text: "Tiếng Việt"),
        ]), roomKind: .appBot)
        XCTAssertEqual(RowPreview.display(for: notice, locale: vi).value, .appNotice("Tiếng Việt"))
        XCTAssertEqual(RowPreview.display(for: notice, locale: Locale(identifier: "ja")).value,
                       .appNotice("English"))
        XCTAssertEqual(RowPreview.display(for: notice, locale: Locale(identifier: "fr")).value,
                       .appNotice("English"))
        XCTAssertEqual(RowPreview.flattenMarkdown("[hello](https://example.test)"), "hello")
        XCTAssertEqual(RowPreview.flattenMarkdown("![alt](mxc://example.test/image)"), "alt")
        XCTAssertEqual(RowPreview.flattenMarkdown("**a**\n_b_"), "a b")
    }

    // MARK: RowTime

    func testRowTimeBandsUseOnlyInjectedClockAndCalendar() {
        let now = date(11, 9, 41)
        let locale = Locale(identifier: "vi")
        let cases: [(Date, RowTime.Display)] = [
            (now.addingTimeInterval(-59), .justNow),
            (now.addingTimeInterval(-60), .relative(value: 1, unit: .minute)),
            (now.addingTimeInterval(-59 * 60), .relative(value: 59, unit: .minute)),
            (now.addingTimeInterval(-60 * 60), .relative(value: 1, unit: .hour)),
            (date(11, 0, 1), .relative(value: 9, unit: .hour)),
            (date(10, 1), .yesterday),
            (date(8), .weekday(date(8))),
            (date(1), .date(date(1), includesYear: false)),
            (calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!, .date(calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!, includesYear: true)),
        ]
        for (event, expected) in cases { XCTAssertEqual(RowTime.display(for: event, now: now, calendar: calendar, locale: locale), expected) }
        XCTAssertEqual(RowTime.display(for: now.addingTimeInterval(60), now: now, calendar: calendar,
                                       locale: locale), .justNow)
        XCTAssertEqual(RowTime.display(for: date(10, 23, 50), now: date(11, 0, 10), calendar: calendar,
                                       locale: locale), .relative(value: 20, unit: .minute))
        XCTAssertEqual(RowTime.display(for: date(10, 22), now: date(11, 0, 10), calendar: calendar,
                                       locale: locale), .yesterday)
    }

    // MARK: PushPresentation

    func testPushPresentationTable() {
        let cases: [(PushPresentation.Screen, PushPresentation.Decision)] = [
            (.chat(roomID: "target"), .suppress),
            (.homeRoot, .suppress),
            (.chat(roomID: "other"), .present(PushPresentation.foregroundOptions)),
            (.other, .present(PushPresentation.foregroundOptions)),
        ]
        for (screen, expected) in cases {
            XCTAssertEqual(PushPresentation.decide(screen: screen, notificationRoomID: "target"), expected)
        }
    }

    private func room(_ id: String, _ kind: RosterProjection.Room.Kind,
                      membership: RosterProjection.Room.Membership = .joined, at: Date? = nil,
                      favourite: Bool = false, tag: Int? = nil, hidden: Bool = false,
                      legacy: Bool = false) -> RosterProjection.Room {
        .init(id: id, kind: kind, membership: membership, latestEventAt: at, isFavourite: favourite,
              tagOrder: tag, isHiddenOnThisDevice: hidden, isLegacyEncrypted: legacy)
    }
}
