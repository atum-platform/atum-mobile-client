import CryptoKit
import XCTest
@testable import AtumNativeAPI

final class ModelChoiceDestinationContractTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "model-choice-v1.3"
        ))
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testFrozenPlatformFixtureBytesAndStrictDestinationSnapshot() throws {
        let snapshotBytes = try fixture("destination.snapshot")
        let requestBytes = try fixture("destination-cloud-atum.request")
        // Freeze the intentionally sanitised public fixture bytes.
        XCTAssertEqual(sha256(snapshotBytes),
                       "364a39b4487a75728af0831a025576613c4e8b8d8a88662de7d8b215cd3338e0")
        XCTAssertEqual(sha256(requestBytes),
                       "0e372623aa1178ef78bacec84b7388a250232bed51dbb9ebb73538c09de09075")

        let snapshot = try NativeAPI.decode(ManagedModelDestinationSnapshot.self,
                                            from: snapshotBytes)
        XCTAssertEqual(snapshot.agentPrincipal.rawValue,
                       "00000000-0000-4000-8000-bd7662a5eeb4")
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.recommended.model, ManagedModelLineup.defaultAlias)
        XCTAssertEqual(snapshot.choices.map(\.destination.rawValue),
                       ["cloud", "mac:mini-b", "mac:mini-a", "mac:book-a"])
        XCTAssertEqual(snapshot.choices[2].source, .chatGPTPlan)
        XCTAssertEqual(snapshot.choices[3].source, .ownKey("openrouter"))
        XCTAssertEqual(snapshot.effectiveModel(for: try ManagedModelDestinationID("cloud")),
                       ManagedModelLineup.defaultAlias)
        // A Mac-local plan/key is not re-labelled as an Atum provider model.
        XCTAssertEqual(snapshot.effectiveModel(for: try ManagedModelDestinationID("mac:book-a")),
                       ManagedModelLineup.defaultAlias)
    }

    func testDestinationSnapshotRejectsDriftDuplicatesAndImpossibleSpend() throws {
        let bytes = try fixture("destination.snapshot")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        func data(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var value = original
            mutate(&value)
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }

        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: data { $0["future"] = true }
        ))
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: data { root in
                var choices = root["choices"] as! [[String: Any]]
                choices.append(choices[0])
                root["choices"] = choices
            }
        ))
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: data { root in
                var spend = root["spend"] as! [String: Any]
                spend["state"] = "exhausted"
                spend["notice"] = "exhausted"
                root["spend"] = spend
            }
        ))
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: data { root in
                var choices = root["choices"] as! [[String: Any]]
                choices[0]["source"] = "chatgpt_plan"
                root["choices"] = choices
            }
        ))
    }

    func test14IsAdditiveAndOnlyACloudDestinationMayNameOpencodeGo() throws {
        let bytes = try fixture("destination.snapshot")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["profile"] = "atum.model-choice/1.4"
        var choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        choices[0] = ["destination": "cloud", "source": "opencode_go",
                      "model": "glm-5.2", "effort": "high"]
        object["choices"] = choices
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(snapshot.choice(for: try ManagedModelDestinationID("cloud"))?.source,
                       .opencodeGo)
        XCTAssertNil(snapshot.choice(for: try ManagedModelDestinationID("cloud"))?.managedEffort,
                     "a subscription level is not an Atum effort")

        choices[1] = ["destination": "mac:mini-b", "source": "opencode_go",
                      "model": "glm-5.2", "effort": "high"]
        object["choices"] = choices
        XCTAssertThrowsError(try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        ), "1.4 keeps ChatGPT-plan and own-key Mac choices; OpenCode Go is account-wide and cloud-only")
    }

    func testDestinationWriteMatchesFrozenRequestShapeAndNeverCarriesSecrets() throws {
        let bytes = try fixture("destination.snapshot")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        raw["revision"] = 0
        let snapshot = try NativeAPI.decode(
            ManagedModelDestinationSnapshot.self,
            from: JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)
        )
        let write = try ManagedModelDestinationWrite(
            requestId: NativeID("00000000-0000-4000-8000-303617b97302"),
            snapshot: snapshot,
            destination: ManagedModelDestinationID("cloud"),
            model: ManagedModelLineup.defaultAlias
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(write)) as? NSDictionary)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("destination-cloud-atum.request")
        ) as? NSDictionary)
        XCTAssertEqual(actual, expected)
        XCTAssertNil(actual["token"])
        XCTAssertNil(actual["credential"])
    }
}
