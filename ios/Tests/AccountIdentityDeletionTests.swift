import AtumChat
import AtumNativeAPI
import XCTest

/// AC-1: the person-name rule, as desktop `src/matrix/person-name.ts`.
final class MatrixPersonNameTests: XCTestCase {
    private let opaque = "@user-0123456789abcdef0123456789abcdef:atum.chat"

    func testOpaqueIDsAreRecognisedAndReadableOnesAreNot() {
        XCTAssertTrue(MatrixPersonName.isOpaque(opaque))
        XCTAssertTrue(MatrixPersonName.isOpaque("@agent-0123456789abcdef0123:atum.chat"))
        XCTAssertTrue(MatrixPersonName.isOpaque("@app-0123456789abcdef:atum.chat"))
        XCTAssertFalse(MatrixPersonName.isOpaque("@minh:atum.chat"))
        XCTAssertFalse(MatrixPersonName.isOpaque("@user-short:atum.chat"))
        XCTAssertFalse(MatrixPersonName.isOpaque("not an id"))
        XCTAssertEqual(MatrixPersonName.localpart("@minh:atum.chat"), "minh")
        XCTAssertEqual(MatrixPersonName.localpart("minh"), "")
    }

    func testOnlyDirectoryShapedHandlesAreHandles() {
        XCTAssertEqual(MatrixPersonName.validHandle("minh"), "minh")
        XCTAssertEqual(MatrixPersonName.validHandle("an_2"), "an_2")
        for value in [nil, "", "mi", "Minh", "@minh", "2minh", "user-0123", String(repeating: "a", count: 33)] as [String?] {
            XCTAssertNil(MatrixPersonName.validHandle(value), String(describing: value))
        }
    }

    func testNameDropsEveryStandInForAMissingName() {
        XCTAssertEqual(MatrixPersonName.name("  Minh  ", userID: opaque), "Minh")
        XCTAssertEqual(MatrixPersonName.name("Minh (\(opaque))", userID: opaque), "Minh")
        for raw in [nil, "", "  ", opaque, "user-0123456789abcdef0123456789abcdef",
                    "(\(opaque))", "\(opaque), \(opaque)"] as [String?] {
            XCTAssertNil(MatrixPersonName.name(raw, userID: opaque), String(describing: raw))
        }
        // A readable localpart someone typed as their name is their name.
        XCTAssertEqual(MatrixPersonName.name("minh", userID: "@minh:atum.chat"), "minh")
    }

    func testLabelIsNameThenHandleThenReadableLocalpartThenUnnamed() {
        XCTAssertEqual(MatrixPersonName.label(name: "Minh", handle: "minh", userID: opaque, unnamed: "Atum user"),
                       .init(name: "Minh", address: "@minh"))
        XCTAssertEqual(MatrixPersonName.label(name: "Minh", handle: nil, userID: opaque, unnamed: "Atum user"),
                       .init(name: "Minh"))
        XCTAssertEqual(MatrixPersonName.label(name: nil, handle: "minh", userID: opaque, unnamed: "Atum user"),
                       .init(name: "@minh"))
        XCTAssertEqual(MatrixPersonName.label(name: nil, handle: "@bad", userID: opaque, unnamed: "Atum user"),
                       .init(name: "Atum user"))
        XCTAssertEqual(MatrixPersonName.label(name: nil, handle: nil, userID: "@an:atum.chat", unnamed: "Atum user"),
                       .init(name: "an"))
        XCTAssertEqual(MatrixPersonName.shown(nil, userID: opaque, unnamed: "Atum user"), "Atum user")
    }

    func testSomeoneOnAnotherServerKeepsTheirAddress() {
        let remote = "@lan:example.org"
        XCTAssertEqual(MatrixPersonName.label(name: "Lan", handle: nil, userID: remote,
                                              ownerUserID: opaque, unnamed: "Atum user"),
                       .init(name: "Lan", address: remote))
        XCTAssertEqual(MatrixPersonName.label(name: nil, handle: nil, userID: remote,
                                              ownerUserID: opaque, unnamed: "Atum user"),
                       .init(name: remote))
    }

    func testSenderLabelsDropOpaqueLocalpartsAndTheIDSuffix() {
        XCTAssertNil(MobileSenderLabelPolicy.label(senderID: opaque,
                                                   profileDisplayName: "user-0123456789abcdef0123456789abcdef",
                                                   knownNames: [:]))
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: opaque, profileDisplayName: "Minh (\(opaque))",
                                                     knownNames: [:]), "Minh")
    }
}

/// AC-2a: the deletion request the phone drafts, as desktop `MatrixDeleteAccount`.
final class AccountDeletionEmailRequestTests: XCTestCase {
    func testTheDraftGoesToThePrivacyMailboxWithTheAtumID() {
        let draft = AccountDeletionEmailRequest(subject: "Delete my Atum account",
                                                body: "Please delete my Atum account.",
                                                idLabel: "Atum ID",
                                                accountID: "@user-0123456789abcdef0123456789abcdef:atum.chat")
        XCTAssertEqual(draft.recipient, "privacy@atumplatform.com")
        XCTAssertEqual(draft.subject, "Delete my Atum account")
        XCTAssertEqual(draft.body,
                       "Please delete my Atum account.\n\nAtum ID: @user-0123456789abcdef0123456789abcdef:atum.chat")
        XCTAssertEqual(draft.mailtoURL?.absoluteString,
                       "mailto:privacy@atumplatform.com?subject=Delete%20my%20Atum%20account"
                       + "&body=Please%20delete%20my%20Atum%20account.%0A%0AAtum%20ID%3A%20"
                       + "%40user-0123456789abcdef0123456789abcdef%3Aatum.chat")
    }

    func testWithoutAnIDTheBodyIsTheRequestAlone() {
        for accountID in [nil, ""] as [String?] {
            let draft = AccountDeletionEmailRequest(subject: "S", body: "B", idLabel: "Atum ID", accountID: accountID)
            XCTAssertEqual(draft.body, "B")
        }
    }

    func testTheLinkEncodesLikeTheDesktopAndKeepsVietnameseIntact() {
        let draft = AccountDeletionEmailRequest(subject: "Yêu cầu xóa tài khoản Atum",
                                                body: "a+b&c=d", idLabel: "ID Atum", accountID: nil)
        let link = draft.mailtoURL?.absoluteString ?? ""
        XCTAssertFalse(link.contains("+"))
        XCTAssertTrue(link.hasSuffix("&body=a%2Bb%26c%3Dd"))
        let subject = URLComponents(string: link)?.queryItems?.first { $0.name == "subject" }?.value
        XCTAssertEqual(subject, "Yêu cầu xóa tài khoản Atum")
    }
}
