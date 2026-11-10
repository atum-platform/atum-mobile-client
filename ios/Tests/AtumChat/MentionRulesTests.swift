import XCTest
@testable import AtumChat

/// The `@` picker and the send payload (U2): the query at the end of the
/// draft, the suggestions, the inserted text, and the `m.mentions.user_ids`
/// plus pill HTML a send carries.
final class MentionRulesTests: XCTestCase {
    private let anna = MentionCandidate(userID: "@anna:atum.test", name: "Anna Lê", handle: "anna")
    private let binh = MentionCandidate(userID: "@binh:atum.test", name: "Bình", handle: "binh")
    private let dung = MentionCandidate(userID: "@dung:atum.test", name: "Đũng Trần", handle: "dung")

    private var all: [MentionCandidate] { [anna, binh, dung] }

    // MARK: Query

    func testQueryIsTheAtWordAtTheEndOfTheDraft() {
        XCTAssertEqual(MentionRules.activeQuery(in: "@"), "")
        XCTAssertEqual(MentionRules.activeQuery(in: "hi @an"), "an")
        XCTAssertEqual(MentionRules.activeQuery(in: "hi\n@bi"), "bi")
    }

    func testNoQueryInsideAWordAfterASpaceOrForLongText() {
        XCTAssertNil(MentionRules.activeQuery(in: "mail me at a@b"))
        XCTAssertNil(MentionRules.activeQuery(in: "hi @anna "))
        XCTAssertNil(MentionRules.activeQuery(in: "hi @anna le"))
        XCTAssertNil(MentionRules.activeQuery(in: "no mention"))
        XCTAssertNil(MentionRules.activeQuery(in: "@" + String(repeating: "x", count: 41)))
    }

    // MARK: Suggestions

    func testSuggestionsMatchNameWordsAndHandlesIgnoringDiacritics() {
        XCTAssertEqual(MentionRules.suggestions(for: "an", in: all).map(\.userID), ["@anna:atum.test"])
        XCTAssertEqual(MentionRules.suggestions(for: "binh", in: all).map(\.userID), ["@binh:atum.test"])
        XCTAssertEqual(MentionRules.suggestions(for: "tran", in: all).map(\.userID), ["@dung:atum.test"])
        XCTAssertEqual(MentionRules.suggestions(for: "du", in: all).map(\.userID), ["@dung:atum.test"])
        XCTAssertTrue(MentionRules.suggestions(for: "zzz", in: all).isEmpty)
    }

    func testEmptyQueryListsEveryoneUpToTheLimitInNameOrder() {
        XCTAssertEqual(MentionRules.suggestions(for: "", in: all).map(\.name), ["Anna Lê", "Bình", "Đũng Trần"])
        XCTAssertEqual(MentionRules.suggestions(for: "", in: all, limit: 2).count, 2)
    }

    func testCandidatesDropTheOwnAccountAndUseTheRosterNameForABareUserID() {
        let candidates = MentionRules.candidates(
            members: [("@me:atum.test", "Me"), ("@anna:atum.test", "@anna:atum.test"), ("@binh:atum.test", "Bình")],
            roster: [MentionRosterEntry(handle: "anna", name: "Anna Lê")],
            ownUserID: "@me:atum.test")
        XCTAssertEqual(candidates.map(\.userID), ["@anna:atum.test", "@binh:atum.test"])
        XCTAssertEqual(candidates.first?.name, "Anna Lê")
        XCTAssertEqual(candidates.first?.handle, "anna")
        XCTAssertEqual(candidates.last?.name, "Bình")
    }

    func testAnOpaqueAllocatedIDIsNeverOfferedAsAHandle() {
        let opaque = "@user-0123456789abcdef0123456789abcdef:atum.test"
        let candidates = MentionRules.candidates(members: [(opaque, "Atum user"), ("@binh:atum.test", "Bình")],
                                                 ownUserID: "@me:atum.test")
        XCTAssertEqual(candidates.map(\.handle), [nil, "binh"])
    }

    // MARK: Insert

    func testPickReplacesTheTrailingQueryWithTheNameAndASpace() throws {
        let inserted = try XCTUnwrap(MentionRules.insert(anna, among: all, into: "hi @an"))
        XCTAssertEqual(inserted.draft, "hi @Anna Lê ")
        XCTAssertEqual(inserted.token, "@Anna Lê")
        XCTAssertNil(MentionRules.insert(anna, among: all, into: "no query"))
    }

