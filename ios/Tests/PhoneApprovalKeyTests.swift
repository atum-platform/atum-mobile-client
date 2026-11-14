import XCTest
import CryptoKit
@testable import AtumNativeAPI

final class PhoneApprovalKeyTests: XCTestCase {
    func testFrozenPublicProofs() throws {
        for n in 1...2 {
            let url = Bundle.module.url(forResource: "ios-\(n)", withExtension: "json", subdirectory: "phone-enrollment")!
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var fields = object["body"] as! [String: Any]
            for role in ["identity", "approval"] {
                let hex = Array((object[role + "PublicDERHex"] as! String).utf8)
                let raw = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(bytes: hex[$0...($0 + 1)], encoding: .utf8)!, radix: 16)! })
                fields[role + "Key"] = raw.phoneBase64URL
                let expectedName = role == "identity" ? "expectedIdentityId" : "expectedApprovalId"
                XCTAssertEqual(PhoneEnrollment.keyID(spki: raw), object[expectedName] as? String)
            }
            let body = try JSONSerialization.data(withJSONObject: fields)
            let bytes = try PhoneEnrollment.canonicalBytes(body: body)
            let signatures = object["sigs"] as! [String: String]
            for role in ["identity", "approval"] {
                let publicBytes = try PhoneEnrollment.decodeBase64URL(fields[role + "Key"] as! String)
                let verifier = try P256.Signing.PublicKey(derRepresentation: publicBytes)
                let proof = try P256.Signing.ECDSASignature(rawRepresentation: PhoneEnrollment.decodeBase64URL(signatures[role]!))
                XCTAssertTrue(verifier.isValidSignature(proof, for: bytes))
            }
        }
    }
}

private final class SoftwarePhoneKeys: PhoneApprovalKeyStore {
    var keys: [String: P256.Signing.PrivateKey] = [:]
    var signed: [PhoneKeyRole] = []
    func create(_ role: PhoneKeyRole) throws { keys[role.rawValue] = P256.Signing.PrivateKey() }
    func publicKey(_ role: PhoneKeyRole) throws -> Data {
        guard let key = keys[role.rawValue] else { throw PhoneApprovalFailure.setupRequired }
        return key.publicKey.derRepresentation
    }
    func sign(_ bytes: Data, role: PhoneKeyRole, reason: String) throws -> Data {
        guard let key = keys[role.rawValue] else { throw PhoneApprovalFailure.setupRequired }
        signed.append(role)
        return try key.signature(for: bytes).rawRepresentation
    }
    func remove(_ role: PhoneKeyRole) throws { keys.removeValue(forKey: role.rawValue) }
}

extension PhoneApprovalKeyTests {
    private func body(_ keys: SoftwarePhoneKeys, epoch: Int = 1, previous: SoftwarePhoneKeys? = nil) throws -> Data {
        var value: [String: Any] = ["deviceServiceId": UUID().uuidString.lowercased(), "displayName": "Phone / 😀", "platform": "ios", "osVersion": "26.1", "identityKey": try keys.publicKey(.identity).phoneBase64URL, "approvalKey": try keys.publicKey(.approval).phoneBase64URL, "matrix": ["userId": "@owner:example.com", "deviceId": "PHONE", "fingerprint": String(repeating: "a", count: 43)], "enrollmentEpoch": epoch, "scopes": [], "controllerKeys": [String(repeating: "b", count: 43)], "issuedAt": 1]
        if let previous { value["previousApprovalKid"] = PhoneEnrollment.keyID(spki: try previous.publicKey(.approval)) }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testFakeEnrollmentAndRotation() throws {
        let old = SoftwarePhoneKeys(), new = SoftwarePhoneKeys()
        for keys in [old, new] { try keys.create(.identity); try keys.create(.approval) }
        _ = try PhoneEnrollment.request(body: body(old), keys: old, reason: "Set up")
        XCTAssertEqual(old.signed.count, 2)
        let rotating = try body(new, epoch: 2, previous: old)
        let request = try PhoneEnrollment.request(body: rotating, keys: new, rotatingFrom: old, reason: "Rotate")
        let envelope = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let signatures = envelope["sigs"] as! [String: String]
        let proof = try P256.Signing.ECDSASignature(rawRepresentation: PhoneEnrollment.decodeBase64URL(signatures["previousApproval"]!))
        XCTAssertTrue(try P256.Signing.PublicKey(derRepresentation: old.publicKey(.approval)).isValidSignature(proof, for: PhoneEnrollment.canonicalBytes(body: rotating)))
        XCTAssertThrowsError(try PhoneEnrollment.request(body: rotating, keys: new, reason: "Missing previous"))
        try new.remove(.approval)
        XCTAssertThrowsError(try new.publicKey(.approval))
    }
    func testInvalidBodiesNeverSign() throws {
        let keys = SoftwarePhoneKeys(); try keys.create(.identity); try keys.create(.approval)
        let good = try body(keys)
        for (field, value) in [("platform", "macos" as Any), ("scopes", ["execute"]), ("issuedAt", true), ("extra", "field"), ("displayName", String(repeating: "😀", count: 33)), ("identityKey", "invalid")] {
            var object = try JSONSerialization.jsonObject(with: good) as! [String: Any]
            object[field] = value
            XCTAssertThrowsError(try PhoneEnrollment.request(body: JSONSerialization.data(withJSONObject: object), keys: keys, reason: "Bad"))
        }
        XCTAssertThrowsError(try PhoneEnrollment.canonicalBytes(body: Data("{\"platform\":\"ios\",\"platform\":\"ios\"}".utf8)))
        XCTAssertTrue(keys.signed.isEmpty)
    }
    func testNamespaceIsolation() {
        let installation = UUID(), generation = UUID()
        XCTAssertNotEqual(PhoneKeyNamespace(owner: "one", installation: installation, generation: generation).value, PhoneKeyNamespace(owner: "two", installation: installation, generation: generation).value)
        XCTAssertNotEqual(PhoneKeyNamespace(owner: "one", installation: installation, generation: generation).value, PhoneKeyNamespace(owner: "one", installation: installation, generation: UUID()).value)
    }
    func testOfflineSignOutPersistsAndRetriesForSameOwner() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = try PhoneRevocationQueue(file: file), keys = SoftwarePhoneKeys(), id = UUID()
        try keys.create(.identity); try keys.create(.approval)
        do { try await queue.signOut(owner: "one", id: id, keys: keys) { _ in throw URLError(.notConnectedToInternet) }; XCTFail() } catch {}
        XCTAssertThrowsError(try keys.publicKey(.approval))
        let restored = try PhoneRevocationQueue(file: file)
        let pending = await restored.pending(owner: "one")
        XCTAssertEqual(pending.count, 1)
        try await restored.retry(owner: "two") { _ in XCTFail("Wrong owner retry") }
        try await restored.retry(owner: "one") { XCTAssertEqual($0, id) }
        let final = try PhoneRevocationQueue(file: file)
        let remaining = await final.pending(owner: "one")
        XCTAssertTrue(remaining.isEmpty)
    }
}

