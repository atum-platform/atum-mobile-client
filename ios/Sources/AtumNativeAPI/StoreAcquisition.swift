import CryptoKit
import Foundation

@MainActor public protocol StoreAttemptJournal: AnyObject {
    func attempts(account: String) throws -> [StorePurchaseAttempt]
    func save(_ attempt: StorePurchaseAttempt, account: String) throws
    func remove(_ attempt: StorePurchaseAttempt, account: String) throws
}

/// Atomic before-send persistence; a corrupt/unwritable journal refuses a new
/// purchase. Sign-out never deletes unresolved intents. Nothing here is a secret.
@MainActor public final class StoreFileJournal: StoreAttemptJournal {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private func file(_ account: String) -> URL {
        let digest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    public func attempts(account: String) throws -> [StorePurchaseAttempt] {
        let url = file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000 else { throw ContractViolation.invalidValue }
        let values = try NativeAPI.decode([StorePurchaseAttempt].self, from: data)
        let targets = values.map { $0.itemID + "/" + ($0.assistantID?.rawValue ?? "account") }
        guard values.count <= 1000, Set(targets).count == values.count,
              Set(values.map(\.idempotencyKey)).count == values.count else { throw ContractViolation.invalidValue }
        return values
    }
    public func save(_ attempt: StorePurchaseAttempt, account: String) throws {
        var values = try attempts(account: account)
        values.removeAll { $0.itemID == attempt.itemID && $0.assistantID == attempt.assistantID }
        values.append(attempt)
        try write(values, account: account)
    }
    public func remove(_ attempt: StorePurchaseAttempt, account: String) throws {
        let values = try attempts(account: account).filter { $0.idempotencyKey != attempt.idempotencyKey }
        try write(values, account: account)
    }
    private func write(_ values: [StorePurchaseAttempt], account: String) throws {
        guard values.count <= 1000 else { throw ContractViolation.invalidValue }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        #if os(iOS)
        try data.write(to: file(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file(account), options: .atomic)
        #endif
    }
}

public struct StoreAcquireQuote: Equatable, Sendable {
    public let item: StoreCatalogItem
    public let assistantID: NativeID?
    public let offer: StoreCatalogOffer
    public let balance: Int64
    public var price: Int64 { offer.priceMicroProtons }
    public var resultingBalance: Int64 { balance - price }
    public init(item: StoreCatalogItem, assistantID: NativeID?, balance: Int64) throws {
        offer = try StoreAcquirePolicy.offer(for: item, assistantID: assistantID)
        guard (0...NativeAPI.maximumInteger).contains(balance) else { throw ContractViolation.invalidValue }
        self.item = item; self.assistantID = assistantID; self.balance = balance
    }
}

public enum StoreAcquireState: Equatable, Sendable {
    case idle, working, insufficientBalance, offline, forbidden, unavailable, uncertain
    case result(StorePurchaseResult)
}

/// One account and one in-flight write. Ambiguous responses keep the original
/// offer, target and key even if today's catalog/price changes. Replay is an
/// explicit user action, never a second automatically generated purchase.
@MainActor public final class StoreAcquisition {
    public typealias Purchase = @MainActor (StorePurchaseAttempt) async throws -> StorePurchaseResult
    public let account: String
    private let journal: any StoreAttemptJournal
    private let purchase: Purchase
    public private(set) var state: StoreAcquireState = .idle
    public private(set) var working = false
    public init(account: String, journal: any StoreAttemptJournal, purchase: @escaping Purchase) {
        self.account = account; self.journal = journal; self.purchase = purchase
    }
    public func attempt(itemID: String, assistantID: NativeID?) throws -> StorePurchaseAttempt? {
        try journal.attempts(account: account).first { $0.itemID == itemID && $0.assistantID == assistantID }
    }
    /// Retires saved attempts whose purchase history shows them reversed (same
    /// offer, version, target and key). A reversed charge is fully explained,
    /// and without this the item offers no recovery yet refuses every new
    /// purchase while the attempt waits. Every other state keeps the original
    /// key: a completed purchase missing from a separately read entitlement
    /// list may only be lagging, and a new key there could charge twice.
    public func retireReversed(by purchases: [StorePurchase]) throws {
        for attempt in try journal.attempts(account: account)
        where purchases.contains(where: { attempt.matches($0) && $0.state == .reversed }) {
            try journal.remove(attempt, account: account)
        }
    }
    public func confirm(_ quote: StoreAcquireQuote, online: Bool) async -> StoreAcquireState {
        guard !working else { return .working }
        do {
            if let existing = try attempt(itemID: quote.item.itemID, assistantID: quote.assistantID) {
                return await send(existing, online: online)
            }
            guard online else { state = .offline; return state }
            guard quote.resultingBalance >= 0 else { state = .insufficientBalance; return state }
            let intent = try StorePurchaseAttempt(item: quote.item, assistantID: quote.assistantID,
                                                 idempotencyKey: NativeID(UUID().uuidString.lowercased()))
            try journal.save(intent, account: account)
            return await send(intent, online: online)
        } catch { state = .unavailable; return state }
    }
    public func retry(_ attempt: StorePurchaseAttempt, online: Bool) async -> StoreAcquireState {
        guard !working else { return .working }
        do {
            guard try journal.attempts(account: account).contains(attempt) else {
                state = .unavailable; return state
            }
        } catch { state = .unavailable; return state }
        return await send(attempt, online: online)
    }
    private func send(_ attempt: StorePurchaseAttempt, online: Bool) async -> StoreAcquireState {
        guard online else { state = .offline; return state }
        working = true; state = .working
        defer { working = false }
        do {
            let result = try await purchase(attempt)
            try attempt.validate(result)
            // Keep settled attempts too: a crash before the refreshed inventory
            // paints must still replay this purchase, never mint a fresh key.
            switch result {
            case .offerChanged, .refused: try? journal.remove(attempt, account: account)
            case .purchased(let purchase, _) where purchase.state == .reversed:
                try? journal.remove(attempt, account: account)
            case .purchased, .alreadyOwned: break
            }
            state = .result(result)
        } catch let failure as NativeDomainClientFailure {
            if case .http(let http) = failure, http.response.error == .denied {
                state = .forbidden
            } else if failure == .authenticationRefused {
                state = .forbidden
            } else {
                state = .uncertain
            }
        } catch { state = .uncertain }
        return state
    }
}
