import XCTest
@testable import AtumChat

/// B20–B22 (the long-press menu per room kind), B21 and B25 (the composer
/// pill and its chips), B11 (the people line) and B26 (the failure haptic).
final class MessageMenuRulesTests: XCTestCase {
    private func image(_ id: String, from sender: String, isOwn: Bool = false) -> ChatItem {
        ChatItem(id: id, kind: .image(width: 400, height: 300), sender: sender, isOwn: isOwn,
                 eventOrTransactionId: .event("$" + id))
    }

    // MARK: Per room kind (§2.7)

    func testMyAssistantOffersSelectOnAnswersAndDeleteOnMineButNeverEdit() {
        let answer = F.text("a", from: F.agent, "**Kết quả**")
        XCTAssertEqual(MessageMenuRules.items(for: answer, in: .assistant), [.react, .reply, .copy, .selectText])
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Câu hỏi"), in: .assistant),
                       [.react, .reply, .copy, .delete], "editing a prompt does not re-run an agent")
    }

    func testABotRoomOffersOnlyCopyAndSelect() {
        XCTAssertEqual(MessageMenuRules.items(for: F.text("a", from: F.bot, "Chào bạn"), in: .appBot),
                       [.copy, .selectText])
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Hỏi Moon"), in: .appBot), [.copy])
        XCTAssertEqual(MessageMenuRules.items(for: image("i", from: F.bot), in: .appBot), [],
                       "nothing to copy, no reply or react in bot rooms: no menu")
    }

    func testPeopleAndGroupsOfferEditAndDeleteOnMineAndNoSelect() {
        for kind in [RoomKind.person, .group] {
            XCTAssertEqual(MessageMenuRules.items(for: F.text("t", from: F.friend, "Chào"), in: kind),
                           [.react, .reply, .copy], "\(kind)")
            XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Ok"), in: kind),
                           [.react, .reply, .copy, .edit, .delete], "\(kind)")
        }
    }

    // MARK: Rows

    func testRowsWithNothingToActOnHaveNoMenu() {
        let rows: [ChatItem] = [
            F.notice("n", from: F.agent),
            ChatItem(id: "x", kind: .placeholder(.redacted), sender: F.friend, eventOrTransactionId: .event("$x")),
            ChatItem(id: "u", kind: .placeholder(.undecryptable), sender: F.friend, eventOrTransactionId: .event("$u")),
            ChatItem(id: "s", kind: .roomState, sender: F.friend, eventOrTransactionId: .event("$s")),
            F.divider("d"), F.readMarker(), F.start(),
            ChatItem(id: "atum.typing", kind: .typing(names: ["Atum"])),
            ChatItem(id: "atum.loading", kind: .loadingEarlier)
        ]
        for kind in RoomKind.allCases {
            for item in rows {
                XCTAssertEqual(MessageMenuRules.items(for: item, in: kind), [], "\(item.id) in \(kind)")
            }
        }
    }

    func testImagesAndFilesHaveNoCopyButCanBeAnsweredReactedAndDeleted() {
        XCTAssertEqual(MessageMenuRules.items(for: image("i", from: F.friend), in: .group), [.react, .reply])
        XCTAssertEqual(MessageMenuRules.items(for: image("i", from: F.me, isOwn: true), in: .person),
                       [.react, .reply, .delete], "edit is for text only")
    }

    func testAFailedSendCanBeDeletedButNotEditedOrAnswered() {
        let failed = F.echo("f", "Chưa đi", delivery: .failed(isRecoverable: true))
        XCTAssertEqual(MessageMenuRules.items(for: failed, in: .person), [.react, .copy, .delete],
                       "no event ID yet: no reply; a failed send is retried or deleted, not edited")
        let pending = F.echo("p", "Đang đi")
        XCTAssertEqual(MessageMenuRules.items(for: pending, in: .assistant), [.react, .copy, .delete])
    }

    func testASendHeldDuringARenewalCanBeCopiedOrDropped() {
        let held = ChatItem(id: ConversationCore.heldRowPrefix + "1", kind: .message, sender: F.me, isOwn: true,
                            isLocalEcho: true, delivery: .sending(), body: "Gửi lúc đổi phiên")
        XCTAssertEqual(MessageMenuRules.items(for: held, in: .person), [.copy, .delete])
        XCTAssertEqual(MessageMenuRules.items(for: held, in: .assistant), [.copy, .delete])
        XCTAssertFalse(MessageMenuRules.deleteNeedsConfirmation(held), "it never left the phone")
    }

    func testAWhitespaceBodyOffersNoCopy() {
        XCTAssertEqual(MessageMenuRules.items(for: F.text("w", from: F.agent, "  \n "), in: .assistant),
                       [.react, .reply])
    }

    // MARK: Palette (B22)

    func testThePaletteIsDesktopsSetAndMarksMyReactions() {
        var item = F.text("a", from: F.agent)
        item.reactions = [ChatReaction(key: "❤️", senderIDs: [F.agent, F.me]), ChatReaction(key: "👍", senderIDs: [F.agent])]
        let choices = MessageMenuRules.reactionChoices(for: item, ownUserID: F.me)
        XCTAssertEqual(choices.map(\.key), ["👍", "❤️", "😂", "😮", "😢", "🙏"])
        XCTAssertEqual(choices.filter(\.isSelected).map(\.key), ["❤️"], "only keys I reacted with")
        XCTAssertTrue(MessageMenuRules.reactionChoices(for: item, ownUserID: nil).allSatisfy { !$0.isSelected })
    }

    // MARK: Delete confirmation (B20)

    func testDeleteAsksFirstOnlyWhenTheMessageMayHaveReachedTheOthers() {
        XCTAssertTrue(MessageMenuRules.deleteNeedsConfirmation(F.mine("m")))
        XCTAssertTrue(MessageMenuRules.deleteNeedsConfirmation(F.echo("p")), "a pending send may already be out")
        XCTAssertFalse(MessageMenuRules.deleteNeedsConfirmation(F.echo("f", delivery: .failed(isRecoverable: false))))
    }
}

