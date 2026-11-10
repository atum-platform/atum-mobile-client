import AtumNativeAPI
import XCTest
@testable import AtumMobile

final class AssistantHomeDestinationTests: XCTestCase {
    func testOnlyCloudIsOfferedWithEligibleMacsForCloudAndExistingMacHomes() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotJSON.utf8)) as? [String: Any])
        for isMac in [false, true] {
            for reachability in ["reachable", "asleep", "offline"] {
                var placement = try XCTUnwrap(value["placement"] as? [String: Any])
                placement["location"] = isMac
                    ? ["kind": "mac", "deviceServiceId": "00000000-0000-4000-8000-b454f82c5857"]
                    : ["kind": "cloud"]
                value["placement"] = placement
                value["currentHomeReachability"] = ["state": reachability, "lastSeenAtPlatform": 1_800_000_000_000]
                let waitsForMac = isMac && reachability != "reachable"
                value["moveCapability"] = waitsForMac
                    ? ["state": "unavailable", "reason": "platform_not_ready"]
                    : ["state": "available", "profile": "atum.agent-home/2.4"]
                let snapshot = try NativeAPI.decode(AgentHomeSnapshot.self,
                    from: JSONSerialization.data(withJSONObject: value))
                XCTAssertEqual(snapshot.eligibleDevices.count, 2)
                XCTAssertEqual(snapshot.waitsForHomeMac, waitsForMac)
                XCTAssertEqual(snapshot.offeredHomeDestinations, [.cloud])
                XCTAssertTrue(snapshot.offeredHomeDestinations.allSatisfy { $0.deviceID == nil })
                if isMac {
                    XCTAssertNotEqual(snapshot.placement.location, snapshot.offeredHomeDestinations.first)
                }
            }
        }
    }

    // Frozen agent-home snapshot shape with synthetic principals/devices.
    private let snapshotJSON = """
    {
      "meta": {
        "requestId": "00000000-0000-4000-8000-f1d11edf5c5c",
        "commandId": "00000000-0000-4000-8000-fbfe405ca65f",
        "signer": "platform_controller",
        "signerKeyId": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "sequence": 12,
        "issuedAt": 1800000000000,
        "expiresAt": 1800000015000,
        "nonce": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        "signature": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      },
      "profile": "atum.agent-home/2.4",
      "ownerUserId": "@owner:atum.example",
      "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
      "placement": {
        "ownerUserId": "@owner:atum.example",
        "agentPrincipal": "00000000-0000-4000-8000-bd7662a5eeb4",
        "homeId": "00000000-0000-4000-8000-e8d95748107a",
        "location": {
          "kind": "cloud"
        },
        "homeEpoch": 4,
        "activeMove": null
      },
      "currentHomeReachability": {
        "state": "reachable",
        "lastSeenAtPlatform": 1800000000000
      },
      "eligibleDevices": [
        {
          "deviceServiceId": "00000000-0000-4000-8000-b454f82c5857",
          "displayName": "Mac mini",
          "eligibility": "ready"
        },
        {
          "deviceServiceId": "00000000-0000-4000-8000-0000000000bb",
          "displayName": "Other Mac",
          "eligibility": "ready"
        }
      ],
      "moveCapability": {
        "state": "available",
        "profile": "atum.agent-home/2.4"
      },
      "observedAtPlatform": 1800000000000
    }
    """
}
