import XCTest
@testable import AtumChat

/// Plan S1 T for B16: runs break on a 5-minute gap, a sender change, a day
/// boundary and a visible divider; the sender line only at a run's start; a
/// time label after 60 minutes, unless a day divider already sits there.
final class GroupingTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func rows(_ items: [ChatItem]) -> [ChatRow] { items.map { ChatRow(item: $0) } }

    private func positions(_ items: [ChatItem], context: RoomContext = F.botRoom()) -> [RunPosition?] {
        Grouping.layout(rows(items), context: context, calendar: utc).map(\.position)
    }

    private func at(_ minute: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minute * 60) }

    private func text(_ id: String, from sender: String, minute: Double) -> ChatItem {
        var item = F.text(id, from: sender)
        item.timestamp = at(minute)
        if sender == F.me { item.isOwn = true }
        return item
    }

    // MARK: Runs

    func testConsecutiveMessagesWithinFiveMinutesFormOneRun() {
        let items = [text("a", from: F.bot, minute: 0), text("b", from: F.bot, minute: 3),
                     text("c", from: F.bot, minute: 8)]
        XCTAssertEqual(positions(items), [.first, .middle, .last],
                       "each within 5 minutes of the previous one, not of the first")
    }

    func testAGapOfMoreThanFiveMinutesStartsANewRun() {
        let items = [text("a", from: F.bot, minute: 0), text("b", from: F.bot, minute: 5),
                     text("c", from: F.bot, minute: 10.01)]
        XCTAssertEqual(positions(items), [.first, .last, .single], "exactly 5 minutes still continues")
    }

    func testASenderChangeBreaksTheRunAndMyOwnMessagesFormRunsToo() {
        let items = [text("a", from: F.bot, minute: 0), text("q1", from: F.me, minute: 1),
                     text("q2", from: F.me, minute: 2), text("b", from: F.bot, minute: 3)]
        XCTAssertEqual(positions(items), [.single, .first, .last, .single])
    }

    func testADayBoundaryBreaksTheRunEvenWithDividersHidden() {
        // 23:58 and 00:01 UTC: three minutes apart, on two days.
        let midnight = utc.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000 + 86_400))
        var late = F.text("late", from: F.bot)
        late.timestamp = midnight.addingTimeInterval(-120)
        var early = F.text("early", from: F.bot)
        early.timestamp = midnight.addingTimeInterval(60)
        XCTAssertEqual(positions([late, early]), [.single, .single])
    }

    func testAVisibleDividerReadMarkerOrSyntheticRowBreaksTheRun() {
        let divider = ChatItem(id: "d", kind: .dayDivider(at(0)))
        XCTAssertEqual(positions([text("a", from: F.bot, minute: 0), divider, text("b", from: F.bot, minute: 1)]),
                       [.single, nil, .single])
        XCTAssertEqual(positions([text("a", from: F.bot, minute: 0), F.readMarker(), text("b", from: F.bot, minute: 1)]),
                       [.single, nil, .single])
        let typing = ChatItem(id: Projection.typingRowID, kind: .typing(names: ["Moon"]))
        XCTAssertEqual(positions([text("a", from: F.bot, minute: 0), typing]), [.single, nil])
    }

    func testANoticeIsNotInARunAndDoesNotBreakOne() {
        var notice = F.notice("n", from: F.bot)
        notice.timestamp = at(1)
        let items = [text("a", from: F.bot, minute: 0), notice, text("b", from: F.bot, minute: 2)]
        XCTAssertEqual(positions(items), [.first, nil, .last])
    }

    func testImagesFilesAndPlaceholdersAreBubblesInRuns() {
        var image = F.text("i", from: F.friend)
        image.kind = .image(width: 100, height: 80)
        image.timestamp = at(1)
        var file = F.text("f", from: F.friend)
        file.kind = .file(name: "a.pdf")
        file.timestamp = at(2)
        var deleted = F.text("x", from: F.friend)
        deleted.kind = .placeholder(.redacted)
        deleted.timestamp = at(3)
        let group = RoomContext(kind: .group, ownUserID: F.me)
        XCTAssertEqual(positions([text("t", from: F.friend, minute: 0), image, file, deleted], context: group),
                       [.first, .middle, .middle, .last])
    }

    // MARK: Sender line

    func testTheSenderLineShowsOnlyAtTheStartOfARunInGroups() {
        let items = [text("f1", from: F.friend, minute: 0), text("f2", from: F.friend, minute: 1),
                     text("f3", from: F.friend, minute: 20), text("o1", from: F.other, minute: 21)]
        let group = RoomContext(kind: .group, ownUserID: F.me)
        let layout = Grouping.layout(rows(items), context: group, calendar: utc)
        XCTAssertEqual(layout.map(\.showsSender), [true, false, true, true],
                       "a new run after a 5-minute gap names the sender again")
        let bot = [text("b1", from: F.bot, minute: 0), text("b2", from: F.bot, minute: 1)]
        XCTAssertEqual(Grouping.layout(rows(bot), context: F.groupWithApp(), calendar: utc).map(\.showsSender),
                       [true, false], "an app in a group is named like any member")
        XCTAssertEqual(Grouping.layout(rows(bot), context: F.botRoom(), calendar: utc).map(\.showsSender),
                       [false, false], "an app's own chat names nobody (owner, 2026-11-05)")
    }

    func testNoSenderLineInMyAssistantChatInAOneToOnePeopleChatOrOnMyMessages() {
        let items = [text("a", from: F.agent, minute: 0), text("q", from: F.me, minute: 1)]
        XCTAssertEqual(Grouping.layout(rows(items), context: F.assistantRoom(), calendar: utc).map(\.showsSender),
                       [false, false])
        let person = [text("f", from: F.friend, minute: 0), text("q", from: F.me, minute: 1)]
        XCTAssertEqual(Grouping.layout(rows(person), context: F.personRoom(), calendar: utc).map(\.showsSender),
                       [false, false], "coordinator decision: 1:1 people rooms show no name")
        let group = RoomContext(kind: .group, ownUserID: F.me)
        XCTAssertEqual(Grouping.layout(rows([text("q", from: F.me, minute: 0)]), context: group,
                                       calendar: utc).map(\.showsSender), [false])
    }

    // MARK: Time labels

    func testATimeLabelFollowsAGapOfSixtyMinutesOrMore() {
        let items = [text("a", from: F.bot, minute: 0), text("b", from: F.me, minute: 59),
                     text("c", from: F.bot, minute: 119), text("d", from: F.bot, minute: 120)]
        let labels = Grouping.layout(rows(items), context: F.botRoom(), calendar: utc).map(\.timeLabel)
        XCTAssertEqual(labels, [nil, nil, at(119), nil], "59 minutes: none; exactly 60: a label")
    }

    func testTheDayDividerWinsOverTheTimeLabel() {
        let divider = ChatItem(id: "d", kind: .dayDivider(at(600)))
        let items = [text("a", from: F.bot, minute: 0), divider, text("b", from: F.bot, minute: 600)]
        let labels = Grouping.layout(rows(items), context: F.botRoom(), calendar: utc).map(\.timeLabel)
        XCTAssertEqual(labels, [nil, nil, nil])
    }

    func testNoticesCountForTheGapAndTheFirstRowHasNoLabel() {
        var notice = F.notice("n", from: F.agent)
        notice.timestamp = at(50)
        let items = [text("q", from: F.me, minute: 0), notice, text("a", from: F.agent, minute: 100)]
        let labels = Grouping.layout(rows(items), context: F.assistantRoom(), calendar: utc).map(\.timeLabel)
        XCTAssertEqual(labels, [nil, nil, nil], "50 minutes after the notice, not 100 after the question")
    }
}