final class ComposerRulesTests: XCTestCase {
    private func rows(_ items: [ChatItem], kind: RoomKind = .assistant) -> [ChatRow] {
        let context = RoomContext(kind: kind, ownUserID: F.me, agentUserIDs: [F.agent])
        return Projection.rows(items, context: context, options: .s1)
    }

    // MARK: B25

    func testSendShowsOnlyForADraftWithText() {
        XCTAssertFalse(ComposerRules.canSend(""))
        XCTAssertFalse(ComposerRules.canSend("   \n\t "))
        XCTAssertTrue(ComposerRules.canSend(" *hi* "))
        XCTAssertTrue(ComposerRules.canSend("\n1. a_b_"))
    }

    // MARK: The controls row (2026-10-24)

    func testEveryChatKindHasAPlusExceptAnAppWithoutAnActionAndWhileEditing() {
        for kind in [RoomKind.person, .group, .assistant] {
            XCTAssertTrue(ComposerRules.showsAddButton(kind: kind, isEditing: false, hasAppComposerAction: false),
                          "\(kind)")
            XCTAssertFalse(ComposerRules.showsAddButton(kind: kind, isEditing: true, hasAppComposerAction: false),
                           "editing hides + in \(kind)")
        }
        XCTAssertTrue(ComposerRules.showsAddButton(kind: .appBot, isEditing: false, hasAppComposerAction: true))
        XCTAssertFalse(ComposerRules.showsAddButton(kind: .appBot, isEditing: false, hasAppComposerAction: false))
        XCTAssertFalse(ComposerRules.showsAddButton(kind: .appBot, isEditing: true, hasAppComposerAction: true))
    }

    func testOnlyAppBotsKeepTheirMenuFreeOfFileEntries() {
        for kind in RoomKind.allCases {
            XCTAssertEqual(ComposerRules.addMenuOffersFiles(kind: kind), kind != .appBot, "\(kind)")
        }
    }

