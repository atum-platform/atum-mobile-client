import AtumDesign
import Foundation
import XCTest
@testable import AtumNativeAPI

final class GoogleWriteCardPresentationTests: XCTestCase {
    private typealias Card = GoogleWriteCardPresentation
    private typealias Keys = GoogleWriteCardPresentation.Keys

    private let assistant = GoogleWriteProposalSource.assistant(
        agentID: try! NativeID("bbbbbbbb-1111-4111-8111-b11111111111"), roomID: "!agent:example.test")

    private let email: [GoogleWritePreviewLine] = [
        .to(["person@example.test", "second@example.test"]), .cc([]), .bcc(["blind@example.test"]),
        .subject("Plan"), .forwarded(from: "", subject: "Prior"),
        .attachments([.init(filename: "notes.txt", mimeType: "text/plain", size: 42, sha256: nil)]),
        .reply, .threadID("thread"), .body("line 1\n**not markdown**"), .quote("original"), .quoteTruncated,
    ]

    private let event: [GoogleWritePreviewLine] = [
        .sourceID("calendar"), .eventID("event"), .title("Review"), .start("2026-11-26T08:00:00+07:00"),
        .end("2026-11-26T09:00:00+07:00"), .cleared(.location), .description("Discuss"),
    ]

    private func card(_ source: GoogleWriteProposalSource? = nil, kind: GoogleWriteProposalKind = .sendEmail,
                      lines: [GoogleWritePreviewLine]? = nil, operation: GoogleMailboxOperation? = nil,
                      state: GoogleWriteProposalState = .pending, canDecide: Bool = true) -> Card? {
        Card(source: source ?? assistant, kind: kind, lines: lines ?? email, operation: operation,
             state: state, canDecide: canDecide, resolve: { $0 })
    }

    func testPendingEmailDrawsDesktopGridThenNoteBodyAndQuote() throws {
        let card = try XCTUnwrap(card())
        XCTAssertEqual(card.glyph, .mail)
        XCTAssertEqual(card.question, "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.message.send-email")
        XCTAssertEqual(card.phase, .open(canDecide: true, busy: nil, retryLine: nil))
        XCTAssertEqual(card.blocks, [
            .row(label: Keys.to, value: .text("person@example.test, second@example.test")),
            .row(label: Keys.bcc, value: .text("blind@example.test")),
            .row(label: Keys.subject, value: .text("Plan")),
            .row(label: Keys.forwarded, value: .text("Prior")),
            .row(label: Keys.attachments,
                 value: .attachments([.init(filename: "notes.txt", mimeType: "text/plain", size: 42, sha256: nil)])),
            .note(Keys.inReplyTo),
            .text("line 1\n**not markdown**"),
            .quote(label: Keys.quote, text: "original", truncatedNote: Keys.truncated),
        ])
    }

    func testEventShowsRemovalRowsOnlyForExplicitClears() throws {
        let omitted = Array(event.dropLast(2))
        let unchanged = try XCTUnwrap(card(.work, kind: .updateEvent, lines: omitted))
        XCTAssertEqual(unchanged.glyph, .calendar)
        XCTAssertEqual(unchanged.question, "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.message.update-event")
        XCTAssertEqual(unchanged.blocks, [
            .row(label: Keys.title, value: .text("Review")),
            .row(label: Keys.start, value: .time("2026-11-26T08:00:00+07:00")),
            .row(label: Keys.end, value: .time("2026-11-26T09:00:00+07:00")),
        ])
        let clearLocation = try XCTUnwrap(card(.work, kind: .updateEvent, lines: event))
        XCTAssertEqual(clearLocation.blocks, unchanged.blocks + [
            .row(label: Keys.location, value: .removal(Keys.clear)), .text("Discuss"),
        ])
        XCTAssertTrue(clearLocation.showsApprove)
        let clearBoth = try XCTUnwrap(card(.work, kind: .updateEvent,
                                          lines: omitted + [.cleared(.location), .cleared(.description)]))
        XCTAssertEqual(clearBoth.blocks, unchanged.blocks + [
            .row(label: Keys.location, value: .removal(Keys.clear)),
            .row(label: Keys.details, value: .removal(Keys.clear)),
        ])
        XCTAssertFalse(clearBoth.showsApprove)
        XCTAssertEqual(clearBoth.phase, .open(canDecide: true, busy: nil, retryLine: nil))

        let createdEmpty = try XCTUnwrap(card(.work, kind: .createEvent,
                                             lines: omitted + [.cleared(.location), .cleared(.description)]))
        XCTAssertEqual(createdEmpty.blocks, unchanged.blocks)
        XCTAssertTrue(createdEmpty.showsApprove)
    }

