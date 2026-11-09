import XCTest
@testable import AtumChat

/// §2.3 rule 2: display IDs stay stable across my send's remote echo, and
/// across a rebuilt timeline (a token renewal) for every row: remote events,
/// messages sent from this phone, day dividers, the read marker and the
/// start header.
final class DisplayIdentityTests: XCTestCase {
    func testARemoteEventIsKeyedByItsEventIDAcrossTimelines() {
        var first = DisplayIdentityTable()
        var second = DisplayIdentityTable()
        XCTAssertEqual(first.id(uniqueID: "7", ref: .event("$a")), "$a")
        XCTAssertEqual(second.id(uniqueID: "42", ref: .event("$a")), "$a",
                       "a renewed session's timeline gives the same row the same ID")
    }

    func testMyEchoKeepsItsIDWhenTheRemoteCopyKeepsTheUniqueID() {
        var table = DisplayIdentityTable()
        let echo = table.id(uniqueID: "9", ref: .transaction("t1"))
        XCTAssertEqual(echo, "local.t1")
        XCTAssertEqual(table.id(uniqueID: "9", ref: .transaction("t1"), sentEventID: "$m"), echo)
        XCTAssertEqual(table.id(uniqueID: "9", ref: .event("$m")), echo)
    }

    func testMyEchoKeepsItsIDEvenIfTheRemoteCopyComesWithANewUniqueID() {
        var table = DisplayIdentityTable()
        let echo = table.id(uniqueID: "9", ref: .transaction("t1"))
        _ = table.id(uniqueID: "9", ref: .transaction("t1"), sentEventID: "$m")
        XCTAssertEqual(table.id(uniqueID: "12", ref: .event("$m")), echo, "the alias carries it over")
    }

    func testMyPhoneSentMessageKeepsItsIDInTheNextTimeline() {
        var first = DisplayIdentityTable()
        let echo = first.id(uniqueID: "9", ref: .transaction("t1"), sentEventID: "$m")
        var second = DisplayIdentityTable(aliases: first.aliases)
        XCTAssertEqual(second.id(uniqueID: "0", ref: .event("$m")), echo,
                       "the rebuilt timeline only has the remote copy, under the same ID")
    }

    func testAnEchoStillSendingKeepsItsIDInTheNextTimeline() {
        var first = DisplayIdentityTable()
        var second = DisplayIdentityTable(aliases: first.aliases)
        XCTAssertEqual(first.id(uniqueID: "9", ref: .transaction("t1")),
                       second.id(uniqueID: "3", ref: .transaction("t1")),
                       "the send queue's transaction ID is the same in every timeline")
    }

    func testUniqueIDsCountingAgainInANewTimelineNeverCollide() {
        var first = DisplayIdentityTable()
        let mine = first.id(uniqueID: "5", ref: .transaction("t1"), sentEventID: "$m")
        var second = DisplayIdentityTable(aliases: first.aliases)
        let other = second.id(uniqueID: "5", ref: .transaction("t2"))
        XCTAssertNotEqual(mine, other)
        XCTAssertEqual(second.id(uniqueID: "6", ref: .event("$m")), mine)
    }

    func testVirtualItemsAreKeyedByWhatTheyAre() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let evening = morning.addingTimeInterval(8 * 3600)
        let table = DisplayIdentityTable()
        let firstDivider = table.id(uniqueID: "3", virtual: .dayDivider(morning), calendar: calendar)
        XCTAssertEqual(firstDivider, table.id(uniqueID: "77", virtual: .dayDivider(evening), calendar: calendar),
                       "one day, one divider ID, whatever timeline made it")
        XCTAssertNotEqual(firstDivider, table.id(uniqueID: "3", virtual: .dayDivider(morning.addingTimeInterval(86_400)),
                                                 calendar: calendar))
        XCTAssertEqual(table.id(uniqueID: "4", virtual: .readMarker), table.id(uniqueID: "40", virtual: .readMarker))
        XCTAssertEqual(table.id(uniqueID: "5", virtual: .timelineStart),
                       table.id(uniqueID: "50", virtual: .timelineStart))
        XCTAssertEqual(table.id(uniqueID: "6", virtual: nil), "virtual.6", "an item the bindings do not define")
    }

    func testKeySpacesStayApart() {
        var table = DisplayIdentityTable()
        let ids = [table.id(uniqueID: "4", ref: .transaction("t")), table.id(uniqueID: "5", virtual: .readMarker),
                   table.id(uniqueID: "6", ref: .event("$e"))]
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertFalse(ids.contains { $0.hasPrefix("atum.") }, "atum. belongs to synthetic rows and held sends")
    }

    func testAResetKeepsTheIDsOfItemsItBringsBackAndAliasesOutliveTheirRow() {
        var table = DisplayIdentityTable()
        let echo = table.id(uniqueID: "9", ref: .transaction("t1"), sentEventID: "$m")
        _ = table.id(uniqueID: "1", ref: .event("$old"))
        table.beginReset()
        XCTAssertEqual(table.id(uniqueID: "9", ref: .event("$m")), echo, "the reset brought my message back")
        table.finishBatch()
        table.beginReset()
        table.finishBatch()
        XCTAssertEqual(table.id(uniqueID: "14", ref: .event("$m")), echo,
                       "gone from the buffer and paged back in later: still the same row")
    }
}
