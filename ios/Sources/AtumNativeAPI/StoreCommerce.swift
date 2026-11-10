import Foundation

/// Frozen atum.store/1.1 public wire. Prices are display/confirmation data;
/// requests carry only the immutable offer identity and the chosen assistant.
public enum StoreWire {
    public static let capabilitiesHeader = "Atum-Store-Capabilities"
    public static let capabilities = "store.ownership.1"
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try NativeAPI.decode(type, from: data, forbidden: [
            "accessToken", "refreshToken", "token", "credential", "password", "leaseToken", "recoveryKey",
            "apiKey", "privateKey", "protectedBody", "serviceKey", "receipt", "requires"
        ])
    }
}

extension KeyedDecodingContainer where Key == Field {
    func storeID(_ key: String) throws -> NativeID {
        try NativeID(string(key, minimum: 36, maximum: 36,
            pattern: "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}").lowercased())
    }
    func storeTimestamp(_ key: String) throws -> NativeTimestamp {
        let timestamp: NativeTimestamp = try value(key)
        try validateStoreTimestamp(timestamp)
        return timestamp
    }
    func nullableStoreID(_ key: String) throws -> NativeID? {
        let text: String? = try nullable(key)
        return try text.map { try NativeID($0.lowercased()) }
    }
}

public enum StoreGrantSource: String, Decodable, Sendable { case purchase, gift, compensation, promo }

public struct StoreOwnership: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case owned, visiting, available }
    public let state: State
    public let source: String?
    public let assistantIDs: [NativeID]
    public let until: NativeTimestamp?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["state", "source", "assistantIds", "until"])
        state = try c.value("state"); source = try c.nullable("source")
        let ids: [String] = try c.value("assistantIds")
        assistantIDs = try ids.map { try NativeID($0.lowercased()) }
        until = try c.nullable("until")
        if let until { try validateStoreTimestamp(until) }
        guard assistantIDs.count <= 1000, Set(assistantIDs).count == assistantIDs.count else {
            throw ContractViolation.invalidValue
        }
        switch state {
        case .owned:
            guard let source, StoreGrantSource(rawValue: source) != nil else { throw ContractViolation.invariant }
        case .visiting:
            guard source == "visit", assistantIDs.isEmpty, until != nil else { throw ContractViolation.invariant }
        case .available:
            guard source == nil, assistantIDs.isEmpty, until == nil else { throw ContractViolation.invariant }
        }
    }
}

public struct StoreHubInstall: Decodable, Equatable, Sendable {
    public let id: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["source", "id"])
        guard try c.value("source", as: String.self) == "hermes_hub" else { throw ContractViolation.invalidValue }
        id = try c.string("id", minimum: 1, maximum: 200, pattern: "official/[a-z0-9_-]+/[a-z0-9_-]+")
    }
}

public struct StoreSubscription: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case active, cancelled, lapsed }
    public let state: State
    public let renewAt: NativeTimestamp
    public let priceMicroProtons, offerVersion: Int64
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        state = try c.value("state"); renewAt = try c.storeTimestamp("renewAt")
        priceMicroProtons = try c.integer("priceMicroProtons"); offerVersion = try c.integer("offerVersion", minimum: 1)
    }
}

