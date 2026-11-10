import Foundation
import StoreKit

/// Only verified consumables from our two product IDs cross into the coordinator.
@MainActor public final class StoreKitPurchaseStore: ApplePurchaseStore {
    private var loaded: [String: Product] = [:]
    public init() {}

    public func products(ids: Set<String>) async throws -> [AppleStoreProduct] {
        let products = try await Product.products(for: ids)
        guard products.allSatisfy({ $0.type == .consumable }) else { throw ContractViolation.invalidValue }
        loaded = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return products.map { .init(id: $0.id, displayPrice: $0.displayPrice) }
    }

    public func purchase(id: String, accountToken: UUID) async throws -> AppleStorePurchaseResult {
        guard let product = loaded[id], ApplePurchaseCoordinator.productIDs.contains(id) else {
            throw ContractViolation.invalidValue
        }
        switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
        case let .success(result):
            guard let transaction = Self.verified(result) else { return .unverified }
            return .verified(transaction)
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .unverified
        }
    }

    public func updates() -> AsyncStream<AppleVerifiedTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    if let transaction = Self.verified(result) { continuation.yield(transaction) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unfinished() async -> [AppleVerifiedTransaction] {
        var transactions: [AppleVerifiedTransaction] = []
        for await result in Transaction.unfinished {
            guard !Task.isCancelled else { break }
            if let transaction = Self.verified(result) { transactions.append(transaction) }
        }
        return transactions
    }

    private static func verified(_ result: VerificationResult<Transaction>) -> AppleVerifiedTransaction? {
        guard case let .verified(transaction) = result, transaction.productType == .consumable,
              ApplePurchaseCoordinator.productIDs.contains(transaction.productID) else { return nil }
        let environment: ApplePurchaseEnvironment?
        switch transaction.environment {
        case .production: environment = .production
        case .sandbox: environment = .sandbox
        default: environment = nil // Xcode / LocalTesting never reaches a deployed server.
        }
        return .init(id: String(transaction.id), productID: transaction.productID,
                     environment: environment, accountToken: transaction.appAccountToken,
                     signedTransaction: result.jwsRepresentation,
                     finish: { await transaction.finish() })
    }
}