    func testTwoPeopleWithOneNameGetTheirHandleInTheInsertedText() {
        let other = MentionCandidate(userID: "@anna2:atum.test", name: "Anna Lê", handle: "anna2")
        XCTAssertEqual(MentionRules.token(for: anna, among: [anna, other]), "@Anna Lê (anna)")
        XCTAssertEqual(MentionRules.token(for: other, among: [anna, other]), "@Anna Lê (anna2)")
    }

    // MARK: Resolve

    func testASurvivingPickSendsItsUserIDAndAPillBody() throws {
        var draft = MentionDraft()
        draft.register(token: "@Anna Lê", userID: anna.userID)
        let resolved = MentionRules.resolve(text: "hi @Anna Lê, ready?", draft: draft)
        XCTAssertEqual(resolved.userIDs, ["@anna:atum.test"])
        XCTAssertEqual(resolved.formattedHTML,
                       "hi <a href=\"https://matrix.to/#/@anna:atum.test\">@Anna Lê</a>, ready?")
    }

    func testAPickEditedAwayOrExtendedSendsNoMention() {
        var draft = MentionDraft()
        draft.register(token: "@Anna Lê", userID: anna.userID)
        XCTAssertEqual(MentionRules.resolve(text: "hi Anna", draft: draft), .none)
        XCTAssertEqual(MentionRules.resolve(text: "hi @Anna Lêx", draft: draft), .none)
        XCTAssertEqual(MentionRules.resolve(text: "mail@Anna Lê", draft: draft), .none)
    }

    func testTwoMentionsAndARepeatListEachPersonOnce() {
        var draft = MentionDraft()
        draft.register(token: "@Anna Lê", userID: anna.userID)
        draft.register(token: "@Bình", userID: binh.userID)
        let resolved = MentionRules.resolve(text: "@Bình @Anna Lê @Bình", draft: draft)
        XCTAssertEqual(resolved.userIDs, ["@binh:atum.test", "@anna:atum.test"])
    }

    func testHTMLEscapesTheTypedTextAndKeepsLineBreaks() throws {
        var draft = MentionDraft()
        draft.register(token: "@Bình", userID: binh.userID)
        let resolved = MentionRules.resolve(text: "a < b & @Bình\nok", draft: draft)
        XCTAssertEqual(resolved.formattedHTML,
                       "a &lt; b &amp; <a href=\"https://matrix.to/#/@binh:atum.test\">@Bình</a><br>ok")
    }

    func testTextWithNoPicksIsLeftAsPlainText() {
        XCTAssertEqual(MentionRules.resolve(text: "hi @Anna Lê", draft: MentionDraft()), .none)
    }

    // MARK: Ledger (picks live per message, not per chat)

