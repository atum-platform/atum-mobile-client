import XCTest
@testable import AtumNativeAPI

/// The cloud's subscription models on the phone, as on the desktop: the two
/// account status shapes, the 1.4 / 1.5 write and the picker rows they make.
final class PhoneSubscriptionModelsTests: XCTestCase {
    private let cloud = try! ManagedModelDestinationID("cloud")

    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try NativeAPI.decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    private func model(_ id: String, _ name: String, efforts: [Any] = ["low", "medium", "high"],
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

    private func reads(_ account: PhoneSubscriptionAccount) -> PhoneSubscriptionAccountReads {
        PhoneSubscriptionAccountReads(chatGPT: { account.chatGPT }, openCodeGo: { account.openCodeGo },
                                      accountConnections: { account.accountConnections })
    }

    private func snapshot(profile: String = "atum.model-choice/1.5",
                          cloudChoice: [String: Any]? = nil,
                          revision: Int = 7) throws -> ManagedModelDestinationSnapshot {
        try decode(ManagedModelDestinationSnapshot.self, [
            "profile": profile,
            "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": revision,
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

    func testFutureEffortsKeepTheCatalogAndTheKnownWritableModels() throws {
        let relayStatus = try decode(ChatGPTRelayStatus.self, relay(enabled: true, models: [
            model("a", "A", efforts: ["future", "extra_high", "maximum", "low"], defaultEffort: "future"),
            model("b", "B", efforts: ["future"], defaultEffort: "medium"),
        ]))
        XCTAssertEqual(relayStatus.models[0].efforts, [.xhigh, .max, .low])
        XCTAssertEqual(relayStatus.models[0].writeEffort, .low)
        XCTAssertNil(relayStatus.models[1].writeEffort)
    }

    func testMalformedAndDuplicatedEffortsKeepTheSubscriptionCatalogUsable() throws {
        let relayStatus = try decode(ChatGPTRelayStatus.self, relay(enabled: true, models: [
            model("a", "A", efforts: ["medium", 7]),
            model("b", "B", efforts: ["medium", "future", "future"]),
            model("c", "C", efforts: ["medium", "medium"]),
            model("d", "D", efforts: [7, NSNull(), [:] as [String: String]]),
        ]))
        XCTAssertEqual(relayStatus.models.map(\.efforts), [[.medium], [.medium], [.medium], []])
        XCTAssertEqual(relayStatus.models.map(\.writeEffort), [.medium, .medium, .medium, nil])
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
        XCTAssertThrowsError(try ManagedModelSubscriptionWrite(requestId: id, snapshot: saved, source: .chatGPTPlan,
                                                               model: "gpt-6.1", effort: .max))
    }

    // MARK: The composer chip (W4-T)

    private func chatGPT(_ model: String) -> [String: Any] {
        ["destination": "cloud", "source": "chatgpt_plan", "model": model, "effort": "medium"]
    }

    /// The 1.1 offer; only its choice and revision matter to the chip (its
    /// unavailable grant keeps the fixture to the contract's invariants).
    private func offer(choice: String, revision: Int) throws -> ManagedModelSnapshot {
        func row(_ alias: String) -> [String: Any] {
            ["alias": alias, "displayName": alias, "providerModel": "provider/hidden",
             "contextBudget": 120_000, "outputBudget": 16_384,
             "efforts": ["low", "medium", "high"], "defaultEffort": "medium",
             "cost": ["currency": "USD", "inputPerMtok": "1.00", "outputPerMtok": "2.00",
                      "maxTurnMicroProtons": 1],
             "eligibility": ["state": "unavailable", "reason": "provider_unavailable"],
             "inputModalities": ["text"], "supportsTools": true]
        }
        return try decode(ManagedModelSnapshot.self, [
            "profile": "atum.model-choice/1.1",
            "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": revision, "source": "saved", "policyVersion": "2026-10-17.1",
            "policyDigest": String(repeating: "a", count: 64),
            "choice": ["v": 2, "source": "atum", "model": choice, "effort": "medium"],
            "models": [row("nguyet-thuc"), row("nhat-thuc")],
            "runtimes": [["runtime": "cloud"]],
            "grant": ["profile": "atum.model-grant/1", "state": "unavailable",
                      "reason": "provider_unavailable", "policyDigest": String(repeating: "a", count: 64)],
        ])
    }

    /// The chip names a saved ChatGPT-plan model by its display name, not the
    /// raw id the W4-R captures showed ("gpt-6.1"), before any account read.
    func testTheChipNamesASavedPlanModelByItsDisplayNameNeverTheRawID() throws {
        let saved = try snapshot(cloudChoice: chatGPT("gpt-6.1"))
        let face = try XCTUnwrap(PhoneModelPickerProjection.chip(pick: nil, destination: saved, offer: nil))
        XCTAssertEqual(face.name, "GPT-6.1")
        XCTAssertEqual(face.source, .chatGPTPlan)
        XCTAssertNil(face.connectionLabel)

        let go = try snapshot(profile: "atum.model-choice/1.4",
                              cloudChoice: ["destination": "cloud", "source": "opencode_go",
                                            "model": "glm-5.2", "effort": "high"])
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: nil, destination: go, offer: nil)?.name, "GLM 5.2")
    }

    func testChipWarnsWhenItsSavedSubscriptionCannotAnswer() throws {
        let plan = try snapshot(cloudChoice: chatGPT("gpt-6.1"))
        let go = try snapshot(profile: "atum.model-choice/1.4",
                              cloudChoice: ["destination": "cloud", "source": "opencode_go",
                                            "model": "glm-5.2", "effort": "high"])
        let unavailable = try account(relay: relay(enabled: false), connections: connections(connected: false))
        let available = try account(relay: relay(enabled: true), connections: connections(connected: true))

        let row = try XCTUnwrap(PhoneModelPickerProjection.subscriptions(plan, destination: cloud, account: available)
            .first { $0.selected })
        let pick = PhoneModelPickerProjection.ChipPick(row: row, destinationRevision: plan.revision, offerRevision: nil)
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: plan, offer: nil, account: unavailable),
                       .init(name: "GPT-6.1", source: .chatGPTPlan, planUnavailable: .noMac))
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: nil, destination: go, offer: nil, account: unavailable),
                       .init(name: "GLM 5.2", source: .opencodeGo, planUnavailable: .reconnect))
        XCTAssertNil(PhoneModelPickerProjection.chip(pick: pick, destination: plan, offer: nil, account: available)?
            .planUnavailable)
        XCTAssertNil(PhoneModelPickerProjection.chip(pick: nil, destination: go, offer: nil)?.planUnavailable)
        XCTAssertNil(PhoneModelPickerProjection.chip(pick: nil, destination: try snapshot(), offer: nil,
                                                    account: unavailable)?.planUnavailable)
    }

    /// Review r1: the relay names "gpt-6.1-mini" "GPT-6.1 mini", the id alone
    /// reads "GPT-6.1 Mini". Once the account's status is loaded the chip uses
    /// the list's own row, cold or after a pick, so the two never disagree.
    func testTheChipAndTheListNameASubscriptionModelTheSameWayOnceTheCatalogIsLoaded() throws {
        let saved = try snapshot(cloudChoice: chatGPT("gpt-6.1-mini"))
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let listed = try XCTUnwrap(PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
            .first { $0.selected })
        XCTAssertEqual(listed.displayName, "GPT-6.1 mini")

        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: nil, destination: saved, offer: nil)?.name,
                       "GPT-6.1 Mini", "no catalog yet: the desktop's words for the id, as the list's saved row")
        let cold = PhoneModelPickerProjection.chip(pick: nil, destination: saved, offer: nil, account: status)
        XCTAssertEqual(cold, .init(name: listed.displayName, source: listed.source,
                                   connectionLabel: listed.connectionLabel))

        // A pick's row from an older catalog yields to the list's current row.
        let stale = PhoneModelPickerProjection.Row(
            favoriteID: nil, source: .chatGPTPlan, model: "gpt-6.1-mini", displayName: "GPT-6.1 Mini",
            selected: true, selectable: false, isSubscription: true)
        let pick = PhoneModelPickerProjection.ChipPick(row: stale, destinationRevision: 6, offerRevision: nil)
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: saved, offer: nil, account: status)?.name,
                       "GPT-6.1 mini")
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: saved, offer: nil)?.name,
                       "GPT-6.1 Mini", "with no account read the pick keeps its own row's name")
    }

    /// Review r1 blocker: pick ChatGPT's mini in the composer, then choose
    /// Atum from Assistant Info. The composer's next destination readback is
    /// newer than the pick and saves Atum, so the pick no longer names the chip.
    func testANewerReadbackThatSavesSomethingElseEndsThePicksHold() throws {
        let before = try snapshot(cloudChoice: chatGPT("gpt-6.1"), revision: 7)
        let status = try account(relay: relay(enabled: true), connections: nil)
        let row = try XCTUnwrap(PhoneModelPickerProjection.subscriptions(before, destination: cloud, account: status)
            .first { $0.model == "gpt-6.1-mini" })
        let pick = PhoneModelPickerProjection.ChipPick(row: row.selecting(true), destinationRevision: 7,
                                                       offerRevision: 3)

        // The write's own readback saves the pick: it keeps naming the chip.
        let written = try snapshot(cloudChoice: chatGPT("gpt-6.1-mini"), revision: 8)
        XCTAssertEqual(PhoneModelPickerProjection.reconciled(pick, destination: written, offer: nil), pick)
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: written, offer: nil, account: status),
                       .init(name: "GPT-6.1 mini", source: .chatGPTPlan))
        // A readback no newer than the pick never drops it.
        XCTAssertEqual(PhoneModelPickerProjection.reconciled(pick, destination: before, offer: nil), pick)

        // Assistant Info chose Atum: name and mark follow the newer readback.
        let info = try snapshot(revision: 9)
        XCTAssertNil(PhoneModelPickerProjection.reconciled(pick, destination: info, offer: nil))
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: info, offer: nil, account: status),
                       .init(name: "Nguyệt Thực", source: .atum))
        // A newer readback with no saved cloud choice answers with the recommendation.
        let none = try decode(ManagedModelDestinationSnapshot.self, [
            "profile": "atum.model-choice/1.5", "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": 9, "policyDigest": String(repeating: "b", count: 64),
            "recommended": ["source": "atum", "model": "nguyet-thuc", "effort": "medium"], "choices": [],
            "dailyCap": ["dailyProtons": 0, "timeZone": "Asia/Ho_Chi_Minh",
                         "warningPercent": 80, "counts": "atum_billed_only"],
            "spend": ["day": "2026-11-11", "usedProtons": 0, "state": "normal", "notice": "none"],
        ])
        XCTAssertNil(PhoneModelPickerProjection.reconciled(pick, destination: none, offer: nil))
    }

    /// An Atum pick over the 1.1 offer: the destination read may lag the 1.1
    /// write, so only a newer readback that saves another model drops it.
    func testAnAtumPickYieldsOnlyToANewerReadbackThatSavesAnotherModel() throws {
        let stale = try snapshot(cloudChoice: chatGPT("gpt-6.1"), revision: 7)
        let row = try XCTUnwrap(PhoneModelPickerProjection.conversation(
            offer: nil, destination: stale, destinationID: cloud).first { $0.model == ManagedModelLineup.hardAlias })
        let pick = PhoneModelPickerProjection.ChipPick(row: row, destinationRevision: 7, offerRevision: 3)
        let written = try offer(choice: ManagedModelLineup.hardAlias, revision: 4)

        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: stale, offer: written)?.name,
                       "Nhật Thực", "the destination read has not caught up with the 1.1 write")
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: stale, offer: written)?.source, .atum)
        XCTAssertNil(PhoneModelPickerProjection.reconciled(pick, destination: stale,
                                                           offer: try offer(choice: "nguyet-thuc", revision: 5)))
        let elsewhere = try snapshot(cloudChoice: chatGPT("gpt-6.1"), revision: 8)
        XCTAssertNil(PhoneModelPickerProjection.reconciled(pick, destination: elsewhere, offer: written))
        XCTAssertEqual(PhoneModelPickerProjection.chip(pick: pick, destination: elsewhere, offer: written)?.name,
                       "GPT-6.1")
    }

    /// Review r1: the composer lists only Atum's line-up and the cloud's
    /// subscriptions, never an own-key row (desktop `chipRoute` is the current
    /// route, and a cloud assistant's picker has no own-key route). The chip's
    /// mark facts are exactly those of the row the list draws.
    func testTheChipsMarkFactsAreTheListedRowsOwn() throws {
        let saved = try snapshot()
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let rows = PhoneModelPickerProjection.conversation(offer: nil, destination: saved, destinationID: cloud)
            .filter { !$0.announced }
            + PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: status)
        XCTAssertFalse(rows.contains { if case .ownKey = $0.source { true } else { false } })
        for row in rows {
            let face = try XCTUnwrap(PhoneModelPickerProjection.chip(
                pick: .init(row: row, destinationRevision: 7, offerRevision: nil),
                destination: saved, offer: nil, account: status))
            XCTAssertEqual(face.source, row.source, row.model)
            XCTAssertEqual(face.connectionLabel, row.connectionLabel, row.model)
        }
    }

    func testTheChipNamesAtumsLineUpAndNothingBeforeAnyRead() throws {
        XCTAssertNil(PhoneModelPickerProjection.chip(pick: nil, destination: nil, offer: nil))
        let face = PhoneModelPickerProjection.chip(pick: nil, destination: try snapshot(), offer: nil)
        XCTAssertEqual(face, .init(name: "Nguyệt Thực", source: .atum))
    }

    /// The desktop card's `external.modelLabel` for a saved model with no
    /// catalog row (`model-destinations.test.ts`).
    func testASavedExternalModelIsLabelledAsTheDesktopCardLabelsIt() {
        XCTAssertEqual(ModelDisplayName.destinationLabel(model: "openai/gpt-6.1-sol"), "Openai GPT 6.1 Sol")
        XCTAssertEqual(ModelDisplayName.destinationLabel(model: "glm-5.2"), "Glm 5.2")
        XCTAssertEqual(ModelDisplayName.destinationLabel(model: "GPT_4o"), "GPT 4o")
        XCTAssertEqual(ModelDisplayName.destinationLabel(model: "Claude--opus"), "Claude Opus")
        XCTAssertEqual(ModelDisplayName.destinationLabel(model: "openai/gpt-6.1-sol", displayName: "GPT-6.1 Sol"),
                       "GPT-6.1 Sol", "a catalog row's own label wins")
    }

    /// The desktop's `matrixModelDisplayName`, case for case.
    func testAnIDOnlyModelIsNamedAsTheDesktopNamesIt() {
        XCTAssertEqual(ModelDisplayName.name(model: "gpt-6.1"), "GPT-6.1")
        XCTAssertEqual(ModelDisplayName.name(model: "gpt-5.6-luna"), "GPT-5.6 Luna")
        XCTAssertEqual(ModelDisplayName.name(model: "glm-5.2"), "GLM 5.2")
        XCTAssertEqual(ModelDisplayName.name(model: "deepseek_v4"), "DeepSeek V4")
        XCTAssertEqual(ModelDisplayName.name(model: "gpt-mini"), "GPT Mini")
        XCTAssertEqual(ModelDisplayName.name(model: "gpt-6.1", displayName: "GPT-6.1 (plan)"), "GPT-6.1 (plan)")
        XCTAssertEqual(ModelDisplayName.name(model: "gpt-6.1", displayName: " gpt-6.1 "), "GPT-6.1",
                       "a catalog that repeats the id has no display name of its own")
        XCTAssertEqual(ModelDisplayName.name(model: "--"), "--")
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
            XCTAssertFalse(rows[0].selected)
            XCTAssertFalse(rows[0].selectable)
            XCTAssertNil(rows[0].unavailable)
        }
    }

    @available(macOS 14.0, *)
    @MainActor
    func testRefusalRefreshDisablesCachedPlanRowsAndShowsLoadingUntilTheRelayAnswers() async throws {
        let saved = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "medium"])
        let enabled = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let disabled = try account(relay: relay(enabled: false), connections: connections(connected: true))
        let state = PhoneModelPickerAccount()
        func rows() -> [PhoneModelPickerProjection.Row] {
            PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: state.value)
        }

        await state.reload(reads(enabled))
        let alternate = try XCTUnwrap(rows().first { $0.model == "gpt-6.1-mini" })
        XCTAssertTrue(alternate.selectable)
        XCTAssertEqual(rows().first?.selected, true)
        XCTAssertNil(rows().first?.unavailable)

        let relayRead = PendingRead<ChatGPTRelayStatus?>()
        let refresh = Task {
            await state.reload(PhoneSubscriptionAccountReads(
                chatGPT: { await relayRead.read() }, openCodeGo: { disabled.openCodeGo },
                accountConnections: { nil }
            ))
        }
        await waitUntil { relayRead.pending && state.value?.openCodeGoState == .ready }
        XCTAssertEqual(state.value?.chatGPTState, .loading)
        XCTAssertEqual(state.value?.chatGPT?.state, .enabled)
        XCTAssertEqual(rows().map(\.model), ["gpt-6.1", "gpt-6.1-mini", "glm-5.2"])
        XCTAssertEqual(rows().map(\.selectable), [false, false, true])
        XCTAssertEqual(rows().first?.unavailable, .loading)
        XCTAssertEqual(rows().first?.selected, false)
        XCTAssertNil(PhoneModelPickerProjection.canSelectSubscription(alternate, snapshot: saved, account: state.value))
        relayRead.finish(disabled.chatGPT)
        await refresh.value

        XCTAssertEqual(state.value?.chatGPTState, .unavailable)
        XCTAssertEqual(rows().map(\.model), ["gpt-6.1", "glm-5.2"])
        XCTAssertEqual(rows().first?.unavailable, .notReady)
        XCTAssertEqual(rows().first?.selected, false)
        XCTAssertEqual(rows().first?.selectable, false)
    }

    @available(macOS 14.0, *)
    @MainActor
    func testLateReplyCannotReplaceNewerState() async throws {
        let enabled = try account(relay: relay(enabled: true), connections: nil)
        let disabled = try account(relay: relay(enabled: false), connections: nil)
        let state = PhoneModelPickerAccount()
        let relayRead = PendingRead<ChatGPTRelayStatus?>()
        let old = Task {
            await state.reload(PhoneSubscriptionAccountReads(
                chatGPT: { await relayRead.read() }, openCodeGo: { nil }, accountConnections: { nil }
            ))
        }
        await waitUntil { relayRead.pending }
        await state.reload(reads(disabled))
        relayRead.finish(enabled.chatGPT)
        await old.value

        XCTAssertEqual(state.value?.chatGPTState, .unavailable)
        XCTAssertEqual(state.value?.chatGPT?.state, .disabled)
    }

    @available(macOS 14.0, *)
    @MainActor
    func testTimedOutSourceKeepsWorkingCatalog() async throws {
        let saved = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                               "model": "gpt-6.1", "effort": "medium"])
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let state = PhoneModelPickerAccount()
        let relayRead = PendingRead<ChatGPTRelayStatus?>()
        await state.reload(PhoneSubscriptionAccountReads(
            chatGPT: { await relayRead.read() }, openCodeGo: { status.openCodeGo },
            accountConnections: { nil }
        ), within: PhoneModelPickerRead(sourceLimit: .milliseconds(40)))
        XCTAssertTrue(relayRead.pending, "the timeout returned while the source still ignored cancellation")
        XCTAssertEqual(state.value?.chatGPTState, .failed)
        XCTAssertEqual(state.value?.openCodeGoState, .ready)
        let rows = PhoneModelPickerProjection.subscriptions(saved, destination: cloud, account: state.value)
        XCTAssertEqual(rows.map(\.model), ["gpt-6.1", "glm-5.2"])
        XCTAssertEqual(rows.map(\.unavailable), [.failed, nil])
        XCTAssertEqual(rows.map(\.selectable), [false, true])
        XCTAssertFalse(rows[0].selected)
        relayRead.finish(status.chatGPT)
        await waitUntil { relayRead.returned }
        XCTAssertEqual(state.value?.chatGPTState, .failed)
    }

    func testDestinationFailureKeepsCatalogReadOnly() throws {
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let savedChatGPT = try snapshot(cloudChoice: ["destination": "cloud", "source": "chatgpt_plan",
                                                    "model": "gpt-6.1", "effort": "medium"])
        let savedGo = try snapshot(cloudChoice: ["destination": "cloud", "source": "opencode_go",
                                               "model": "glm-5.2", "effort": "high"])
        for destination in [nil, savedChatGPT, savedGo] {
            let rows = PhoneModelPickerProjection.subscriptions(
                destination, destination: cloud, account: status, destinationReady: false
            )
            XCTAssertEqual(rows.map(\.model), ["gpt-6.1", "gpt-6.1-mini", "glm-5.2"])
            XCTAssertTrue(rows.allSatisfy { !$0.selected && !$0.selectable && $0.subscriptionEffort == nil })
        }
    }

    @available(macOS 14.0, *)
    @MainActor
    func testPerSourceFailureLeavesOtherSourcesReady() async throws {
        struct ReadError: Error {}
        let status = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let registry = AccountConnections(connections: [])
        let state = PhoneModelPickerAccount()
        await state.reload(PhoneSubscriptionAccountReads(
            chatGPT: { status.chatGPT }, openCodeGo: { throw ReadError() },
            accountConnections: { registry }
        ))

        XCTAssertEqual(state.value?.chatGPTState, .ready)
        XCTAssertEqual(state.value?.openCodeGoState, .failed)
        XCTAssertEqual(state.value?.accountConnectionsState, .ready)
        XCTAssertEqual(state.value?.accountConnections, registry)
        let rows = PhoneModelPickerProjection.subscriptions(try snapshot(), destination: cloud, account: state.value)
        XCTAssertEqual(rows.map(\.model), ["gpt-6.1", "gpt-6.1-mini"])
        XCTAssertTrue(rows.allSatisfy(\.selectable))
        let savedGo = try snapshot(cloudChoice: ["destination": "cloud", "source": "opencode_go",
                                                 "model": "glm-5.2", "effort": "high"])
        let savedRow = try XCTUnwrap(PhoneModelPickerProjection.subscriptions(
            savedGo, destination: cloud, account: state.value
        ).first { $0.source == .opencodeGo })
        XCTAssertEqual(savedRow.model, "glm-5.2")
        XCTAssertFalse(savedRow.selected)
        XCTAssertFalse(savedRow.selectable)
        XCTAssertEqual(savedRow.unavailable, .failed)
    }

    @available(macOS 14.0, *)
    @MainActor
    func testAccountChangeAndRetirementDropOldReplies() async throws {
        let enabled = try account(relay: relay(enabled: true), connections: nil)
        let newAccount = try account(relay: nil, connections: connections(connected: true))
        let state = PhoneModelPickerAccount()
        var accountIsCurrent = true
        let registryRead = PendingRead<AccountConnections?>()
        let old = Task {
            await state.reload(PhoneSubscriptionAccountReads(
                chatGPT: { enabled.chatGPT }, openCodeGo: { nil },
                accountConnections: { await registryRead.read() }, isCurrent: { accountIsCurrent }
            ))
        }
        await waitUntil { registryRead.pending && state.value?.chatGPTState == .ready }
        accountIsCurrent = false
        XCTAssertNil(state.value)
        await state.reload(reads(newAccount))
        registryRead.finish(AccountConnections(connections: []))
        await old.value
        XCTAssertEqual(state.value, newAccount)

        let relayRead = PendingRead<ChatGPTRelayStatus?>()
        let retired = Task {
            await state.reload(PhoneSubscriptionAccountReads(
                chatGPT: { await relayRead.read() }, openCodeGo: { newAccount.openCodeGo },
                accountConnections: { nil }
            ))
        }
        await waitUntil { relayRead.pending && state.value?.openCodeGoState == .ready }
        state.retire(keepingSettled: true)
        relayRead.finish(enabled.chatGPT)
        await retired.value
        XCTAssertEqual(state.value, newAccount)
        state.retire()
        XCTAssertNil(state.value)
    }

    @available(macOS 14.0, *)
    @MainActor
    func testRegistryLandingOnlySupersedesTheRegistryRead() async throws {
        let state = PhoneModelPickerAccount()
        let old = AccountConnections(connections: [])
        let landed = AccountConnections(connections: [
            AccountConnection(id: "codex", kind: .plan, status: .connected, devices: []),
        ])
        let relay = try decode(ChatGPTRelayStatus.self, relay(enabled: true))
        let relayRead = PendingRead<ChatGPTRelayStatus?>()
        let registryRead = PendingRead<AccountConnections?>()
        let refresh = Task {
            await state.reload(PhoneSubscriptionAccountReads(
                chatGPT: { await relayRead.read() }, openCodeGo: { nil },
                accountConnections: { await registryRead.read() }
            ))
        }
        await waitUntil { registryRead.pending && relayRead.pending }
        state.landed(landed)
        XCTAssertEqual(state.value?.accountConnectionsState, .ready)
        registryRead.finish(old)
        relayRead.finish(relay)
        await refresh.value
        XCTAssertEqual(state.value?.accountConnections, landed)
        XCTAssertEqual(state.value?.chatGPT, relay)
        XCTAssertEqual(state.value?.chatGPTState, .ready)
    }

    @MainActor
    func testQueuedReplyWinsEvenIfTheClockPassesTheDeadlineBeforeTheActorResumes() async {
        let pending = PendingRead<String>()
        let timer = PendingRead<Void>()
        let start = ContinuousClock().now
        var now = start
        let budget = PhoneModelPickerRead(
            start: start, sourceLimit: .seconds(4), overallLimit: .seconds(8),
            now: { now }, sleepUntil: { _ in await timer.read() }
        )
        let read = Task { await budget.withinOverall { await pending.read() } }
        await waitUntil { pending.pending && timer.pending }
        pending.finish("destination")
        // Both operations run in one actor turn. The reply is queued before
        // the deadline, and the timer has yet to finish.
        now = start.advanced(by: .seconds(9))
        await waitUntil { pending.returned }
        timer.finish(())
        let answer = await read.value
        XCTAssertEqual(answer, "destination")
    }

    @MainActor
    func testRetiredDestinationScopeSettlesUnavailableAndDropsItsReply() async throws {
        let pending = PendingRead<PhoneModelPickerReadResult<ManagedModelDestinationSnapshot>>()
        let destination = try snapshot()
        var isCurrent = true
        var state = PhoneModelPickerReadState.loading
        let read = Task {
            let result = await PhoneModelPickerRead().scoped(isCurrent: { isCurrent }) {
                await pending.read()
            }
            state = result.state
        }
        await waitUntil { pending.pending }
        isCurrent = false
        pending.finish(.value(destination))
        await read.value
        XCTAssertEqual(state, .unavailable)
    }

    @MainActor
    func testDestinationMakesTheCatalogWritableWhileTheOfferStillWaits() async throws {
        let offer = PendingRead<PhoneModelPickerReadResult<ManagedModelSnapshot>>()
        let account = try account(relay: relay(enabled: true), connections: connections(connected: true))
        let destination = try snapshot()
        let budget = PhoneModelPickerRead()
        let offerRead = Task { await budget.scoped(isCurrent: { true }) { await offer.read() } }
        await waitUntil { offer.pending }
        let read = await budget.scoped(isCurrent: { true }) { .value(destination) }
        XCTAssertEqual(read.state, .ready)
        if case let .value(snapshot) = read {
            let rows = PhoneModelPickerProjection.subscriptions(
                snapshot, destination: cloud, account: account, destinationReady: read.state == .ready
            )
            XCTAssertEqual(rows.count, 3)
            XCTAssertTrue(rows.allSatisfy(\.selectable))
        } else {
            XCTFail("destination snapshot did not settle")
        }
        XCTAssertTrue(offer.pending)
        offer.finish(.failed)
        let offerResult = await offerRead.value
        XCTAssertEqual(offerResult.state, .failed)
        XCTAssertEqual(read.state, .ready)
    }

    func testWorkHandoffsKeepNativePlanIdentityAndExcludeCloudRelayDuplicates() throws {
        let mac = AccountConnectionDevice(deviceServiceID: "mac", displayName: "Mac", stale: false,
                                          observedAt: 1)
        let workModel = AccountConnectionModel(id: "work-model", displayName: "Work model")
        let registry = AccountConnections(connections: AccountPlan.allCases.map { plan in
            AccountConnection(id: plan.rawValue, kind: .plan,
                              status: plan == .antigravity ? .needsAttention : .connected,
                              devices: [mac], models: [workModel])
        })
        let enabled = try decode(ChatGPTRelayStatus.self, relay(enabled: true))
        let handoffs = PhoneSubscriptionAccount(chatGPT: enabled, openCodeGo: nil, accountConnections: registry)
            .workPlanHandoffs
        XCTAssertEqual(handoffs.map(\.id), [.claude])
        XCTAssertEqual(handoffs.first?.models, [workModel])
        XCTAssertEqual(handoffs.first?.reason, .openOnMac)
        let nativeOnly = PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil, accountConnections: registry)
        XCTAssertEqual(nativeOnly.workPlanHandoffs.map(\.id), [.codex, .claude])
    }

    @MainActor
    func testOverallDeadlineReturnsWithAnUncooperativeDestinationRead() async {
        let pending = PendingRead<String>()
        let budget = PhoneModelPickerRead(overallLimit: .milliseconds(40))
        let answer = await budget.withinOverall { await pending.read() }
        XCTAssertNil(answer)
        XCTAssertTrue(pending.pending)
        pending.finish("late destination")
        await waitUntil { pending.returned }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition(), clock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "read did not reach the expected state", file: file, line: line)
    }

    @MainActor
    private final class PendingRead<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        var pending: Bool { continuation != nil }
        private(set) var returned = false

        func read() async -> Value {
            let value = await withCheckedContinuation { continuation = $0 }
            returned = true
            return value
        }

        func finish(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
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
