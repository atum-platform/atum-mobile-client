import Foundation

/// One row of the phone's Proton pack sheet (owner ruling 1): the pack's total
/// Protons and StoreKit's localized price, nothing else. The server's paid and
/// bonus parts are summed here and never leave this type separately; there is
/// no rate, saving or per-Proton figure to show.
public struct AppleProtonPackRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let totalMicroProtons: Int64
    public let displayPrice: String

    public init(id: String, totalMicroProtons: Int64, displayPrice: String) {
        self.id = id; self.totalMicroProtons = totalMicroProtons; self.displayPrice = displayPrice
    }

    /// Rows for every product the server lists and StoreKit priced, smallest
    /// pack first. A pack whose total would overflow is left out, not clamped.
    public static func rows(packs: [AppleProductsResponse.Pack],
                            products: [AppleStoreProduct]) -> [AppleProtonPackRow] {
        let prices = Dictionary(products.map { ($0.id, $0.displayPrice) }, uniquingKeysWith: { first, _ in first })
        return packs.compactMap { pack -> AppleProtonPackRow? in
            guard let price = prices[pack.productId], !price.isEmpty else { return nil }
            let (total, overflow) = pack.paidMicroProtons.addingReportingOverflow(pack.bonusMicroProtons)
            guard !overflow, total > 0 else { return nil }
            return .init(id: pack.productId, totalMicroProtons: total, displayPrice: price)
        }
        .sorted { $0.totalMicroProtons == $1.totalMicroProtons ? $0.id < $1.id : $0.totalMicroProtons < $1.totalMicroProtons }
    }
}

extension ApplePurchaseCoordinator {
    /// The pack sheet's rows: total Protons and StoreKit price only.
    public var packRows: [AppleProtonPackRow] { AppleProtonPackRow.rows(packs: packs, products: products) }
}
