import XCTest
import Foundation
import AtumNativeAPI
import AtumPrototype

final class NativeAPITests: XCTestCase {
    private func fixtures() throws -> NativeAPIFixtures { try NativeAPIFixtures() }
    private func edited(_ file: String, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures().data(file)) as? [String: Any])
        edit(&json)
        return try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    }
    private func decodeMessage(_ name: String, _ data: Data) throws {
        switch name {
        case "agents.response": _ = try NativeAPI.decode(AgentsResponse.self, from: data)
        case "wallet.response": _ = try NativeAPI.decode(WalletResponse.self, from: data)
        case "wallet.history.response": _ = try NativeAPI.decode(WalletHistoryResponse.self, from: data)
        case "alias.lookup.response": _ = try NativeAPI.decode(AliasLookupResponse.self, from: data)
        case "alias.current.response": _ = try NativeAPI.decode(AliasCurrentResponse.self, from: data)
        case "alias.check.response": _ = try NativeAPI.decode(AliasCheckResponse.self, from: data)
        case "alias.claim.request": _ = try NativeAPI.decode(AliasClaimRequest.self, from: data)
        case "alias.claim.response": _ = try NativeAPI.decode(AliasClaimResponse.self, from: data)
        case "error.response": _ = try NativeAPI.decode(NativeErrorResponse.self, from: data)
        default: XCTFail("Unimplemented provider resource message: \(name)")
        }
    }

    func testEverySelectedProviderAcceptRejectFixture() throws {
        let source = try fixtures()
        for fixture in source.manifest.fixtures {
            let data = try source.data(fixture.file)
            if fixture.expect == "accept" {
                XCTAssertNoThrow(try decodeMessage(fixture.message, data), fixture.file)
            } else {
                XCTAssertEqual(fixture.expect, "reject")
                XCTAssertThrowsError(try decodeMessage(fixture.message, data), fixture.file)
            }
        }
        XCTAssertThrowsError(try source.data("../../contract.json"))
    }

    func testWalletSumBoundsNullabilityAndExactFormatting() throws {
        let source = try fixtures()
        let wallet = try source.decode(WalletResponse.self, "wallet.response.json")
        XCTAssertEqual(wallet.balances.available, wallet.balances.paid + wallet.balances.earned + wallet.balances.promo)
        XCTAssertTrue(wallet.checkoutOpen) // Metadata alone; still no purchase path.
        XCTAssertEqual(MicroProtonFormat.string(wallet.balances.available, locale: "en"), "25")
        XCTAssertEqual(MicroProtonFormat.string(1, locale: "en"), "0.000001")
        XCTAssertEqual(MicroProtonFormat.string(NativeAPI.maximumInteger, locale: "en"), "9,007,199,254.740991")
        XCTAssertEqual(MicroProtonFormat.string(-1_250_001, locale: "en"), "-1.250001")
        XCTAssertEqual(MicroProtonFormat.string(5_000_000, locale: "vi", showPositiveSign: true), "+5")
        XCTAssertNotNil(wallet.allowance?.grantedAt?.date)
        XCTAssertNil(try source.decode(WalletResponse.self, "wallet-no-allowance.response.json").allowance)
        for bad in [-1, NativeAPI.maximumInteger + 1] {
            let data = try edited("wallet.response.json") { object in
                var balances = object["balances"] as! [String: Any]; balances["held"] = bad; object["balances"] = balances
            }
            XCTAssertThrowsError(try NativeAPI.decode(WalletResponse.self, from: data))
        }
        let missing = try edited("wallet.response.json") { $0.removeValue(forKey: "allowance") }
        XCTAssertThrowsError(try NativeAPI.decode(WalletResponse.self, from: missing))
        let mistyped = try edited("wallet.response.json") { $0["checkoutOpen"] = 1 }
        XCTAssertThrowsError(try NativeAPI.decode(WalletResponse.self, from: mistyped))
        for token in ["25000000.0", "25e6", "true"] {
            let body = String(decoding: try source.data("wallet.response.json"), as: UTF8.self)
                .replacingOccurrences(of: "25000000", with: token)
            XCTAssertThrowsError(try NativeAPI.decode(WalletResponse.self, from: Data(body.utf8)))
        }
        let held = try edited("wallet.response.json") { object in
            var balances = object["balances"] as! [String: Any]; balances["held"] = 1_000_000; object["balances"] = balances
        }
        // Held is separate from the already-spendable sum; never subtract twice.
        XCTAssertEqual(try NativeAPI.decode(WalletResponse.self, from: held).balances.available, wallet.balances.available)
    }

    func testHistoryPreservesSignedAmountsCursorAndRequiredNulls() throws {
        let page = try fixtures().decode(WalletHistoryResponse.self, "wallet-history.response.json")
        XCTAssertLessThan(try XCTUnwrap(page.entries.first).amount, 0)
        XCTAssertNotNil(page.next)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures().data("wallet-history.response.json")) as? [String: Any])
        XCTAssertEqual(page.next, original["next"] as? String)
        XCTAssertNil(try fixtures().decode(WalletHistoryResponse.self, "wallet-history-last-page.response.json").next)
        let missing = try edited("wallet-history.response.json") { $0.removeValue(forKey: "next") }
        XCTAssertThrowsError(try NativeAPI.decode(WalletHistoryResponse.self, from: missing))
        for change in ["tooMany", "badCursor", "missingReference", "longReference", "uppercaseID", "unknownField"] {
            let data = try edited("wallet-history.response.json") { object in
                var entries = object["entries"] as! [[String: Any]]
                switch change {
                case "tooMany": entries = Array(repeating: entries[0], count: 101)
                case "badCursor": object["next"] = "cursor+not_urlsafe"
                case "missingReference": entries[0].removeValue(forKey: "reference")
                case "longReference": entries[0]["reference"] = String(repeating: "e\u{301}", count: 101)
                case "uppercaseID": entries[0]["id"] = (entries[0]["id"] as! String).uppercased()
                default: entries[0]["balance"] = 0
                }
                object["entries"] = entries
            }
            XCTAssertThrowsError(try NativeAPI.decode(WalletHistoryResponse.self, from: data), change)
        }
    }

    func testAgentOpenObjectsRejectCredentialsButDegradePresentationAndRowsIndependently() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures().data("agents.response.json")) as? [[String: Any]])
        json[0]["futureDisplay"] = ["revision": 1, "label": "synthetic"]
        json[0]["title"] = "Research partner"
        json[0]["mark_shape"] = "heart"
        json[0]["mark_color"] = "coral"
        var body = try JSONSerialization.data(withJSONObject: json)
        let presented = try NativeAPI.decode(AgentsResponse.self, from: body)
        XCTAssertEqual(presented.agents[0].title, "Research partner")
        XCTAssertEqual(presented.agents[0].mark, AgentMark(shape: .heart, color: .coral))
        json[0]["futureDisplay"] = ["nested": [["refreshToken": "synthetic-forbidden-field"]]]
        body = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try NativeAPI.decode(AgentsResponse.self, from: body))
        json[0].removeValue(forKey: "futureDisplay")
        json[0].removeValue(forKey: "mark_color")
        let missingMark = try NativeAPI.decode(
            AgentsResponse.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(missingMark.agents[0].mark)
        json[0]["mark_color"] = "coral"
        json[0]["matrixUser"] = NSNull()
        let noMatrix = try NativeAPI.decode(AgentsResponse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(noMatrix.agents[0].canOpenChat)
        json[0]["status"] = "retired"
        json[0]["matrixUser"] = "@demo:atum.test"
        XCTAssertFalse(try NativeAPI.decode(AgentsResponse.self, from: JSONSerialization.data(withJSONObject: json)).agents[0].canOpenChat)
        json[0].removeValue(forKey: "identity_id")
        let missingIdentity = try NativeAPI.decode(
            AgentsResponse.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(missingIdentity.agents.map(\.displayName), ["Lịch"],
                       "one structurally invalid item is discarded without erasing known agents")
        json[0]["identity_id"] = NSNull()
        XCTAssertThrowsError(try NativeAPI.decode(AgentsResponse.self, from: JSONSerialization.data(withJSONObject: Array(repeating: json[0], count: 52))))
    }

    func testAliasAvailabilityDoesNotCreateIdentityOrMessageTarget() throws {
        let available = try fixtures().decode(AliasLookupResponse.self, "alias-lookup-available.response.json")
        XCTAssertNil(available.humanMessageTarget)
        let assigned = try fixtures().decode(AliasLookupResponse.self, "alias-lookup-assigned.response.json")
        XCTAssertNotNil(assigned.humanMessageTarget)
        let noMatrix = try edited("alias-lookup-assigned.response.json") { $0["matrixUser"] = NSNull() }
        XCTAssertNil(try NativeAPI.decode(AliasLookupResponse.self, from: noMatrix).humanMessageTarget)
        for kind in ["agent", "app", "organization"] {
            let data = try edited("alias-lookup-assigned.response.json") { $0["kind"] = kind }
            XCTAssertNil(try NativeAPI.decode(AliasLookupResponse.self, from: data).humanMessageTarget)
        }
        XCTAssertEqual(try fixtures().decode(AliasCurrentResponse.self, "alias-current-none.response.json"), .none)
        XCTAssertThrowsError(try NativeAPI.decode(AliasCurrentResponse.self, from: Data("{}".utf8)))
        let invalidHandle = try edited("alias-current.response.json") { $0["handle"] = "@invalid" }
        XCTAssertThrowsError(try NativeAPI.decode(AliasCurrentResponse.self, from: invalidHandle))
    }

    func testAliasClaimRequestEncodesOnlyStableOwnerInputAndOptionalIsNotNullable() throws {
        let request = try fixtures().decode(AliasClaimRequest.self, "alias-claim.request.json")
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try NativeAPI.decode(AliasClaimRequest.self, from: encoded), request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["handle", "requestId", "assistantId"]))
        XCTAssertNil(object["principal"])
        let noAssistant = try AliasClaimRequest(handle: "@demo", requestId: request.requestId)
        let without = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(noAssistant)) as? [String: Any])
        XCTAssertNil(without["assistantId"])
        let nullAssistant = try edited("alias-claim.request.json") { $0["assistantId"] = NSNull() }
        XCTAssertThrowsError(try NativeAPI.decode(AliasClaimRequest.self, from: nullAssistant))
        let falseReplay = try edited("alias-claim-replayed.response.json") { $0["replayed"] = false }
        XCTAssertThrowsError(try NativeAPI.decode(AliasClaimResponse.self, from: falseReplay))
    }

    func testHTTPErrorStatusAndRetryAfterAreNeverGuessed() throws {
        let unauthorized = try fixtures().data("error-unauthenticated.response.json")
        XCTAssertEqual(try NativeHTTPFailure(status: 401, headers: [:], body: unauthorized).response.error, .unauthenticated)
        XCTAssertThrowsError(try NativeHTTPFailure(status: 403, headers: [:], body: unauthorized))
        let body = Data("{\"error\":\"matrix_429\"}".utf8)
        XCTAssertEqual(try NativeHTTPFailure(status: 429, headers: ["Retry-After": "120"], body: body).retryAfterSeconds, 120)
        for raw in ["", "-1", "1.5", "tomorrow", "99999999999999999999999"] {
            XCTAssertThrowsError(try NativeHTTPFailure(status: 429, headers: ["retry-after": raw], body: body))
        }
        XCTAssertThrowsError(try NativeHTTPFailure(status: 429, headers: [:], body: body))
        XCTAssertThrowsError(try NativeHTTPFailure(status: 429, headers: ["Retry-After": "1", "retry-after": "2"], body: body))
        XCTAssertTrue(try NativeHTTPFailure(status: 503, headers: [:], body: Data("{\"error\":\"matrix_503\"}".utf8)).cloudUnavailable)
        XCTAssertTrue(try NativeHTTPFailure(status: 503, headers: [:], body: fixtures().data("error-cloud-unavailable.response.json")).cloudUnavailable)
        XCTAssertThrowsError(try NativeAPI.decode(NativeErrorResponse.self, from: Data("{\"error\":\"matrix_503\",\"details\":null}".utf8)))
    }

    func testFailedReadsPreserveLastGoodValueAndSuccessfulNullIsDistinct() throws {
        var wallet = NativeRead<WalletResponse>()
        wallet.fail(.offline)
        XCTAssertNil(wallet.value)
        let value = try fixtures().decode(WalletResponse.self, "wallet.response.json")
        wallet.receive(value)
        for condition in [NativeRead<WalletResponse>.Condition.offline, .failed, .unavailable] {
            wallet.fail(condition)
            XCTAssertEqual(wallet.value, value)
            XCTAssertTrue(wallet.isStale)
        }
        wallet.receive(value); XCTAssertFalse(wallet.isStale)
        wallet.clear(); XCTAssertNil(wallet.value)
        var alias = NativeRead<AliasCurrentResponse>()
        alias.fail(.failed); XCTAssertNil(alias.value)
        alias.receive(.none); XCTAssertEqual(alias.value, AliasCurrentResponse.none)
    }

    func testNativeFixtureProjectionRetainsContractSemantics() throws {
        let account = try NativeFixtureAccount()
        XCTAssertNil(try account.walletRead(state: "loading").value)
        for state in ["normal", "offline", "error", "unavailable"] {
            let read = try account.walletRead(state: state)
            XCTAssertEqual(read.value, account.wallet)
            XCTAssertEqual(read.isStale, state != "normal")
        }
        XCTAssertEqual(try account.walletRead(state: "out-of-protons").value?.balances.available, 0)
        XCTAssertEqual(try account.walletRead(state: "low-protons").value?.balances.available, 8_000_000)
        let last = try account.historyPage(after: XCTUnwrap(account.history.next))
        XCTAssertNil(last.next)
        XCTAssertThrowsError(try account.historyPage(after: "invented_cursor"))
        if case .assigned(let handle, _) = account.currentAlias { XCTAssertEqual(account.handle, "@" + handle.rawValue) }
        else { XCTFail("Assigned alias fixture must preserve its handle") }
    }
}
