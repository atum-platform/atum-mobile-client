import XCTest
@testable import AtumChat

final class ChatExitPolicyTests: XCTestCase {
    func testPeopleDeleteAndGroupsLeave() {
        XCTAssertEqual(ChatExitPolicy.action(for: .person, viewerIsFounder: false), .deleteChat)
        XCTAssertEqual(ChatExitPolicy.action(for: .group, viewerIsFounder: false), .leaveGroup)
        XCTAssertEqual(ChatExitPolicy.action(for: .person, viewerIsFounder: true), .deleteChat)
    }

    /// Assistant, app-bot, team space, system rooms and invitations never offer an exit;
    /// the Founder chat only to people who are not the Founder.
    func testProtectedRoomsOfferNoExit() {
        for room in [ChatExitPolicy.Room.assistant, .appBot, .teamSpace, .system, .invitation] {
            for founder in [false, true] {
                XCTAssertNil(ChatExitPolicy.action(for: room, viewerIsFounder: founder), "\(room)")
            }
        }
        XCTAssertEqual(ChatExitPolicy.action(for: .founder, viewerIsFounder: false), .deleteChat)
        XCTAssertNil(ChatExitPolicy.action(for: .founder, viewerIsFounder: true))
    }

    func testOnlyPeopleCanBeIgnoredAndNeverYourselfOrAnAssistant() {
        XCTAssertTrue(ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: false,
                                               in: .person, viewerIsFounder: false))
        XCTAssertTrue(ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: false,
                                               in: .group, viewerIsFounder: false))
        XCTAssertFalse(ChatExitPolicy.mayIgnore(memberIsAssistant: true, memberIsSelf: false,
                                                in: .group, viewerIsFounder: false))
        XCTAssertFalse(ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: true,
                                                in: .group, viewerIsFounder: false))
        for room in [ChatExitPolicy.Room.assistant, .appBot, .teamSpace, .system, .invitation] {
            XCTAssertFalse(ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: false,
                                                    in: room, viewerIsFounder: false), "\(room)")
        }
        XCTAssertFalse(ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: false,
                                                in: .founder, viewerIsFounder: true))
    }
}
