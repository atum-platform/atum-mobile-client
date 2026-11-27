import AtumChat
import Foundation
import XCTest
@testable import AtumNativeAPI

@MainActor
final class PersonalMessageSearchTests: XCTestCase {
    func testSearchRequestsOnlyKnownPlainRoomsAndProjectsExactHits() async throws {
        let harness = Harness(rooms: [
            room("assistant", false), room("people", false), room("app", false),
            room("private", true), room("unknown", nil),
        ])
        harness.transport.pages = [response([
            event("assistant", "$old", at: 9),
            event("people", "$new", threadRoot: "$root"),
            event("app", "$reply", reply: true),
            event("assistant", "$ignored", sender: "@ignored:test"),
            event("assistant", "$redacted", redacted: true),
            event("assistant", "$edit", edit: true),
            event("private", "$private"),
            event("unknown", "$unknown"),
            event("unrequested", "$unrequested"),
        ])]
        let result = try await harness.provider.search(" invoice ", isCurrent: { true })
        XCTAssertEqual(harness.transport.calls.count, 1)
        let request = try XCTUnwrap(harness.transport.calls.first)
        let categories = try XCTUnwrap(request.body["search_categories"] as? [String: Any])
        let roomEvents = try XCTUnwrap(categories["room_events"] as? [String: Any])
        let filter = try XCTUnwrap(roomEvents["filter"] as? [String: Any])
        XCTAssertEqual(roomEvents["search_term"] as? String, "invoice")
        XCTAssertEqual(filter["rooms"] as? [String], ["!app:test", "!assistant:test", "!people:test"])
        XCTAssertEqual(filter["not_senders"] as? [String], ["@ignored:test"])
        XCTAssertEqual(result.results.map(\.id.eventID), ["$old", "$new", "$reply"])
        XCTAssertEqual(result.results[1].id.threadRootID, "$root")
        XCTAssertEqual(result.results[0].snippet, result.results[1].snippet)
        XCTAssertEqual(result.coverage.eligibleRooms, 5)
        XCTAssertEqual(result.coverage.searchedRooms, 3)
        XCTAssertEqual(result.coverage.encryptedRooms, 1)
        XCTAssertFalse(result.coverage.truncated)
    }

    func testEmptyAndUnknownScopeAreNeverSent() async throws {
        let harness = Harness(rooms: [room("unknown", nil), room("private", true)])
        let answer = try await harness.provider.search("invoice", isCurrent: { true })
        XCTAssertEqual(answer.coverage.searchedRooms, 0)
        XCTAssertEqual(harness.transport.calls.count, 0)
        harness.rooms = []
        _ = try await harness.provider.search("invoice", isCurrent: { true })
        harness.rooms = [room("people", false)]
        _ = try await harness.provider.search(" ", isCurrent: { true })
        XCTAssertEqual(harness.transport.calls.count, 0)
    }

    func testLeaveOrEncryptionDuringRequestRefusesContinuationAndRemovesHits() async throws {
        let harness = Harness(rooms: [room("left", false), room("changed", false), room("stayed", false)])
        harness.transport.pages = [response([event("left", "$left"), event("changed", "$private")], next: "p+1")]
        harness.transport.onSend = { harness.rooms = [self.room("changed", true), self.room("stayed", false)] }
        let answer = try await harness.provider.search("invoice", isCurrent: { true })
        XCTAssertTrue(answer.results.isEmpty)
        XCTAssertEqual(answer.coverage.searchedRooms, 1)
        XCTAssertEqual(answer.coverage.encryptedRooms, 1)
        XCTAssertEqual(harness.transport.calls.count, 1)
        harness.transport.onSend = nil
    }

    func testContinuationPreservesSnapshotAndCoverage() async throws {
        let harness = Harness(rooms: [room("people", false)])
        harness.transport.pages = [response([event("people", "$skip", redacted: true)], next: "p+1"),
                                   response([event("people", "$older")], next: "p+2")]
        let answer = try await harness.provider.search("invoice", isCurrent: { true })
        XCTAssertEqual(harness.transport.calls.count, 2)
        XCTAssertEqual(harness.transport.calls[1].nextBatch, "p+1")
        XCTAssertEqual(answer.results.first?.id.eventID, "$older")
        XCTAssertTrue(answer.coverage.truncated)
        XCTAssertEqual(harness.provider.retained(answer.results), answer.results)
        harness.rooms = []
        XCTAssertTrue(harness.provider.retained(answer.results).isEmpty)
    }

    func testGenerationFenceDropsLatePageAndDoesNotSendContinuation() async throws {
        let harness = Harness(rooms: [room("people", false)])
        harness.transport.pages = [response([], next: "p+1")]
        var current = true
        harness.transport.onSend = { current = false }
        do {
            _ = try await harness.provider.search("invoice", isCurrent: { current })
            XCTFail("Superseded search produced an answer")
        } catch is CancellationError {
            XCTAssertEqual(harness.transport.calls.count, 1)
        }
    }

    private func room(_ id: String, _ encrypted: Bool?) -> PersonalMessageSearch.Room {
        .init(id: "!\(id):test", name: id, isEncrypted: encrypted)
    }

    private func event(_ room: String, _ id: String, sender: String = "@user:test", at: Int64 = 10,
                       threadRoot: String? = nil, reply: Bool = false, redacted: Bool = false,
                       edit: Bool = false) -> [String: Any] {
        var content: [String: Any] = ["body": "invoice 1042", "msgtype": "m.text"]
        if let threadRoot {
            content["m.relates_to"] = ["rel_type": "m.thread", "event_id": threadRoot]
        } else if reply {
            content["m.relates_to"] = ["m.in_reply_to": ["event_id": "$root"]]
        } else if edit {
            content["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$root"]
        }
        var event: [String: Any] = ["room_id": "!\(room):test", "event_id": id, "sender": sender,
                                    "origin_server_ts": at, "type": "m.room.message", "content": content]
        if redacted { event["unsigned"] = ["redacted_because": ["event_id": "$redaction"]] }
        return ["result": event]
    }

    private func response(_ events: [[String: Any]], next: String? = nil) -> Data {
        var page: [String: Any] = ["results": events]
        if let next { page["next_batch"] = next }
        return try! JSONSerialization.data(withJSONObject: ["search_categories": ["room_events": page]])
    }
}

@MainActor
private final class Harness {
    let transport = SearchTransport()
    var rooms: [PersonalMessageSearch.Room]

    init(rooms: [PersonalMessageSearch.Room]) { self.rooms = rooms }

    var provider: PersonalMessageSearch {
        PersonalMessageSearch(transport: transport, rooms: { self.rooms },
                              ignoredUsers: { ["@ignored:test"] },
                              endpoint: {
            CompanySearchEndpoint(url: URL(string: "https://matrix.example.org")!, bearer: "fixture",
                                  stillCurrent: {})
        })
    }
}

@MainActor
private final class SearchTransport: CompanySearchTransport {
    var pages: [Data] = []
    var calls: [(body: [String: Any], nextBatch: String?)] = []
    var onSend: (() -> Void)?

    func search(body: Data, endpoint: CompanySearchEndpoint, nextBatch: String?) async throws -> Data {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        calls.append((json, nextBatch))
        onSend?()
        return pages.removeFirst()
    }
}
