import XCTest
@testable import AtumChat
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// assistant, an app: "app chat matches agent chat and person chat - we want
/// consistency"); in a group the sender's face
/// sits only beside the last bubble of a run and the name only above the
/// first; a run breaks on a sender change, a day change and a long gap.
final class BubbleFaceGroupingTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let group = RoomContext(kind: .group, ownUserID: F.me)

    private func at(_ minute: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minute * 60) }

    private func text(_ id: String, from sender: String, minute: Double) -> ChatItem {
        var item = F.text(id, from: sender)
        item.timestamp = at(minute)
        if sender == F.me { item.isOwn = true }
        return item
    }

    private func layout(_ items: [ChatItem], _ context: RoomContext) -> [RowGrouping] {
        Grouping.layout(items.map { ChatRow(item: $0) }, context: context, calendar: utc)
    }

    func testOneToOneChatsShowNoFaceAnywhere() {
        let items = [text("a", from: F.friend, minute: 0), text("b", from: F.friend, minute: 1),
                     text("q", from: F.me, minute: 2), text("c", from: F.friend, minute: 3)]
        XCTAssertEqual(layout(items, F.personRoom()).map(\.showsFace), [false, false, false, false])
        let agent = [text("a", from: F.agent, minute: 0), text("b", from: F.agent, minute: 1)]
        XCTAssertEqual(layout(agent, F.assistantRoom()).map(\.showsFace), [false, false],
                       "my assistant's chat")
        let bot = [text("a", from: F.bot, minute: 0), text("b", from: F.bot, minute: 1)]
        XCTAssertEqual(layout(bot, F.botRoom()).map(\.showsFace), [false, false], "an app's chat")
    }

    func testAnAppsChatLaysOutExactlyLikeAPersonsAndMyAssistants() {
        // The same timeline from the other side's point of view: two runs
        // around one message of mine, a long gap, a day change.
        func timeline(_ other: String) -> [ChatItem] {
            [text("a", from: other, minute: 0), text("b", from: other, minute: 1),
             text("q", from: F.me, minute: 2), text("c", from: other, minute: 3),
             text("d", from: other, minute: 70), text("e", from: other, minute: 1500)]
        }
        let person = layout(timeline(F.friend), F.personRoom())
        let assistant = layout(timeline(F.agent), F.assistantRoom())
        let app = layout(timeline(F.bot), F.botRoom())
        XCTAssertEqual(app, person, "names, faces, run breaks and run times")
        func shape(_ value: [RowGrouping]) -> [RowGrouping] {
            value.map { RowGrouping(position: $0.position, showsSender: $0.showsSender, showsFace: $0.showsFace) }
        }
        XCTAssertEqual(shape(app), shape(assistant), "names, faces and run breaks")
        // Desktop: every answer of my agent carries its time; an app's or a
        // person's messages only at the end of a run (TL-4).
        XCTAssertEqual(assistant.map(\.showsTime), [true, true, true, true, true, true])
        XCTAssertEqual(app.map(\.showsTime), [false, true, true, true, true, true])
        XCTAssertEqual(app.map(\.showsSender), [false, false, false, false, false, false])
        XCTAssertEqual(app.map(\.position), [.first, .last, .single, .single, .single, .single])
    }

    func testAnAppInAGroupIsNamedAboveItsFirstBubbleAndShowsItsFaceBesideTheLast() {
        let items = [text("f", from: F.friend, minute: 0),
                     text("b1", from: F.bot, minute: 1), text("b2", from: F.bot, minute: 2)]
        let result = layout(items, F.groupWithApp())
        XCTAssertEqual(result.map(\.showsSender), [true, true, false])
        XCTAssertEqual(result.map(\.showsFace), [true, false, true])
    }

    func testOneToOneChatsShowNoName() {
        XCTAssertEqual(RoomKind.allCases.filter(\.showsSenderLine), [.group])
    }

    func testOnlyAGroupsMembersWearTheirOwnFaces() {
        XCTAssertEqual(RoomKind.allCases.filter { !$0.senderWearsRoomFace }, [.group],
                       "in a group the room's face is the group's, never an app's or assistant's")
    }

    func testAnAppMemberIsASquircleAndPeopleAndAssistantsAreCircles() {
        XCTAssertEqual(AvatarShapePolicy.frame(for: .member(isApp: true, isAssistant: true)), .squircle)
        XCTAssertEqual(AvatarShapePolicy.frame(for: .member(isApp: true, isAssistant: false)), .squircle)
        XCTAssertEqual(AvatarShapePolicy.frame(for: .member(isApp: false, isAssistant: true)), .circle)
        XCTAssertEqual(AvatarShapePolicy.frame(for: .member(isApp: false, isAssistant: false)), .circle)
    }

    func testAGroupRunOfThreeHasTheFaceOnTheLastAndTheNameOnTheFirst() {
        let items = [text("a", from: F.friend, minute: 0), text("b", from: F.friend, minute: 1),
                     text("c", from: F.friend, minute: 2)]
        let result = layout(items, group)
        XCTAssertEqual(result.map(\.position), [.first, .middle, .last])
        XCTAssertEqual(result.map(\.showsFace), [false, false, true])
        XCTAssertEqual(result.map(\.showsSender), [true, false, false])
    }

    func testASingleBubbleRunHasBothTheNameAndTheFace() {
        let result = layout([text("a", from: F.friend, minute: 0)], group)
        XCTAssertEqual(result.map(\.showsFace), [true])
        XCTAssertEqual(result.map(\.showsSender), [true])
    }

    func testASenderChangeEndsTheRunAndMyOwnBubblesNeverShowAFace() {
        let items = [text("f1", from: F.friend, minute: 0), text("f2", from: F.friend, minute: 1),
                     text("o1", from: F.other, minute: 2),
                     text("m1", from: F.me, minute: 3), text("m2", from: F.me, minute: 4),
                     text("f3", from: F.friend, minute: 5)]
        let result = layout(items, group)
        XCTAssertEqual(result.map(\.showsFace), [false, true, true, false, false, true])
        XCTAssertEqual(result.map(\.showsSender), [true, false, true, false, false, true])
    }

    func testADayChangeEndsTheRun() {
        let midnight = utc.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000 + 86_400))
        var late = F.text("late", from: F.friend)
        late.timestamp = midnight.addingTimeInterval(-120)
        var early = F.text("early", from: F.friend)
        early.timestamp = midnight.addingTimeInterval(60)
        let divider = ChatItem(id: "d", kind: .dayDivider(midnight))
        XCTAssertEqual(layout([late, divider, early], group).map(\.showsFace), [true, false, true],
                       "the SDK's day divider sits between them")
        XCTAssertEqual(layout([late, early], group).map(\.showsFace), [true, true],
                       "the calendar day breaks the run even without the divider row")
    }

    func testAGapOfMoreThanFiveMinutesEndsTheRun() {
        let items = [text("a", from: F.friend, minute: 0), text("b", from: F.friend, minute: 5),
                     text("c", from: F.friend, minute: 10.5), text("d", from: F.friend, minute: 11)]
        let result = layout(items, group)
        XCTAssertEqual(result.map(\.showsFace), [false, true, false, true])
        XCTAssertEqual(result.map(\.showsSender), [true, false, true, false])
    }

    func testANoticeInsideARunKeepsTheFaceOnTheLastBubble() {
        var notice = F.notice("n", from: F.friend)
        notice.timestamp = at(1)
        let items = [text("a", from: F.friend, minute: 0), notice, text("b", from: F.friend, minute: 2)]
        XCTAssertEqual(layout(items, group).map(\.showsFace), [false, false, true])
    }

    func testTheFaceMovesToANewLastBubbleWhenTheRunGrows() {
        let first = [text("a", from: F.friend, minute: 0), text("b", from: F.friend, minute: 1)]
        XCTAssertEqual(layout(first, group).map(\.showsFace), [false, true])
        let grown = first + [text("c", from: F.friend, minute: 2)]
        XCTAssertEqual(layout(grown, group).map(\.showsFace), [false, false, true])
    }

    func testOnlyGroupsShowFaces() {
        XCTAssertEqual(RoomKind.allCases.filter(\.showsSenderFace), [.group])
    }
}
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
final class BubbleGeometryTests: XCTestCase {
    func testTheWidestBubbleIsSeventyEightPercentOfTheRow() {
        XCTAssertEqual(BubbleGeometry.maxWidth(row: 370), 288)
        XCTAssertEqual(BubbleGeometry.maxWidth(row: 370, gutter: 31), 288,
                       "the group's face gutter does not narrow a long bubble")
    }

    func testTheGutterOnlyNarrowsTheBubbleWhenItWouldOverflowTheRow() {
        XCTAssertEqual(BubbleGeometry.maxWidth(row: 200, gutter: 80), 120)
        XCTAssertEqual(BubbleGeometry.maxWidth(row: 100, gutter: 31), 96, "never below the minimum")
    }

    func testShortTextGetsASmallBubbleAndLongTextGrowsToTheLimit() {
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [42], natural: [42], limit: 288), 42)
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [180.2], natural: [180.2], limit: 288), 181)
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [281], natural: [900], limit: 288), 281,
                       "wrapped text: its longest line")
    }

    func testAStretchyPartTakesTheTextsWidthOrItsOwnNaturalWidth() {
        // Text 60 wide, a row of buttons that would fill 288 but needs 140.
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [60, 288], natural: [60, 140], limit: 288), 140)
        // Text 200 wide, a rule that needs almost nothing.
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [200, 288], natural: [200, 1], limit: 288), 200)
        // A long code line never pushes past the limit.
        XCTAssertEqual(BubbleGeometry.hugWidth(fitted: [288], natural: [640], limit: 288), 288)
    }
}
