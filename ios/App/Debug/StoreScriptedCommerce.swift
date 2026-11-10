#if DEBUG
import AtumNativeAPI
import Foundation
import SwiftUI

/// Synthetic Store commerce for the scripted simulator host. It answers the
/// `StoreCommerceAPI` seam in memory with frozen `atum.store/1.1` shapes and
/// synthetic identities only: no client, no network, no Protons move anywhere.
@MainActor final class ScriptedStoreJournal: StoreAttemptJournal {
    private var values = [String: [StorePurchaseAttempt]]()
    func attempts(account: String) throws -> [StorePurchaseAttempt] { values[account] ?? [] }
    func save(_ attempt: StorePurchaseAttempt, account: String) throws {
        values[account, default: []].removeAll { $0.itemID == attempt.itemID && $0.assistantID == attempt.assistantID }
        values[account, default: []].append(attempt)
    }
    func remove(_ attempt: StorePurchaseAttempt, account: String) throws {
        values[account]?.removeAll { $0.idempotencyKey == attempt.idempotencyKey }
    }
}

@MainActor final class ScriptedStoreAPI: StoreCommerceAPI {
    enum Mode { case acquire, insufficient, uncertain, owned }

    static let account = "@synthetic-store:example.invalid"
    static let mai = id("20000000-0000-4000-8000-0000000000a1")
    static let maiPrincipal = id("20000000-0000-4000-8000-0000000000a2")
    static let lanAgent = id("20000000-0000-4000-8000-0000000000b1")
    static let lanPrincipal = id("20000000-0000-4000-8000-0000000000b2")
    static let petOffer = "30000000-0000-4000-8000-000000000001"
    static let skillOffer = "30000000-0000-4000-8000-000000000002"
    static let agentOffer = "30000000-0000-4000-8000-000000000003"

    private let mode: Mode
    private var available: Int64
    private var entitlements = [[String: Any]]()
    private var purchases = [[String: Any]]()
    /// Uncertain: the first write commits but its reply is lost.
    private var loseNextReply: Bool

    init(mode: Mode) {
        self.mode = mode
        available = mode == .insufficient ? 10_000_000 : 120_000_000
        loseNextReply = mode == .uncertain
        if mode == .owned {
            entitlements = [
                Self.entitlement(id: "40000000-0000-4000-8000-000000000001", item: "pet/gigi", kind: "pet",
                                 assistant: nil, delivery: "bundled"),
                Self.entitlement(id: "40000000-0000-4000-8000-000000000002", item: "skill/nova", kind: "skill",
                                 assistant: Self.mai.rawValue, delivery: "cloud"),
                Self.entitlement(id: "40000000-0000-4000-8000-000000000003", item: "agent/scout", kind: "agent",
                                 assistant: Self.lanAgent.rawValue, delivery: "cloud",
                                 subscription: ["state": "active", "renewAt": "2026-12-10T00:00:00.000Z",
                                                "priceMicroProtons": 30_000_000, "offerVersion": 1]),
            ]
            purchases = [
                Self.purchase(id: "50000000-0000-4000-8000-000000000001", item: "pet/gigi", offer: Self.petOffer,
                              key: "60000000-0000-4000-8000-000000000001", assistant: nil, amount: 90_000_000,
                              state: "completed"),
                Self.purchase(id: "50000000-0000-4000-8000-000000000002", item: "skill/nova", offer: Self.skillOffer,
                              key: "60000000-0000-4000-8000-000000000002", assistant: Self.mai.rawValue,
                              amount: 24_000_000, state: "completed"),
            ]
        }
    }

    var targets: [LiveStoreCommerce.Target] {
        [.init(id: Self.mai, principal: Self.maiPrincipal, name: "Mai", roomID: "mai-room"),
         .init(id: Self.lanAgent, principal: Self.lanPrincipal, name: "Lan", roomID: nil)]
    }

    func storeCatalog() async throws -> StoreCatalogResponse {
        try decode(["items": Self.catalogItems])
    }

    func storeEntitlements() async throws -> StoreEntitlementsResponse {
        try decode(["entitlements": entitlements])
    }

    func storePurchases() async throws -> StorePurchasesResponse {
        try decode(["purchases": purchases])
    }