/// Plan S1 T for B14: today, yesterday, the weekday for two to six days ago,
/// otherwise the date; in the given time zone and the app's language.
final class DayLabelTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testVietnameseLabelsForEachRange() {
        let saigon = calendar("Asia/Ho_Chi_Minh")
        let vi = Locale(identifier: "vi")
        let now = date(saigon, 2026, 10, 10, 9) // Saturday
        func label(_ day: Int, month: Int = 10, year: Int = 2026) -> String {
            DayLabel.text(for: date(saigon, year, month, day), now: now, calendar: saigon, locale: vi)
        }
        XCTAssertEqual(label(10), "Hôm nay")
        XCTAssertEqual(label(9), "Hôm qua")
        XCTAssertEqual(label(8), "Thứ Năm", "two days ago is the weekday, never \"Hôm kia\"")
        XCTAssertEqual(label(5), "Thứ Hai")
        XCTAssertEqual(label(4), "Chủ Nhật", "six days ago is still the weekday")
        XCTAssertEqual(label(3), "3 tháng 10", "seven days ago is the date")
        XCTAssertEqual(label(10, year: 2025), "ngày 10 tháng 10, 2025", "another year shows the year")
    }

    func testTheAppLanguageNotTheDeviceLocalePicksTheWords() {
        let utc = calendar("UTC")
        let now = date(utc, 2026, 10, 10)
        let en = Locale(identifier: "en")
        XCTAssertEqual(DayLabel.text(for: now, now: now, calendar: utc, locale: en), "Today")
        XCTAssertEqual(DayLabel.text(for: date(utc, 2026, 10, 9), now: now, calendar: utc, locale: en), "Yesterday")
        XCTAssertEqual(DayLabel.text(for: date(utc, 2026, 10, 5), now: now, calendar: utc, locale: en), "Monday")
    }

    func testTheDayIsJudgedInTheCalendarsTimeZone() {
        // 2026-10-09 20:00 UTC is already 10-10 03:00 in Saigon.
        let instant = date(calendar("UTC"), 2026, 10, 9, 20)
        let now = date(calendar("UTC"), 2026, 10, 10, 4)
        let vi = Locale(identifier: "vi")
        XCTAssertEqual(DayLabel.text(for: instant, now: now, calendar: calendar("UTC"), locale: vi), "Hôm qua")
        XCTAssertEqual(DayLabel.text(for: instant, now: now, calendar: calendar("Asia/Ho_Chi_Minh"), locale: vi),
                       "Hôm nay")
    }

    func testAFutureDayShowsItsDate() {
        let utc = calendar("UTC")
        let now = date(utc, 2026, 10, 10)
        XCTAssertEqual(DayLabel.text(for: date(utc, 2026, 10, 12), now: now, calendar: utc,
                                     locale: Locale(identifier: "vi")), "12 tháng 10")
    }
}
