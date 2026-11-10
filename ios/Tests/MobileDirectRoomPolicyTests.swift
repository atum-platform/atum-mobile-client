import XCTest
@testable import AtumNativeAPI

final class MobileDirectRoomPolicyTests: XCTestCase {
    func testAccountDataIsPerTargetDeduplicatedAndStable() throws {
        let raw = #"{"@member:example.test":["!z:example.test","!a:example.test","!z:example.test"],"@other:example.test":["!other:example.test"]}"#
        XCTAssertEqual(try MobileDirectRoomPolicy.roomIDs(accountData: raw, userID: "@member:example.test"), ["!a:example.test", "!z:example.test"])
        XCTAssertEqual(try MobileDirectRoomPolicy.roomIDs(accountData: raw, userID: "@missing:example.test"), [])
        XCTAssertEqual(try MobileDirectRoomPolicy.roomIDs(accountData: nil, userID: "@member:example.test"), [])
        XCTAssertThrowsError(try MobileDirectRoomPolicy.roomIDs(accountData: "broken", userID: "@member:example.test"))
    }

    func testDirectHintRequiresActiveMembershipAndOrdinaryOneToOneRoom() {
        func eligible(joined: Bool = true, space: Bool = false, count: UInt64 = 2,
                      members: [String] = ["@self:example.test", "@member:example.test"], custom: Bool = false) -> Bool {
            MobileDirectRoomPolicy.canReuse(isJoined: joined, isSpace: space,
                activeMemberCount: count, activeMemberIDs: members, target: "@member:example.test",
                hasCustomRoomType: custom)
        }
        XCTAssertTrue(eligible()) // target may be joined or invited
        XCTAssertFalse(eligible(joined: false))
        XCTAssertFalse(eligible(space: true))
        XCTAssertFalse(eligible(count: 3))
        XCTAssertFalse(eligible(members: ["@self:example.test"]))
        XCTAssertFalse(eligible(custom: true))
    }
}