    func wallet() async throws -> WalletResponse {
        try decode(["unit": "micro_proton",
                    "balances": ["available": available, "paid": available, "earned": 0, "promo": 0, "held": 0],
                    "allowance": NSNull(), "checkoutOpen": false])
    }

    func managedModelDestinations(agentPrincipal: NativeID) async throws -> ManagedModelDestinationSnapshot {
        try decode([
            "profile": "atum.model-choice/1.3", "agentPrincipal": agentPrincipal.rawValue, "revision": 1,
            "policyDigest": String(repeating: "a", count: 64),
            "recommended": ["source": "atum", "model": "nguyet-thuc", "effort": "medium"],
            "choices": [["destination": "cloud", "source": "atum", "model": "nguyet-thuc", "effort": "medium"]],
            "dailyCap": ["dailyProtons": 0, "timeZone": "Asia/Ho_Chi_Minh", "warningPercent": 80,
                         "counts": "atum_billed_only"],
            "spend": ["day": "2026-11-10", "usedProtons": 0, "state": "normal", "notice": "none"],
        ])
    }

    func acquireStoreItem(_ attempt: StorePurchaseAttempt) async throws -> StorePurchaseResult {
        try await Task.sleep(for: .milliseconds(400))
        let key = attempt.idempotencyKey.rawValue
        // Exact replay: the same key returns the original purchase, never a second charge.
        if let existing = purchases.first(where: { $0["idempotencyKey"] as? String == key }) {
            return try result(existing, attempt: attempt)
        }
        let price = attempt.itemID == "pet/gigi" ? Int64(90_000_000) : 24_000_000
        guard available >= price else { return .refused(.insufficientProtons) }
        available -= price
        let purchase = Self.purchase(id: UUID().uuidString.lowercased(), item: attempt.itemID,
                                     offer: attempt.offerID.rawValue, key: key,
                                     assistant: attempt.assistantID?.rawValue, amount: price, state: "completed")
        purchases.append(purchase)
        entitlements.append(Self.entitlement(id: UUID().uuidString.lowercased(), item: attempt.itemID,
                                             kind: attempt.itemID.hasPrefix("pet/") ? "pet" : "skill",
                                             assistant: attempt.assistantID?.rawValue,
                                             delivery: attempt.itemID.hasPrefix("pet/") ? "bundled" : "cloud"))
        if loseNextReply {
            loseNextReply = false
            throw URLError(.timedOut)
        }
        return try result(purchase, attempt: attempt)
    }