extension PhoneApprovalKeyTests {
    func testBodyBuilderBindsKeysAndRejectsBadMetadata() throws {
        let keys = SoftwarePhoneKeys(); try keys.create(.identity); try keys.create(.approval)
        let body = try PhoneEnrollment.body(id: UUID(), displayName: "Phone", osVersion: "26.1", matrixUserID: "@owner:example.com", matrixDeviceID: "PHONE", matrixFingerprint: String(repeating: "a", count: 43), controllerKeyIDs: [String(repeating: "b", count: 43)], issuedAt: 1, keys: keys)
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(object["identityKey"] as? String, try keys.publicKey(.identity).phoneBase64URL)
        XCTAssertEqual(object["approvalKey"] as? String, try keys.publicKey(.approval).phoneBase64URL)
        for field in ["identityKey", "approvalKey", "matrix", "controllerKeys", "issuedAt", "enrollmentEpoch"] {
            var bad = object; bad.removeValue(forKey: field)
            XCTAssertThrowsError(try PhoneEnrollment.canonicalBytes(body: JSONSerialization.data(withJSONObject: bad)))
        }
        let other = SoftwarePhoneKeys(); try other.create(.identity); try other.create(.approval)
        XCTAssertThrowsError(try PhoneEnrollment.request(body: body, keys: other, reason: "Wrong keys"))
        XCTAssertTrue(other.signed.isEmpty)
    }
    func testCorruptQueueDoesNotSilentlyLoseRevocations() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try PhoneRevocationQueue(file: file))
    }
    func testTypedRecordsAndList() throws {
        let record = Data("""
        {"deviceServiceId":"00000000-0000-4000-8000-000000000001","displayName":"Phone","platform":"ios","identityKeyId":"a","approvalKeyId":"b","matrix":{"deviceId":"PHONE","fingerprint":"f"},"enrollmentEpoch":1,"scopes":[],"pinnedControllerKeys":[],"state":"active","revokeSeq":0,"createdAt":1,"rotatedAt":null,"revokedAt":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(PhoneRegistryRecord.self, from: record)
        XCTAssertEqual(decoded.platform, .ios)
        XCTAssertNil(decoded.revokedAt)
        XCTAssertEqual(try JSONDecoder().decode(PhoneRegistryRecord.self, from: JSONEncoder().encode(decoded)), decoded)
        let list = Data("{\"deviceServices\":".utf8) + Data("[".utf8) + record + Data("]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(PhoneRegistryList.self, from: list).deviceServices, [decoded])
    }
}

extension PhoneApprovalKeyTests {
    func testRevocation404IsTerminalBut403RetainsPending() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let queue = try PhoneRevocationQueue(file: file), id = UUID()
        try await queue.enqueue(owner: "owner", id: id)
        let denied = try JSONDecoder().decode(PhoneRegistryError.self, from: Data("{\"error\":\"matrix_403\"}".utf8))
        do { try await queue.retry(owner: "owner") { _ in throw denied }; XCTFail() } catch {}
        let pending = await queue.pending(owner: "owner")
        XCTAssertEqual(pending.count, 1)
        let absent = try JSONDecoder().decode(PhoneRegistryError.self, from: Data("{\"error\":\"matrix_404\"}".utf8))
        try await queue.retry(owner: "owner") { _ in throw absent }
        let remaining = await queue.pending(owner: "owner")
        XCTAssertTrue(remaining.isEmpty)
    }
    func testPersistenceFailurePreventsCredentialDiscardHook() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data().write(to: parent)
        let queue = try PhoneRevocationQueue(file: parent.appendingPathComponent("queue"))
        let keys = SoftwarePhoneKeys(); try keys.create(.approval); try keys.create(.identity)
        do {
            try await queue.signOut(owner: "owner", id: UUID(), keys: keys) { _ in XCTFail("Must persist before network") }
            XCTFail("Persistence must fail")
        } catch {}
        XCTAssertNoThrow(try keys.publicKey(.approval))
        XCTAssertNoThrow(try keys.publicKey(.identity))
    }
}
