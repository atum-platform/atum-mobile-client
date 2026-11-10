import Foundation
import XCTest
@testable import AtumNativeAPI

final class ApplePurchaseContractTests: XCTestCase {
    @MainActor func testV12AllowlistedCatalogueAndPromoOnlyCredit() throws {
        let catalog = try NativeAPI.decode(AppleProductsResponse.self,
            from: ApplePurchaseV12TestData.data("allowlisted-products.response"))
        XCTAssertEqual(catalog.environment, .sandbox); XCTAssertTrue(catalog.checkoutOpen)
        XCTAssertEqual(Set(catalog.products.map(\.productId)), ApplePurchaseCoordinator.productIDs)
        XCTAssertEqual(catalog.products.map(\.paidMicroProtons), [95_000_000_000, 395_000_000_000])
        XCTAssertEqual(catalog.products.map(\.bonusMicroProtons), [5_000_000_000, 105_000_000_000])
        let credit = try NativeAPI.decode(AppleTransactionResponse.self,
            from: ApplePurchaseV12TestData.data("sandbox-credited.response"))
        XCTAssertEqual(credit.state, .credited); XCTAssertTrue(credit.finish)
        XCTAssertEqual(credit.credited?.paidMicroProtons, 0)
        XCTAssertEqual(credit.credited?.bonusMicroProtons, 100_000_000_000)
        XCTAssertEqual(credit.balances?.paid, 0); XCTAssertEqual(credit.balances?.earned, 0)
        XCTAssertEqual(credit.balances?.promo, 100_000_000_000)
        XCTAssertEqual(credit.balances?.available, 100_000_000_000)
    }

    func testV12CapErrorIsAClosedRefusalWithoutGuessedOutcome() throws {
        let data = try ApplePurchaseV12TestData.data("sandbox-cap.error")
        let error = try NativeAPI.decode(ApplePurchaseError.self, from: data)
        XCTAssertEqual(error.error, .closed); XCTAssertEqual(error.error.status, 403)
        XCTAssertEqual(error.reason, .sandboxCapExceeded)
        XCTAssertThrowsError(try NativeAPI.decode(AppleTransactionResponse.self, from: data))
    }