    func cancelStoreSubscription(_ id: NativeID) async throws -> StoreEntitlement {
        try await Task.sleep(for: .milliseconds(300))
        guard let index = entitlements.firstIndex(where: { $0["id"] as? String == id.rawValue }),
              var subscription = entitlements[index]["subscription"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        subscription["state"] = "cancelled"
        entitlements[index]["subscription"] = subscription
        return try decode(entitlements[index])
    }

    // MARK: Shapes

    private func result(_ purchase: [String: Any], attempt: StorePurchaseAttempt) throws -> StorePurchaseResult {
        let entitlement: Any = entitlements.last { $0["itemId"] as? String == attempt.itemID
            && ($0["assistantId"] as? String) == attempt.assistantID?.rawValue }.map { $0 as Any } ?? NSNull()
        return try decode(["outcome": "purchased", "purchase": purchase, "entitlement": entitlement])
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T {
        try StoreWire.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func id(_ value: String) -> NativeID { try! NativeID(value) }

    private static func copy(_ vi: String, _ en: String) -> [String: String] { ["vi": vi, "en": en] }

    static let catalogItems: [[String: Any]] = [
        [
            "itemId": "pet/gigi", "kind": "pet", "title": copy("Gigi", "Gigi"),
            "summary": copy("Một người bạn", "A companion"),
            "description": copy("Một người bạn vui tươi", "A cheerful companion"),
            "tryPrompt": copy("Chọn người bạn này.", "Choose this companion."),
            "needs": ["Atum"], "glyph": "🐾", "accent": "#f3c969", "featured": false, "sortOrder": 10,
            "offer": ["id": petOffer, "version": 1, "priceMicroProtons": 90_000_000, "scope": "account",
                      "billingInterval": "one_time", "delivery": "bundled"],
        ],
        [
            "itemId": "skill/nova", "kind": "skill", "title": copy("Nova", "Nova"),
            "summary": copy("Một kỹ năng thử nghiệm", "A synthetic skill"),
            "description": copy("Một kỹ năng thử nghiệm cho trợ lý", "A synthetic skill for an assistant"),
            "tryPrompt": copy("Tóm tắt ghi chú hôm nay.", "Summarise today's notes."),
            "needs": ["Atum"], "glyph": "✦", "accent": "#9fb8f5", "featured": false, "sortOrder": 20,
            "offer": ["id": skillOffer, "version": 1, "priceMicroProtons": 24_000_000, "scope": "agent",
                      "billingInterval": "one_time", "delivery": "cloud"],
        ],
        [
            "itemId": "agent/scout", "kind": "agent", "title": copy("Scout", "Scout"),
            "summary": copy("Một trợ lý thử nghiệm", "A synthetic assistant"),
            "description": copy("Một trợ lý thử nghiệm", "A synthetic assistant"),
            "tryPrompt": copy("Xin chào.", "Hello."),
            "needs": ["Atum"], "glyph": "A", "accent": "#c7c7c7", "featured": false, "sortOrder": 30,
            "offer": ["id": agentOffer, "version": 1, "priceMicroProtons": 30_000_000, "scope": "agent",
                      "billingInterval": "month", "delivery": "cloud", "renewalPriceMicroProtons": 30_000_000],
        ],
    ]

    private static func entitlement(id: String, item: String, kind: String, assistant: String?,
                                    delivery: String, subscription: [String: Any]? = nil) -> [String: Any] {
        ["id": id, "itemId": item, "kind": kind, "state": "active", "assistantId": assistant ?? NSNull(),
         "delivery": delivery, "grantedAt": "2026-11-01T00:00:00.000Z", "subscription": subscription ?? NSNull()]
    }

    private static func purchase(id: String, item: String, offer: String, key: String, assistant: String?,
                                 amount: Int64, state: String) -> [String: Any] {
        ["id": id, "state": state, "itemId": item, "offerId": offer, "offerVersion": 1, "idempotencyKey": key,
         "assistantId": assistant ?? NSNull(), "amountMicroProtons": amount,
         "createdAt": "2026-11-01T00:00:00.000Z"]
    }
}

/// The scripted Store with a live `LiveStoreCommerce` over the synthetic API.
struct StoreCommerceScriptedHost: View {
    let design: LiveDesign
    let mode: ScriptedStoreAPI.Mode
    @State private var commerce = LiveStoreCommerce(journal: ScriptedStoreJournal())
    @State private var api: ScriptedStoreAPI?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            StoreScreen(design: design, store: presentation, onRefresh: {},
                        onOpenRoom: { roomID in path.append(roomID) }, commerce: commerce)
                .navigationDestination(for: String.self) { _ in
                    Text(verbatim: "Mai").accessibilityIdentifier("scripted.mai-chat")
                }
        }
        .task {
            guard api == nil else { return }
            let value = ScriptedStoreAPI(mode: mode)
            api = value
            commerce.configure(account: ScriptedStoreAPI.account, client: value, targets: value.targets)
        }
    }

    private var presentation: LiveProductStoreRead {
        let catalog = (try? StoreWire.decode(StoreCatalogResponse.self, from: JSONSerialization.data(
            withJSONObject: ["items": ScriptedStoreAPI.catalogItems])).items) ?? []
        let items = catalog.filter(\.isVisibleInStore).map { item in
            LiveProductStoreItem(
                id: item.itemID,
                kind: item.kind == .pet ? .pet : item.kind == .skill ? .skill : .agent,
                title: item.title.localized(locale: "vi", fallback: item.itemID),
                summary: item.summary.localized(locale: "vi"), glyph: item.glyph, featured: item.featured,
                price: item.offer.map { MicroProtonFormat.string($0.priceMicroProtons, locale: "vi_VN") },
                detailDescription: item.description.localized(locale: "vi"),
                tryPrompt: item.tryPrompt.localized(locale: "vi"),
                offer: item.offer, ownership: item.ownership, deliverable: item.deliverable,
                needs: item.needs, install: item.install)
        }
        let walletValue = commerce.wallet.map {
            MicroProtonFormat.balance($0.balances.available, locale: "vi_VN")
        }
        return .init(availability: .ready, walletValue: walletValue, items: items, apps: [])
    }
}
#endif
