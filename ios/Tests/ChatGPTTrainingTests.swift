import Foundation
import XCTest
@testable import AtumNativeAPI

/// The training-off projection is read as strictly as the desktop reads it
/// (`parseMatrixChatGptTraining`): only this build's wording is current, and
/// an answer outside the contract is unreadable, never a confirmation.
final class ChatGPTTrainingTests: XCTestCase {
    private let connection = "00000000-0000-4000-8000-0000000000c1"

    private func decode(_ object: [String: Any]) throws -> ChatGPTTrainingStatus {
        try ChatGPTTrainingStatus.decode(JSONSerialization.data(withJSONObject: object))
    }

    func testOnlyTheV1WordingIsCurrent() throws {
        let confirmed = try decode(["current": true, "wordingVersion": "chatgpt-google-v1",
                                    "connectionId": connection, "confirmedAt": "2026-11-20T08:00:00Z",
                                    "revision": 3])
        XCTAssertTrue(confirmed.current)
        XCTAssertEqual(confirmed.connectionID, connection)
        XCTAssertEqual(confirmed.confirmedAt, ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z"))

        let later = try decode(["current": true, "wordingVersion": "chatgpt-google-v2",
                                "connectionId": connection, "confirmedAt": "2026-11-20T08:00:00Z",
                                "revision": 4])
        XCTAssertFalse(later.current, "another wording is not what this build showed")
        XCTAssertNil(later.confirmedAt)

        let absent = try decode(["current": false, "wordingVersion": NSNull(), "connectionId": NSNull(),
                                 "confirmedAt": NSNull(), "revision": NSNull()])
        XCTAssertEqual(absent, ChatGPTTrainingStatus(current: false, connectionID: nil, confirmedAt: nil))
    }

    func testAnAnswerOutsideTheContractIsUnreadable() {
        let bad: [[String: Any]] = [
            [:],
            ["current": "true"],
            ["current": 1],
            ["current": true, "wordingVersion": 1],
            ["current": false, "connectionId": "relay-1"],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "confirmedAt": "yesterday"],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": -1],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": 1.5],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": true],
        ]
        for object in bad {
            XCTAssertThrowsError(try decode(object), "\(object)")
        }
        XCTAssertThrowsError(try ChatGPTTrainingStatus.decode(Data("[]".utf8)))
    }

    func testTheConfirmationBodyIsTheExactThreeFields() throws {
        let data = try JSONEncoder().encode(ChatGPTTrainingConfirmRequest(connectionID: connection))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["wordingVersion": "chatgpt-google-v1", "connectionId": connection,
                                "transferWordingVersion": "chatgpt-google-transfer-v1"])
    }
}
