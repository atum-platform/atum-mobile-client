import XCTest
@testable import AtumChat

/// Which image is the notification's big one and which group name it carries,
/// for every room kind, with each fallback.
final class CommunicationNotificationPolicyTests: XCTestCase {
    private typealias Policy = CommunicationNotificationPolicy
    private let face = String(repeating: "a", count: 64) + ".png"

    private func input(sender: String = "Mai", senderAvatar: String? = "mxc://hs.test/mai",
                       room: String? = "Book club", roomAvatar: String? = "mxc://hs.test/room",
                       isDirect: Bool) -> Policy.Input {
        .init(roomID: "!room:hs.test", senderName: sender, senderAvatarURI: senderAvatar,
              roomName: room, roomAvatarURI: roomAvatar, isDirect: isDirect)
    }

    // MARK: Person to person

    func testDirectChatUsesTheSendersAvatar() throws {
        let plan = try XCTUnwrap(Policy.plan(input(room: nil, isDirect: true), entry: nil))
        XCTAssertEqual(plan.style, .person)
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/mai")], "a DM never shows the room's avatar")
        XCTAssertEqual(plan.monogramName, "Mai")
    }

    func testDirectChatWithoutAnAvatarIsTheSendersMonogram() throws {
        let plan = try XCTUnwrap(Policy.plan(input(senderAvatar: nil, isDirect: true), entry: nil))
        XCTAssertEqual(plan.style, .person)
        XCTAssertEqual(plan.images, [])
        XCTAssertEqual(plan.monogramName, "Mai")
    }

    func testMalformedOrNonMatrixAvatarIsNeverFetched() throws {
        for bad in ["https://evil.test/a.png", "mxc://", "mxc://hs.test", "mxc://hs.test/a/b",
                    "mxc://hs.test/a?x=1", "mxc://hs.test/a b", "mxc:///a"] {
            let plan = try XCTUnwrap(Policy.plan(input(senderAvatar: bad, isDirect: true), entry: nil))
            XCTAssertEqual(plan.images, [], bad)
        }
    }

    func testNoSenderKeepsTheGenericNotification() {
        XCTAssertNil(Policy.plan(input(sender: "  ", isDirect: true), entry: nil))
        XCTAssertNil(Policy.plan(input(sender: "", isDirect: false), entry: nil))
    }

    // MARK: Assistant and app chats

    func testAssistantChatUsesTheHeaderFaceTheAppDrew() throws {
        let entry = NotificationRoomEntry(kind: .assistant, faceFile: face, faceName: "Atlas")
        let plan = try XCTUnwrap(Policy.plan(input(sender: "atlas-bot", isDirect: false), entry: entry))
        XCTAssertEqual(plan.style, .person, "an assistant chat is a 1:1 conversation, even if not marked direct")
        XCTAssertEqual(plan.images, [.appFace(face), .matrix("mxc://hs.test/room"), .matrix("mxc://hs.test/mai")])
        XCTAssertEqual(plan.monogramName, "Atlas", "the header's name, not the bot's Matrix name")
    }

    func testAppChatWithoutADrawnFaceFallsBackToTheRoomThenTheBotPhoto() throws {
        let entry = NotificationRoomEntry(kind: .appBot, faceName: "Moon")
        let plan = try XCTUnwrap(Policy.plan(input(sender: "Moon", isDirect: true), entry: entry))
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/room"), .matrix("mxc://hs.test/mai")])
        let bare = try XCTUnwrap(Policy.plan(input(sender: "Moon", senderAvatar: nil, roomAvatar: nil,
                                                    isDirect: true), entry: entry))
        XCTAssertEqual(bare.images, [])
        XCTAssertEqual(bare.monogramName, "Moon")
    }

    func testAFaceFileThatIsNotTheAppsHashIsIgnored() throws {
        for bad in ["../rooms.json", "x.png", String(repeating: "A", count: 64) + ".png", face + "/"] {
            let entry = NotificationRoomEntry(kind: .assistant, faceFile: bad, faceName: "Atlas")
            let plan = try XCTUnwrap(Policy.plan(input(roomAvatar: nil, isDirect: true), entry: entry))
            XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/mai")], bad)
        }
    }

    // MARK: Ordinary groups

    func testGroupUsesTheRoomAvatarAsTheGroupImage() throws {
        let plan = try XCTUnwrap(Policy.plan(input(isDirect: false), entry: nil))
        XCTAssertEqual(plan.style, .group(name: "Book club"))
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/room")], "never the sender's face as the group's")
        XCTAssertEqual(plan.monogramName, "Book club")
    }

    func testGroupWithoutAvatarIsTheGroupsMonogram() throws {
        let plan = try XCTUnwrap(Policy.plan(input(roomAvatar: nil, isDirect: false), entry: nil))
        XCTAssertEqual(plan.images, [])
        XCTAssertEqual(plan.monogramName, "Book club")
    }

    func testGroupWithoutAValidatedNameKeepsPlainContent() {
        XCTAssertNil(Policy.plan(input(room: nil, isDirect: false), entry: nil))
    }

    // MARK: Team Space