    func testGmailMailboxAndDraftReplacementOfferDeclineAndMacNotice() throws {
        let mailbox = try XCTUnwrap(card(.work, kind: .mailbox, lines: [.mailboxTarget(conversation: true)],
                                        operation: .trash))
        let replacement = try XCTUnwrap(card(.work, kind: .updateDraft))
        for blocked in [mailbox, replacement] {
            XCTAssertFalse(blocked.showsApprove)
            XCTAssertEqual(blocked.approvalNotice, Keys.approvalOnMac)
            XCTAssertEqual(blocked.phase, .open(canDecide: true, busy: nil, retryLine: nil))
        }
        XCTAssertTrue(try XCTUnwrap(card(.work, kind: .createDraft)).showsApprove)
    }

    func testBusyReconcilingAndRetryStates() throws {
        XCTAssertEqual(card(state: .deciding(.approve), canDecide: false)?.phase,
                       .open(canDecide: false, busy: .approve, retryLine: nil))
        XCTAssertEqual(card(state: .deciding(.decline), canDecide: false)?.phase,
                       .open(canDecide: false, busy: .decline, retryLine: nil))
        // Reconciling never claims a request is in flight and never offers the actions.
        XCTAssertEqual(card(state: .reconciling, canDecide: false)?.phase,
                       .open(canDecide: false, busy: nil, retryLine: nil))
        XCTAssertEqual(card(state: .failedRetryable)?.phase,
                       .open(canDecide: true, busy: nil, retryLine: Keys.retry))
        // The store's availability wins: a pending card it cannot decide stays disabled.
        XCTAssertEqual(card(state: .pending, canDecide: false)?.phase,
                       .open(canDecide: false, busy: nil, retryLine: nil))
    }

    func testSettledLinesFollowDesktopPerSource() throws {
        let prefix = "src.matrix.google-write-card-copy.copies."
        let cases: [(GoogleWriteProposalState, String, String)] = [
            (.approved, "approved", "work.approved"),
            (.declined, "declined", "work.declined"),
            (.superseded, "superseded", "work.superseded"),
            (.changed, "changed", "work.changed"),
            (.closed, "closed", "work.expired"),
            (.expired, "closed", "work.expired"),
        ]
        for (state, assistantLine, workLine) in cases {
            XCTAssertEqual(card(state: state)?.phase, .settled(summary: "Plan", line: prefix + assistantLine), "\(state)")
            XCTAssertEqual(card(.work, state: state)?.phase, .settled(summary: "Plan", line: prefix + workLine), "\(state)")
            XCTAssertEqual(card(state: state)?.isOpen, false)
        }
        XCTAssertEqual(card(.work, state: .outcomeUnknown)?.phase, .settled(summary: "Plan", line: Keys.unknown))
    }

