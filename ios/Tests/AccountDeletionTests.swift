import XCTest
import Foundation
import AtumNativeAPI
import AtumPrototype

final class AccountDeletionTests: XCTestCase {
    private func edited(_ name: String, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: NativeDeletionFixtures().data(name)) as? [String: Any])
        edit(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testEveryProjectedProviderDisposition() throws {
        let fixtures = try NativeDeletionFixtures()
        for entry in fixtures.manifest.fixtures {
            let data = try fixtures.data(entry.file)
            let decode: () throws -> Void = {
                switch entry.message {
                case "deletion.status.response": _ = try AccountDeletion.status(data)
                case "deletion.request": _ = try AccountDeletion.request(data)
                case "deletion.accepted.response": _ = try AccountDeletion.accepted(data)
                case "deletion.progress.response": _ = try AccountDeletion.progress(data)
                case "deletion.error.response": _ = try AccountDeletion.failure(data)
                default: XCTFail("Unsupported selected deletion message")
                }
            }
            if entry.expect == "accept" { XCTAssertNoThrow(try decode(), entry.file) }
            else { XCTAssertEqual(entry.expect, "reject"); XCTAssertThrowsError(try decode(), entry.file) }
        }
        XCTAssertThrowsError(try fixtures.data("../../contract.json"))
    }
    func testDisclosureAndReplayReceiptValuesArePreservedWithoutAuthorityClaims() throws {
        let fixtures = try NativeDeletionFixtures()
        let status = try AccountDeletion.status(fixtures.data("status-none.response.json"))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures.data("status-none.response.json")) as? [String: Any])
        let disclosure = try XCTUnwrap(source["disclosure"] as? [String: Any])
        XCTAssertEqual(Set(status.disclosure.deleted.map(\.rawValue)), Set(disclosure["deleted"] as! [String]))
        XCTAssertEqual(status.disclosure.localOnMac, disclosure["localOnMac"] as? [String])
        XCTAssertEqual(status.disclosure.retained.count, (disclosure["retained"] as! [Any]).count)
        let accepted = try AccountDeletion.accepted(fixtures.data("accepted.response.json"))
        let replay = try AccountDeletion.accepted(edited("accepted.response.json") { $0["statusToken"] = String(repeating: "B", count: 43) })
        XCTAssertEqual(accepted.requestID, replay.requestID)
        XCTAssertEqual(accepted.completesBy, replay.completesBy)
        XCTAssertNotEqual(accepted.statusToken, replay.statusToken)
        // Decoding a replay does not replace secure custody or authorize a POST.
        let request = try AccountDeletion.request(fixtures.data("request-with-apple-code.json"))
        for printed in [String(describing: status), String(reflecting: status), String(reflecting: status.reauthNonce),
                        String(describing: accepted), String(reflecting: accepted.statusToken), String(reflecting: request)] {
            XCTAssertFalse(printed.contains(status.reauthNonce.wireValue))
            XCTAssertFalse(printed.contains(accepted.statusToken.wireValue))
            XCTAssertFalse(printed.contains(request.reauthIDToken.wireValue))
            XCTAssertFalse(printed.contains(try XCTUnwrap(request.appleAuthorizationCode).wireValue))
        }
    }
    func testCompletedProgressRequiresEverySystemDoneAndCannotBecomeDeactivation() throws {
        let complete = try AccountDeletion.progress(NativeDeletionFixtures().data("progress-completed.response.json"))
        XCTAssertEqual(Set(complete.steps.map(\.system)), Set(DeletionProgress.System.allCases))
        for invalid in ["deactivated", "requested", "none"] {
            XCTAssertThrowsError(try AccountDeletion.progress(edited("progress-completed.response.json") { $0["state"] = invalid }))
        }
        XCTAssertThrowsError(try AccountDeletion.progress(edited("progress-completed.response.json") {
            var steps = $0["steps"] as! [[String: Any]]; steps[0]["state"] = "blocked"; $0["steps"] = steps
        }))
        XCTAssertThrowsError(try AccountDeletion.progress(edited("progress-in-progress.response.json") {
            var steps = $0["steps"] as! [[String: Any]]; steps[1]["system"] = steps[0]["system"]; $0["steps"] = steps
        }))
        XCTAssertThrowsError(try AccountDeletion.progress(edited("progress-in-progress.response.json") {
            $0["steps"] = Array(($0["steps"] as! [[String: Any]]).dropLast())
        }))
        XCTAssertThrowsError(try AccountDeletion.progress(edited("progress-in-progress.response.json") { $0["extra"] = ["statusToken": "withheld"] }))
    }
    func testNonceAndStatusTokenWireBoundsAndMissingRefundCannotDisappear() throws {
        for bad: Any in ["", String(repeating: "A", count: 42), String(repeating: "A", count: 44), NSNull()] {
            XCTAssertThrowsError(try AccountDeletion.status(edited("status-none.response.json") { $0["reauthNonce"] = bad }))
            XCTAssertThrowsError(try AccountDeletion.accepted(edited("accepted.response.json") { $0["statusToken"] = bad }))
        }
        for bad: Any in [true, -1, 1.5, NativeAPI.maximumInteger + 1] {
            XCTAssertThrowsError(try AccountDeletion.status(edited("status-none.response.json") { $0["reauthNonceExpiresAt"] = bad }))
        }
        XCTAssertThrowsError(try AccountDeletion.status(edited("status-none.response.json") {
            var disclosure = $0["disclosure"] as! [String: Any]; var protons = disclosure["protons"] as! [String: Any]
            protons.removeValue(forKey: "refundEligible"); disclosure["protons"] = protons; $0["disclosure"] = disclosure
        }))
        for key in ["principal", "owner", "recoveryKey", "email"] {
            XCTAssertThrowsError(try AccountDeletion.request(edited("request.json") { $0[key] = "synthetic forbidden" }))
        }
        XCTAssertThrowsError(try AccountDeletion.request(edited("request.json") { $0["reauthIdToken"] = "unverified-opaque" }))
    }
}
