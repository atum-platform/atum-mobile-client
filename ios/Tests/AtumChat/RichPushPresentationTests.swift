import XCTest
@testable import AtumChat

final class RichPushPresentationTests: XCTestCase {
    private let copy = RichPushPresentation.Copy(generic: "New message", unnamed: "Atum user", image: "Photo",
        video: "Video", audio: "Audio", file: "File", sticker: "Sticker", invite: "Invited you to chat")
    private func item(_ kind: RichPushItem.Kind, direct: Bool = true, name: String? = "Mai",
                      room: String? = "Book club", sender: String = "@mai:example.test") -> RichPushItem {
        .init(senderID: sender, senderName: name, roomName: room, isDirect: direct, kind: kind)
    }
    private func content(_ item: RichPushItem, copy: RichPushPresentation.Copy? = nil) throws -> RichPushPresentation.Content {
        guard case let .content(value) = RichPushPresentation.map(item, ownUserID: "@me:example.test", copy: copy ?? self.copy)
        else { throw Failure.noContent }
        return value
    }
    private enum Failure: Error { case noContent }

    func testDirectTextAndNoticeUseSenderTitle() throws {
        for kind in [RichPushItem.Kind.text("Hello"), .notice("Hello")] {
            let value = try content(item(kind))
            XCTAssertEqual(value.title, "Mai"); XCTAssertEqual(value.subtitle, ""); XCTAssertEqual(value.body, "Hello")
        }
    }
    func testGroupUsesRoomTitleAndSenderSubtitle() throws {
        let value = try content(item(.text("Hello"), direct: false))
        XCTAssertEqual(value.title, "Book club"); XCTAssertEqual(value.subtitle, "Mai"); XCTAssertEqual(value.body, "Hello")
    }
    func testEmoteIncludesNameInAction() throws {
        XCTAssertEqual(try content(item(.emote("waves"))).body, "Mai waves")
    }
    func testMediaAndInvitesUseExportedCopy() throws {
        let cases: [(RichPushItem.Kind, String)] = [(.image, "Photo"), (.video, "Video"), (.audio, "Audio"),
            (.file, "File"), (.sticker, "Sticker"), (.invite, "Invited you to chat"), (.location, "New message")]
        for (kind, expected) in cases { XCTAssertEqual(try content(item(kind)).body, expected) }
    }
    func testMissingMediaCopyKeepsGenericBody() throws {
        let missing = RichPushPresentation.Copy(generic: "New message", unnamed: "Atum user")
        for kind in [RichPushItem.Kind.image, .video, .audio, .file, .sticker, .invite, .location] {
            XCTAssertEqual(try content(item(kind), copy: missing).body, "New message")
        }
    }
    func testNamesNeverFallBackToIDsLocalpartsOrServers() throws {
        for raw in [nil, "", "@mai:example.test", "mai", "example.test", "another.test", "Other (@other:example.test)"] as [String?] {
            XCTAssertEqual(try content(item(.text("Hello"), name: raw)).title, "Atum user")
        }
        XCTAssertEqual(try content(item(.text("Hello"), name: "Mai (@mai:example.test)")).title, "Mai")
        let noFallback = RichPushPresentation.Copy(generic: "New message")
        XCTAssertEqual(RichPushPresentation.map(item(.text("Hello"), name: nil), ownUserID: "me", copy: noFallback), .generic)
    }
    func testMissingOrIdentityRoomNamesKeepGeneric() {
        for room in [nil, "", "@mai:example.test", "mai", "example.test", "!room:example.test", "#room:example.test"] as [String?] {
            XCTAssertEqual(RichPushPresentation.map(item(.text("Hello"), direct: false, room: room), ownUserID: "me", copy: copy), .generic)
        }
    }
    func testUndecryptableUnsupportedAndEmptyTextKeepGeneric() {
        for kind in [RichPushItem.Kind.undecryptable, .unsupported, .text(" \n"), .emote(" \n")] {
            XCTAssertEqual(RichPushPresentation.map(item(kind), ownUserID: "me", copy: copy), .generic)
        }
    }
    func testOwnEventsAreSuppressed() {
        XCTAssertEqual(RichPushPresentation.map(item(.text("mine"), sender: "me"), ownUserID: "me", copy: copy), .suppress)
    }
}
