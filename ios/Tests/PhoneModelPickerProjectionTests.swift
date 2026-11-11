import XCTest
@testable import AtumNativeAPI

final class PhoneModelPickerProjectionTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "model-choice-v1.3"
        ))
        return try Data(contentsOf: url)
    }

    private func cloudSnapshot() throws -> ManagedModelSnapshot {
        let object: [String: Any] = [
            "profile": "atum.model-choice/1.1",
            "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": 1,
            "source": "saved",
            "policyVersion": "2026-10-17.1",
            "policyDigest": String(repeating: "a", count: 64),
            "choice": ["v": 2, "source": "atum", "model": "nhat-thuc", "effort": "medium"],
            "models": [
                offer(alias: "nguyet-thuc", name: "Nguyệt Thực 1.3", eligibility: ["state": "ready"]),
                offer(alias: "nhat-thuc", name: "Nhật Thực 1.1",
                      eligibility: ["state": "unavailable", "reason": "provider_unavailable"])
            ],
            "runtimes": [["runtime": "cloud"]],
            "grant": [
                "profile": "atum.model-grant/1", "state": "unavailable",
                "reason": "provider_unavailable", "policyDigest": String(repeating: "a", count: 64)
            ]
        ]
        return try NativeAPI.decode(ManagedModelSnapshot.self,
                                    from: JSONSerialization.data(withJSONObject: object))
    }

    private func offer(alias: String, name: String,
                       eligibility: [String: String]) -> [String: Any] {
        [
            "alias": alias, "displayName": name, "providerModel": "provider/hidden-from-projection",
            "contextBudget": 120_000, "outputBudget": 16_384,
            "efforts": ["low", "medium", "high"], "defaultEffort": "medium",
            "cost": ["currency": "USD", "inputPerMtok": "1.00", "outputPerMtok": "2.00",
                     "maxTurnMicroProtons": 1],
            "eligibility": eligibility, "inputModalities": ["text"], "supportsTools": true
        ]
    }

    private func destinationSnapshot(removing destination: String? = nil) throws
        -> ManagedModelDestinationSnapshot {
        let data = try fixture("destination.snapshot")
        guard let destination else {
            return try NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: data)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        object["choices"] = choices.filter { ($0["destination"] as? String) != destination }
        object["revision"] = 4
        return try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func testCloudProjectsTheLineUpWithOfferEligibilityAndCleanNames() throws {
        let rows = PhoneModelPickerProjection.cloud(try cloudSnapshot())
        XCTAssertEqual(rows.map(\.source), [.atum, .atum, .atum])
        XCTAssertEqual(rows.map(\.model), ["nguyet-thuc", "nhat-thuc", "thai-cuc"])
        XCTAssertEqual(rows.map(\.favoriteID), ["nguyet-thuc", "nhat-thuc", nil])
        XCTAssertEqual(rows.map(\.displayName), ["Nguyệt Thực 1.3", "Nhật Thực 1.1", "Thái Cực"])
        XCTAssertEqual(rows.map(\.selected), [false, true, false])
        XCTAssertEqual(rows.map(\.selectable), [true, false, false])
        XCTAssertEqual(rows.map(\.announced), [false, false, true])
        XCTAssertEqual(rows.map(\.tagline), [.everyday, .hard, .flagship])
        XCTAssertFalse(rows.map(\.displayName).contains("provider/hidden-from-projection"))
        XCTAssertFalse(rows.map(\.displayName).contains { $0.contains("20×") || $0.contains("20x") })
    }

    func testTheLineUpIsPresentEvenWhenTheOfferNamesNoModel() throws {
        // The picker must always show the three Atum rows: an older 1.1 offer
        // that lists nothing is a loading state, not a reason to hide it.
        let empty = try readySnapshot(efforts: ["medium"])
        let rows = PhoneModelPickerProjection.conversation(
            offer: empty, destination: nil, destinationID: try ManagedModelDestinationID("cloud"))
        XCTAssertEqual(rows.map(\.model), ["nguyet-thuc", "nhat-thuc", "thai-cuc"])
    }

    func testDefaultBadgeNamesTheLineUpDefaultOnlyWhileItCanBeChosen() throws {
        // `cloudSnapshot()` offers the default ready and the hard model unavailable.
        let ready = PhoneModelPickerProjection.cloud(try cloudSnapshot())
        XCTAssertEqual(ready.map(\.badges), [[.default], [], []])

        // A cloud destination whose default is not eligible now: a badge on a
        // row nobody can pick would lie, so nothing carries it.
        let offline = PhoneModelPickerProjection.destination(
            try NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot")),
            destination: try ManagedModelDestinationID("cloud"),
            cloudEligibleAliases: [ManagedModelLineup.hardAlias]
        )
        XCTAssertEqual(offline.map(\.badges), [[], [], []])
    }

    func testDestinationDefaultBadgeFollowsTheServerRecommendation() throws {
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot")
        )
        XCTAssertEqual(snapshot.recommended.model, ManagedModelLineup.defaultAlias)

        let cloud = PhoneModelPickerProjection.destination(
            snapshot, destination: try ManagedModelDestinationID("cloud"),
            cloudEligibleAliases: Set(ManagedModelLineup.servedAliases)
        )
        XCTAssertEqual(cloud.filter { $0.badges.contains(.default) }.map(\.model),
                       [ManagedModelLineup.defaultAlias])

        // Default is not "current": this Mac runs the hard model and the badge
        // stays on the recommendation. An external saved row never carries it.
        let mini = PhoneModelPickerProjection.destination(
            snapshot, destination: try ManagedModelDestinationID("mac:mini-b"), cloudEligibleAliases: []
        )
        XCTAssertEqual(mini.filter(\.selected).map(\.model), [ManagedModelLineup.hardAlias])
        XCTAssertEqual(mini.filter { $0.badges.contains(.default) }.map(\.model),
                       [ManagedModelLineup.defaultAlias])
        let external = PhoneModelPickerProjection.destination(
            snapshot, destination: try ManagedModelDestinationID("mac:book-a"), cloudEligibleAliases: []
        )
        XCTAssertEqual(external.first?.badges, [])
        XCTAssertEqual(external.filter { $0.badges.contains(.default) }.map(\.model),
                       [ManagedModelLineup.defaultAlias])
    }

    func testSavedExternalMacIsActualReadOnlyChoiceWithoutFalseAtumSelection() throws {
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot")
        )
        let destination = try ManagedModelDestinationID("mac:book-a")
        let rows = PhoneModelPickerProjection.mac(snapshot, destination: destination)

        XCTAssertEqual(rows.first?.source, .ownKey("openrouter"))
        XCTAssertEqual(rows.first?.model, "openai/gpt-6.1-sol")
        XCTAssertEqual(rows.first?.displayName, "openai/gpt-6.1-sol")
        XCTAssertEqual(rows.first?.selected, true)
        XCTAssertEqual(rows.first?.selectable, false)
        XCTAssertNil(rows.first?.favoriteID, "no opaque controller route exists to favorite yet")
        XCTAssertFalse(rows.dropFirst().contains(where: \.selected),
                       "an external choice must not fall back to a selected Atum recommendation")
        XCTAssertTrue(rows.dropFirst().filter { !$0.announced }
            .allSatisfy { $0.source == .atum && $0.selectable })
    }

    func testMissingMacChoiceProducesNoSyntheticSelectableRows() throws {
        let snapshot = try destinationSnapshot()
        let destination = try ManagedModelDestinationID("mac:new-device")
        let rows = PhoneModelPickerProjection.mac(snapshot,
                                                   destination: destination)
        XCTAssertEqual(rows, [])
        XCTAssertFalse(PhoneModelPickerProjection.canSelectAtumModel(
            ManagedModelLineup.defaultAlias,
            snapshot: snapshot,
            destination: destination,
            cloudEligibleAliases: Set(ManagedModelLineup.servedAliases)
        ))
    }

    func testActiveMacAtumChoiceRemainsSelectable() throws {
        let snapshot = try destinationSnapshot()
        let destination = try ManagedModelDestinationID("mac:mini-b")
        let rows = PhoneModelPickerProjection.mac(snapshot, destination: destination)
        XCTAssertEqual(rows.filter(\.selected).map(\.model), [ManagedModelLineup.hardAlias])
        XCTAssertTrue(PhoneModelPickerProjection.canSelectAtumModel(
            ManagedModelLineup.defaultAlias,
            snapshot: snapshot,
            destination: destination,
            cloudEligibleAliases: []
        ))
    }

    func testConflictReadbackRemovingMacClosesActualSelectionBoundary() throws {
        let destination = try ManagedModelDestinationID("mac:mini-b")
        let before = try destinationSnapshot()
        XCTAssertTrue(PhoneModelPickerProjection.canSelectAtumModel(
            ManagedModelLineup.defaultAlias,
            snapshot: before,
            destination: destination,
            cloudEligibleAliases: []
        ))

        // This is the authoritative snapshot the UI installs from a conflict
        // readback before a person can retry in the still-present destination view.
        let afterConflict = try destinationSnapshot(removing: destination.rawValue)
        XCTAssertEqual(PhoneModelPickerProjection.destination(
            afterConflict, destination: destination, cloudEligibleAliases: []
        ), [])
        XCTAssertFalse(PhoneModelPickerProjection.canSelectAtumModel(
            ManagedModelLineup.defaultAlias,
            snapshot: afterConflict,
            destination: destination,
            cloudEligibleAliases: []
        ))
    }

    func testCloudDestinationUsesOnlyAtumAndDecodedEligibility() throws {
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot")
        )
        let rows = PhoneModelPickerProjection.destination(
            snapshot,
            destination: try ManagedModelDestinationID("cloud"),
            cloudEligibleAliases: [ManagedModelLineup.defaultAlias]
        )
        XCTAssertEqual(rows.map(\.source), [.atum, .atum, .atum])
        XCTAssertEqual(rows.map(\.selectable), [true, false, false])
        XCTAssertEqual(rows.filter(\.selected).map(\.model), [ManagedModelLineup.defaultAlias])
    }

    // MARK: Thinking level and the way back to Atum

    /// A cloud offer whose current model is ready, with the levels it accepts.
    private func readySnapshot(model: String = "nguyet-thuc", effort: String? = "medium",
                               efforts: [String] = ["low", "medium", "high"]) throws -> ManagedModelSnapshot {
        let digest = String(repeating: "a", count: 64)
        let defaultEffort = efforts.contains("medium") ? "medium" : efforts[0]
        var choice: [String: Any] = ["v": 2, "source": "atum", "model": model]
        if let effort { choice["effort"] = effort }
        var current = offer(alias: model, name: "Current", eligibility: ["state": "ready"])
        current["efforts"] = efforts
        current["defaultEffort"] = defaultEffort
        let object: [String: Any] = [
            "profile": "atum.model-choice/1.1",
            "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
            "revision": 1, "source": "saved", "policyVersion": "2026-10-17.1", "policyDigest": digest,
            "choice": choice, "models": [current], "runtimes": [["runtime": "cloud"]],
            "grant": [
                "profile": "atum.model-grant/1", "state": "active", "alias": model, "model": model,
                "effort": effort ?? defaultEffort, "policyDigest": digest, "contextBudget": 120_000,
                "outputBudget": 16_384, "maxTurnMicroProtons": 10_000_000
            ]
        ]
        return try NativeAPI.decode(ManagedModelSnapshot.self,
                                    from: JSONSerialization.data(withJSONObject: object))
    }

    func testThinkingOffersTheLevelsTheServerListsForTheCurrentModelQuickestFirst() throws {
        let thinking = try XCTUnwrap(PhoneModelPickerProjection.thinking(
            try readySnapshot(effort: "high", efforts: ["high", "low", "medium"])))
        XCTAssertEqual(thinking.model, "nguyet-thuc")
        XCTAssertEqual(thinking.levels, [.low, .medium, .high])
        XCTAssertEqual(thinking.current, .high)
    }

    func testThinkingReadsTheOffersDefaultWhenNoLevelWasSaved() throws {
        let thinking = try XCTUnwrap(PhoneModelPickerProjection.thinking(
            try readySnapshot(effort: nil, efforts: ["low", "high"])))
        XCTAssertEqual(thinking.levels, [.low, .high])
        XCTAssertEqual(thinking.current, .low, "the offer's default; nothing was saved")
    }

    func testThereIsNoThinkingControlForOneLevelOrAModelThatCannotBeWritten() throws {
        XCTAssertNil(PhoneModelPickerProjection.thinking(try readySnapshot(efforts: ["medium"])),
                     "a control with one choice is not a control")
        XCTAssertNil(PhoneModelPickerProjection.thinking(try cloudSnapshot()),
                     "the current model is not eligible now, so nothing can be written")
    }

    func testOnlyAnOfferedDifferentLevelMayBeWritten() throws {
        let snapshot = try readySnapshot(effort: "medium", efforts: ["low", "medium"])
        XCTAssertTrue(PhoneModelPickerProjection.canChangeThinking(to: .low, snapshot: snapshot))
        XCTAssertFalse(PhoneModelPickerProjection.canChangeThinking(to: .medium, snapshot: snapshot),
                       "already the saved level")
        XCTAssertFalse(PhoneModelPickerProjection.canChangeThinking(to: .high, snapshot: snapshot),
                       "not a level this model offers")
        XCTAssertFalse(PhoneModelPickerProjection.canChangeThinking(to: .low, snapshot: try cloudSnapshot()))
    }

    func testAThinkingChangeIsTheSameFencedWriteAModelPickIs() throws {
        let snapshot = try readySnapshot(effort: "medium")
        let write = try ManagedModelWrite(requestId: try NativeID(UUID().uuidString.lowercased()),
                                          snapshot: snapshot, model: "nguyet-thuc", effort: .high)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(write)) as? [String: Any])
        let choice = try XCTUnwrap(encoded["choice"] as? [String: Any])
        XCTAssertEqual(choice["model"] as? String, "nguyet-thuc")
        XCTAssertEqual(choice["effort"] as? String, "high")
        XCTAssertEqual(encoded["expectedRevision"] as? Int, 1, "fenced by the snapshot it was read from")
        // The contract still refuses a level the model does not offer.
        XCTAssertThrowsError(try ManagedModelWrite(
            requestId: try NativeID(UUID().uuidString.lowercased()),
            snapshot: try readySnapshot(efforts: ["low", "medium"]), model: "nguyet-thuc", effort: .high))
    }

    func testSwitchBackNamesTheRecommendationForAMacOnAConnection() throws {
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot"))
        // `mac:book-a` runs its own OpenRouter key, `mac:mini-a` a ChatGPT plan.
        for mac in ["mac:book-a", "mac:mini-a"] {
            let destination = try ManagedModelDestinationID(mac)
            let model = try XCTUnwrap(PhoneModelPickerProjection.switchBackModel(snapshot, destination: destination), mac)
            XCTAssertEqual(model, snapshot.recommended.model, mac)
            XCTAssertTrue(PhoneModelPickerProjection.canSelectAtumModel(
                model, snapshot: snapshot, destination: destination, cloudEligibleAliases: []),
                "the way back is the same write boundary as picking that model")
        }
    }

    func testThereIsNoWayBackWhenAlreadyOnAtumOrNotAMacOrNotInTheLatestSnapshot() throws {
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot"))
        for destination in ["mac:mini-b", "cloud", "mac:new-device"] {
            XCTAssertNil(PhoneModelPickerProjection.switchBackModel(
                snapshot, destination: try ManagedModelDestinationID(destination)), destination)
        }
    }

    func testTheWayBackFallsBackToTheLineUpDefaultWhenTheRecommendationCannotBePicked() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("destination.snapshot")) as? [String: Any])
        object["recommended"] = ["source": "atum", "model": ManagedModelLineup.announcedAlias, "effort": "medium"]
        let snapshot = try NativeAPI.decode(ManagedModelDestinationSnapshot.self,
                                            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(PhoneModelPickerProjection.switchBackModel(
            snapshot, destination: try ManagedModelDestinationID("mac:book-a")), ManagedModelLineup.defaultAlias)
    }

    func testCloudDestinationCannotUseMacProjectionOrDecodeExternalSource() throws {
        let snapshotData = try fixture("destination.snapshot")
        let snapshot = try NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: snapshotData)
        XCTAssertEqual(PhoneModelPickerProjection.mac(
            snapshot, destination: try ManagedModelDestinationID("cloud")
        ), [])

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        var choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        choices[0]["source"] = "chatgpt_plan"
        choices[0]["model"] = "gpt-6-luna"
        object["choices"] = choices
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    // MARK: The conversation picker, 1.4 subscriptions and the restored line-up

    /// The 1.4 contract is additive: the same shape plus `opencode_go` on a
    /// cloud destination. The phone accepts both profile literals and keeps a
    /// 1.3 snapshot working exactly as before.
    private func subscriptionSnapshot() throws -> ManagedModelDestinationSnapshot {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("destination.snapshot")) as? [String: Any])
        object["profile"] = "atum.model-choice/1.4"
        var choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        choices[0] = ["destination": "cloud", "source": "opencode_go",
                      "model": "glm-5.2", "effort": "high"]
        object["choices"] = choices
        return try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func testA14SnapshotDecodesAndDrawsTheConnectedSubscriptionAfterTheLineUp() throws {
        let snapshot = try subscriptionSnapshot()
        let destination = try ManagedModelDestinationID("cloud")
        let lineUp = PhoneModelPickerProjection.conversation(
            offer: nil, destination: snapshot, destinationID: destination)
        XCTAssertEqual(lineUp.map(\.model), ["nguyet-thuc", "nhat-thuc", "thai-cuc"],
                       "the line-up stays present when only the 1.4 read answers")
        XCTAssertTrue(lineUp.allSatisfy { !$0.selected },
                      "the subscription is current, so no Atum row claims the check")

        let subscriptions = PhoneModelPickerProjection.subscriptions(snapshot, destination: destination)
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions[0].source, .opencodeGo)
        XCTAssertEqual(subscriptions[0].model, "glm-5.2")
        XCTAssertTrue(subscriptions[0].isSubscription)
        XCTAssertTrue(subscriptions[0].selected)
        XCTAssertFalse(subscriptions[0].selectable,
                       "without the account status the saved choice stays read-only")
    }

    func testOpencodeGoIsCloudOnly() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("destination.snapshot")) as? [String: Any])
        var choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        choices[1] = ["destination": "mac:mini-b", "source": "opencode_go",
                      "model": "glm-5.2", "effort": "high"]
        object["choices"] = choices
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testAPickMovesTheCheckBeforeTheNextRead() throws {
        let offer = try cloudSnapshot()
        // The offer's saved choice is Nhật Thực; the 1.3 cloud default is
        // Nguyệt Thực. Before a pick, the 1.3 read is the authority.
        let destination = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot"))
        let before = PhoneModelPickerProjection.conversation(
            offer: offer, destination: destination,
            destinationID: try ManagedModelDestinationID("cloud"))
        XCTAssertEqual(before.filter(\.selected).map(\.model), [ManagedModelLineup.defaultAlias])

        // A successful 1.1 write moves the check at once; the old 1.3 read is
        // not allowed to pull it back until the next read returns.
        let after = PhoneModelPickerProjection.conversation(
            offer: offer, destination: destination,
            destinationID: try ManagedModelDestinationID("cloud"),
            selectedAtumModel: ManagedModelLineup.hardAlias)
        XCTAssertEqual(after.filter(\.selected).map(\.model), [ManagedModelLineup.hardAlias])
    }

    func testTheAnnouncedRowIsAlreadyInThe13Projection() throws {
        let mac = PhoneModelPickerProjection.mac(
            try NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: fixture("destination.snapshot")),
            destination: try ManagedModelDestinationID("mac:mini-b"))
        XCTAssertEqual(mac.last?.model, ManagedModelLineup.announcedAlias)
        XCTAssertEqual(mac.last?.displayName, "Thái Cực")
        XCTAssertEqual(mac.last?.tagline, .flagship)
        XCTAssertEqual(mac.last?.announced, true)
        XCTAssertEqual(mac.last?.selectable, false)
    }
}
