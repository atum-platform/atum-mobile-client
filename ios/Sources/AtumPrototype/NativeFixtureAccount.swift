import Foundation
import AtumNativeAPI

/// Account-scoped P2 fixture projections. Upstream bytes are retained separately.
public struct NativeFixtureAccount {
    public let wallet: WalletResponse
    public let history: WalletHistoryResponse
    public let historyLastPage: WalletHistoryResponse
    public let agents: AgentsResponse
    public let currentAlias: AliasCurrentResponse
    private let fixtures: NativeAPIFixtures

    public init() throws {
        fixtures = try NativeAPIFixtures()
        wallet = try fixtures.decode(WalletResponse.self, "wallet.response.json")
        history = try fixtures.decode(WalletHistoryResponse.self, "wallet-history.response.json")
        historyLastPage = try fixtures.decode(WalletHistoryResponse.self, "wallet-history-last-page.response.json")
        agents = try fixtures.decode(AgentsResponse.self, "agents.response.json")
        currentAlias = try fixtures.decode(AliasCurrentResponse.self, "alias-current.response.json")
    }
    public var handle: String? {
        if case .assigned(let handle, _) = currentAlias { return "@" + handle.rawValue }
        return nil
    }
    public func historyPage(after cursor: String) throws -> WalletHistoryResponse {
        guard cursor == history.next else { throw ContractViolation.invalidValue }
        return historyLastPage
    }
    public func walletRead(state: String) throws -> NativeRead<WalletResponse> {
        var read = NativeRead<WalletResponse>()
        if state == "loading" { return read }
        if state == "out-of-protons" || state == "low-protons" {
            // Derived synthetic study, decoded through the same production
            // consumer. Never infer a live balance from local UI state.
            var object = try JSONSerialization.jsonObject(with: fixtures.data("wallet.response.json")) as! [String: Any]
            let amount = state == "out-of-protons" ? 0 : 8_000_000
            object["balances"] = ["available": amount, "paid": amount, "earned": 0, "promo": 0, "held": 0]
            read.receive(try NativeAPI.decode(WalletResponse.self, from: JSONSerialization.data(withJSONObject: object)))
        } else { read.receive(wallet) }
        switch state {
        case "offline": read.fail(.offline)
        case "error", "denied": read.fail(.failed)
        case "unavailable": read.fail(.unavailable)
        default: break
        }
        return read
    }
}
