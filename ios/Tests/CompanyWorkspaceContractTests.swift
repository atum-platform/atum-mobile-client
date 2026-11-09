import Foundation
import XCTest
@testable import AtumNativeAPI

/// Replays the platform's `atum.company-workspace/1.1` fixture pack against
/// the phone's strict decoders. Every `accept` fixture decodes; every 1.1
/// `reject` fixture is refused; v1 answers are reported as `.v1` rather than
/// widened, which is what hides the feature on an older server.
final class CompanyWorkspaceContractTests: XCTestCase {
    private struct Fixture: Decodable {
        let file: String
        let message: String?
        let expect: String
        let violation: String?
    }

    private struct Contract: Decodable {
        let fixtures: [Fixture]
    }

    private enum Outcome {
        case v1
        case decoded
    }

    private func fixtureDirectory() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.1", withExtension: nil))
    }

    private func contract() throws -> Contract {
        let url = try fixtureDirectory().appendingPathComponent("contract.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    private func data(_ file: String) throws -> Data {
        let name = (file as NSString).lastPathComponent
        let url = try fixtureDirectory().appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func decode(_ message: String, _ data: Data) throws -> Outcome {
        switch message {
        case "list.response":
            return try CompanyWorkspaceWire.decodeList(data) == .v1 ? .v1 : .decoded
        case "snapshot.response":
            return try CompanyWorkspaceWire.decodeSnapshot(data) == .v1 ? .v1 : .decoded
        case "channel-directory.response":
            return try CompanyWorkspaceWire.decodeChannelDirectory(data) == .v1 ? .v1 : .decoded
        case "channel.snapshot":
            return try CompanyWorkspaceWire.decodeChannelSnapshot(data) == .v1 ? .v1 : .decoded
        case "leave.response":
            _ = try CompanyWorkspaceWire.decodeLeave(data)
            return .decoded
        default:
            throw XCTSkip("the phone does not consume \(message)")
        }
    }

    func testEveryOneOneAcceptFixtureDecodesAndEveryRejectIsRefused() throws {
        let messages = ["list.response", "snapshot.response", "channel-directory.response",
                        "channel.snapshot", "leave.response"]
        var checked = 0
        for item in try contract().fixtures {
            guard let message = item.message, messages.contains(message) else { continue }
            let body = try data(item.file)
            checked += 1
            switch item.expect {
            case "accept":
                XCTAssertEqual(try decode(message, body), .decoded, item.file)
            case "reject" where item.file.contains("v1-shape"):
                // The pack refuses these against the 1.1 shape because the
                // answer states v1. For the phone that is the degrade signal:
                // it must never widen a v1 body into the 1.1 models.
                XCTAssertEqual(try decode(message, body), .v1, item.file)
            case "reject":
                XCTAssertThrowsError(try decode(message, body), item.file) { error in
                    XCTAssertFalse(error is CompanyWireRefusal, "\(item.file) must refuse, not degrade")
                }
            default:
                XCTFail("unknown expectation in \(item.file)")
            }
        }
        XCTAssertGreaterThan(checked, 25)
    }

    func testV1AnswersDegradeInsteadOfWidening() throws {
        XCTAssertEqual(try CompanyWorkspaceWire.decodeList(
            try data("fixtures/v1.list.response.json")), .v1)
        XCTAssertEqual(try CompanyWorkspaceWire.decodeSnapshot(
            try data("fixtures/v1.snapshot.response.json")), .v1)
        XCTAssertEqual(try CompanyWorkspaceWire.probe(
            try data("fixtures/v1.list.response.json")), .v1)
        XCTAssertEqual(try CompanyWorkspaceWire.probe(
            try data("fixtures/list.response.json")), .v1_1)
    }

    func testSpecificRefusals() throws {
        // A principal anywhere is forbidden on the 1.1 wire.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeList(
            try data("fixtures/list-inviter-principal.response.json")))
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeSnapshot(
            try data("fixtures/snapshot-principal.response.json")))
        // An HTTP avatar or an email is not a member field.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeSnapshot(
            try data("fixtures/snapshot-avatar-url.response.json")))
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeSnapshot(
            try data("fixtures/snapshot-email.response.json")))
        // A member ref is exactly 32 base64url bytes.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeSnapshot(
            try data("fixtures/snapshot-bad-ref.response.json")))
        // Only the seeded default system key is defined.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeChannelSnapshot(
            try data("fixtures/channel-system-key.snapshot.json")))
        // `state` has only revoking/removed.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeLeave(
            try data("fixtures/leave-active.response.json")))
        // `retired` is required.
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeLeave(
            try data("fixtures/leave-no-retired.response.json")))
    }

    func testUnknownSchemaVersionIsRefused() {
        let body = Data(#"{"schemaVersion":3,"companies":[],"invitations":[],"canCreate":false}"#.utf8)
        XCTAssertThrowsError(try CompanyWorkspaceWire.decodeList(body))
        XCTAssertThrowsError(try CompanyWorkspaceWire.probe(body))
    }

    func testRequestShapesAreExact() throws {
        let request = CompanyAcceptRequest(
            requestId: try NativeID("00000000-0000-4000-8000-175097128f22"),
            invitationId: try NativeID("00000000-0000-4000-8000-55301f2eb1d3"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        XCTAssertEqual(object, ["requestId": "00000000-0000-4000-8000-175097128f22",
                                "invitationId": "00000000-0000-4000-8000-55301f2eb1d3"])
        let leave = CompanyLeaveRequest(
            requestId: try NativeID("00000000-0000-4000-8000-175097128f22"))
        let leaveObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(leave)) as? [String: String]
        XCTAssertEqual(leaveObject, ["requestId": "00000000-0000-4000-8000-175097128f22"])
        XCTAssertThrowsError(try NativeID("not-a-company"))
    }

    func testLeaveAcknowledgementStates() throws {
        let revoking = try CompanyWorkspaceWire.decodeLeave(
            try data("fixtures/leave.response.json"))
        XCTAssertFalse(revoking.isFinished)
        let removed = try CompanyWorkspaceWire.decodeLeave(
            try data("fixtures/leave-removed.response.json"))
        XCTAssertTrue(removed.isFinished)
        let retired = try CompanyWorkspaceWire.decodeLeave(
            try data("fixtures/leave-retired.response.json"))
        XCTAssertTrue(retired.isFinished)
    }
}