public struct StoreEntitlement: Decodable, Equatable, Identifiable, Sendable {
    public enum State: String, Decodable, Sendable { case active, revoked }
    public let id: NativeID
    public let itemID: String
    public let kind: StoreCatalogItem.Kind
    public let state: State
    public let assistantID: NativeID?
    public let delivery: StoreCatalogOffer.Delivery
    public let grantedAt: NativeTimestamp
    public let subscription: StoreSubscription?
    public let source: StoreGrantSource?
    public var isOwned: Bool { state == .active && subscription?.state != .lapsed }
    public var canCancel: Bool { isOwned && subscription?.state == .active && (source == nil || source == .purchase) }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        id = try c.storeID("id"); kind = try c.value("kind")
        itemID = try c.string("itemId", minimum: 1, maximum: 128,
                             pattern: "(skill|agent|pet)/[a-z0-9][a-z0-9_/-]{0,119}")
        state = try c.value("state"); assistantID = try c.nullableStoreID("assistantId")
        delivery = try c.value("delivery"); grantedAt = try c.storeTimestamp("grantedAt")
        subscription = try c.nullable("subscription"); source = try c.optional("source")
        guard itemID.hasPrefix(kind.rawValue + "/"),
              (kind == .pet) == (assistantID == nil),
              (kind == .agent) == (subscription != nil) else { throw ContractViolation.invariant }
    }
}

public struct StoreEntitlementsResponse: Decodable, Equatable, Sendable {
    public let entitlements: [StoreEntitlement]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        entitlements = try c.value("entitlements")
        guard entitlements.count <= 1000, Set(entitlements.map(\.id)).count == entitlements.count else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct StorePurchase: Decodable, Equatable, Identifiable, Sendable {
    public enum State: String, Decodable, Sendable { case deliveryPending = "delivery_pending", granted, completed, reversed }
    public let id, offerID, idempotencyKey: NativeID
    public let itemID: String
    public let offerVersion, amountMicroProtons: Int64
    public let assistantID: NativeID?
    public let createdAt: NativeTimestamp
    public let state: State
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        id = try c.storeID("id"); offerID = try c.storeID("offerId"); idempotencyKey = try c.storeID("idempotencyKey")
        itemID = try c.string("itemId", minimum: 1, maximum: 128)
        try storeText(itemID, maximum: 128)
        offerVersion = try c.integer("offerVersion", minimum: 1)
        amountMicroProtons = try c.integer("amountMicroProtons")
        assistantID = try c.nullableStoreID("assistantId"); createdAt = try c.storeTimestamp("createdAt")
        state = try c.value("state")
        let source: String? = try c.optional("source")
        guard source == nil || source == "purchase" else { throw ContractViolation.invalidValue }
    }
}

public struct StorePurchasesResponse: Decodable, Equatable, Sendable {
    public let purchases: [StorePurchase]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        purchases = try c.value("purchases")
        guard purchases.count <= 1000, Set(purchases.map(\.id)).count == purchases.count else { throw ContractViolation.invalidValue }
    }
}

public enum StorePurchaseResult: Decodable, Equatable, Sendable {
    public enum Refusal: String, Decodable, Sendable {
        case insufficientProtons = "insufficient_protons", offerUnavailable = "offer_unavailable"
        case featureUnavailable = "feature_unavailable", petCreditReserved = "pet_credit_reserved", forbidden
    }
    case purchased(StorePurchase, StoreEntitlement?)
    case alreadyOwned(StoreEntitlement)
    case offerChanged(StoreCatalogOffer)
    case refused(Refusal)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        switch try c.value("outcome", as: String.self) {
        case "purchased":
            let purchase: StorePurchase = try c.value("purchase")
            let entitlement: StoreEntitlement? = try c.nullable("entitlement")
            guard ![.completed, .granted].contains(purchase.state) || entitlement != nil else { throw ContractViolation.invariant }
            if let entitlement {
                guard purchase.itemID == entitlement.itemID, purchase.assistantID == entitlement.assistantID else {
                    throw ContractViolation.invariant
                }
            }
            self = .purchased(purchase, entitlement)
        case "already_owned":
            guard try c.nullable("purchase", as: StorePurchase.self) == nil else { throw ContractViolation.invariant }
            self = .alreadyOwned(try c.value("entitlement"))
        case "offer_changed": self = .offerChanged(try c.value("offer"))
        case "refused": self = .refused(try c.value("code"))
        default: throw ContractViolation.invalidValue
        }
    }
}

