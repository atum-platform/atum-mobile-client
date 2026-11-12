import XCTest
@testable import AtumChat

/// Desktop timeline parity (2026-11-11): the scripted `chat.timeline-parity`
/// chat at the moments the captures are taken, through the real player,
/// reducer and projection.
final class TimelineParityTests: XCTestCase {
    private let env = ScriptedEnvironment(reference: Date(timeIntervalSince1970: 1_800_000_000))

    private func rows(after seconds: TimeInterval) throws -> [ChatRow] {
        let script = try XCTUnwrap(ScriptedScenarios.selection(named: "chat.timeline-parity", environment: env)?.chat)
        return ScriptedScenarios.rows(script, after: seconds, environment: env, options: .s1)
    }

    func testAtumsSeenFaceSitsUnderMyMessageAtOpen() throws {
        let rows = try rows(after: 0.5)
        let question = try XCTUnwrap(rows.first { $0.id == "chat.timeline-parity.question" })
        XCTAssertEqual(question.delivery, .seen(readerCount: 1))
        XCTAssertEqual(question.readers.map(\.userID), [ScriptedCast.atum])
        XCTAssertNotEqual(rows.last?.id, Projection.typingRowID, "nobody types yet")
    }

    func testTypingIsTheAtomRowThenTheWorkingLineTakesItsPlace() throws {
        XCTAssertEqual(try rows(after: 4).last?.id, Projection.typingRowID, "Atum types: the atom alone")
        let working = try rows(after: 6.5)
        XCTAssertEqual(working.last?.id, Projection.typingRowID)
        XCTAssertFalse(working.contains { $0.id == "chat.timeline-parity.working" },
                       "one working row, never a typing bubble above the line")
        let edited = try XCTUnwrap(try rows(after: 9).last)
        XCTAssertEqual(WorkingLineText(body: edited.item.body),
                       WorkingLineText(current: "Đang chạy tác vụ…",
                                       steps: [.init(text: "Đọc báo cáo quý 3", done: true),
                                               .init(text: "Viết bản tóm tắt", done: false)]))
    }

    func testTheWorkingLineGoesWhenTheAnswerArrives() {
        let context = RoomContext(kind: .assistant, ownUserID: ScriptedCast.me, agentUserIDs: [ScriptedCast.atum])
        let question = ChatItem(id: "q", kind: .message, sender: ScriptedCast.me, isOwn: true, body: "Q")
        var line = ChatItem(id: "p", kind: .notice, sender: ScriptedCast.atum, body: "Đang chạy tác vụ…",
                            replyTo: "$q")
        line.progress = ChatProgress(phase: .working)
        let answer = ChatItem(id: "a", kind: .message, sender: ScriptedCast.atum, body: "Xong.", replyTo: "$q")
        XCTAssertEqual(Projection.rows([question, line, answer], context: context, typingNames: ["Atum"],
                                       options: .s1).map(\.id), ["q", "a", Projection.typingRowID],
                       "an ended line shows nothing; the agent still typing is the atom")
        XCTAssertEqual(Projection.rows([question, line, answer], context: context, options: .s1).map(\.id),
                       ["q", "a"])
    }
}
