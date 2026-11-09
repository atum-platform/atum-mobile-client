import XCTest
@testable import AtumNativeAPI

/// Revamp plan §4.2 items 1–3: the bot's chat is chosen in desktop's order
/// (`chooseAppBotDm`) for the list and for reopening, room-less bots get no
/// row, and a bot notice shows one line in the phone's language.
final class AppBotRoomChoiceTests: XCTestCase {
    private typealias Policy = MobileAppBotRoomPolicy

    private func room(_ id: String, joined: Bool = true, oneToOne: Bool = true, invitedByBot: Bool = false,
                      encrypted: Bool? = false, message: UInt64 = 0, active: UInt64 = 0) -> MobileAppBotChatCandidate {
        MobileAppBotChatCandidate(roomID: id, membership: joined ? .joined : .invited,
                                  isOneToOneWithBot: joined && oneToOne, invitedByBot: invitedByBot,
                                  encrypted: encrypted, lastMessageAt: message, lastActiveAt: max(active, message))
    }

    private func choice(_ id: String, _ action: MobileAppBotChatChoice.Action,
                        _ reason: MobileAppBotChatChoice.Reason) -> MobileAppBotChatChoice {
        MobileAppBotChatChoice(roomID: id, action: action, reason: reason)
    }

    func testThePointersPlainRoomWinsWhenItHasMessages() {
        let rooms = [room("!pointer", message: 100), room("!newer", message: 900)]
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!pointer", candidates: rooms), choice("!pointer", .open, .pointer))
    }

    func testAnEmptyPointerRoomLosesToAPlainRoomWithMessages() {
        let rooms = [room("!pointer"), room("!talked", message: 50)]
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!pointer", candidates: rooms),
                       choice("!talked", .open, .mostHistory))
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!pointer", candidates: [room("!pointer"), room("!quiet")]),
                       choice("!pointer", .open, .pointer), "nobody has written anywhere: the pointer wins")
    }

    func testAPlainRoomAlwaysBeatsARoomWithEncryptionWhateverThePointerNames() {
        let rooms = [room("!old", encrypted: true, message: 999), room("!plain", message: 10)]
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!old", candidates: rooms), choice("!plain", .open, .mostHistory))
    }

    func testOnlyRoomsWithEncryptionOrUnknownStateMeanNoRowOnThePhone() {
        XCTAssertNil(Policy.chooseChat(pointerRoomID: "!old", candidates: [room("!old", encrypted: true, message: 5)]),
                     "the Mac moves the person to a plain room; the phone shows nothing until then")
        XCTAssertNil(Policy.chooseChat(pointerRoomID: nil, candidates: [room("!loading", encrypted: nil, message: 5)]))
        XCTAssertNil(Policy.chooseChat(pointerRoomID: nil, candidates: []))
    }

    func testTheBotsInvitationWinsOnlyWhileNoPlainRoomHasMessages() {
        let invite = room("!invite", joined: false, invitedByBot: true, active: 70)
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: nil, candidates: [room("!empty"), invite]),
                       choice("!invite", .join, .invited))
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: nil, candidates: [room("!talked", message: 3), invite]),
                       choice("!talked", .open, .mostHistory), "the person is already talking there")
    }

    func testOnlyThePlainInvitationOfTheBotItselfCounts() {
        let fromSomeoneElse = room("!stranger", joined: false, invitedByBot: false)
        XCTAssertNil(Policy.chooseChat(pointerRoomID: nil, candidates: [fromSomeoneElse]))
        let encryptedInvite = room("!old-invite", joined: false, invitedByBot: true, encrypted: true)
        XCTAssertNil(Policy.chooseChat(pointerRoomID: nil, candidates: [encryptedInvite]))
        let pointedInvite = room("!pointed", joined: false, invitedByBot: true, active: 1)
        let laterInvite = room("!later", joined: false, invitedByBot: true, active: 99)
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!pointed", candidates: [laterInvite, pointedInvite]),
                       choice("!pointed", .join, .invited), "the pointer's invitation comes first")
    }

    func testAGroupWithTheBotIsNotItsChat() {
        XCTAssertNil(Policy.chooseChat(pointerRoomID: nil, candidates: [room("!group", oneToOne: false, message: 9)]))
    }

    func testMostHistoryBreaksTiesByActivityThenRoomID() {
        let rooms = [room("!b", message: 10, active: 20), room("!a", message: 10, active: 20), room("!c", message: 10, active: 30)]
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: nil, candidates: rooms)?.roomID, "!c")
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: nil, candidates: Array(rooms.prefix(2)))?.roomID, "!a")
    }

    func testAPointerToARoomThisPhoneDoesNotHoldFallsBackToHistory() {
        XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!gone", candidates: [room("!here", message: 1)]),
                       choice("!here", .open, .mostHistory))
    }

    func testTheChoiceIsTheSameWhateverTheCandidateOrder() {
        let rooms = [room("!p"), room("!x", message: 4, active: 9), room("!y", message: 4, active: 2),
                     room("!old", encrypted: true, message: 99), room("!i", joined: false, invitedByBot: true)]
        let expected = Policy.chooseChat(pointerRoomID: "!p", candidates: rooms)
        XCTAssertEqual(expected, choice("!x", .open, .mostHistory))
        for shift in 1..<rooms.count {
            let rotated = Array(rooms[shift...] + rooms[..<shift])
            XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!p", candidates: rotated), expected)
            XCTAssertEqual(Policy.chooseChat(pointerRoomID: "!p", candidates: rotated.reversed()), expected)
        }
    }

    // MARK: Notice line

    private let twoLines = "Moon cần ngày sinh của bạn.\nMoon needs your birth date."

    func testABotNoticeShowsTheLineInThePhonesLanguage() {
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: true, isNotice: true, languageCode: "vi"),
                       "Moon cần ngày sinh của bạn.")
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: true, isNotice: true, languageCode: "vi-VN"),
                       "Moon cần ngày sinh của bạn.")
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: true, isNotice: true, languageCode: "en"),
                       "Moon needs your birth date.")
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: true, isNotice: true, languageCode: "fr"),
                       "Moon needs your birth date.", "no Vietnamese, no other translation: English")
        XCTAssertEqual(Policy.noticeLine(body: "Một dòng.\r\nOne line.", senderIsCatalogBot: true, isNotice: true,
                                         languageCode: "vi"), "Một dòng.")
    }

    func testAnythingButAnExactTwoLineBotNoticeShowsInFull() {
        for body in ["Một dòng.", "a\nb\nc", "a\n", "\nb", "a\n \n", ""] {
            XCTAssertEqual(Policy.noticeLine(body: body, senderIsCatalogBot: true, isNotice: true, languageCode: "vi"),
                           body, body.debugDescription)
        }
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: false, isNotice: true, languageCode: "vi"),
                       twoLines, "a person's notice is never cut")
        XCTAssertEqual(Policy.noticeLine(body: twoLines, senderIsCatalogBot: true, isNotice: false, languageCode: "vi"),
                       twoLines, "a bot's answer is never cut")
    }
}