    func testSettledSummaryNamesTheRequest() throws {
        let mailbox: [GoogleWritePreviewLine] = [.sourceID("gmail"), .mailboxTarget(conversation: true),
                                                 .threadID("thread")]
        let archive = try XCTUnwrap(Card(source: .work, kind: .mailbox, lines: mailbox, operation: .archive,
                                         state: .approved, canDecide: false,
                                         resolve: { $0 == Keys.mailbox(.archive) ? "Archive this in Gmail?" : $0 }))
        XCTAssertEqual(archive.glyph, .mailbox)
        XCTAssertEqual(archive.phase, .settled(summary: "Archive this in Gmail", line: Keys.settled(.approved, work: true)))
        XCTAssertEqual(archive.blocks, [.row(label: Keys.appliesTo, value: .text(Keys.conversation))])

        let labelled = try XCTUnwrap(card(.work, kind: .mailbox, lines: [
            .sourceID("gmail"), .mailboxTarget(conversation: false), .messageID("m"), .labels(["A", "B"]),
        ], operation: .addLabels, state: .declined))
        XCTAssertEqual(labelled.question, "src.matrix.google-write-card-copy.copies.mailbox.add_labels")
        XCTAssertEqual(labelled.phase, .settled(summary: "A, B", line: Keys.settled(.declined, work: true)))
        XCTAssertEqual(labelled.blocks, [.row(label: Keys.appliesTo, value: .text(Keys.oneEmail)),
                                         .row(label: Keys.labels, value: .text("A, B"))])

        let label = try XCTUnwrap(card(.work, kind: .createLabel, lines: [.sourceID("gmail"), .name("Receipts")],
                                       state: .superseded))
        XCTAssertEqual(label.glyph, .label)
        XCTAssertEqual(label.blocks, [.row(label: Keys.name, value: .text("Receipts"))])
        XCTAssertEqual(label.phase, .settled(summary: "Receipts", line: Keys.settled(.superseded, work: true)))

        XCTAssertEqual(card(kind: .createEvent, lines: event, state: .closed)?.phase,
                       .settled(summary: "Review", line: Keys.settled(.closed, work: false)))
        XCTAssertEqual(card(.work, kind: .createDraft, state: .pending)?.glyph, .draft)
    }

    func testUnsupportedProposalsDrawNothing() {
        XCTAssertNil(card(.unsupported("future")))
        XCTAssertNil(card(kind: .unsupported("future_action")))
        XCTAssertNil(card(state: .unsupported))
        XCTAssertNil(card(.work, kind: .mailbox, lines: [], operation: nil))
    }

    func testEveryCardKeyIsPinnedWithoutArgumentsInEnglishAndVietnamese() throws {
        let copy = try AtumCopy()
        let keys = Keys.all
        // 49 card keys and four reused pinned strings for removal, handoff and uncertain outcome.
        XCTAssertEqual(Set(keys).count, 53)
        XCTAssertFalse(keys.contains("src.matrix.google-write-card-copy.copies.work.source"))
        for key in keys {
            XCTAssertEqual(copy.parameterKinds(key), [], key)
            for locale in ["en", "vi"] {
                XCTAssertFalse(try copy.text(key, locale: locale).isEmpty, "\(locale): \(key)")
            }
        }
        XCTAssertEqual(try copy.text(Keys.approving, locale: "vi"), "Đang duyệt…")
        XCTAssertEqual(try copy.text(Keys.settled(.closed, work: true), locale: "en"), "This request expired.")
    }

    func testTimesAndSizesUseTheOwnerLocale() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let english = Card.time("2026-11-26T08:00:00+07:00", locale: Locale(identifier: "en_US"), timeZone: zone)
        XCTAssertTrue(english.contains("Nov 26, 2026"), english)
        XCTAssertTrue(english.contains("8:00"), english)
        let vietnamese = Card.time("2026-11-26T01:00:00.000Z", locale: Locale(identifier: "vi"), timeZone: zone)
        XCTAssertTrue(vietnamese.contains("2026"), vietnamese)
        XCTAssertTrue(vietnamese.contains("08:00"), vietnamese)
        XCTAssertEqual(Card.time("next week", locale: Locale(identifier: "en_US"), timeZone: zone), "next week")

        let files: [GoogleWriteAttachment] = [.init(filename: "a.pdf", mimeType: "application/pdf", size: 1_540_000,
                                                    sha256: nil),
                                              .init(filename: "b.txt", mimeType: "text/plain", size: 12_000, sha256: nil)]
        XCTAssertEqual(Card.attachments(files, locale: Locale(identifier: "en_US")), "a.pdf · 1.5 MB, b.txt · 12 kB")
        XCTAssertTrue(Card.attachments(files, locale: Locale(identifier: "vi")).hasPrefix("a.pdf · 1,5 MB"))
    }
}
