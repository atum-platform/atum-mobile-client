import XCTest
@testable import AtumChat

/// The agent's desk Now and Files (desktop #51 `agent-desk-model.ts`), the
/// panel's opening page, and Home's bell items (desktop #48).
final class AgentDeskPolicyTests: XCTestCase {
    private let agent = "@luna:atum.test"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: String, _ kind: ChatItem.Kind = .message, sender: String, own: Bool = false,
                     at minutes: Double = 0, body: String = "", media: Bool = false) -> ChatRow {
        ChatRow(item: ChatItem(id: id, kind: kind, sender: sender, isOwn: own,
                               timestamp: base.addingTimeInterval(minutes * 60), body: body,
                               media: media ? ChatMedia(sourceHandle: "mxc://" + id, filename: id + ".pdf") : nil))
    }

    func testNowIsFreeWithoutTheWorkingFooter() {
        XCTAssertEqual(AgentDeskPolicy.now(rows: [row("a", sender: "@me:atum.test", own: true)]), .free)
    }

    func testNowReadsTheFootersLineAndStepsSinceTheQuestion() {
        let rows = [row("q", sender: "@me:atum.test", own: true, at: 1, body: "Viết giúp mình"),
                    row("typing", .typing(names: []), sender: "", body: "Đang soạn…\n✓ Đọc tệp\n• Viết tóm tắt")]
        guard case let .working(since, line, steps) = AgentDeskPolicy.now(rows: rows) else {
            return XCTFail("not working")
        }
        XCTAssertEqual(since, base.addingTimeInterval(60))
        XCTAssertEqual(line, "Đang soạn…")
        XCTAssertEqual(steps, [.init(text: "Đọc tệp", done: true), .init(text: "Viết tóm tắt", done: false)])
    }

    func testMinutesStartAtOneWholeMinute() {
        XCTAssertNil(AgentDeskPolicy.minutes(since: nil, now: base))
        XCTAssertNil(AgentDeskPolicy.minutes(since: base, now: base.addingTimeInterval(59)))
        XCTAssertEqual(AgentDeskPolicy.minutes(since: base, now: base.addingTimeInterval(4 * 60 + 30)), 4)
    }

    func testSentFilesAreTheAgentsOwnNewestFour() {
        var rows = (0..<6).map { row("f\($0)", .file(name: "f\($0).pdf"), sender: agent, at: Double($0), media: true) }
        rows.append(row("mine", .file(name: "mine.pdf"), sender: "@me:atum.test", own: true, at: 9, media: true))
        rows.append(row("other", .file(name: "o.pdf"), sender: "@eve:atum.test", at: 9, media: true))
        rows.append(row("text", sender: agent, at: 9, body: "hi"))
        XCTAssertEqual(AgentDeskPolicy.sentFiles(rows: rows, agentUserID: agent).map(\.id), ["f5", "f4", "f3", "f2"])
        XCTAssertEqual(AgentDeskPolicy.sentFiles(rows: rows, agentUserID: nil), [])
    }

    func testAnAssistantChatWithADeskOpensOnIt() {
        XCTAssertEqual(ChatPanelPolicy.openingPage(for: .assistant, hasAgentDesk: true), .agentDesk)
        XCTAssertNil(ChatPanelPolicy.openingPage(for: .assistant, hasAgentDesk: false))
        XCTAssertNil(ChatPanelPolicy.openingPage(for: .person, hasAgentDesk: true))
        XCTAssertEqual(ChatPanelPolicy.openingHeight(for: .assistant, page: .agentDesk), .medium)
        XCTAssertEqual(ChatPanelPolicy.openingHeight(for: .assistant), .large)
    }

    func testTheBellListsOnlyWhatThePhoneKnowsInDesktopsOrder() {
        XCTAssertEqual(AttentionBellPolicy.items(.init()), [])
        XCTAssertEqual(AttentionBellPolicy.items(.init(freshSpendable: 5)), [])
        XCTAssertEqual(AttentionBellPolicy.items(.init(signInRequired: true, freshSpendable: 0)), [.signIn, .protons])
        XCTAssertEqual(AttentionBellPolicy.tone([]), nil)
        XCTAssertEqual(AttentionBellPolicy.tone([.protons]), .warn)
        XCTAssertEqual(AttentionBellPolicy.labelKey(.signIn), "src.matrix.attention-copy.copies.items.sign_in")
    }
}