    func testChannelIsAGroupNamedLikeTeamSpaceWithTheCompanyLogoFallback() throws {
        let entry = NotificationRoomEntry(kind: .teamChannel, groupName: "# general · Acme",
                                          companyLogoURI: "mxc://hs.test/logo", companyName: "Acme")
        let plan = try XCTUnwrap(Policy.plan(input(room: "general", isDirect: false), entry: entry))
        XCTAssertEqual(plan.style, .group(name: "# general · Acme"))
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/room"), .matrix("mxc://hs.test/logo")])
        XCTAssertEqual(plan.monogramName, "Acme", "with no image the monogram still says which company")
        let noAvatar = try XCTUnwrap(Policy.plan(input(roomAvatar: nil, isDirect: false), entry: entry))
        XCTAssertEqual(noAvatar.images, [.matrix("mxc://hs.test/logo")])
    }

    func testChannelWhoseAvatarIsTheLogoFetchesItOnce() throws {
        let entry = NotificationRoomEntry(kind: .teamChannel, groupName: "# general · Acme",
                                          companyLogoURI: "mxc://hs.test/room", companyName: "Acme")
        let plan = try XCTUnwrap(Policy.plan(input(isDirect: false), entry: entry))
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/room")])
    }

    func testChannelWithoutAppLabelFallsBackToTheRoomName() throws {
        let entry = NotificationRoomEntry(kind: .teamChannel, companyLogoURI: "mxc://hs.test/logo")
        let plan = try XCTUnwrap(Policy.plan(input(room: "general", roomAvatar: nil, isDirect: false), entry: entry))
        XCTAssertEqual(plan.style, .group(name: "general"))
        XCTAssertEqual(plan.monogramName, "general")
    }

    func testTeamConversationIsAGroupWithTheCompanyLogoFallback() throws {
        let entry = NotificationRoomEntry(kind: .teamConversation, groupName: "Launch · Acme",
                                          companyLogoURI: "mxc://hs.test/logo", companyName: "Acme")
        let plan = try XCTUnwrap(Policy.plan(input(roomAvatar: nil, isDirect: false), entry: entry))
        XCTAssertEqual(plan.style, .group(name: "Launch · Acme"))
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/logo")])
    }

    func testTeamDirectConversationIsAPersonChat() throws {
        let entry = NotificationRoomEntry(kind: .teamDirect, groupName: "Anna · Acme",
                                          companyLogoURI: "mxc://hs.test/logo", companyName: "Acme")
        let plan = try XCTUnwrap(Policy.plan(input(isDirect: false), entry: entry))
        XCTAssertEqual(plan.style, .person)
        XCTAssertEqual(plan.images, [.matrix("mxc://hs.test/mai")], "a person's face, never the company logo")
        XCTAssertEqual(plan.monogramName, "Mai")
    }

    // MARK: Directory trust

    func testDirectoryOfAnotherAccountOrVersionIsIgnored() {
        let entry = NotificationRoomEntry(kind: .teamChannel, groupName: "# general · Acme")
        var directory = NotificationRoomDirectory(ownUserID: "@me:hs.test", rooms: ["!room:hs.test": entry])
        XCTAssertEqual(Policy.entry(roomID: "!room:hs.test", ownUserID: "@me:hs.test", directory: directory), entry)
        XCTAssertNil(Policy.entry(roomID: "!room:hs.test", ownUserID: "@other:hs.test", directory: directory))
        XCTAssertNil(Policy.entry(roomID: "!other:hs.test", ownUserID: "@me:hs.test", directory: directory))
        directory.version = 99
        XCTAssertNil(Policy.entry(roomID: "!room:hs.test", ownUserID: "@me:hs.test", directory: directory))
        XCTAssertNil(Policy.entry(roomID: "!room:hs.test", ownUserID: "@me:hs.test", directory: nil))
    }

    func testDirectoryRoundTripsAsJSON() throws {
        let directory = NotificationRoomDirectory(ownUserID: "@me:hs.test", rooms: [
            "!a:hs.test": .init(kind: .assistant, faceFile: face, faceName: "Atlas"),
            "!b:hs.test": .init(kind: .teamChannel, groupName: "# general · Acme",
                                companyLogoURI: "mxc://hs.test/logo", companyName: "Acme"),
        ])
        let decoded = try JSONDecoder().decode(NotificationRoomDirectory.self,
                                               from: JSONEncoder().encode(directory))
        XCTAssertEqual(decoded, directory)
    }

    // MARK: Rich text names feed the intent

    func testRichPresentationCarriesTheValidatedSenderAndRoomNames() {
        let copy = RichPushPresentation.Copy(generic: "New message")
        let group = RichPushPresentation.map(.init(senderID: "@mai:hs.test", senderName: "Mai", roomName: "Book club",
                                                   isDirect: false, kind: .text("Hi")), ownUserID: "@me:hs.test", copy: copy)
        guard case let .content(content) = group else { return XCTFail("expected content") }
        XCTAssertEqual(content.senderName, "Mai"); XCTAssertEqual(content.roomName, "Book club")
        let direct = RichPushPresentation.map(.init(senderID: "@mai:hs.test", senderName: "Mai", roomName: "Mai",
                                                    isDirect: true, kind: .text("Hi")), ownUserID: "@me:hs.test", copy: copy)
        guard case let .content(dm) = direct else { return XCTFail("expected content") }
        XCTAssertEqual(dm.senderName, "Mai"); XCTAssertNil(dm.roomName)
    }
}
