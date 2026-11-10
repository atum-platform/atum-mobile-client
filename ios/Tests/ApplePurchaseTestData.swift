import Foundation

/// Public synthetic d1 examples. These are not Apple-signed payloads or provider fixtures.
enum ApplePurchaseTestData {
    static let accountToken = "00000000-0000-4000-8000-0000000000aa"
    static let signedData = "header.payload.sig"

    enum Case: String, CaseIterable {
        case productsOpen = "products-open.response"
        case productsClosed = "products-closed.response"
        case productsWrongProductID = "products-wrong-product-id.response"
        case accountToken = "account-token.response"
        case transactionRequest = "transaction.request"
        case transactionNamesPrincipal = "transaction-names-principal.request"
        case transactionCredited = "transaction-credited.response"
        case transactionReplayed = "transaction-replayed.response"
        case transactionNeedsSupport = "transaction-needs-support.response"
        case transactionWithoutFinish = "transaction-without-finish.response"
        case notification = "notification.request"
        case transactionFacts = "transaction.facts"
        case transactionWrongBundle = "transaction-wrong-bundle.facts"
        case transactionSandboxToProduction = "transaction-sandbox-to-production.facts"
        case transactionXcodeToSandbox = "transaction-xcode-to-sandbox.facts"
        case transactionXcodeServer = "transaction-xcode-server.facts"
        case transactionWithoutAccountToken = "transaction-without-account-token.facts"
        case errorEnvironmentMismatch = "error-environment-mismatch.response"
        case errorInvalidSignature = "error-invalid-signature.response"
        case errorGuessedOutcome = "error-guessed-outcome.response"
        case transactionRefundAndReversal = "transaction-refund-and-reversal.sequence"
        case transactionCreditedTwice = "transaction-credited-twice.sequence"
        case transactionSupportResolved = "transaction-support-resolved.sequence"
        case transactionOrphanCredited = "transaction-orphan-credited.sequence"

        var accepts: Bool {
            switch self {
            case .productsWrongProductID, .transactionNamesPrincipal, .transactionWithoutFinish,
                 .transactionWrongBundle, .transactionSandboxToProduction, .transactionXcodeToSandbox,
                 .transactionXcodeServer, .transactionWithoutAccountToken, .errorGuessedOutcome,
                 .transactionCreditedTwice, .transactionOrphanCredited: return false
            default: return true
            }
        }

        var message: String {
            switch self {
            case .productsOpen, .productsClosed, .productsWrongProductID: return "apple.products.response"
            case .accountToken: return "apple.account_token.response"
            case .transactionRequest, .transactionNamesPrincipal: return "apple.transaction.request"
            case .transactionCredited, .transactionReplayed, .transactionNeedsSupport,
                 .transactionWithoutFinish: return "apple.transaction.response"
            case .notification: return "apple.notification.request"
            case .transactionFacts, .transactionWrongBundle, .transactionSandboxToProduction,
                 .transactionXcodeToSandbox, .transactionXcodeServer,
                 .transactionWithoutAccountToken: return "apple.transaction.facts"
            case .errorEnvironmentMismatch, .errorInvalidSignature,
                 .errorGuessedOutcome: return "apple.error.response"
            default: return "apple_transaction"
            }
        }
    }