    func testTheMicIsInEveryRowUnlessEditing() {
        XCTAssertTrue(ComposerRules.showsMicButton(isEditing: false))
        XCTAssertFalse(ComposerRules.showsMicButton(isEditing: true))
    }

    // MARK: B21 reply chip

    func testTheReplyChipNamesTheSenderAndQuotesTheFirstLine() {
        var answer = F.text("a", from: F.agent, "\n  Dòng đầu  \nDòng hai")
        answer.senderName = "Atum"
        let chip = ComposerRules.replyChip(replyTarget: "$a", rows: rows([answer]), kind: .assistant, roomTitle: "Atum")
        XCTAssertEqual(chip, ComposerChip(who: .named("Atum"), preview: .text("Dòng đầu")))
    }

    func testReplyingToMyOwnMessageSaysMe() {
        let chip = ComposerRules.replyChip(replyTarget: "$m", rows: rows([F.mine("m", "Câu hỏi")]), kind: .assistant,
                                           roomTitle: "Atum")
        XCTAssertEqual(chip?.who, .me)
    }

    func testAnUnnamedSenderTakesTheRoomTitleExceptInGroups() {
        let friend = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(ComposerRules.replyChip(replyTarget: "$t", rows: rows([friend], kind: .person), kind: .person,
                                               roomTitle: "Minh Anh")?.who, .named("Minh Anh"))
        XCTAssertEqual(ComposerRules.replyChip(replyTarget: "$t", rows: rows([friend], kind: .group), kind: .group,
                                               roomTitle: "Nhóm")?.who, .unnamed, "never a raw Matrix ID")
    }

    func testTheChipFindsAnAcceptedEchoByItsEventID() {
        let accepted = F.echo("e", "Đã đi", delivery: .sent(eventID: "$server"))
        let chip = ComposerRules.replyChip(replyTarget: "$server", rows: rows([accepted]), kind: .person,
                                           roomTitle: "Minh Anh")
        XCTAssertEqual(chip, ComposerChip(who: .me, preview: .text("Đã đi")))
    }

    func testAnOriginalThatIsNotLoadedStillShowsAChip() {
        XCTAssertEqual(ComposerRules.replyChip(replyTarget: "$gone", rows: [], kind: .group, roomTitle: "Nhóm"),
                       ComposerChip(who: .unnamed, preview: .none))
        XCTAssertNil(ComposerRules.replyChip(replyTarget: nil, rows: rows([F.mine("m")]), kind: .group, roomTitle: ""))
    }

    func testImagesAndFilesPreviewAsWhatTheyAre() {
        let photo = ChatItem(id: "p", kind: .image(width: nil, height: nil), sender: F.friend,
                             eventOrTransactionId: .event("$p"))
        let file = ChatItem(id: "f", kind: .file(name: "bao-cao.pdf"), sender: F.friend,
                            eventOrTransactionId: .event("$f"))
        let shown = rows([photo, file], kind: .person)
        XCTAssertEqual(ComposerRules.replyChip(replyTarget: "$p", rows: shown, kind: .person, roomTitle: "Lan")?.preview,
                       .photo)
        XCTAssertEqual(ComposerRules.replyChip(replyTarget: "$f", rows: shown, kind: .person, roomTitle: "Lan")?.preview,
                       .file("bao-cao.pdf"))
    }

    // MARK: B20 edit chip

    func testTheEditChipShowsTheMessageBeingChanged() {
        let shown = rows([F.mine("m", "Mai 9 giờ nhé")], kind: .person)
        XCTAssertEqual(ComposerRules.editChip(editTarget: "m", rows: shown),
                       ComposerChip(who: .me, preview: .text("Mai 9 giờ nhé")))
        XCTAssertNil(ComposerRules.editChip(editTarget: nil, rows: shown))
    }

    // MARK: B11 people line

