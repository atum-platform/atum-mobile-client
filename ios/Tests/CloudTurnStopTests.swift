import Foundation
import XCTest
import AtumNativeAPI
import AtumChat

/// `atum.cloud-execution/1` §3.5 stop shapes, as the desktop sends and checks
/// them (atum-app `apps/desktop/electron/matrix/device/cloud-stop.ts`). The
/// values are the pack's synthetic `stop-turn.request.json` and
/// `stop-dispatched.response.json`.
final class CloudTurnStopTests: XCTestCase {
    private let requestID = "8e0a2c4e-6b8d-4f0b-8d2f-4a6c8e0b2d79"
    private let agent = "7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e42"
    private let room = "!kQeGvMzTnYhPwRsLdAcF:atumplatform.com"
    private let event = "$Xb3hQ9vTzM2kLw7pNcR4sYd8fGj1aE6uV0oIxKqHnB5"

    private func request() throws -> CloudTurnStop.Request {
        try CloudTurnStop.Request(requestId: NativeID(requestID), agentPrincipal: NativeID(agent),
                                  roomId: MatrixRoomID(room), eventId: MatrixEventID(event))
    }

    private func reply(_ state: String, agent: String? = nil, eventId: String? = nil,
                       kind: String = "turn", extra: String = "") -> Data {
        Data("""
        {"agentPrincipal":"\(agent ?? self.agent)","target":{"kind":"\(kind)","roomId":"\(room)",\
        "eventId":"\(eventId ?? event)"},"state":"\(state)","stoppedAt":1790672700000\(extra)}
        """.utf8)
    }

    func testTheBodyIsExactlyTheFrozenTurnTarget() throws {
        let body = try JSONSerialization.jsonObject(with: try request().body()) as? NSDictionary
        let expected: NSDictionary = [
            "requestId": requestID, "agentPrincipal": agent,
            "target": ["kind": "turn", "roomId": room, "eventId": event],
        ]
        XCTAssertEqual(body, expected)
    }

    func testEachFrozenStateIsRead() throws {
        let request = try request()
        XCTAssertEqual(try CloudTurnStop.response(reply("stopped"), for: request).state, .stopped)
        XCTAssertEqual(try CloudTurnStop.response(reply("stop_requested"), for: request).state, .stopRequested)
        XCTAssertEqual(try CloudTurnStop.response(reply("completed"), for: request).state, .completed)
    }

    func testAnythingElseIsUnconfirmed() throws {
        let request = try request()
        XCTAssertThrowsError(try CloudTurnStop.response(reply("stopping"), for: request), "unknown state")
        XCTAssertThrowsError(try CloudTurnStop.response(reply("stopped", agent: "7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e43"),
                                                        for: request), "another agent")
        XCTAssertThrowsError(try CloudTurnStop.response(reply("stopped", eventId: "$other"), for: request),
                             "another turn")
        XCTAssertThrowsError(try CloudTurnStop.response(reply("stopped", kind: "occurrence"), for: request),
                             "not a turn")
        XCTAssertThrowsError(try CloudTurnStop.response(reply("stopped", extra: #","executorId":"x""#), for: request),
                             "names the executor")
        XCTAssertThrowsError(try CloudTurnStop.response(Data("{}".utf8), for: request))
    }
}

extension CloudTurnStopTests {
    func testScheduledStopFreezesOnlyTheExactExecutionAndKeepsDesktopRequestID() throws {
        let agent = try NativeID(agent)
        let a = try XCTUnwrap(ChatScheduleExecution(job: "fixture-job", execution: "run-a"))
        let b = try XCTUnwrap(ChatScheduleExecution(job: "fixture-job", execution: "run-b"))
        let input = try CloudScheduleStop.Request(agent: agent, execution: a)
        let expected: NSDictionary = [
            "agent": agent.rawValue,
            "requestId": "8b26d56e-47d0-84cf-922b-c310c8ecfa30",
            "source": ["kind": "schedule", "job": "fixture-job", "execution": "run-a"]
        ]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: input.body()) as? NSDictionary, expected)
        XCTAssertEqual(try CloudScheduleStop.Request(agent: agent, execution: a).requestId, input.requestId)
        XCTAssertNotEqual(try CloudScheduleStop.Request(agent: agent, execution: b).requestId, input.requestId)
        XCTAssertNil(ChatScheduleExecution(job: "fixture-job", execution: "urn:other"))
    }

    func testScheduledStopRequiresCorrelatedAndConsistentFlags() throws {
        let execution = try XCTUnwrap(ChatScheduleExecution(job: "fixture-job", execution: "run-a"))
        let input = try CloudScheduleStop.Request(agent: NativeID(agent), execution: execution)
        func result(_ state: String, flags: Bool = false, status: Int = 200,
                    id: String? = nil) throws -> AssistantTurnStopResult {
            let receipt = """
            {"ok":true,"requestId":"\(id ?? input.requestId.rawValue)","state":"\(state)",
             "cancelled":\(flags),"interrupted":\(flags)}
            """
            return try CloudScheduleStop.result(status: status, data: Data(receipt.utf8), for: input)
        }
        XCTAssertEqual(try result("interrupted", flags: true), .stopped)
        XCTAssertEqual(try result("finished"), .completed)
        XCTAssertEqual(try result("pending"), .stopRequested)
        XCTAssertEqual(try result("unknown"), .stopRequested)
        XCTAssertEqual(try result("refused", status: 403), .failed)
        XCTAssertEqual(try result("unavailable", status: 503), .failed)
        XCTAssertThrowsError(try result("interrupted"))
        XCTAssertThrowsError(try result("pending", flags: true))
        XCTAssertThrowsError(try result("interrupted", flags: true, id: requestID))
    }
}