    static func data(_ sample: Case, ownerProducts: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(sample, ownerProducts: ownerProducts))
    }

    static func object(_ sample: Case, ownerProducts: Bool = false) -> [String: Any] {
        switch sample {
        case .productsOpen, .productsClosed, .productsWrongProductID:
            let products: [[String: Any]]
            if sample == .productsClosed {
                products = []
            } else if ownerProducts {
                products = [
                    pack("com.atum.mobile.protons.100k", "100k", 95_000_000_000, 5_000_000_000),
                    pack("com.atum.mobile.protons.500k", "500k", 395_000_000_000, 105_000_000_000)
                ]
            } else {
                products = [pack(sample == .productsWrongProductID ? "vn.atum.protons.100k"
                    : "com.atum.mobile.protons.pack_100k", "pack_100k", 100_000_000_000, 0)]
            }
            return ["catalogVersion": 1, "environment": sample == .productsClosed ? "production" : "sandbox",
                    "checkoutOpen": sample != .productsClosed, "products": products]
        case .accountToken:
            return ["appAccountToken": accountToken]
        case .transactionRequest, .transactionNamesPrincipal:
            var value = ["signedTransaction": signedData]
            if sample == .transactionNamesPrincipal { value["principal"] = "fake-principal" }
            return value
        case .notification:
            return ["signedPayload": signedData]
        case .transactionCredited, .transactionReplayed, .transactionNeedsSupport, .transactionWithoutFinish:
            let credited = sample == .transactionCredited
            var value: [String: Any] = [
                "transactionId": sample == .transactionNeedsSupport ? "2000000123456790" : "2000000123456789",
                "state": sample == .transactionReplayed ? "already_credited"
                    : sample == .transactionNeedsSupport ? "needs_support" : "credited",
                "finish": true,
                "credited": credited ? ["paidMicroProtons": 100_000_000_000, "bonusMicroProtons": 0] : NSNull(),
                "balances": credited ? ["available": 100_000_000_000, "paid": 100_000_000_000,
                                         "earned": 0, "promo": 0, "held": 0] : NSNull()
            ]
            if sample == .transactionWithoutFinish { value.removeValue(forKey: "finish") }
            return value
        case .transactionFacts, .transactionWrongBundle, .transactionSandboxToProduction,
             .transactionXcodeToSandbox, .transactionXcodeServer, .transactionWithoutAccountToken:
            var transaction: [String: Any] = [
                "bundleId": sample == .transactionWrongBundle ? "com.example.other" : "com.atum.mobile",
                "appAppleId": 6819235537, "type": "Consumable", "quantity": 1,
                "environment": [.transactionXcodeToSandbox, .transactionXcodeServer].contains(sample) ? "Xcode" : "Sandbox",
                "productId": "com.atum.mobile.protons.pack_100k", "transactionId": "2000000123456789",
                "originalTransactionId": "2000000123456789", "appAccountToken": accountToken,
                "purchaseDate": 1_791_200_000_000, "storefront": "VNM"
            ]
            if sample == .transactionWithoutAccountToken { transaction.removeValue(forKey: "appAccountToken") }
            return ["serverEnvironment": sample == .transactionSandboxToProduction ? "Production"
                    : sample == .transactionXcodeServer ? "Xcode" : "Sandbox",
                    "chainVerified": true, "transaction": transaction]
        case .errorEnvironmentMismatch:
            return ["error": "matrix_409", "details": ["reason": "environment_mismatch"]]
        case .errorInvalidSignature:
            return ["error": "matrix_422", "details": ["reason": "invalid_signature"]]
        case .errorGuessedOutcome:
            return ["error": "matrix_503", "details": ["reason": "probably_credited"]]
        case .transactionRefundAndReversal:
            return sequence([
                ["received", "credited", "verified_and_credited"],
                ["credited", "revoked", "refund_clawed_back"],
                ["revoked", "credited", "refund_reversed"]
            ])
        case .transactionCreditedTwice:
            return sequence([["received", "credited", "verified_and_credited"],
                             ["credited", "credited", "verified_and_credited"]])
        case .transactionSupportResolved:
            return sequence([["received", "needs_support", "purchase_check_failed"],
                             ["needs_support", "credited", "support_credited_to_token_owner"]])
        case .transactionOrphanCredited:
            return sequence([["received", "orphaned", "token_tombstoned"],
                             ["orphaned", "credited", "support_credited_to_token_owner"]])
        }
    }

    private static func pack(_ id: String, _ packID: String, _ paid: Int64, _ bonus: Int64) -> [String: Any] {
        ["productId": id, "packId": packID, "paidMicroProtons": paid, "bonusMicroProtons": bonus]
    }

    private static func sequence(_ steps: [[String]]) -> [String: Any] {
        ["steps": steps.map { ["from": $0[0], "to": $0[1], "event": $0[2]] }]
    }
}
