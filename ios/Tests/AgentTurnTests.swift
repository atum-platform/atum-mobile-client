import XCTest
import Foundation
import AtumNativeAPI
import AtumPrototype

final class AgentTurnTests: XCTestCase {
    private struct Sequence: Decodable {
        struct Step: Decodable { let from, to: ClientTurn.State; let event: ClientTurn.Event }
        let steps: [Step]
    }
    private func turn(automatic: Bool = false) throws -> ClientTurn {
        let key = try AgentTurns.request(NativeTurnFixtures().data("turn-state.request.json"))
        return try ClientTurn(key: key, sentAt: Date(timeIntervalSince1970: 0), automaticAnswering: automatic,
            expectedAgentSender: "@agent-0123456789abcdef0123:atum.test")
    }
    private func check(_ name: String, _ data: Data) throws {
        switch name {
        case "turn.answer_content": _ = try AgentTurns.answer(data)
        case "turn.status_notice_content": _ = try AgentTurns.notice(data)
        case "agents.readiness_entry": _ = try AgentTurns.readiness(data)
        case "turn.state.request": _ = try AgentTurns.request(data)
        case "turn.state.response": _ = try AgentTurns.state(data)
        default: XCTFail("Missing frozen message consumer: \(name)")
        }
    }
    func testAllFrozenMessagesAndClientTransitionFixtures() throws {
        let source = try NativeTurnFixtures()
        for fixture in source.manifest.fixtures {
            let data = try source.data(fixture.file)
            if let message = fixture.message {
                if fixture.expect == "accept" { XCTAssertNoThrow(try check(message, data), fixture.file) }
                else { XCTAssertThrowsError(try check(message, data), fixture.file) }
            } else {
                XCTAssertEqual(fixture.machine, "client_turn")
                let sequence = try JSONDecoder().decode(Sequence.self, from: data)
                var client = try turn()
                let valid = sequence.steps.allSatisfy { step in
                    client.state == step.from && client.advance(step.event) && client.state == step.to
                }
                XCTAssertEqual(valid, fixture.expect == "accept", fixture.file)
            }
        }
        XCTAssertThrowsError(try source.data("../../contract.json"))
    }
    func testNoticeIsStatusAndLateAnswerReplacesElapsedLabel() throws {
        let source = try NativeTurnFixtures()
        var client = try turn()
        XCTAssertNil(source.answer.result.status) // M1 does not require proposal.
        XCTAssertTrue(client.receive(source.notice, room: client.key.roomId, sender: client.expectedAgentSender))
        XCTAssertEqual(client.state, .statusShown)
        XCTAssertNil(client.answer)
        XCTAssertFalse(client.expireM1(at: Date(timeIntervalSince1970: 119.999)))
        XCTAssertTrue(client.expireM1(at: Date(timeIntervalSince1970: 120)))
        XCTAssertEqual(client.state, .notAnswered)
        XCTAssertFalse(client.advance(.failed)) // Timeout is never execution failure.
        XCTAssertTrue(client.receive(source.answer, room: client.key.roomId, sender: client.expectedAgentSender))
        XCTAssertEqual(client.state, .answered)
        XCTAssertEqual(client.answer, source.answer)
        XCTAssertFalse(client.receive(source.answer, room: client.key.roomId, sender: client.expectedAgentSender))
        XCTAssertFalse(client.expireM1(at: Date(timeIntervalSince1970: 9999)))
        var automatic = try turn(automatic: true)
        XCTAssertFalse(automatic.expireM1(at: Date(timeIntervalSince1970: 899.999)))
        XCTAssertTrue(automatic.expireM1(at: Date(timeIntervalSince1970: 900)))
    }
    func testCorrelationRequiresExactRoomReplyAndAgentSender() throws {
        let source = try NativeTurnFixtures()
        var client = try turn()
        XCTAssertFalse(client.receive(source.answer, room: try MatrixRoomID("!other:atum.test"), sender: client.expectedAgentSender))
        XCTAssertFalse(client.receive(source.answer, room: client.key.roomId, sender: "@foreign-agent:atum.test"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: source.data("answer.content.json")) as? [String: Any])
        json["m.relates_to"] = ["m.in_reply_to": ["event_id": "$anotherTurn"]]
        let unrelated = try AgentTurns.answer(JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(client.receive(unrelated, room: client.key.roomId, sender: client.expectedAgentSender))
        XCTAssertEqual(client.state, .sent)
        XCTAssertNil(client.answer)
        XCTAssertTrue(client.receive(source.answer, room: client.key.roomId, sender: client.expectedAgentSender))
    }
    func testNoThreadOrMissingResultCanBecomeAnswer() throws {
        let source = try NativeTurnFixtures()
        for file in ["answer-in-thread.content.json", "answer-without-result.content.json", "status-notice.content.json"] {
            XCTAssertThrowsError(try AgentTurns.answer(source.data(file)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.data("answer.content.json")) as? [String: Any])
        object["futureMetadata"] = ["unknown": 1.25]
        XCTAssertNoThrow(try AgentTurns.answer(JSONSerialization.data(withJSONObject: object)))
        object["futureMetadata"] = ["nested": ["leaseToken": "synthetic-forbidden-field"]]
        XCTAssertThrowsError(try AgentTurns.answer(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "futureMetadata")
        object["io.atum.turn"] = "00000000-0000-1000-8000-dac9aa69218f"
        XCTAssertThrowsError(try AgentTurns.answer(JSONSerialization.data(withJSONObject: object)))
    }
    func testProposedStatusDoesNotInventM1AuthorityAndRunningDoesNotTimeout() throws {
        let source = try NativeTurnFixtures()
        let proposed = try AgentTurns.answer(source.data("answer-with-proposed-status.content.json"))
        XCTAssertEqual(proposed.result.status, .savedToDrive)
        var client = try turn()
        XCTAssertTrue(client.advance(.running))
        XCTAssertFalse(client.expireM1(at: Date(timeIntervalSince1970: 9999)))
        XCTAssertEqual(client.state, .working) // The freshness bound is for unclaimed M1 turns.
        XCTAssertTrue(client.advance(.stopSent))
        XCTAssertEqual(client.state, .stopping)
        XCTAssertTrue(client.receive(proposed, room: client.key.roomId, sender: client.expectedAgentSender))
        XCTAssertEqual(client.state, .answered) // Completed before Stop; not "stopped".
    }
    func testReadinessAndTurnStateUseBoundsWithoutExecutorSecrets() throws {
        let source = try NativeTurnFixtures()
        let local = try AgentTurns.readiness(source.data("readiness-ready-local.entry.json"))
        XCTAssertEqual(local.readiness.executorKind, .local)
        let offline = try AgentTurns.readiness(source.data("readiness-offline.entry.json"))
        XCTAssertNil(offline.readiness.executorKind)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: source.data("readiness-ready-local.entry.json")) as? [String: Any])
        var readiness = object["readiness"] as! [String: Any]
        readiness.removeValue(forKey: "executorKind"); object["readiness"] = readiness
        XCTAssertThrowsError(try AgentTurns.readiness(JSONSerialization.data(withJSONObject: object)))
        let body = String(decoding: try source.data("turn-state-dispatched.response.json"), as: UTF8.self)
            .replacingOccurrences(of: "1791200000000", with: "1791200000000.0")
        XCTAssertThrowsError(try AgentTurns.state(Data(body.utf8)))
        var request = try XCTUnwrap(JSONSerialization.jsonObject(with: source.data("turn-state.request.json")) as? [String: Any])
        request["eventId"] = "not-a-remote-event-id"
        XCTAssertThrowsError(try AgentTurns.request(JSONSerialization.data(withJSONObject: request)))
    }
}
