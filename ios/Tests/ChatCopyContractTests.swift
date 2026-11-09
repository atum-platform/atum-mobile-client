import AtumChat
import AtumDesign
import XCTest

final class ChatCopyContractTests: XCTestCase {
    func testEveryChatKeyResolvesInEveryPinnedLocaleWithItsArguments() throws {
        let copy = try AtumCopy()
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for key in ChatCopyKey.allCases {
                XCTAssertNoThrow(try copy.text(key.rawValue, locale: locale, arguments: arguments(for: key)),
                                 "\(locale) \(key.rawValue)")
            }
        }
    }

    private func arguments(for key: ChatCopyKey) -> [AtumCopy.Argument] {
        switch key {
        case .seenBy, .newMessages, .mediaPhotoNumber, .mediaRemovePhoto,
             .mediaUploadProgress, .mediaTooLargeSome, .mediaTooMany:
            [.number(2)]
        case .typingOne, .typingSome, .composerPlaceholder, .replyingTo,
             .reactWith, .deleteMessageAssistantNote, .deleteBotChatBody,
             .removeFile, .appBotOpen, .appBotContinueSetupBody,
             .appBotContinueRouteBody, .appBotRoomFailed,
             .appBotNoticeNeedsSetup, .appBotNoticeNeedsIntake,
             .appBotNoticeAllowanceExhausted, .appBotNoticeUnverifiedSender,
             .appBotNoticeLinkPending, .appBotNoticeBusy,
             .appBotNoticeUnavailable, .appBotNoticeTimeout,
             .appBotNoticeOutcomeUnknown, .appBotNoticeMissedOffline,
             .appBotNoticeSentBeforeLink, .appBotNoticeUnsupported,
             .appBotNoticeTooLong, .appBotNoticeCannotRead,
             .appBotNoticeJoined:
            [.text("Lan")]
        case .infoMemberCount:
            [.number(3)]
        case .incomingAnnouncement:
            [.text("Lan"), .text("xin chào")]
        default:
            []
        }
    }
}
