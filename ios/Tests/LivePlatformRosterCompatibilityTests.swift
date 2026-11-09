import Foundation
import XCTest
@testable import AtumNativeAPI

final class LivePlatformRosterCompatibilityTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let directory = try XCTUnwrap(
            Bundle.module.url(forResource: "live-platform-2026-10-28", withExtension: nil)
        )
        let data = try Data(contentsOf: directory.appendingPathComponent("server-shapes.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodedAgents(_ rows: [[String: Any]]) throws -> AgentsResponse {
        try NativeAPI.decode(
            AgentsResponse.self,
            from: JSONSerialization.data(withJSONObject: rows)
        )
    }

    func testCurrentServerRosterRestoresThePrimaryAndEveryPortrait() throws {
        let value = try fixture()
        let response = try decodedAgents(try XCTUnwrap(value["agents"] as? [[String: Any]]))
        let active = response.agents.filter { $0.status == .active }

        XCTAssertEqual(active.map(\.displayName), ["Raymond", "Alfred", "Founder", "Luna", "Wendy", "Axe"])
        XCTAssertEqual(active.first?.isDefault, true)
        XCTAssertEqual(active.first?.avatarURL, "https://cdn.example.invalid/assistants/raymond.png")
        XCTAssertTrue(active.dropFirst().allSatisfy { $0.avatarURL != nil })
    }

    func testFutureCompanionAndMalformedItemDoNotEraseKnownAssistants() throws {
        let value = try fixture()
        var rows = try XCTUnwrap(value["agents"] as? [[String: Any]])
        rows.append(try XCTUnwrap(value["petCompanion"] as? [String: Any]))
        rows.append(try XCTUnwrap(value["futureRosterItem"] as? [String: Any]))
        let response = try decodedAgents(rows)
        let active = response.agents.filter { $0.status == .active }

        XCTAssertEqual(active.map(\.displayName), ["Raymond", "Alfred", "Founder", "Luna", "Wendy", "Axe"])
        XCTAssertEqual(active.first?.isDefault, true, "the primary assistant survives another item")
        XCTAssertEqual(active.first?.avatarURL, "https://cdn.example.invalid/assistants/raymond.png")
        XCTAssertTrue(active.dropFirst().allSatisfy { $0.avatarURL != nil }, "portraits survive per-item evolution")

        let companion = try XCTUnwrap(response.agents.first { $0.displayName == "Companion" })
        XCTAssertEqual(companion.status, .unknown)
        XCTAssertEqual(companion.answering, .unknown)
        XCTAssertNil(companion.mark, "an unknown companion mark is presentation-only and degrades to no mark")
        XCTAssertEqual(response.agents.count, 7, "an irreparably unknown row is discarded by itself")
    }

    func testCurrentSubscriptionSnapshotsDecodeWithoutDroppingKnownChoices() throws {
        let values = try XCTUnwrap(fixture()["modelDestinations"] as? [[String: Any]])
        let snapshots = try values.map {
            try NativeAPI.decode(
                ManagedModelDestinationSnapshot.self,
                from: JSONSerialization.data(withJSONObject: $0)
            )
        }

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].choice(for: try ManagedModelDestinationID("cloud"))?.source,
                       .opencodeGo)
        XCTAssertEqual(snapshots[1].choice(for: try ManagedModelDestinationID("cloud"))?.source,
                       .chatGPTPlan)
        XCTAssertNil(snapshots[1].choice(for: try ManagedModelDestinationID("mac:future")),
                     "one unknown provider choice does not erase the picker")
    }

    func testCurrentCloudPlacementStillDecodesAsTheCloudPlace() throws {
        let body = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(fixture()["placement"])
        )
        let snapshot = try NativeAPI.decode(AgentHomeSnapshot.self, from: body)

        XCTAssertEqual(snapshot.placement.location, .cloud)
        XCTAssertEqual(snapshot.device(try NativeID("00000000-0000-4000-8000-b454f82c5857"))?.displayName,
                       "Mac mini")
    }

    func testAssistantCardFallsBackFromAnUnknownMarkWithoutLosingThePortrait() throws {
        let body = try JSONSerialization.data(
            withJSONObject: try XCTUnwrap(fixture()["presentation"])
        )
        let snapshot = try NativeAPI.decode(AgentPresentationSnapshot.self, from: body)

        XCTAssertEqual(snapshot.mark, AgentMark(shape: .circle, color: .blue))
        XCTAssertEqual(snapshot.avatarURL, "https://cdn.example.invalid/assistants/raymond.png")
    }
}