    func testThePeopleLineJoinsTwoOrThreeNamesInTheAppLanguage() {
        let vi = Locale(identifier: "vi")
        XCTAssertNil(ComposerRules.typingCopy(.nobody, locale: vi))
        XCTAssertEqual(ComposerRules.typingCopy(.names(["Lan"]), locale: vi), .one("Lan"))
        XCTAssertEqual(ComposerRules.typingCopy(.names(["Lan", "Minh"]), locale: vi), .some("Lan và Minh"))
        XCTAssertEqual(ComposerRules.typingCopy(.names(["Lan", "Minh", "Hoa"]), locale: vi), .some("Lan, Minh và Hoa"))
        XCTAssertEqual(ComposerRules.typingCopy(.names(["Lan", "Minh"]), locale: Locale(identifier: "en")),
                       .some("Lan and Minh"))
        XCTAssertEqual(ComposerRules.typingCopy(.many, locale: vi), .many)
    }

    func testTheLineFollowsTheTypingNamesRule() {
        let four = ["Lan", "Minh", "Hoa", "Huy"]
        XCTAssertEqual(ComposerRules.typingCopy(TypingNames.presentation(kind: .group, names: four).line,
                                                locale: Locale(identifier: "vi")), .many)
        XCTAssertNil(ComposerRules.typingCopy(TypingNames.presentation(kind: .assistant, names: ["Atum"]).line,
                                              locale: Locale(identifier: "vi")),
                     "agents show dots as the last row, never the line")
    }
}

/// B26: one warning when a send fails while I am in the chat.
final class SendFailureWatchTests: XCTestCase {
    private func snapshot(_ items: [ChatItem], change: SnapshotChange, generation: UInt64 = 1) -> Snapshot {
        let rows = Projection.rows(items, context: F.personRoom(), options: .s1)
        return Snapshot(rows: rows, change: change, generation: generation)
    }

    func testAFailureAlreadyThereWhenTheChatOpensNeverBuzzes() {
        var watch = SendFailureWatch()
        let old = F.echo("old", delivery: .failed(isRecoverable: false))
        XCTAssertFalse(watch.observe(.empty))
        XCTAssertFalse(watch.observe(snapshot([old], change: .reset)), "the cached batch is the baseline")
        XCTAssertFalse(watch.observe(snapshot([old, F.text("t", from: F.friend)], change: .appendedAtEnd(count: 1, localEcho: false))))
    }

    func testASendThatFailsBuzzesOnceAndAgainAfterARetryFails() {
        var watch = SendFailureWatch()
        let base = [F.text("t", from: F.friend)]
        _ = watch.observe(snapshot(base, change: .reset))
        XCTAssertFalse(watch.observe(snapshot(base + [F.echo("e")], change: .appendedAtEnd(count: 0, localEcho: true))))
        let failed = F.echo("e", delivery: .failed(isRecoverable: true))
        XCTAssertTrue(watch.observe(snapshot(base + [failed], change: .inPlace)))
        XCTAssertFalse(watch.observe(snapshot(base + [failed], change: .inPlace)), "still the same failure")
        XCTAssertFalse(watch.observe(snapshot(base + [F.echo("e")], change: .inPlace)), "Thử lại: the clock again")
        XCTAssertTrue(watch.observe(snapshot(base + [failed], change: .inPlace)), "failed again")
    }

    func testARebuiltTimelineIsANewBaseline() {
        var watch = SendFailureWatch()
        _ = watch.observe(snapshot([F.echo("e")], change: .reset, generation: 1))
        let failed = F.echo("e", delivery: .failed(isRecoverable: true))
        XCTAssertFalse(watch.observe(snapshot([failed], change: .inPlace, generation: 2)),
                       "a renewed session's timeline brings its rows back; nothing failed while I watched")
    }

    func testSomeoneElsesMessagesNeverBuzz() {
        var watch = SendFailureWatch()
        _ = watch.observe(snapshot([], change: .reset))
        XCTAssertFalse(watch.observe(snapshot([F.text("t", from: F.friend)], change: .appendedAtEnd(count: 1, localEcho: false))))
    }
}
