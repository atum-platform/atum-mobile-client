@testable import AtumChat
import XCTest

/// Wave 2 HC-3, HC-4 and HC-5 pure rules.
final class HomeChatsWave2Tests: XCTestCase {
    // MARK: HC-3 RosterWorking

    func testAnAssistantRoomWorksWhileTheAgentTypes() {
        let working = RosterWorking.rooms(typing: ["!a": ["@agent:x"], "!b": []],
                                          ownUserID: "@me:x", assistantRoomIDs: ["!a", "!b"])
        XCTAssertEqual(working, ["!a"])
    }

    func testMyOwnTypingNeverCountsAsWork() {
        let working = RosterWorking.rooms(typing: ["!a": ["@me:x", ""]],
                                          ownUserID: "@me:x", assistantRoomIDs: ["!a"])
        XCTAssertTrue(working.isEmpty)
    }

    func testOnlyAssistantRoomsEverWork() {
        let working = RosterWorking.rooms(typing: ["!person": ["@lan:x"], "!a": ["@agent:x"]],
                                          ownUserID: "@me:x", assistantRoomIDs: ["!a"])
        XCTAssertEqual(working, ["!a"])
    }

    func testNoTypingReadMeansNoAtom() {
        XCTAssertTrue(RosterWorking.rooms(typing: [:], ownUserID: "@me:x", assistantRoomIDs: ["!a"]).isEmpty)
    }

    // MARK: HC-4 EmptyChatPolicy

    func testAssistantChatsGreetAndOtherChatsSayNoMessages() {
        XCTAssertEqual(EmptyChatPolicy.content(for: .assistant), .assistantGreeting)
        XCTAssertEqual(EmptyChatPolicy.content(for: .person), .noMessages)
        XCTAssertEqual(EmptyChatPolicy.content(for: .group), .noMessages)
        XCTAssertEqual(EmptyChatPolicy.content(for: .appBot), .noMessages)
    }

    func testTimeOfDayFollowsDesktopGreetingFor() {
        XCTAssertEqual(EmptyChatPolicy.period(hour: 4), .evening)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 5), .morning)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 11), .morning)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 12), .afternoon)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 17), .afternoon)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 18), .evening)
        XCTAssertEqual(EmptyChatPolicy.period(hour: 0), .evening)
        XCTAssertEqual(EmptyChatPolicy.greetingKey(.morning), .greetingMorning)
    }

    func testThreeStartersInDesktopOrder() {
        XCTAssertEqual(EmptyChatPolicy.starters.map(\.label), [.starter0Label, .starter1Label, .starter2Label])
        XCTAssertEqual(EmptyChatPolicy.starters.map(\.text), [.starter0Text, .starter1Text, .starter2Text])
    }

    // MARK: HC-5 StartChatQuery

    func testQueriesParseAsDesktopParsePersonQuery() {
        XCTAssertEqual(StartChatQuery.parse("   "), .empty)
        XCTAssertEqual(StartChatQuery.parse("@Lan_99"), .handle("lan_99"))
        XCTAssertEqual(StartChatQuery.parse("lan"), .handle("lan"))
        XCTAssertEqual(StartChatQuery.parse("@lan:atum.chat"), .matrixID("@lan:atum.chat"))
        XCTAssertEqual(StartChatQuery.parse("Lan Nguyen"), .text("Lan Nguyen"))
        XCTAssertEqual(StartChatQuery.parse("la"), .text("la"))
        XCTAssertEqual(StartChatQuery.parse("9lan"), .text("9lan"))
        XCTAssertEqual(StartChatQuery.parse("Đào"), .text("Đào"))
        XCTAssertEqual(StartChatQuery.parse(String(repeating: "a", count: 33)), .text(String(repeating: "a", count: 33)))
        XCTAssertEqual(StartChatQuery.parse("@:x"), .text("@:x"))
        XCTAssertEqual(StartChatQuery.parse("@lan:"), .text("@lan:"))
    }

    func testOnlyHandlesAndAddressesOfferFindOnAtum() {
        XCTAssertEqual(StartChatQuery.parse("@lan").findable, "lan")
        XCTAssertEqual(StartChatQuery.parse("@lan:atum.chat").findable, "lan:atum.chat")
        XCTAssertNil(StartChatQuery.parse("Lan Nguyen").findable)
        XCTAssertNil(StartChatQuery.parse("").findable)
    }
}
