import Foundation

public enum ApplePurchaseEnvironment: String, Decodable, Sendable { case production, sandbox }

public struct AppleProductsResponse: Decodable, Equatable, Sendable {
    public struct Pack: Decodable, Equatable, Sendable {
        public let productId, packId: String
        public let paidMicroProtons, bonusMicroProtons: Int64
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["productId", "packId", "paidMicroProtons", "bonusMicroProtons"])
            productId = try c.string("productId", minimum: 25, maximum: 80,
                                     pattern: "com[.]atum[.]mobile[.]protons[.][a-z0-9_]{1,40}")
            packId = try c.string("packId", minimum: 1, maximum: 40, pattern: "[a-z0-9_]+")
            paidMicroProtons = try c.integer("paidMicroProtons", minimum: 1)
            bonusMicroProtons = try c.integer("bonusMicroProtons")
        }
    }
    public let catalogVersion: Int64
    public let environment: ApplePurchaseEnvironment
    public let checkoutOpen: Bool
    public let products: [Pack]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["catalogVersion", "environment", "checkoutOpen", "products"])
        catalogVersion = try c.integer("catalogVersion", minimum: 1)
        environment = try c.value("environment"); checkoutOpen = try c.value("checkoutOpen")
        products = try c.value("products")
        guard products.count <= 20, Set(products.map(\.productId)).count == products.count else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct AppleAccountTokenResponse: Decodable, Sendable {
    public let appAccountToken: UUID
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["appAccountToken"])
        let raw = try c.string("appAccountToken", minimum: 36, maximum: 36,
                               pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        guard let uuid = UUID(uuidString: raw) else { throw ContractViolation.invalidValue }
        appAccountToken = uuid
    }
}

/// Do not render or log this request (or a VerificationResult).
public struct AppleTransactionRequest: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let signedTransaction: String
    public var description: String { "AppleTransactionRequest(redacted)" }
    public var debugDescription: String { description }
    public init(signedTransaction: String) throws {
        self.signedTransaction = try checkedString(signedTransaction, minimum: 5, maximum: 16_384,
            pattern: "[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+")
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["signedTransaction"])
        try self.init(signedTransaction: c.value("signedTransaction"))
    }
}

public struct AppleTransactionResponse: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case credited, alreadyCredited = "already_credited", creditedToOtherAccount = "credited_to_other_account"
        case revoked, needsSupport = "needs_support"
    }
    public struct Credit: Decodable, Equatable, Sendable {
        public let paidMicroProtons, bonusMicroProtons: Int64
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["paidMicroProtons", "bonusMicroProtons"])
            paidMicroProtons = try c.integer("paidMicroProtons")
            bonusMicroProtons = try c.integer("bonusMicroProtons")
        }
    }
    public let transactionId: String
    public let state: State
    public let finish: Bool
    public let credited: Credit?
    public let balances: WalletResponse.Balances?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["transactionId", "state", "finish", "credited", "balances"])
        transactionId = try c.string("transactionId", minimum: 1, maximum: 32, pattern: "[0-9]+")
        state = try c.value("state"); finish = try c.value("finish")
        credited = try c.nullable("credited"); balances = try c.nullable("balances")
        guard state == .credited ? (credited != nil && balances != nil) : (credited == nil && balances == nil)
        else { throw ContractViolation.invariant }
    }
}

public struct ApplePurchaseError: Error, Decodable, Equatable, Sendable {
    public enum Code: String, Decodable, Sendable {
        case invalid = "matrix_400", unauthenticated = "matrix_401", closed = "matrix_403"
        case environmentMismatch = "matrix_409", verification = "matrix_422", unavailable = "matrix_503"
        public var status: Int { Int(rawValue.dropFirst(7))! }
    }
    public enum Reason: String, Decodable, Sendable {
        case invalid, checkoutClosed = "checkout_closed", environmentMismatch = "environment_mismatch"
        case invalidSignature = "invalid_signature", wrongBundle = "wrong_bundle", unavailable
    }
    private struct Details: Decodable {
        let reason: Reason?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["reason"]); reason = try c.optional("reason")
        }
    }
    public let error: Code
    public let reason: Reason?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["error", "details"])
        error = try c.value("error")
        reason = try c.optional("details", as: Details.self)?.reason
        let allowed: [Code: Set<Reason>] = [.invalid: [.invalid], .unauthenticated: [],
            .closed: [.checkoutClosed], .environmentMismatch: [.environmentMismatch],
            .verification: [.invalidSignature, .wrongBundle], .unavailable: [.unavailable]]
        guard reason.map({ allowed[error]!.contains($0) }) ?? (error == .unauthenticated)
        else { throw ContractViolation.invalidValue }
    }
}

@MainActor public protocol ApplePurchasesAPI: AnyObject {
    func appleProducts() async throws -> AppleProductsResponse
    func appleAccountToken() async throws -> AppleAccountTokenResponse
    func appleTransaction(_ request: AppleTransactionRequest) async throws -> AppleTransactionResponse
}
