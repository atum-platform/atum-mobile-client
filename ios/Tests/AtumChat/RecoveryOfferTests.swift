import XCTest
@testable import AtumChat

/// W4 E3 (coordinator decision 5): the optional recovery row shows in a
/// chat only where it can help, and never blocks anything.
final class RecoveryOfferTests: XCTestCase {
    private func rows(_ kinds: [ChatItem.Kind]) -> [ChatRow] {
        kinds.enumerated().map { ChatRow(item: ChatItem(id: "r\($0.offset)", kind: $0.element)) }
    }

    func testOfferedInPeopleAndGroupChatsShowingMessagesThisPhoneCouldNotOpen() {
        for reason in [ChatItem.PlaceholderReason.undecryptableOldHistory, .undecryptable] {
            let shown = rows([.message, .placeholder(reason), .message])
            XCTAssertTrue(RecoveryOffer.inChat(kind: .person, rows: shown, accountOffersRecovery: true))
            XCTAssertTrue(RecoveryOffer.inChat(kind: .group, rows: shown, accountOffersRecovery: true))
        }
    }

    func testNeverInAgentOrBotChatsTheyArePlainRooms() {
        let shown = rows([.placeholder(.undecryptableOldHistory)])
        XCTAssertFalse(RecoveryOffer.inChat(kind: .assistant, rows: shown, accountOffersRecovery: true))
        XCTAssertFalse(RecoveryOffer.inChat(kind: .appBot, rows: shown, accountOffersRecovery: true))
    }

    func testNotWhenNothingIsLockedOrTheAccountHasNothingToRecover() {
        XCTAssertFalse(RecoveryOffer.inChat(kind: .person, rows: rows([.message, .placeholder(.redacted),
                                                                       .placeholder(.unsupported)]),
                                            accountOffersRecovery: true))
        XCTAssertFalse(RecoveryOffer.inChat(kind: .person, rows: rows([.placeholder(.undecryptable)]),
                                            accountOffersRecovery: false),
                       "the key backup is open already, or old history cannot open on this phone")
    }
}