/// Durable, account-scoped intent. No bearer, payer, price or purchase authority.
public struct StorePurchaseAttempt: Codable, Equatable, Sendable {
    public let itemID: String
    public let offerID: NativeID
    public let offerVersion: Int64
    public let assistantID: NativeID?
    public let idempotencyKey: NativeID
    public init(item: StoreCatalogItem, assistantID: NativeID?, idempotencyKey: NativeID) throws {
        let offer = try StoreAcquirePolicy.offer(for: item, assistantID: assistantID)
        self.itemID = item.itemID; self.offerID = try NativeID(offer.id)
        self.offerVersion = offer.version; self.assistantID = assistantID; self.idempotencyKey = idempotencyKey
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["itemID", "offerID", "offerVersion", "assistantID", "idempotencyKey"])
        itemID = try c.string("itemID", minimum: 1, maximum: 128,
            pattern: "(skill|pet)/[a-z0-9][a-z0-9_/-]{0,119}")
        offerID = try c.storeID("offerID"); offerVersion = try c.integer("offerVersion", minimum: 1)
        assistantID = try c.optional("assistantID"); idempotencyKey = try c.storeID("idempotencyKey")
        guard itemID.hasPrefix("skill/") == (assistantID != nil) else { throw ContractViolation.invariant }
    }
    public var body: Data {
        get throws {
            var value: [String: Any] = ["offerId": offerID.rawValue, "offerVersion": offerVersion, "idempotencyKey": idempotencyKey.rawValue]
            if let assistantID { value["assistantId"] = assistantID.rawValue }
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }
    }
    public func matches(_ purchase: StorePurchase) -> Bool {
        purchase.itemID == itemID && purchase.offerID == offerID && purchase.offerVersion == offerVersion
            && purchase.assistantID == assistantID && purchase.idempotencyKey == idempotencyKey
    }
    public func validate(_ result: StorePurchaseResult) throws {
        switch result {
        case .purchased(let purchase, _): guard matches(purchase) else { throw ContractViolation.invariant }
        case .alreadyOwned(let entitlement):
            guard entitlement.itemID == itemID, entitlement.assistantID == assistantID, entitlement.isOwned else {
                throw ContractViolation.invariant
            }
        case .offerChanged: break // a replacement offer still requires a fresh confirmation
        case .refused: break
        }
    }
}

/// Base purchase.request excludes the Shell's transport idempotency envelope.
public struct StorePurchaseIntent: Decodable, Equatable, Sendable {
    public let offerID: NativeID
    public let offerVersion: Int64
    public let assistantID: NativeID?
    public let consentRenewal: Bool?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["offerId", "offerVersion", "assistantId", "consentRenewal"])
        offerID = try c.storeID("offerId"); offerVersion = try c.integer("offerVersion", minimum: 1)
        if c.contains(Field("assistantId")) { assistantID = try c.storeID("assistantId") }
        else { assistantID = nil }
        consentRenewal = try c.optional("consentRenewal")
        guard consentRenewal != false else { throw ContractViolation.invalidValue }
    }
}

private func validateStoreTimestamp(_ value: NativeTimestamp) throws {
    _ = try checkedString(value.rawValue, minimum: 1, maximum: 40,
        pattern: "[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]([.][0-9]{1,6})?(Z|[+-][0-2][0-9]:[0-5][0-9])")
}

/// The currently deliverable native acquisition slice, independent of wallet
/// arithmetic and UI. Unsupported scopes/kinds cannot form an intent.
public enum StoreAcquirePolicy {
    public static func offer(for item: StoreCatalogItem, assistantID: NativeID?) throws -> StoreCatalogOffer {
        guard let offer = item.offer, item.kind != .agent, offer.billingInterval == .oneTime,
              item.deliverable != false, (item.kind == .skill) == (assistantID != nil),
              (item.kind == .pet ? offer.scope == .account : offer.scope == .agent) else {
            throw ContractViolation.invalidValue
        }
        return offer
    }
}
