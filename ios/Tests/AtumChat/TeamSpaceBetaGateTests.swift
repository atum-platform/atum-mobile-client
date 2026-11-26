import AtumChat
import XCTest

/// Desktop #132 (`app.test.tsx` "without beta features greys Team space as
/// \"Coming soon\" and never opens a company channel").
final class TeamSpaceBetaGateTests: XCTestCase {
    func testFlagChoosesTheGate() {
        XCTAssertEqual(TeamSpaceBetaGate(betaFeatures: true), .open)
        XCTAssertEqual(TeamSpaceBetaGate(betaFeatures: false), .comingSoon)
        XCTAssertFalse(TeamSpaceBetaGate.open.isComingSoon)
        XCTAssertTrue(TeamSpaceBetaGate.comingSoon.isComingSoon)
    }

    func testGatedTabIsNamedComingSoonAndCarriesNoMark() {
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.tabLabel(title: "Team space", comingSoon: "Coming soon"),
                       "Team space · Coming soon")
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.tabLabel(title: "Không gian nhóm", comingSoon: "Sắp có"),
                       "Không gian nhóm · Sắp có")
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.tabBadge(.mention(3)), .none)
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.tabBadge(.dot), .none)
    }

    func testBetaAccountTabIsUnchanged() {
        XCTAssertEqual(TeamSpaceBetaGate.open.tabLabel(title: "Team space", comingSoon: "Coming soon"), "Team space")
        XCTAssertEqual(TeamSpaceBetaGate.open.tabBadge(.mention(3)), .mention(3))
        XCTAssertEqual(TeamSpaceBetaGate.open.tabBadge(.none), .none)
    }

    func testTeamSpaceRoutesLandOnComingSoonOnlyWhenGated() {
        // Notifications, room links and selected company rooms: the same page, never the room.
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.landing(routesToTeamSpace: true), .comingSoon)
        // Personal chats (and the assistants Settings opens) still open.
        XCTAssertEqual(TeamSpaceBetaGate.comingSoon.landing(routesToTeamSpace: false), .room)
        XCTAssertEqual(TeamSpaceBetaGate.open.landing(routesToTeamSpace: true), .room)
        XCTAssertEqual(TeamSpaceBetaGate.open.landing(routesToTeamSpace: false), .room)
    }

    func testClosingTheGateClosesAnOpenTeamSpaceRoom() {
        XCTAssertTrue(TeamSpaceBetaGate.comingSoon.closesOpenRoom(teamSpaceRoomID: "!launch:atum.test"))
        XCTAssertFalse(TeamSpaceBetaGate.comingSoon.closesOpenRoom(teamSpaceRoomID: nil))
        XCTAssertFalse(TeamSpaceBetaGate.open.closesOpenRoom(teamSpaceRoomID: "!launch:atum.test"))
    }
}
