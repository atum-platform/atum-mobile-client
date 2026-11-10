import Foundation

/// Store listing projection for the native domain API. Offers are immutable
/// confirmation inputs; only a typed purchase result establishes acquisition.
public struct StoreCatalogResponse: Decodable, Equatable, Sendable {
    public let items: [StoreCatalogItem]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        items = try c.value("items")
        guard items.count <= 1_000 else { throw ContractViolation.invalidValue }

        var ids = Set<String>()
        for item in items {
            guard ids.insert(item.itemID).inserted else { throw ContractViolation.invariant }
        }
    }
}

/// A bounded, server-authored Store card. Additional top-level item fields are
/// deliberately ignored. Known Store 1.1 ownership/install fields are validated;
/// they never become purchase or launch authority merely by being present.
public struct StoreCatalogItem: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Decodable, Sendable { case skill, agent, pet }

    public let itemID: String
    public let kind: Kind
    public let title: StoreLocalizedCopy
    public let summary: StoreLocalizedCopy
    public let description: StoreLocalizedCopy
    public let glyph: String
    public let accent: String
    public let featured: Bool
    public let sortOrder: Int64
    public let offer: StoreCatalogOffer?
    public let ownership: StoreOwnership?
    public let deliverable: Bool?
    public let install: StoreHubInstall?
    public let tryPrompt: StoreLocalizedCopy
    public let needs: [String]

    public var id: String { itemID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        itemID = try c.string("itemId", minimum: 1, maximum: 128,
            pattern: "(skill|agent|pet)/[a-z0-9][a-z0-9_/-]{0,119}")
        kind = try c.value("kind")
        guard itemID.hasPrefix(kind.rawValue + "/") else { throw ContractViolation.invariant }
        title = try c.value("title")
        summary = try c.value("summary")
        description = try c.value("description")

        // Validate required, currently unrendered contract fields before
        // discarding them. This preserves a single strict listing boundary.
        tryPrompt = try c.value("tryPrompt")
        needs = try c.value("needs", as: [String].self)
        guard needs.count <= 20 else { throw ContractViolation.invalidValue }
        for need in needs { try storeText(need, maximum: 128) }

        glyph = try c.string("glyph", minimum: 1, maximum: 8)
        try storeText(glyph, maximum: 8)
        accent = try c.string("accent", minimum: 7, maximum: 7, pattern: "#[0-9a-fA-F]{6}")
        featured = try c.value("featured")
        sortOrder = try c.integer("sortOrder")
        offer = try c.nullable("offer")
        ownership = try c.optional("ownership")
        deliverable = try c.optional("deliverable")
        install = try c.optional("install")
        guard install == nil || (kind == .skill && offer == nil) else { throw ContractViolation.invariant }
    }
}

/// Locale-keyed Store copy. The public Store contract requires Vietnamese and
/// permits a small additive set of locale variants for presentation fallback.
public struct StoreLocalizedCopy: Decodable, Equatable, Sendable {
    public let values: [String: String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard c.allKeys.count <= 10 else { throw ContractViolation.invalidValue }
        var values: [String: String] = [:]
        for key in c.allKeys {
            let locale = try checkedString(key.stringValue, minimum: 2, maximum: 5,
                pattern: "[a-z]{2}(-[A-Za-z]{2})?")
            let text = try c.decode(String.self, forKey: key)
            try storeText(text, maximum: 12_000)
            values[locale] = text
        }
        guard values["vi"] != nil else { throw ContractViolation.invalidValue }
        self.values = values
    }

    public func localized(locale: String, fallback: String = "") -> String {
        values[locale] ?? values["en"] ?? values["vi"] ?? fallback
    }
}

/// Immutable offer metadata. The request echoes ID/version, never a client price;
/// the server resolves price, ownership and delivery on every acquisition.
public struct StoreCatalogOffer: Decodable, Equatable, Sendable {
    public enum Scope: String, Decodable, Sendable { case account, agent }
    public enum BillingInterval: String, Decodable, Sendable { case oneTime = "one_time", month }
    public enum Delivery: String, Decodable, Sendable { case cloud, bundled }

    public let id: String
    public let version: Int64
    public let priceMicroProtons: Int64
    public let renewalPriceMicroProtons: Int64?
    public let scope: Scope
    public let billingInterval: BillingInterval
    public let delivery: Delivery

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "version", "priceMicroProtons", "renewalPriceMicroProtons", "scope", "billingInterval", "delivery"])
        id = try c.string("id", minimum: 36, maximum: 36,
            pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").lowercased()
        version = try c.integer("version", minimum: 1)
        priceMicroProtons = try c.integer("priceMicroProtons")
        scope = try c.value("scope")
        billingInterval = try c.value("billingInterval")
        delivery = try c.value("delivery")

        switch billingInterval {
        case .month:
            renewalPriceMicroProtons = try c.integer("renewalPriceMicroProtons")
        case .oneTime:
            guard !c.contains(Field("renewalPriceMicroProtons")) else {
                throw ContractViolation.invariant
            }
            renewalPriceMicroProtons = nil
        }
    }
}

/// Matches the public Store validator: text is scalar-bounded and rejects the
/// disallowed C0 controls without stripping server-authored display text.
func storeText(_ value: String, maximum: Int) throws {
    // `store-contract` validates JavaScript string length, which is UTF-16
    // code units rather than Swift Character count.
    guard !value.isEmpty, value.utf16.count <= maximum else {
        throw ContractViolation.invalidValue
    }
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0...8, 11, 12, 14...31:
            throw ContractViolation.invalidValue
        default:
            continue
        }
    }
}
