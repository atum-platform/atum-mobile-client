import XCTest
@testable import AtumChat

final class ClearedWorkingLineTests: XCTestCase {
    func testPersistedSelfRedactionsOnly() throws {
        for sender in ["agent", "cloud"] {
            for (redacter, reason, expected) in [(sender, "Turn ended", true), (sender, "Other", false),
                                                (sender, "", false), ("moderator", "Turn ended", false)] {
                var content: [String: String] = [:]
                if !reason.isEmpty { content["reason"] = reason }
                let data = try JSONSerialization.data(withJSONObject: ["unsigned": ["redacted_because":
                    ["sender": redacter, "content": content]]])
                let fact = ClearedWorkingLine.matches(json: String(decoding: data, as: UTF8.self), originalSender: sender)
                XCTAssertEqual(fact, expected)
                let item = ChatItem(id: "r", kind: .placeholder(.redacted), sender: sender, redactedAsEndedTurn: fact)
                XCTAssertEqual(TransientLines.visibleItems([item], agents: ["agent"]).isEmpty, expected)
                var own = item
                own.isOwn = true
                XCTAssertEqual(TransientLines.visibleItems([own], agents: ["agent"]), [own])
            }
        }
    }

    func testMissingOrMalformedJSONKeepsPlaceholder() {
        for json in [nil, "{}", "invalid"] as [String?] {
            XCTAssertFalse(ClearedWorkingLine.matches(json: json, originalSender: "cloud"))
        }
    }
}
