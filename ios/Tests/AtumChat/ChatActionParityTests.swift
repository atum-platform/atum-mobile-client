import Foundation
import XCTest
@testable import AtumChat

final class ChatActionParityTests: XCTestCase {
    private func event(_ content: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "type": "m.room.message", "sender": "@source:example.test", "content": content
        ]), as: UTF8.self)
    }

    func testForwardUsesDisplayedEditWithoutReplyMentionOrActionData() throws {
        let original = try event([
            "msgtype": "m.notice", "body": "before", "io.atum.provenance": ["origin": "protected"],
            "m.relates_to": ["m.in_reply_to": ["event_id": "$private"]]
        ])
        let edit = try event([
            "msgtype": "m.notice", "body": "* after",
            "m.relates_to": ["rel_type": "m.replace", "event_id": "$original"],
            "m.new_content": [
                "msgtype": "m.notice", "body": "> <@source:example.test> quoted\n\n@room after",
                "format": "org.matrix.custom.html", "formatted_body": "<mx-reply>quoted</mx-reply><b>after</b>",
                "m.mentions": ["room": true], "io.atum.result": true, "io.atum.app_bot": ["command": "hidden"]
            ]
        ])
        let output = try ForwardContent(originalEvent: original, latestEvent: edit)
        XCTAssertEqual(output.kind, .text)
        XCTAssertEqual(output.body, "@room after")
        XCTAssertEqual(output.formattedBody, "<b>after</b>")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "body", "msgtype", "format", "formatted_body", "m.mentions", "io.atum.forwarded", "io.atum.provenance"
        ])
        XCTAssertEqual(json["m.mentions"] as? [String: Bool], [:])
        let extra = try JSONSerialization.jsonObject(with: Data(output.attachmentExtraJSON.utf8)) as? [String: Any]
        XCTAssertEqual(extra?["io.atum.provenance"] as? [String: String], ["origin": "protected"])
        XCTAssertEqual(try output.transfer(sourceEncrypted: true, destinationEncrypted: false), .reuse)
    }

    func testForwardAttachmentBoundaryIsDecidedBeforeTransfer() throws {
        let image = try event(["msgtype": "m.image", "body": "Photo.png", "url": "mxc://example.test/photo"])
        let plain = try ForwardContent(originalEvent: image, latestEvent: image)
        XCTAssertEqual(try plain.transfer(sourceEncrypted: false, destinationEncrypted: false), .reuse)
        XCTAssertEqual(try plain.transfer(sourceEncrypted: false, destinationEncrypted: true), .encryptAndUpload)
        XCTAssertThrowsError(try plain.transfer(sourceEncrypted: true, destinationEncrypted: true))
        let file = try event([
            "msgtype": "m.file", "body": "Report.pdf",
            "file": ["url": "mxc://example.test/cipher", "v": "v2", "iv": "iv",
                     "hashes": ["sha256": "sha"], "key": ["kty": "oct", "alg": "A256CTR", "k": "secret",
                                                           "key_ops": ["encrypt", "decrypt"], "ext": true]]
        ])
        let encrypted = try ForwardContent(originalEvent: file, latestEvent: file)
        XCTAssertThrowsError(try encrypted.transfer(sourceEncrypted: true, destinationEncrypted: false)) {
            XCTAssertEqual($0 as? ForwardFailure, .encryptedAttachment)
        }
        XCTAssertEqual(try encrypted.transfer(sourceEncrypted: true, destinationEncrypted: true), .reuse)
    }

    func testForwardRejectsProtectedCompanyFilesAndOutOfScopeTargets() throws {
        let original = try event(["msgtype": "m.text", "body": "Protected", "io.atum.company_file": true])
        let edit = try event(["msgtype": "m.text", "body": "Edited"])
        XCTAssertThrowsError(try ForwardContent(originalEvent: original, latestEvent: edit))
        let source = ForwardRoomScope.company("first")
        XCTAssertTrue(source.allowsForward(to: source))
        XCTAssertTrue(source.allowsForward(to: .ownAssistant))
        XCTAssertFalse(source.allowsForward(to: .company("second")))
        XCTAssertFalse(source.allowsForward(to: .personal))
        XCTAssertFalse(source.allowsForward(to: .unavailable))
    }

    func testLinkPreviewSkipsCodeImagesInvitesAndPurchaseLinks() throws {
        let body = """
        `https://code.example.test`
        ![picture](https://images.example.test/file.png)
        https://team.example.test/j/secret?ignored=true
        https://payos.vn/pay
        (https://www.example.test/story#local-secret).
        """
        let url = try XCTUnwrap(LinkPolicy.firstPreviewURL(in: body))
        XCTAssertEqual(url.absoluteString, "https://www.example.test/story")
        XCTAssertNil(LinkPolicy.firstPreviewURL(in: "https://credentials:secret@example.test/"))
        XCTAssertNil(LinkPolicy.firstPreviewURL(in: "https://atumplatform.com/#atum-app/id"))
        let metadata = try XCTUnwrap(LinkPreview.Metadata(json: """
        {"og:title":"The  story","og:site_name":"example.test","og:image":"https://images.example.test/photo"}
        """))
        XCTAssertNil(metadata.imageURI)
        let card = try XCTUnwrap(metadata.card(url: url, image: nil))
        XCTAssertEqual(card.title, "The story")
        XCTAssertNil(card.siteName)
        XCTAssertNil(card.image)
        XCTAssertNil(LinkPreview.Metadata(json: "{}")?.card(url: url, image: nil))
    }

    func testRoomMentionRequiresAnExplicitSurvivingPick() throws {
        XCTAssertFalse(RoomMentionRules.offersSuggestion(for: "ro", canNotifyRoom: false))
        XCTAssertNil(RoomMentionRules.insert(into: "Hi @ro", canNotifyRoom: false))
        var ledger = MentionLedger()
        ledger.stage(text: "Hi @room")
        XCTAssertEqual(ledger.mentions(for: "Hi @room"), .none)
        ledger.delivered(text: "Hi @room")
        let pick = try XCTUnwrap(RoomMentionRules.insert(into: "  Hi @ro", canNotifyRoom: true))
        ledger.registerRoomMention(in: pick.draft, offset: pick.offset)
        ledger.draftChanged(to: pick.draft + "please read")
        ledger.stage(text: "Hi @room please read")
        XCTAssertTrue(ledger.mentions(for: "Hi @room please read").room)
        ledger.refused(text: "Hi @room please read", draft: "New\nHi @room please read")
        ledger.stage(text: "New\nHi @room please read")
        XCTAssertTrue(ledger.mentions(for: "New\nHi @room please read").room)

        ledger.registerRoomMention(in: "@room then @room ", offset: 11)
        ledger.draftChanged(to: "@room then ")
        ledger.draftChanged(to: "@room then @room")
        ledger.stage(text: "@room then @room")
        XCTAssertEqual(ledger.mentions(for: "@room then @room"), .none)

        var duplicate = MentionLedger()
        duplicate.registerRoomMention(in: "@room", offset: 0)
        duplicate.stage(text: "@room")
        duplicate.stage(text: "@room")
        XCTAssertEqual(duplicate.mentions(for: "@room"), .none)
        duplicate.delivered(text: "@room")
        XCTAssertEqual(duplicate.mentions(for: "@room"), .none)
    }

    func testUpgradeRequiresBacklinkAndLeavesInaccessibleHistoryReachable() {
        let old = "!old:example.test"
        let replacement = "!new"
        func next(joined: Bool, create: Bool, predecessor: String?) -> RoomUpgradeDestination {
            RoomUpgradeRules.successor(old: old, replacement: replacement, joined: joined,
                                       hasCreateState: create, predecessor: predecessor)
        }
        XCTAssertEqual(next(joined: false, create: false, predecessor: nil), .join(roomID: replacement))
        XCTAssertEqual(next(joined: true, create: false, predecessor: nil), .waitingForState)
        XCTAssertEqual(next(joined: true, create: true, predecessor: old), .open(roomID: replacement))
        XCTAssertEqual(next(joined: true, create: true, predecessor: nil), .unavailable)
        XCTAssertEqual(next(joined: false, create: true, predecessor: "!different"), .unavailable)
        XCTAssertEqual(RoomUpgradeRules.hiddenPredecessors(verifiedLinks: [old: replacement]), [old])
        XCTAssertEqual(RoomUpgradeRules.hiddenPredecessors(verifiedLinks: [old: replacement, replacement: old]), [])
    }
}
