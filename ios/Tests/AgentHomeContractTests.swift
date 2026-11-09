import CryptoKit
import Foundation
import XCTest
@testable import AtumNativeAPI

final class AgentHomeContractTests: XCTestCase {
    private func packURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "agent-home-v2.5", withExtension: nil))
    }

    private func pack(_ file: String) throws -> Data {
        try Data(contentsOf: packURL().appendingPathComponent(file))
    }

    private func object(_ file: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: pack(file)) as? [String: Any])
    }

    func testVendoredPackMatchesTheFrozenPin() throws {
        let vendored = try object("VENDORED.json")
        let expected = try XCTUnwrap(vendored["sha256"] as? String)
        let pinned = String(decoding: try pack("PINNED-SHA256"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(expected, "164b6c3068390756ece8535a7e5c2210ff680421665483f7f8d60fad6cb6bfc5")
        XCTAssertEqual(pinned, expected)
        XCTAssertEqual(vendored["commit"] as? String, "0058111dc6817f203e446edb15c7f9b9459ba4c0")

        let contract = try object("contract.json")
        XCTAssertEqual(contract["contract_id"] as? String, "atum.agent-home")
        XCTAssertEqual(contract["version"] as? String, "2.5")
        var hash = SHA256()
        for file in try XCTUnwrap(contract["pack_files"] as? [String]) {
            let name = Data(file.utf8)
            let body = try pack(file)
            hash.update(data: lengthPrefix(UInt32(name.count), bytes: 4))
            hash.update(data: name)
            hash.update(data: lengthPrefix(UInt64(body.count), bytes: 8))
            hash.update(data: body)
        }
        XCTAssertEqual(hash.finalize().map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testEveryPhoneConsumedFixtureMatchesThePackExpectation() throws {
        let consumed: Set<String> = [
            "owner.home.snapshot", "owner.home.move.preflight-request", "owner.home.move.preflight",
            "owner.home.move.request", "owner.home.move.cancel", "owner.home.move.refusal",
            "owner.home.move.progress", "owner.home.model-choice.write",
            "owner.home.model-choice.receipt", "owner.home.model-choice.refusal",
            "home.connection-catalog", "home.model-choice.projection",
        ]
        let fixtures = try XCTUnwrap(try object("contract.json")["fixtures"] as? [[String: Any]])
        var accepted = 0
        var rejected = 0
        for fixture in fixtures {
            guard let message = fixture["message"] as? String, consumed.contains(message) else { continue }
            let file = try XCTUnwrap(fixture["file"] as? String)
            let expected = try XCTUnwrap(fixture["expect"] as? String)
            XCTAssertEqual(accepts(message, data: try pack(file)), expected == "accept",
                           "\(file) must be \(expected)ed")
            if expected == "accept" { accepted += 1 } else { rejected += 1 }
        }
        XCTAssertEqual(accepted, 92, "an accepted fixture changed without a Swift decoder update")
        XCTAssertEqual(rejected, 41, "a rejected fixture changed without a Swift decoder update")
    }

    func testRequestEncodersRoundTripTheFrozenPhoneBodies() throws {
        try assertRoundTrip(AgentHomePreflightRequest.self,
                            "fixtures/owner.move.preflight-request.unsigned-phone.json")
        try assertRoundTrip(AgentHomeMoveRequest.self, "fixtures/owner.move.request.unsigned-phone.json")
        try assertRoundTrip(AgentHomeCancelRequest.self, "fixtures/owner.move.cancel.unsigned-phone.json")
        try assertRoundTrip(AgentHomeModelChoiceWrite.self,
                            "fixtures/owner.model-choice.write.unsigned-phone.json")
        try assertRoundTrip(AgentHomeMoveRequest.self, "fixtures/owner.move.request.phone.json")
        try assertRoundTrip(AgentHomeModelChoiceWrite.self, "fixtures/owner.model-choice.write.mac.json")
    }

    func testPreflightRuleFixturesMatchThePhonePolicy() throws {
        let checkpoint = try object("fixtures/preflight.rule.checkpoint-acceptance.json")
        XCTAssertEqual(checkpoint["acceptCheckpointLoss"] as? Bool, true)
        XCTAssertEqual(checkpoint["lossCode"] as? String,
                       AgentHomeFeatureLoss.changesSinceLastCheckpointLost.rawValue)

        let cloud = try object("fixtures/preflight.rule.cloud-catalog.json")
        XCTAssertEqual((cloud["catalogRevision"] as? NSNumber)?.int64Value, 0)

        let overrides = try object("fixtures/preflight.rule.conversation-overrides.json")
        XCTAssertEqual(overrides["lossCode"] as? String,
                       AgentHomeFeatureLoss.conversationOverridesCleared.rawValue)

        let macToCloud = try object("fixtures/preflight.rule.mac-to-cloud.json")
        XCTAssertEqual(macToCloud["codes"] as? [String], [
            AgentHomeFeatureLoss.localBrowserSessionsUnavailable.rawValue,
            AgentHomeFeatureLoss.localFilesUnavailable.rawValue,
            AgentHomeFeatureLoss.localToolsUnavailable.rawValue,
            AgentHomeFeatureLoss.modelSourceChangesToAtum.rawValue,
        ])

        let unreachable = try object("fixtures/preflight.rule.unreachable-checkpoint.json")
        XCTAssertEqual(unreachable["sourceState"] as? String, "offline")
        XCTAssertEqual(unreachable["lossCode"] as? String,
                       AgentHomeFeatureLoss.changesSinceLastCheckpointLost.rawValue)
    }

    /// A snapshot fixture with its `moveCapability` replaced, to put the same platform answer in each home.
    private func snapshot(_ fixture: String, capability: [String: Any]) throws -> AgentHomeSnapshot {
        var record = try object("fixtures/" + fixture)
        record["moveCapability"] = capability
        return try NativeAPI.decode(AgentHomeSnapshot.self,
                                    from: JSONSerialization.data(withJSONObject: record))
    }

    func testOnlyAMacHomeThePlatformIsNotReadyForWaitsForThatMac() throws {
        let notReady: [String: Any] = ["state": "unavailable", "reason": "platform_not_ready"]
        let updateRequired: [String: Any] = ["state": "unavailable", "reason": "client_update_required"]
        let macHome = "owner.placement.snapshot.offline.json"
        let cloudHome = "owner.placement.snapshot.json"

        let waiting = try snapshot(macHome, capability: notReady)
        XCTAssertNotNil(waiting.placement.location.deviceID)
        XCTAssertTrue(waiting.waitsForHomeMac)
        XCTAssertEqual(AgentHomeCardRoute(.answered(waiting.moveCapability, waitingForHome: waiting.waitsForHomeMac)), .placement)

        for other in [try snapshot(macHome, capability: updateRequired),
                      try snapshot(cloudHome, capability: notReady),
                      try snapshot(cloudHome, capability: updateRequired)] {
            XCTAssertFalse(other.waitsForHomeMac)
            XCTAssertEqual(AgentHomeCardRoute(.answered(other.moveCapability, waitingForHome: other.waitsForHomeMac)), .legacyEditor)
        }

        // The platform's own answer for an available move is untouched.
        let available = try NativeAPI.decode(AgentHomeSnapshot.self, from: pack("fixtures/" + macHome))
        XCTAssertFalse(available.waitsForHomeMac)
        XCTAssertEqual(AgentHomeCardRoute(.answered(available.moveCapability, waitingForHome: available.waitsForHomeMac)), .placement)
    }

    func testCatalogRowsKeepSameModelOnTwoConnectionsDistinct() throws {
        let catalog = try NativeAPI.decode(AgentHomeMacCatalog.self,
                                           from: pack("fixtures/mac.connection-catalog.two-plan-connections.json"))
        let rows = AgentHomeModelRows.mac(catalog, selected: nil)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.model)), ["gpt-5.6-luna"])
        XCTAssertEqual(Set(rows.map(\.connectionID)).count, 2)
        XCTAssertEqual(Set(rows.map(\.stableID)).count, 2)
        XCTAssertEqual(Set(rows.map(\.accessibilityID)).count, 2)
        XCTAssertTrue(rows.compactMap(\.favoriteID).allSatisfy { !$0.contains("\u{0}") })
        XCTAssertEqual(rows.map(\.connectionLabel), ["ChatGPT", "ChatGPT"])
    }

    func testProgressNeverRegressesAndPostCommitFailureKeepsTheTargetAuthoritative() throws {
        let moving = try NativeAPI.decode(AgentHomeMoveProgress.self,
                                          from: pack("fixtures/owner.move.progress.moving.json"))
        let ready = try NativeAPI.decode(AgentHomeMoveProgress.self,
                                         from: pack("fixtures/owner.move.progress.ready.json"))
        let late = try NativeAPI.decode(AgentHomeMoveProgress.self,
                                        from: pack("fixtures/owner.move.progress.finishing.json"))
        var tracker = AgentHomeProgressTracker()
        XCTAssertTrue(tracker.receive(moving))
        XCTAssertTrue(tracker.receive(ready))
        XCTAssertFalse(tracker.receive(late))
        XCTAssertEqual(tracker.progress, ready)

        let failed = try NativeAPI.decode(
            AgentHomeMoveProgress.self,
            from: pack("fixtures/owner.move.progress.failed.destination_unreachable.json")
        )
        XCTAssertEqual(failed.failureReason, .destinationUnreachable)
        XCTAssertFalse(try XCTUnwrap(failed.oldHomeResumed))
        XCTAssertEqual(failed.authoritativeHome, failed.target)
    }

    /// A pack progress record with its sequence and/or move changed.
    private func progressRecord(_ fixture: String, sequence: Int? = nil,
                                moveID: String? = nil) throws -> AgentHomeMoveProgress {
        var json = try object(fixture)
        if let sequence { json["sequence"] = sequence }
        if let moveID { json["moveId"] = moveID }
        return try NativeAPI.decode(AgentHomeMoveProgress.self,
                                    from: JSONSerialization.data(withJSONObject: json))
    }

    func testOnlyALowerProgressSequenceIsStale() throws {
        let moving = try progressRecord("fixtures/owner.move.progress.moving.json")
        let waiting = try progressRecord("fixtures/owner.move.progress.waiting.json")
        XCTAssertEqual([moving.sequence, waiting.sequence], [2, 3])
        // `ready` at the SAME sequence as `waiting`: the platform derives waiting
        // versus ready from live readiness without always bumping the sequence.
        let readyAtThree = try progressRecord("fixtures/owner.move.progress.ready.json", sequence: 3)
        XCTAssertEqual(readyAtThree.sequence, waiting.sequence)
        XCTAssertNotEqual(readyAtThree.state, waiting.state)

        var tracker = AgentHomeProgressTracker()
        XCTAssertTrue(tracker.receive(waiting))
        XCTAssertFalse(tracker.receive(waiting), "an identical duplicate paints nothing")
        XCTAssertFalse(tracker.receive(moving), "a lower sequence is stale")
        XCTAssertEqual(tracker.progress, waiting)

        XCTAssertTrue(tracker.receive(readyAtThree), "an equal sequence in a different state is newer")
        XCTAssertEqual(tracker.progress, readyAtThree)
        XCTAssertFalse(tracker.receive(moving), "lower stays stale after an equal-sequence update")
        // Equal sequences cannot be ordered further: the latest arrival is shown.
        XCTAssertTrue(tracker.receive(waiting))
        XCTAssertEqual(tracker.progress, waiting)
        // A higher sequence always wins.
        let ready = try progressRecord("fixtures/owner.move.progress.ready.json")
        XCTAssertGreaterThan(ready.sequence, waiting.sequence)
        XCTAssertTrue(tracker.receive(ready))
        XCTAssertEqual(tracker.progress, ready)
    }

    func testProgressOfAnotherMoveNeverPaintsOverTheShownOne() throws {
        let moving = try progressRecord("fixtures/owner.move.progress.moving.json")
        let other = try progressRecord("fixtures/owner.move.progress.ready.json", sequence: 9,
                                       moveID: "00000000-0000-4000-8000-00f765af1c54")
        var tracker = AgentHomeProgressTracker()
        XCTAssertTrue(tracker.receive(moving))
        XCTAssertFalse(tracker.receive(other))
        XCTAssertEqual(tracker.progress, moving)
    }

    func testMacUnavailableReadbackHoldsWithoutPaidFallback() throws {
        let application = try NativeAPI.decode(
            AgentHomeModelApplication.self,
            from: pack("fixtures/model-choice.projection.unavailable.connection_unavailable.json")
        )
        XCTAssertEqual(AgentHomeReadback(application), .unavailable(.connectionUnavailable))
        XCTAssertFalse(AgentHomeReadback(application).mayAnswer)
    }

    func testModelRouteUsesTheCurrentHomeWriteOnlyAtRest() throws {
        let device = try NativeID("00000000-0000-4000-8000-b454f82c5857")
        XCTAssertEqual(AgentHomeModelRoute.select(currentHome: .mac(device), selectedHome: .mac(device)),
                       .currentHomeWrite)
        XCTAssertEqual(AgentHomeModelRoute.select(currentHome: .cloud, selectedHome: .mac(device)),
                       .movePreflight)
        XCTAssertEqual(AgentHomeModelRoute.select(currentHome: .mac(device), selectedHome: .cloud),
                       .movePreflight)
    }

    private func accepts(_ message: String, data: Data) -> Bool {
        switch message {
        case "owner.home.snapshot": return (try? NativeAPI.decode(AgentHomeSnapshot.self, from: data)) != nil
        case "owner.home.move.preflight-request":
            return (try? NativeAPI.decode(AgentHomePreflightRequest.self, from: data)) != nil
        case "owner.home.move.preflight":
            return (try? NativeAPI.decode(AgentHomeMovePreflight.self, from: data)) != nil
        case "owner.home.move.request": return (try? NativeAPI.decode(AgentHomeMoveRequest.self, from: data)) != nil
        case "owner.home.move.cancel": return (try? NativeAPI.decode(AgentHomeCancelRequest.self, from: data)) != nil
        case "owner.home.move.refusal": return (try? NativeAPI.decode(AgentHomeMoveRefusal.self, from: data)) != nil
        case "owner.home.move.progress": return (try? NativeAPI.decode(AgentHomeMoveProgress.self, from: data)) != nil
        case "owner.home.model-choice.write":
            return (try? NativeAPI.decode(AgentHomeModelChoiceWrite.self, from: data)) != nil
        case "owner.home.model-choice.receipt":
            return (try? NativeAPI.decode(AgentHomeModelChoiceReceipt.self, from: data)) != nil
        case "owner.home.model-choice.refusal":
            return (try? NativeAPI.decode(AgentHomeModelChoiceRefusal.self, from: data)) != nil
        case "home.connection-catalog":
            return (try? NativeAPI.decode(AgentHomeMacCatalog.self, from: data)) != nil
        case "home.model-choice.projection":
            return (try? NativeAPI.decode(AgentHomeModelApplication.self, from: data)) != nil
        default: return false
        }
    }

    private func assertRoundTrip<T: Codable>(_ type: T.Type, _ fixture: String,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) throws {
        let original = try pack(fixture)
        let value = try NativeAPI.decode(type, from: original)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                       file: file, line: line)
    }

    private func lengthPrefix<T: FixedWidthInteger>(_ value: T, bytes: Int) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0.suffix(bytes)) }
    }
}
