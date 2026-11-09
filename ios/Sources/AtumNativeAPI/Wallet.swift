import Foundation

public struct WalletResponse: Decodable, Equatable, Sendable {
    public struct Balances: Decodable, Equatable, Sendable {
        public let available, paid, earned, promo, held: Int64
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["available", "paid", "earned", "promo", "held"])
            available = try c.integer("available"); paid = try c.integer("paid")
            earned = try c.integer("earned"); promo = try c.integer("promo"); held = try c.integer("held")
            guard available == paid + earned + promo else { throw ContractViolation.invariant }
        }
    }
    public struct Allowance: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable { case founding, standard }
        public enum State: String, Decodable, Sendable { case granted, deferred }
        public let kind: Kind
        public let state: State
        public let amount: Int64
        public let grantedAt: NativeTimestamp?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["kind", "state", "amount", "grantedAt"])
            kind = try c.value("kind"); state = try c.value("state")
            amount = try c.integer("amount", minimum: 1); grantedAt = try c.nullable("grantedAt")
        }
    }
    public let balances: Balances
    public let allowance: Allowance?
    /// Domain metadata only. It is never purchase-path authorization.
    public let checkoutOpen: Bool
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["unit", "balances", "allowance", "checkoutOpen"])
        guard try c.value("unit", as: String.self) == "micro_proton" else { throw ContractViolation.invalidValue }
        balances = try c.value("balances"); allowance = try c.nullable("allowance")
        checkoutOpen = try c.value("checkoutOpen")
    }
}

public struct WalletHistoryResponse: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Decodable, Sendable { case usage, purchase, topup, grant, sale, reversal }
        public enum Status: String, Decodable, Sendable { case pending, charged, released, completed }
        public let id: NativeID
        public let at: NativeTimestamp
        public let kind: Kind
        public let status: Status
        public let amount: Int64
        public let reference: String?
        public let closedAt: NativeTimestamp?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["id", "at", "kind", "status", "amount", "reference", "closedAt"])
            id = try c.value("id"); at = try c.value("at"); kind = try c.value("kind"); status = try c.value("status")
            amount = try c.integer("amount", minimum: -NativeAPI.maximumInteger)
            reference = try c.nullable("reference"); closedAt = try c.nullable("closedAt")
            if let reference { _ = try checkedString(reference, maximum: 200) }
        }
    }
    public let entries: [Entry]
    /// Opaque provider cursor. Do not decode or reconstruct it from a row.
    public let next: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["entries", "next"])
        entries = try c.value("entries"); next = try c.nullable("next")
        guard entries.count <= 100 else { throw ContractViolation.invalidValue }
        if let next { _ = try checkedString(next, minimum: 1, maximum: 256, pattern: "[A-Za-z0-9_-]+") }
    }
}
