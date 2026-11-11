import Foundation
import StoreKit
import XCTest
@testable import AtumNativeAPI

@MainActor final class StoreKitPurchaseStoreTests: XCTestCase {
    func testDeployedStoreKitEnvironmentsMapExactly() {
        XCTAssertEqual(StoreKitPurchaseStore.purchaseEnvironment(.production), .production)
        XCTAssertEqual(StoreKitPurchaseStore.purchaseEnvironment(.sandbox), .sandbox)
    }

    func testXcodeAndUnknownEnvironmentsCannotAuthorizeCheckout() {
        XCTAssertNil(StoreKitPurchaseStore.purchaseEnvironment(.xcode))
        XCTAssertNil(StoreKitPurchaseStore.purchaseEnvironment(.init(rawValue: "future-environment")))
    }

    func testAdapterWithoutRuntimeEvidenceDefaultsToUnavailable() async throws {
        let store = UnknownEnvironmentStore()
        let environment = try await store.purchaseEnvironment()
        XCTAssertNil(environment)
    }
}

@MainActor private final class UnknownEnvironmentStore: ApplePurchaseStore {
    func products(ids: Set<String>) async throws -> [AppleStoreProduct] { [] }
    func purchase(id: String, accountToken: UUID) async throws -> AppleStorePurchaseResult { .cancelled }
    func updates() -> AsyncStream<AppleVerifiedTransaction> { AsyncStream { $0.finish() } }
    func unfinished() async -> [AppleVerifiedTransaction] { [] }
}
