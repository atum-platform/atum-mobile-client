import AtumChat
import AtumDesign
import XCTest

final class ChatCopyContractTests: XCTestCase {
    func testStructuredTurnStatusKeysResolveInEveryPinnedLocale() throws {
        let copy = try AtumCopy()
        let statuses = ChatProgressPresentation.Activity.allCases.map(ChatProgressPresentation.toolActivity)
            + [.heartbeat(minutes: 1), .heartbeat(minutes: 4), .approvalWait]
        for locale in copy.locales {
            for status in statuses {
                let args: [AtumCopy.Argument] = status.minutes.map { [.number(Int64($0))] } ?? []
                let value = try copy.text(status.exportKey, locale: locale, arguments: args)
                XCTAssertFalse(value.isEmpty)
                if let minutes = status.minutes { XCTAssertTrue(value.contains(String(minutes))) }
            }
        }
    }

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

    /// S3: the room notification menu's words resolve from the export once it is
    /// pinned, and until then from desktop #155's generated table.
    func testEveryNotificationMenuKeyResolvesOrIsPendingInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for key in ChatNotificationCopyKey.allCases {
                if copy.contains(key.rawValue) {
                    XCTAssertNoThrow(try copy.text(key.rawValue, locale: locale), "\(locale) \(key.rawValue)")
                } else {
                    XCTAssertNotEqual(ChatNotificationPendingCopy.text(key, locale: locale), key.rawValue,
                                      "\(locale) \(key.rawValue)")
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

    /// Chat parity S4/S5 (ML1 UI): the group thread and shared pin words read
    /// exported keys in every pinned locale. `allThreads` is pending desktop
    /// #156 copy (`GroupThreadsPendingCopy`) until the export carries it.
    func testGroupThreadAndPinKeysResolveInEveryPinnedLocale() throws {
        let copy = try AtumCopy()
        let pinned = "src.matrix.mobile-copy.mobileScreensCopy.teamSpace.pinned."
        let keys: [(String, [AtumCopy.Argument])] = [
            ("src.matrix.thread-copy.copy.replyInThread", []),
            ("src.matrix.thread-copy.copy.threads", []),
            ("src.matrix.thread-copy.copy.follow", []),
            ("src.matrix.thread-copy.copy.unfollow", []),
            ("src.matrix.thread-copy.copy.unread", []),
            ("src.matrix.thread-copy.copy.noThreads", []),
            ("src.matrix.thread-copy.copy.threadUnavailable", []),
            ("src.matrix.thread-copy.copy.replies", [.number(1)]),
            ("src.matrix.thread-copy.copy.replies", [.number(3)]),
            ("src.matrix.chat-copy.copies.pin", []),
            ("src.matrix.chat-copy.copies.unpin", []),
            ("src.matrix.chat-copy.copies.errorGeneric", []),
            ("src.matrix.person-info-copy.copy.tryAgain", []),
            (pinned + "pinnedMessages", []),
            (pinned + "noPinnedMessages", []),
            (pinned + "pinnedMessageUnavailable", []),
            (pinned + "unpinMessage", []),
            (pinned + "showPinnedMessage", []),
            (pinned + "pinnedMessageCount", [.number(2)]),
        ]
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for (key, arguments) in keys {
                XCTAssertNoThrow(try copy.text(key, locale: locale, arguments: arguments), "\(locale) \(key)")
            }
        }
        XCTAssertEqual(try copy.text("src.matrix.thread-copy.copy.replies", locale: "en", arguments: [.number(3)]),
                       "3 replies")
    }

    /// Chat parity ML6 UI (`ChatActionsCopy`): the forward picker and the
    /// link card read exported desktop `chat-copy` keys in every pinned
    /// locale, with desktop's English.
    func testChatActionKeysResolveInEveryPinnedLocale() throws {
        let copy = try AtumCopy()
        let chat = "src.matrix.chat-copy.copies."
        let keys: [(String, [AtumCopy.Argument], String)] = [
            ("forward", [], "Forward"),
            ("forwardTitle", [], "Forward message"),
            ("forwardSearch", [], "Search chats"),
            ("forwardSend", [], "Send"),
            ("forwardSendTo", [.text("Lan")], "Send to Lan"),
            ("forwardEmpty", [], "No chats found"),
            ("forwardTeamOnly", [.text("Acme")], "Only Acme chats and your assistants"),
            ("forwardEncryptedOnly", [], "This file can go only to encrypted chats"),
            ("sent", [], "Sent"),
            ("retry", [], "Retry"),
            ("errorGeneric", [], "That didn’t work. Try again."),
            ("hideLinkPreview", [], "Hide preview"),
        ]
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            for (key, arguments, _) in keys {
                XCTAssertNoThrow(try copy.text(chat + key, locale: locale, arguments: arguments), "\(locale) \(key)")
            }
        }
        for (key, arguments, english) in keys {
            XCTAssertEqual(try copy.text(chat + key, locale: "en", arguments: arguments), english, key)
        }
    }

    /// S15: desktop #160's band words postdate the pin. The pending table is
    /// desktop's verbatim text; once a repin carries a key, the app reads the
    /// export and this test asks for the table to be retired.
    func testRoomUpgradeWordsArePendingDesktopCopy() throws {
        let copy = try AtumCopy()
        for key in RoomUpgradePendingCopy.Key.allCases {
            XCTAssertFalse(copy.contains(key.exportKey), "Pinned now; retire RoomUpgradePendingCopy.\(key)")
            for locale in RoomUpgradePendingCopy.locales {
                XCTAssertFalse(RoomUpgradePendingCopy.text(key, locale: locale).isEmpty, "\(locale) \(key)")
            }
        }
        XCTAssertEqual(RoomUpgradePendingCopy.text(.moved, locale: "en"), "This chat moved to a new room.")
        XCTAssertEqual(RoomUpgradePendingCopy.text(.join, locale: "en"), "Join new room")
        XCTAssertEqual(RoomUpgradePendingCopy.text(.earlier, locale: "vi"), "Xem tin nhắn trước đó")
        XCTAssertEqual(RoomUpgradePendingCopy.text(.unavailable, locale: "fr"),
                       "The new room isn’t available. Earlier messages stay here.")
    }
}