    func testAPickDoesNotOutliveTheMessageItWasSentWith() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.stage(text: "@Anna Lê hi")
        XCTAssertEqual(ledger.mentions(for: "@Anna Lê hi").userIDs, [anna.userID])
        ledger.delivered(text: "@Anna Lê hi")
        // The next message: Anna's name typed by hand, never picked.
        ledger.draftChanged(to: "@Anna Lê again")
        ledger.stage(text: "@Anna Lê again")
        XCTAssertEqual(ledger.mentions(for: "@Anna Lê again"), .none)
    }

    func testSequentialSendsEachKeepTheirOwnPicks() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.stage(text: "@Anna Lê one")
        ledger.register(token: "@Bình", userID: binh.userID)
        ledger.stage(text: "@Bình two")
        ledger.stage(text: "@Anna Lê three")
        XCTAssertEqual(ledger.mentions(for: "@Anna Lê one").userIDs, [anna.userID])
        XCTAssertEqual(ledger.mentions(for: "@Bình two").userIDs, [binh.userID])
        XCTAssertEqual(ledger.mentions(for: "@Anna Lê three"), .none)
    }

    func testDeletingAPickAndTypingTheNameAgainMentionsNobody() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.draftChanged(to: "hi @Anna Lê ")
        XCTAssertFalse(ledger.current.isEmpty)
        ledger.draftChanged(to: "hi ")
        XCTAssertTrue(ledger.current.isEmpty)
        ledger.draftChanged(to: "hi @Anna Lê ")
        ledger.stage(text: "hi @Anna Lê")
        XCTAssertEqual(ledger.mentions(for: "hi @Anna Lê"), .none)
    }

    func testARefusedSendGivesItsPicksBackWithItsText() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.stage(text: "@Anna Lê hi")
        XCTAssertTrue(ledger.current.isEmpty)
        ledger.refused(text: "@Anna Lê hi", draft: "@Anna Lê hi")
        XCTAssertEqual(ledger.current.picks, ["@Anna Lê": anna.userID])
        // Sent again from the restored draft, it still mentions Anna.
        ledger.stage(text: "@Anna Lê hi")
        XCTAssertEqual(ledger.mentions(for: "@Anna Lê hi").userIDs, [anna.userID])
    }

    func testARefusedSendKeepsOnlyPicksTheRestoredDraftStillHolds() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.stage(text: "@Anna Lê hi")
        ledger.refused(text: "@Anna Lê hi", draft: "something else")
        XCTAssertTrue(ledger.current.isEmpty)
    }

    func testHeldSendsReturnedToTheComposerRestoreTheirPicks() {
        var ledger = MentionLedger()
        ledger.register(token: "@Anna Lê", userID: anna.userID)
        ledger.stage(text: "@Anna Lê hi")
        ledger.restoreStaged(in: "draft @Anna Lê hi")
        XCTAssertEqual(ledger.current.picks, ["@Anna Lê": anna.userID])
    }

    // MARK: Send payload

    /// The payload reaches the source: `userIDs` for `m.mentions.user_ids` and
    /// the pill HTML ride with the text; a message without mentions still
    /// takes the plain path.
    func testSendCarriesTheMentionPayloadToTheSource() async throws {
        let source = PayloadSource()
        var draft = MentionDraft()
        draft.register(token: "@Anna Lê", userID: anna.userID)
        let mentions = MentionRules.resolve(text: "@Anna Lê hi", draft: draft)
        try await SendQueueRules.send(text: "@Anna Lê hi", replyTo: nil, mentions: mentions, on: source)
        try await SendQueueRules.send(text: "plain", replyTo: nil, on: source)
        XCTAssertEqual(source.sent.map(\.text), ["@Anna Lê hi", "plain"])
        XCTAssertEqual(source.sent.first?.mentions.userIDs, ["@anna:atum.test"])
        XCTAssertNotNil(source.sent.first?.mentions.formattedHTML)
        XCTAssertEqual(source.sent.last?.mentions, OutgoingMentions.none)
    }

    func testOnlyPeopleAndGroupChatsOfferTheMentionPicker() {
        XCTAssertTrue(ComposerRules.offersMentions(kind: .group))
        XCTAssertTrue(ComposerRules.offersMentions(kind: .person))
        XCTAssertFalse(ComposerRules.offersMentions(kind: .assistant))
        XCTAssertFalse(ComposerRules.offersMentions(kind: .appBot))
    }

    final class PayloadSource: ChatTimelineSource, @unchecked Sendable {
        struct Sent { let text: String; let mentions: OutgoingMentions }
        private let lock = NSLock()
        private var _sent = [Sent]()
        let outputs = AsyncStream<ChatTimelineOutput> { $0.finish() }
        var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
        private func add(_ item: Sent) { lock.lock(); _sent.append(item); lock.unlock() }

        func start() async {}
        func stop() async {}
        func send(text: String, replyTo eventID: String?) async throws {
            add(Sent(text: text, mentions: .none))
        }
        func send(text: String, replyTo eventID: String?, mentions: OutgoingMentions) async throws {
            add(Sent(text: text, mentions: mentions))
        }
        func edit(_ item: ChatEventRef, text: String) async throws {}
        func redact(_ item: ChatEventRef) async throws {}
        func toggleReaction(_ item: ChatEventRef, key: String) async throws {}
        func isSendQueueEnabled() async -> Bool { true }
        func enableSendQueue() async {}
        func retrySend(_ item: ChatEventRef) async throws {}
        func abortSend(_ item: ChatEventRef) async throws {}
        func paginateBackwards(numEvents: UInt16) async throws -> Bool { false }
        func sendReceipt(_ receipt: ChatReceipt) async throws {}
        func fetchReplyDetails(eventID: String) async {}
    }
}
