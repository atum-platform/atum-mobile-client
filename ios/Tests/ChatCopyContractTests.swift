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

    /// HC-2: a report word the export does not carry yet reads its exported
    /// stand-in; once the copy worker's key is pinned it must resolve itself.
    func testEveryPendingReportKeyResolvesOrFallsBackInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for key in ReportPendingCopy.allCases {
                if copy.contains(key.rawValue) {
                    XCTAssertNoThrow(try copy.text(key.rawValue, locale: locale), "\(locale) \(key.rawValue)")
                } else {
                    XCTAssertNoThrow(try copy.text(key.fallback.rawValue, locale: locale),
                                     "\(locale) \(key.fallback.rawValue)")
                }
            }
        }
    }

    /// HC-3/HC-5: Home's working words and Start chat's find, no-match and
    /// member-count words resolve in every pinned locale.
    func testHomeWave2KeysResolveInEveryPinnedLocale() throws {
        let copy = try AtumCopy()
        let keys: [(String, [AtumCopy.Argument])] = [
            ("src.matrix.working-copy.copies.working", [.text("Lan")]),
            ("src.matrix.roster-create-copy.copies.findOnAtum", [.text("lan")]),
            ("src.matrix.roster-create-copy.copies.noMatches", []),
            ("src.matrix.roster-create-copy.copies.noMatchesHint", []),
            ("src.matrix.roster-create-copy.copies.members", [.number(1)]),
            ("src.matrix.roster-create-copy.copies.members", [.number(4)]),
        ]
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for (key, arguments) in keys {
                XCTAssertNoThrow(try copy.text(key, locale: locale, arguments: arguments), "\(locale) \(key)")
            }
        }
        XCTAssertEqual(try copy.text("src.matrix.roster-create-copy.copies.members", locale: "en",
                                     arguments: [.number(1)]), "1 member")
        XCTAssertEqual(try copy.text("src.matrix.working-copy.copies.working", locale: "en",
                                     arguments: [.text("Lan")]), "Lan is working")
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
        case .searchResult, .searchSearching, .searchSearched:
            [.number(2), .number(5)]
        case .incomingAnnouncement:
            [.text("Lan"), .text("xin chào")]
        default:
            []
        }
    }
}