    func testPublicSyntheticValuesRoundTripWithoutClaimingAppleVerification() throws {
        let token = try NativeAPI.decode(AppleAccountTokenResponse.self,
                                        from: ApplePurchaseTestData.data(.accountToken))
        XCTAssertEqual(token.appAccountToken.uuidString.lowercased(), ApplePurchaseTestData.accountToken)
        let request = try NativeAPI.decode(AppleTransactionRequest.self,
                                          from: ApplePurchaseTestData.data(.transactionRequest))
        XCTAssertEqual(request.signedTransaction, "header.payload.sig")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String],
                       ["signedTransaction": "header.payload.sig"])
        let credited = try NativeAPI.decode(AppleTransactionResponse.self,
                                           from: ApplePurchaseTestData.data(.transactionCredited))
        XCTAssertEqual(credited.credited?.paidMicroProtons, 100_000_000_000)
        XCTAssertEqual(credited.balances?.available, 100_000_000_000)
        let replayed = try NativeAPI.decode(AppleTransactionResponse.self,
                                           from: ApplePurchaseTestData.data(.transactionReplayed))
        XCTAssertEqual(replayed.state, .alreadyCredited)
        XCTAssertTrue(replayed.finish)
        XCTAssertNil(replayed.credited)
        XCTAssertNil(replayed.balances)
    }

    func testFinalOwnerPacksCarryPaidAndBonusAmounts() throws {
        let catalog = try NativeAPI.decode(AppleProductsResponse.self,
            from: ApplePurchaseTestData.data(.productsOpen, ownerProducts: true))
        XCTAssertEqual(catalog.products.map(\.productId),
                       ["com.atum.mobile.protons.100k", "com.atum.mobile.protons.500k"])
        XCTAssertEqual(catalog.products.map(\.paidMicroProtons), [95_000_000_000, 395_000_000_000])
        XCTAssertEqual(catalog.products.map(\.bonusMicroProtons), [5_000_000_000, 105_000_000_000])
    }

    func testEveryD1CaseRetainsItsAcceptanceDisposition() throws {
        XCTAssertEqual(ApplePurchaseTestData.Case.allCases.count, 24)
        for sample in ApplePurchaseTestData.Case.allCases {
            let data = try ApplePurchaseTestData.data(sample)
            do {
                switch sample.message {
                case "apple.products.response": _ = try NativeAPI.decode(AppleProductsResponse.self, from: data)
                case "apple.account_token.response": _ = try NativeAPI.decode(AppleAccountTokenResponse.self, from: data)
                case "apple.transaction.request": _ = try NativeAPI.decode(AppleTransactionRequest.self, from: data)
                case "apple.transaction.response": _ = try NativeAPI.decode(AppleTransactionResponse.self, from: data)
                case "apple.error.response": _ = try NativeAPI.decode(ApplePurchaseError.self, from: data)
                case "apple.notification.request":
                    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    guard Set(value.keys) == ["signedPayload"], let jws = value["signedPayload"] as? String else {
                        throw ContractViolation.invalidValue
                    }
                    _ = try AppleTransactionRequest(signedTransaction: jws)
                case "apple.transaction.facts": try checkServerFacts(data)
                default: try checkServerSequence(data)
                }
                XCTAssertTrue(sample.accepts, "Accepted reject case \(sample.rawValue)")
            } catch {
                XCTAssertFalse(sample.accepts, "Refused accept case \(sample.rawValue): \(type(of: error))")
            }
        }
    }

    // Server-only facts/machines are acceptance evidence, never client authority.
    private func checkServerFacts(_ data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let t = root["transaction"] as! [String: Any]
        guard ["Production", "Sandbox"].contains(root["serverEnvironment"] as? String ?? ""),
              t["environment"] as? String == root["serverEnvironment"] as? String,
              root["chainVerified"] as? Bool == true,
              t["bundleId"] as? String == "com.atum.mobile", t["appAppleId"] as? Int == 6819235537,
              t["type"] as? String == "Consumable", t["quantity"] as? Int == 1,
              let raw = t["appAccountToken"] as? String, UUID(uuidString: raw) != nil else {
            throw ContractViolation.invariant
        }
    }

    private func checkServerSequence(_ data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let transitions: Set<String> = ["received|credited|verified_and_credited",
            "received|revoked|revocation_seen_before_credit", "received|needs_support|purchase_check_failed",
            "received|orphaned|token_tombstoned", "credited|revoked|refund_clawed_back",
            "revoked|credited|refund_reversed", "needs_support|credited|support_credited_to_token_owner",
            "needs_support|revoked|refund_seen"]
        var state = "received"
        for step in root["steps"] as! [[String: String]] {
            guard step["from"] == state, let next = step["to"], let event = step["event"],
                  transitions.contains([state, next, event].joined(separator: "|")) else {
                throw ContractViolation.invariant
            }
            state = next
        }
    }

    func testClosedResponsesAndCrossFieldValidation() throws {
        let data = try ApplePurchaseTestData.data(.transactionCredited)
        var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        value["finish"] = NSNull()
        XCTAssertThrowsError(try NativeAPI.decode(AppleTransactionResponse.self, from: JSONSerialization.data(withJSONObject: value)))
        value["finish"] = true; value["signedPayload"] = "a.b.c"
        XCTAssertThrowsError(try NativeAPI.decode(AppleTransactionResponse.self, from: JSONSerialization.data(withJSONObject: value)))
        XCTAssertThrowsError(try AppleTransactionRequest(signedTransaction: String(repeating: "a", count: 16_385)))
        XCTAssertThrowsError(try NativeAPI.decode(ApplePurchaseError.self,
            from: Data(#"{"error":"matrix_409","details":{"reason":"checkout_closed"}}"#.utf8)))
    }
}
