import XCTest
@testable import AtumNativeAPI

/// The cloud's subscription models on the phone, as on the desktop: the two
/// account status shapes, the 1.4 / 1.5 write and the picker rows they make.
final class PhoneSubscriptionModelsTests: XCTestCase {
    private let cloud = try! ManagedModelDestinationID("cloud")

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try NativeAPI.decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func model(_ id: String, _ name: String, efforts: [String] = ["low", "medium", "high"],
                       defaultEffort: String = "medium") -> [String: Any] {
        ["id": id, "displayName": name, "efforts": efforts, "defaultEffort": defaultEffort,
         "contextBudget": 200_000, "outputBudget": 32_000]
    }

    private func relay(enabled: Bool, models: [[String: Any]]? = nil) -> [String: Any] {
        enabled
            ? ["profile": "atum.chatgpt-relay/1", "revision": 3, "state": "enabled",
               "deviceServiceId": "00000000-0000-4000-8000-0000000000d1", "selectedAt": 1_700_000_000,
               "models": models ?? [model("gpt-6.1", "GPT-6.1"), model("gpt-6.1-mini", "GPT-6.1 mini")]]
            : ["profile": "atum.chatgpt-relay/1", "revision": 4, "state": "disabled", "models": []]
    }

    private func connections(connected: Bool) -> [String: Any] {
        connected
            ? ["profile": "atum.provider-connections/1", "revision": 2,
               "connections": [["provider": "opencode_go", "state": "connected", "revision": 2,
                                "models": [model("glm-5.2", "GLM 5.2", efforts: ["high"], defaultEffort: "medium")],
                                "modelPolicy": "subscription", "connectedAt": 1_700_000_000, "keyVersion": 1]]]
            : ["profile": "atum.provider-connections/1", "revision": 3,
               "connections": [["provider": "opencode_go", "state": "disconnected", "revision": 3,
                                "models": [], "modelPolicy": "none"]]]
    }

    private func account(relay relayObject: [String: Any]?,
                         connections connectionsObject: [String: Any]?) throws -> PhoneSubscriptionAccount {
        PhoneSubscriptionAccount(
            chatGPT: try relayObject.map { try decode(ChatGPTRelayStatus.self, $0) },
            openCodeGo: try connectionsObject.map { try decode(ProviderConnectionsStatus.self, $0) })
    }

    private func snapshot(profile: String = "atum.model-choice/1.5",
                          cloudChoice: [String: Any]? = nil) throws -> ManagedModelDestinationSnapshot {
        try decode(ManagedModelDestinationSnapshot.self, [
            "profile": profile,
            "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": 7,
            "policyDigest": String(repeating: "b", count: 64),
            "recommended": ["source": "atum", "model": "nguyet-thuc", "effort": "medium"],
            "choices": [cloudChoice ?? ["destination": "cloud", "source": "atum",
                                        "model": "nguyet-thuc", "effort": "medium"]],
            "dailyCap": ["dailyProtons": 0, "timeZone": "Asia/Ho_Chi_Minh",
                         "warningPercent": 80, "counts": "atum_billed_only"],
            "spend": ["day": "2026-11-11", "usedProtons": 0, "state": "normal", "notice": "none"],
        ])
    }

    // MARK: The status shapes

    func testTheRelayStatusIsTheClosedDesktopShape() throws {
        let enabled = try decode(ChatGPTRelayStatus.self, relay(enabled: true))
        XCTAssertEqual(enabled.state, .enabled)
        XCTAssertEqual(enabled.models.map(\.displayName), ["GPT-6.1", "GPT-6.1 mini"])
        XCTAssertEqual(try decode(ChatGPTRelayStatus.self, relay(enabled: false)).state, .disabled)

        var extra = relay(enabled: false)
        extra["deviceServiceId"] = "00000000-0000-4000-8000-0000000000d1"
        XCTAssertThrowsError(try decode(ChatGPTRelayStatus.self, extra), "a disabled relay names no Mac")
        XCTAssertThrowsError(try decode(ChatGPTRelayStatus.self, relay(enabled: true, models: [])),
                             "an enabled relay relays at least one model")
        var other = relay(enabled: true)
        other["profile"] = "atum.chatgpt-relay/2"
        XCTAssertThrowsError(try decode(ChatGPTRelayStatus.self, other))
        var leaked = relay(enabled: true)
        leaked["token"] = "x"
        XCTAssertThrowsError(try decode(ChatGPTRelayStatus.self, leaked))
    }

    func testTheProviderConnectionStatusIsOneOpencodeGoRowWithNoKey() throws {
        let connected = try decode(ProviderConnectionsStatus.self, connections(connected: true))
        XCTAssertEqual(connected.state, .connected)
        XCTAssertEqual(connected.models.map(\.id), ["glm-5.2"])
        XCTAssertEqual(try decode(ProviderConnectionsStatus.self, connections(connected: false)).state,
                       .disconnected)

        var wrongPolicy = connections(connected: false)
        var rows = try XCTUnwrap(wrongPolicy["connections"] as? [[String: Any]])
        rows[0]["modelPolicy"] = "subscription"
        wrongPolicy["connections"] = rows
        XCTAssertThrowsError(try decode(ProviderConnectionsStatus.self, wrongPolicy))
        var credential = connections(connected: true)
        rows = try XCTUnwrap(credential["connections"] as? [[String: Any]])
        rows[0]["credential"] = ["kind": "api_key", "value": "secret-value"]
        credential["connections"] = rows
        XCTAssertThrowsError(try decode(ProviderConnectionsStatus.self, credential))
    }

