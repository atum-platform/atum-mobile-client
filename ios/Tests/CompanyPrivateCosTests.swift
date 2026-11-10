import Foundation
import XCTest
@testable import AtumNativeAPI

final class CompanyPrivateCosTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "company-private-cos", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    func testGeneratedReadFixturesDecode() throws {
        for file in ["v1-lazy-first-open.uncreated.response.json",
                     "v1-lazy-first-open.preparing.response.json",
                     "v1.1-ensure-accepted.response.json"] {
            let view = try NativeAPI.decode(CompanyPrivateCosView.self, from: fixture(file))
            if let binding = view.binding {
                XCTAssertEqual(binding.scope.pair, view.pair)
                XCTAssertEqual(binding.roomId, "!private-cos-a:atum.example")
                XCTAssertEqual(binding.agentUserId, "@private_cos_a:atum.example")
            }
        }
        XCTAssertThrowsError(try NativeAPI.decode(CompanyPrivateCosView.self, from:
            fixture("v1.1-ensure-unversioned.response.json")))
        for file in ["v1.3-capability.response.json", "v2-capability.json"] {
            _ = try NativeAPI.decode(CompanyPrivateCosCapability.self, from: fixture(file))
        }
    }

    func testOffOrUnrecognizedCapabilityDoesNotEnableClassification() throws {
        XCTAssertThrowsError(try NativeAPI.decode(CompanyPrivateCosCapability.self,
            from: Data("{\"enabled\":false}".utf8)))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with:
            fixture("v2-capability.json")) as? [String: Any])
        value["profile"] = "atum.company-private-cos/unknown"
        XCTAssertThrowsError(try NativeAPI.decode(CompanyPrivateCosCapability.self,
            from: JSONSerialization.data(withJSONObject: value)))
    }

    private func bound(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> CompanyPrivateCosView {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with:
            fixture("v1-lazy-first-open.preparing.response.json")) as? [String: Any])
        edit(&value)
        return try NativeAPI.decode(CompanyPrivateCosView.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testReadyBindingAndPairMismatch() throws {
        let ready = try bound { $0["state"] = "ready"; $0["greetingState"] = "published" }
        XCTAssertNotNil(ready.binding)
        XCTAssertThrowsError(try bound {
            var pair = $0["pair"] as! [String: Any]
            pair["membershipIncarnation"] = "a3000000-0000-4000-8000-000000000002"
            $0["pair"] = pair
        })
        XCTAssertThrowsError(try bound { $0["state"] = "personal" })
        XCTAssertThrowsError(try bound { $0["unexpected"] = true })
    }

    func testPositiveBindingsAreAccountCompanyAndIncarnationScoped() throws {
        var store = CompanyPrivateCosBindings()
        let view = try bound()
        let company = view.pair.companyPrincipal.rawValue
        store.beginAccount("account-a")
        store.apply(view, companyID: company, accountID: "account-b")
        XCTAssertTrue(store.roomIDs.isEmpty)
        store.apply(view, companyID: "a1000000-0000-4000-8000-000000000002", accountID: "account-a")
        XCTAssertTrue(store.roomIDs.isEmpty)
        store.apply(view, companyID: company, accountID: "account-a")
        XCTAssertEqual(store.companyID(owning: view.binding!.roomId), company)
        XCTAssertEqual(store.agentUserIDs, [view.binding!.agentUserId])
        // An empty same-incarnation GET does not reclassify a known room personal.
        let empty = try bound { $0.removeValue(forKey: "binding"); $0["state"] = "uncreated" }
        store.apply(empty, companyID: company, accountID: "account-a")
        XCTAssertFalse(store.roomIDs.isEmpty)
        let rejoined = try bound {
            $0.removeValue(forKey: "binding"); $0["state"] = "uncreated"
            var pair = $0["pair"] as! [String: Any]
            pair["membershipIncarnation"] = "a3000000-0000-4000-8000-000000000002"
            $0["pair"] = pair
        }
        store.apply(rejoined, companyID: company, accountID: "account-a")
        XCTAssertTrue(store.roomIDs.isEmpty)
        let replacement = try bound {
            var pair = $0["pair"] as! [String: Any]
            pair["membershipIncarnation"] = "a3000000-0000-4000-8000-000000000002"
            $0["pair"] = pair
            var binding = $0["binding"] as! [String: Any]
            var scope = binding["scope"] as! [String: Any]
            scope["pair"] = pair; binding["scope"] = scope
            binding["roomId"] = "!private-cos-new:atum.example"
            binding["agentUserId"] = "@private_cos_new:atum.example"
            $0["binding"] = binding
        }
        store.apply(replacement, companyID: company, accountID: "account-a")
        XCTAssertEqual(store.roomIDs, ["!private-cos-new:atum.example"])
        XCTAssertFalse(store.agentUserIDs.contains(view.binding!.agentUserId))
        store.retain(companies: [])
        XCTAssertTrue(store.views.isEmpty)
        store.apply(view, companyID: company, accountID: "account-a")
        store.beginAccount("account-b")
        XCTAssertTrue(store.views.isEmpty)
        store.apply(view, companyID: company, accountID: "account-a")
        XCTAssertTrue(store.views.isEmpty)
    }
}
