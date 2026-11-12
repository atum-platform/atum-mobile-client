import XCTest
@testable import AtumChat

/// Long messages fold (owner, 2026-11-11; `MessageFold`).
final class MessageFoldTests: XCTestCase {
    private func message(_ id: String, own: Bool = false) -> ChatRow {
        ChatRow(item: ChatItem(id: id, kind: .message, sender: own ? "@me:atum" : "@atum:atum", isOwn: own,
                               eventOrTransactionId: .event(id), body: id))
    }

    private func progress(_ id: String, _ phase: ChatProgress.Phase) -> ChatRow {
        var item = ChatItem(id: id, kind: .notice, sender: "@atum:atum", eventOrTransactionId: .event(id), body: "…")
        item.progress = ChatProgress(phase: phase)
        return ChatRow(item: item)
    }

    private let typing = ChatRow(item: ChatItem(id: "atum.typing", kind: .typing(names: ["Atum"])))

    func testMoreThanTwentyLinesFoldToTwelve() {
        XCTAssertEqual(MessageFold.foldsAfterLines, 20)
        XCTAssertEqual(MessageFold.foldedLines, 12)
        XCTAssertFalse(MessageFold.isLong(lines: 20))
        XCTAssertTrue(MessageFold.isLong(lines: 21))
        XCTAssertGreaterThanOrEqual(MessageFold.foldsAfterLines - MessageFold.foldedLines, 8,
                                    "a fold always hides several lines")
    }

    func testLinesAreCountedFromTheRenderedHeight() {
        XCTAssertEqual(MessageFold.lines(height: 22 * 20, lineHeight: 22), 20)
        XCTAssertEqual(MessageFold.lines(height: 22 * 21 + 8, lineHeight: 22), 21, "block spacing rounds away")
        XCTAssertEqual(MessageFold.lines(height: 100, lineHeight: 0), 0)
    }

    func testAFinalLongMessageStartsFolded() {
        let book = MessageFoldBook()
        XCTAssertTrue(book.isFolded("$a", isLong: true, isGrowing: false))
        XCTAssertFalse(book.isFolded("$a", isLong: false, isGrowing: false), "short messages never fold")
        XCTAssertTrue(MessageFoldBook.showsToggle(isLong: true, isGrowing: false))
        XCTAssertFalse(MessageFoldBook.showsToggle(isLong: false, isGrowing: false))
    }

    func testAGrowingMessageNeverFoldsAndFoldsOnceFinal() {
        var book = MessageFoldBook()
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: true))
        XCTAssertFalse(MessageFoldBook.showsToggle(isLong: true, isGrowing: true), "no toggle while streaming")
        book.readerSees([], among: ["$a"])
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: true), "still growing: still open")
        XCTAssertTrue(book.isFolded("$a", isLong: true, isGrowing: false),
                      "seen growing (owner, 2026-11-12): it folds once final")
        XCTAssertTrue(MessageFoldBook.showsToggle(isLong: true, isGrowing: false), "Show more is offered")
        book.toggle("$a", wasFolded: true)
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false), "the reader can open it")
    }

    func testOpeningOneMessageLeavesTheNextLiveAnswerFolded() {
        var book = MessageFoldBook()
        book.toggle("$a", wasFolded: true)
        book.readerSees([], among: ["$b"])
        XCTAssertFalse(book.isFolded("$b", isLong: true, isGrowing: true))
        XCTAssertTrue(book.isFolded("$b", isLong: true, isGrowing: false), "the next long answer folds")
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false), "the opened one stays open")
    }

    func testAMessageBeingReadBelowItsFoldStaysOpenOnceFinal() {
        var book = MessageFoldBook()
        book.readerSees(["$a"], among: ["$a", "$b"])
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false),
                       "the reader was reading below its fold line when it became final")
        XCTAssertTrue(book.isFolded("$b", isLong: true, isGrowing: false))
        // Once final, it is no longer growing and later passes leave it alone.
        book.readerSees([], among: ["$c"])
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false))
        XCTAssertTrue(MessageFoldBook.showsToggle(isLong: true, isGrowing: false), "Show less is offered")
        book.toggle("$a", wasFolded: false)
        XCTAssertTrue(book.isFolded("$a", isLong: true, isGrowing: false), "the reader can still fold it")
    }

    func testOnlyTheLastPassBeforeFinalCounts() {
        var book = MessageFoldBook()
        book.readerSees(["$a"], among: ["$a"])
        book.readerSees([], among: ["$a"])
        XCTAssertTrue(book.isFolded("$a", isLong: true, isGrowing: false), "the reader scrolled away before it ended")
    }

    func testTheReadersChoiceIsKeptPerEvent() {
        var book = MessageFoldBook()
        book.toggle("$a", wasFolded: true)
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false))
        XCTAssertTrue(book.isFolded("$b", isLong: true, isGrowing: false), "other messages keep their own state")
        book.readerSees(["$a"], among: ["$a"])
        book.toggle("$a", wasFolded: false)
        book.readerSees(["$a"], among: ["$a"])
        XCTAssertTrue(book.isFolded("$a", isLong: true, isGrowing: false), "a later growing pass does not undo a choice")
        book.toggle("$a", wasFolded: true)
        book.readerSees([], among: ["$a"])
        XCTAssertFalse(book.isFolded("$a", isLong: true, isGrowing: false), "nor does a pass that saw nothing")
    }

    func testMessagesAfterMyNewestWhileTheAgentWorksAreGrowing() {
        let rows = [message("$old"), message("$q", own: true), message("$interim"), message("$answer"), typing]
        XCTAssertEqual(MessageFold.growingIDs(in: rows), ["$interim", "$answer"])
    }

    func testALiveWorkingLineCountsAsWorkingButASettledOneDoesNot() {
        XCTAssertEqual(MessageFold.growingIDs(in: [message("$q", own: true), message("$a"), progress("$p", .working)]),
                       ["$a"])
        XCTAssertEqual(MessageFold.growingIDs(in: [message("$q", own: true), message("$a"), progress("$p", .settled)]),
                       [])
    }

    func testNothingGrowsWhenTheAgentIsIdle() {
        XCTAssertEqual(MessageFold.growingIDs(in: [message("$q", own: true), message("$a")]), [])
        XCTAssertEqual(MessageFold.growingIDs(in: [message("$a"), typing, message("$q", own: true)]), [],
                       "typing before my newest message is someone else's turn")
    }

    func testTheToggleWordsCoverEveryLocale() {
        XCTAssertEqual(Set(MessageFoldPendingCopy.locales), ["en", "ja", "vi", "zh", "zh-Hant"])
        for locale in MessageFoldPendingCopy.locales {
            for key in MessageFoldPendingCopy.Key.allCases {
                let word = MessageFoldPendingCopy.text(key, locale: locale)
                XCTAssertFalse(word.isEmpty)
                XCTAssertNotEqual(word, key.rawValue, "\(locale) \(key)")
            }
            XCTAssertNotEqual(MessageFoldPendingCopy.text(.showMore, locale: locale),
                              MessageFoldPendingCopy.text(.showLess, locale: locale))
        }
        XCTAssertEqual(MessageFoldPendingCopy.text(.showMore, locale: "en"), "Show more")
        XCTAssertEqual(MessageFoldPendingCopy.text(.showLess, locale: "vi"), "Thu gọn")
        XCTAssertEqual(MessageFoldPendingCopy.text(.showMore, locale: "fr"), "Show more", "English otherwise")
        XCTAssertEqual(MessageFoldPendingCopy.Key.showMore.exportKey, "src.matrix.mobile-copy.mobileChatCopy.showMore")
    }
}
