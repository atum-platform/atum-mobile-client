import Foundation
import XCTest
import AtumNativeAPI

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