    func testAPickWritesTheModelsDefaultLevelOrTheFirstItAccepts() throws {
        let relayStatus = try decode(ChatGPTRelayStatus.self, relay(enabled: true, models: [
            model("a", "A"), model("b", "B", efforts: [], defaultEffort: "high"),
            model("c", "C", efforts: ["low", "high"], defaultEffort: "medium"),
        ]))
        XCTAssertEqual(relayStatus.models.map(\.writeEffort), [.medium, .high, .low])
    }

    // MARK: The write

    func testAPlanPickIs15AndAnOpencodePickIs14OnTheCloud() throws {
        let saved = try snapshot()
        let id = try NativeID("00000000-0000-4000-8000-303617b97304")
        let plan = try ManagedModelSubscriptionWrite(requestId: id, snapshot: saved, source: .chatGPTPlan,
                                                     model: "gpt-6.1", effort: .medium)
        let go = try ManagedModelSubscriptionWrite(requestId: id, snapshot: saved, source: .opencodeGo,
                                                   model: "glm-5.2", effort: .high)
        for (write, profile, source) in [(plan, "atum.model-choice/1.5", "chatgpt_plan"),
                                         (go, "atum.model-choice/1.4", "opencode_go")] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(write))
                as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["profile", "requestId", "expectedRevision", "policyDigest", "choice"])
            XCTAssertEqual(body["profile"] as? String, profile)
            XCTAssertEqual(body["expectedRevision"] as? Int, 7)
            XCTAssertEqual(body["policyDigest"] as? String, String(repeating: "b", count: 64))
            let choice = try XCTUnwrap(body["choice"] as? [String: String])
            XCTAssertEqual(choice["destination"], "cloud")
            XCTAssertEqual(choice["source"], source)
        }
        XCTAssertThrowsError(try ManagedModelSubscriptionWrite(requestId: id, snapshot: saved, source: .atum,
                                                               model: "nguyet-thuc", effort: .medium))
    }

    // MARK: The picker rows

    func testARelayedPlanAndAConnectedOpencodeGoAreChoosableAndTheSavedOneIsCurrent() throws {
        let saved = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "medium"])
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let rows = PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
        XCTAssertEqual(rows.map(\.model), ["gpt-6.1", "gpt-6.1-mini", "glm-5.2"], "ChatGPT first, as on desktop")
        XCTAssertEqual(rows.map(\.displayName), ["GPT-6.1", "GPT-6.1 mini", "GLM 5.2"])
        XCTAssertEqual(rows.map(\.selected), [true, false, false])
        XCTAssertEqual(rows.map(\.selectable), [false, true, true])
        XCTAssertTrue(rows.allSatisfy { $0.isSubscription && $0.unavailable == nil })

        XCTAssertNil(PhoneModelPickerProjection.canSelectSubscription(rows[0], snapshot: saved, account: status),
                     "the current model is not written again")
        XCTAssertEqual(PhoneModelPickerProjection.canSelectSubscription(rows[1], snapshot: saved, account: status),
                       .medium)
        XCTAssertEqual(PhoneModelPickerProjection.canSelectSubscription(rows[2], snapshot: saved, account: status),
                       .high, "OpenCode Go's model accepts only high")

        let atum = PhoneModelPickerProjection.destination(saved, destination: cloud,
                                                          cloudEligibleAliases: ["nguyet-thuc"])
        XCTAssertFalse(atum.contains(where: \.selected), "no Atum row claims the check under a plan")
    }

    func testAPlanNoMacRelaysStaysListedAsNotReady() throws {
        let saved = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "medium"])
        let status = try account(relay: relay(enabled: false), connections: connections(connected: false))
        let rows = PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].unavailable, .notReady)
        XCTAssertFalse(rows[0].selectable)
        XCTAssertFalse(rows[0].selected, "a plan the cloud cannot reach is not what answers")
        XCTAssertNil(PhoneModelPickerProjection.canSelectSubscription(rows[0], snapshot: saved, account: status))
    }

    func testADisconnectedOpencodeGoChoiceSaysSignInAgain() throws {
        let saved = try snapshot(profile: "atum.model-choice/1.4",
                                 cloudChoice: ["destination": "cloud", "source": "opencode_go",
                                               "model": "glm-5.2", "effort": "high"])
        let status = try account(relay: relay(enabled: false), connections: connections(connected: false))
        let rows = PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
        XCTAssertEqual(rows.map(\.unavailable), [.signedOut])
        XCTAssertFalse(rows[0].selectable)
    }

    func testNothingConnectedListsNoSubscriptionRows() throws {
        let status = try account(relay: relay(enabled: false), connections: connections(connected: false))
        XCTAssertEqual(PhoneModelPickerProjection.subscriptions(try snapshot(), destination: cloud,
                                                                account: status), [])
    }

    func testAnUnreadableStatusKeepsTheSavedChoiceReadOnly() throws {
        let saved = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "medium"])
        for status in [nil, PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil)] {
            let rows = PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(rows[0].selected)
            XCTAssertFalse(rows[0].selectable)
            XCTAssertNil(rows[0].unavailable)
        }
    }

    func testAMacDestinationsPlanStaysReadOnly() throws {
        let saved = try snapshot(profile: "atum.model-choice/1.3",
                                 cloudChoice: ["destination": "mac:mini-b", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "max"])
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let rows = PhoneModelPickerProjection.subscriptions(saved, destination: try ManagedModelDestinationID("mac:mini-b"),
                                                            account: status)
        XCTAssertEqual(rows.map(\.model), ["gpt-6.1"])
        XCTAssertFalse(rows[0].selectable)
    }
}
