#if DEBUG
import AtumNativeAPI
import SwiftUI

/// `-AtumScripted google-write.gallery [-AtumGoogleWritePage open|busy|settled|work]`:
/// the Google write card in each state it can take, over synthetic store
/// projections, for W4-AA2's screenshots (desktop's `work-google-write-gallery`).
/// Nothing is sent; the buttons do nothing.
struct ScriptedGoogleWriteGallery: View {
    let design: LiveDesign

    enum Page: String { case open, busy, settled, work }

    @Environment(\.colorScheme) private var scheme

    private var page: Page {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-AtumGoogleWritePage"), flag + 1 < arguments.count else {
            return .open
        }
        return Page(rawValue: arguments[flag + 1]) ?? .open
    }

    var body: some View {
        ScrollView {
            VStack(spacing: design.kit.space(.s3)) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    GoogleWriteCard(presentation: card, design: design) { _ in }
                }
            }
            .padding(design.kit.space(.s4))
        }
        .background(design.color("ground", scheme: scheme).ignoresSafeArea())
        .accessibilityIdentifier("google-write.gallery.\(page.rawValue)")
    }

    private var cards: [GoogleWriteCardPresentation] {
        let assistant = GoogleWriteProposalSource.assistant(
            agentID: try! NativeID("bbbbbbbb-1111-4111-8111-b11111111111"), roomID: "!agent:example.test")
        func card(_ source: GoogleWriteProposalSource, _ kind: GoogleWriteProposalKind,
                  _ lines: [GoogleWritePreviewLine], _ state: GoogleWriteProposalState,
                  operation: GoogleMailboxOperation? = nil, canDecide: Bool = false) -> GoogleWriteCardPresentation? {
            GoogleWriteCardPresentation(source: source, kind: kind, lines: lines, operation: operation,
                                        state: state, canDecide: canDecide, resolve: { design.text($0) })
        }
        // Attachments are wire data (no public memberwise init): decode one as Shell sends it.
        let agenda = (try? JSONDecoder().decode([GoogleWriteAttachment].self, from: Data(
            #"[{"filename":"agenda.pdf","mimeType":"application/pdf","size":184320}]"#.utf8))) ?? []
        let email: [GoogleWritePreviewLine] = [
            .to(["lan@example.com"]), .cc(["minh@example.com"]), .subject("Thursday review"),
            .attachments(agenda),
            .reply, .threadID("thread"),
            .body("Hi Lan,\n\nThe review moves to Thursday at 10:00. The agenda is attached.\n\nThanks"),
            .quote("> Can we move the review?"),
        ]
        let event: [GoogleWritePreviewLine] = [
            .sourceID("calendar"), .title("Design review"), .start("2026-11-27T10:00:00+07:00"),
            .end("2026-11-27T11:00:00+07:00"), .location("Room 4"), .description("Walk through the phone cards."),
        ]
        let labels: [GoogleWritePreviewLine] = [
            .sourceID("gmail"), .mailboxTarget(conversation: true), .threadID("thread"), .labels(["Receipts", "2026"]),
        ]
        let draft: [GoogleWritePreviewLine] = [
            .sourceID("gmail"), .to(["team@example.com"]), .subject("Weekly notes"), .attachments([]),
            .body("Notes from this week."), .quote(""),
        ]
        let list: [GoogleWriteCardPresentation?] = switch page {
        case .open:
            [card(assistant, .sendEmail, email, .pending, canDecide: true),
             card(assistant, .createEvent, event, .pending, canDecide: true)]
        case .busy:
            [card(assistant, .sendEmail, email, .deciding(.approve)),
             card(assistant, .updateEvent, event, .deciding(.decline)),
             card(assistant, .createEvent, event, .failedRetryable, canDecide: true)]
        case .settled:
            [card(assistant, .sendEmail, email, .approved),
             card(assistant, .sendEmail, email, .declined),
             card(assistant, .createEvent, event, .superseded),
             card(assistant, .createEvent, event, .expired),
             card(assistant, .sendEmail, email, .changed)]
        case .work:
            [card(.work, .mailbox, labels, .pending, operation: .addLabels, canDecide: true),
             card(.work, .createDraft, draft, .reconciling),
             card(.work, .sendEmail, email, .approved),
             card(.work, .mailbox, labels, .declined, operation: .addLabels),
             card(.work, .createLabel, [.sourceID("gmail"), .name("Receipts")], .superseded),
             card(.work, .createEvent, event, .expired),
             card(.work, .updateEvent, event, .changed)]
        }
        return list.compactMap { $0 }
    }
}

/// `-AtumScriptedGoogleWrite`: the live `GoogleWriteProposalStore` over a
/// synthetic owner feed, so an assistant chat (`-AtumScripted chat.long`) and
/// Home (`-AtumScripted home.roster`) draw their real cards in place. The
/// feed lists one assistant email for the scripted chat and one Work mailbox
/// change; each decision is accepted after a second and leaves the list.
/// The drafts' digests are the platform's canonical-JSON SHA-256, so they
/// verify as pending.
@MainActor
enum ScriptedGoogleWrite {
    static let flag = "-AtumScriptedGoogleWrite"
    static let roomID = "!scripted-assistant:example.test"
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    static let store: GoogleWriteProposalStore = {
        let store = GoogleWriteProposalStore()
        store.bind(accountID: "@me:example.test", api: ScriptedGoogleWriteAPI())
        store.setForeground(true)
        return store
    }()
}

@MainActor
private final class ScriptedGoogleWriteAPI: GoogleWriteProposalAPI {
    private var listed: [GoogleWriteProposal]

    init() {
        let email = #"""
            {"to":["lan@example.com"],"cc":["minh@example.com"],"subject":"Thursday review",
             "body":"Hi Lan,\n\nThe review moves to Thursday at 10:00. The agenda is attached.\n\nThanks",
             "quote":"","references":[],"threadId":"thread-1",
             "attachments":[{"filename":"agenda.pdf","mimeType":"application/pdf","size":184320}]}
            """#
        let mailbox = #"""
            {"action":"mailbox","sourceId":"gmail","operation":"add_labels","threadId":"thread-2",
             "labels":["Receipts","2026"]}
            """#
        let rows = [
            Self.row(1, source: #""agent":"bbbbbbbb-1111-4111-8111-b11111111111","room":"\#(ScriptedGoogleWrite.roomID)""#,
                draft: email, digest: "3112c42dd9e35de4b581b01fbb237405008ca82088f2ce7c3a348449b8ab11c0"),
            Self.row(2, source: #""source":"work","agent":null,"room":null"#,
                draft: mailbox, digest: "334943368d347efdd7f0561026d3d895ea0b9371dd217b81b3481361c33b9a3a"),
        ]
        let data = Data(#"{"proposals":[\#(rows.joined(separator: ","))]}"#.utf8)
        listed = (try? JSONDecoder().decode(GoogleWriteProposalList.self, from: data).proposals) ?? []
    }

    private static func row(_ number: Int, source: String, draft: String, digest: String) -> String {
        let id = String(format: "aaaaaaaa-1111-4111-8111-a%011d", number)
        return #"{"proposalId":"\#(id)","operationId":"\#(id)",\#(source),"digest":"\#(digest)","#
            + #""status":"awaiting_owner","draft":\#(draft)}"#
    }

    func googleWriteProposals(isCurrent: @escaping NativeDispatchGate) async throws -> [GoogleWriteProposal] {
        listed
    }

    func decideGoogleWriteProposal(_ decision: GoogleWriteDecision, proposal: GoogleWriteProposal,
                                   isCurrent: @escaping NativeDispatchGate) async -> GoogleWriteDecisionResult {
        try? await Task.sleep(for: .seconds(1))
        listed.removeAll { $0.id == proposal.id }
        return .accepted
    }
}
#endif
