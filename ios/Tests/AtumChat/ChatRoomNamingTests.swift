import XCTest
@testable import AtumChat

/// HC-7: Rename's private name (`io.atum.title`) and the menu rules, against
/// desktop `conversations.ts` `matrixChatTitle` and `roster-model.ts`.
final class ChatRoomNamingTests: XCTestCase {
    func testAStoredNameIsOneBoundedLine() {
        XCTAssertEqual(ChatPrivateTitle.title(eventJSON: #"{"type":"io.atum.title","content":{"title":"  Nhà\n mình  "}}"#),
                       "Nhà mình")
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: #"{"type":"io.atum.title","content":{}}"#), "cleared")
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: #"{"type":"io.atum.other","content":{"title":"x"}}"#))
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: #"{"type":"io.atum.title","content":{"title":7}}"#))
        let long = String(repeating: "a", count: 81)
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: #"{"type":"io.atum.title","content":{"title":"\#(long)"}}"#))
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: nil))
        XCTAssertNil(ChatPrivateTitle.title(eventJSON: "not json"))
    }

    func testSavingWritesTheTitleOrClearsIt() {
        XCTAssertEqual(ChatPrivateTitle.content("  Gia\tđình "), ["title": "Gia đình"])
        XCTAssertEqual(ChatPrivateTitle.content("   "), [:], "an empty private name clears it")
        XCTAssertTrue(ChatPrivateTitle.canSave("", shared: false))
        XCTAssertFalse(ChatPrivateTitle.canSave("  ", shared: true), "a group's shared name is never empty")
        XCTAssertFalse(ChatPrivateTitle.canSave(String(repeating: "b", count: 81), shared: false))
    }

    func testTopicIsOneLineCutToTheGroupBound() {
        XCTAssertEqual(ChatGroupTopic.normalized("a\nb"), "a b")
        XCTAssertEqual(ChatGroupTopic.normalized(String(repeating: "t", count: 600)).count, 500)
    }

    func testMenuRules() {
        XCTAssertTrue(ChatMenuPolicy.offersRename(.person))
        XCTAssertTrue(ChatMenuPolicy.offersRename(.group))
        for room: ChatMenuPolicy.Room in [.founder, .notesSelf, .assistant, .appBot, .teamSpace] {
            XCTAssertFalse(ChatMenuPolicy.offersRename(room), "\(room)")
        }
        XCTAssertTrue(ChatMenuPolicy.renamesForEveryone(.group, canName: true))
        XCTAssertFalse(ChatMenuPolicy.renamesForEveryone(.group, canName: false), "then it is your own name")
        XCTAssertFalse(ChatMenuPolicy.renamesForEveryone(.person, canName: true))

        XCTAssertEqual(ChatMenuPolicy.blockablePeer(.person, memberUserIDs: [F.me, F.friend], ownUserID: F.me,
                                                    nonPersonUserIDs: []), F.friend)
        XCTAssertNil(ChatMenuPolicy.blockablePeer(.group, memberUserIDs: [F.friend], ownUserID: F.me,
                                                  nonPersonUserIDs: []))
        XCTAssertNil(ChatMenuPolicy.blockablePeer(.person, memberUserIDs: [F.friend, F.other], ownUserID: F.me,
                                                  nonPersonUserIDs: []), "not one other person")
        XCTAssertNil(ChatMenuPolicy.blockablePeer(.person, memberUserIDs: [F.agent], ownUserID: F.me,
                                                  nonPersonUserIDs: [F.agent]), "never an assistant")
    }
}
