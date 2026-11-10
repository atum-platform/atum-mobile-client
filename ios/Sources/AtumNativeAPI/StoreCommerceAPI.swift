import Foundation

/// Native Store transport seam. It intentionally has no top-up, payment,
/// desktop execution/task, Hub install or guessed pet-selection operation.
@MainActor public protocol StoreCommerceAPI: AnyObject {
    func storeCatalog() async throws -> StoreCatalogResponse
    func storeEntitlements() async throws -> StoreEntitlementsResponse
    func storePurchases() async throws -> StorePurchasesResponse
    func wallet() async throws -> WalletResponse
    func managedModelDestinations(agentPrincipal: NativeID) async throws -> ManagedModelDestinationSnapshot
    func acquireStoreItem(_ attempt: StorePurchaseAttempt) async throws -> StorePurchaseResult
    func cancelStoreSubscription(_ id: NativeID) async throws -> StoreEntitlement
}

extension NativeDomainClient: StoreCommerceAPI {}
