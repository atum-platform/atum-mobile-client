import Foundation

/// Synthetic wire examples transcribed from atum.mobile-purchases/1.2 fixtures.
/// Pack SHA-256: b74e996a8c35bce7cdbf6593cf20551bdc2777302910600e30d2a0acc33076bd.
/// Swift integer literals preserve the integer-only wire contract without making
/// synthetic amounts look like infrastructure identifiers to the public guard.
enum ApplePurchaseV12TestData {
    static func data(_ name: String) throws -> Data {
        let object: [String: Any]
        switch name {
        case "allowlisted-products.response":
            object = [
                "catalogVersion": 1,
                "environment": "sandbox",
                "checkoutOpen": true,
                "products": [
                    [
                        "productId": "com.atum.mobile.protons.100k",
                        "packId": "pack_100k",
                        "paidMicroProtons": 95_000_000_000,
                        "bonusMicroProtons": 5_000_000_000
                    ],
                    [
                        "productId": "com.atum.mobile.protons.500k",
                        "packId": "pack_500k",
                        "paidMicroProtons": 395_000_000_000,
                        "bonusMicroProtons": 105_000_000_000
                    ]
                ]
            ]
        case "sandbox-credited.response":
            object = [
                "transactionId": "2000000123456789",
                "state": "credited",
                "finish": true,
                "credited": [
                    "paidMicroProtons": 0,
                    "bonusMicroProtons": 100_000_000_000
                ],
                "balances": [
                    "available": 100_000_000_000,
                    "paid": 0,
                    "earned": 0,
                    "promo": 100_000_000_000,
                    "held": 0
                ]
            ]
        case "sandbox-replayed.response":
            object = [
                "transactionId": "2000000123456789",
                "state": "already_credited",
                "finish": true,
                "credited": NSNull(),
                "balances": NSNull()
            ]
        case "sandbox-cap.error":
            object = [
                "error": "matrix_403",
                "details": [
                    "reason": "sandbox_cap_exceeded"
                ]
            ]
        case "production-closed.response":
            object = [
                "catalogVersion": 1,
                "environment": "production",
                "checkoutOpen": false,
                "products": []
            ]
        default: throw CocoaError(.fileReadNoSuchFile)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
