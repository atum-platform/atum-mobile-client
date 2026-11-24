import Foundation
import os
import XCTest
@testable import AtumMobile
@testable import AtumNativeAPI

@MainActor final class LiveAppWalletRefreshTests: XCTestCase {
    func testLateCreditRefreshCannotReplaceNewerRefundBalance() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in "wallet-fixture" },
                                        protocolClasses: [WalletRefreshProtocol.self])
        let model = LiveAppModel(domainClient: client)

        let credit = Task { await model.refreshApplePurchaseWallet() }
        defer { credit.cancel() }
        let creditRequest = try await WalletRefreshProtocol.nextRequest()
        let refund = Task { await model.refreshApplePurchaseWallet() }
        defer { refund.cancel() }
        let refundRequest = try await WalletRefreshProtocol.nextRequest()

        try refundRequest.respond(available: 20)
        await refund.value
        XCTAssertEqual(model.freshWalletAvailable, 20)

        try creditRequest.respond(available: 100)
        await credit.value
        XCTAssertEqual(model.freshWalletAvailable, 20)
    }
}

private final class WalletRefreshProtocol: URLProtocol, @unchecked Sendable {
    private static let pending = OSAllocatedUnfairLock(initialState: [WalletRefreshProtocol]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path == "/api/matrix/v1/wallet" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.pending.withLock { $0.append(self) }
    }

    override func stopLoading() {
        Self.pending.withLock { $0.removeAll { $0 === self } }
    }

    static func nextRequest() async throws -> WalletRefreshProtocol {
        for _ in 0..<1_000 {
            if let request = pending.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                return request
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try XCTUnwrap(nil, "Wallet request did not reach the fixture")
    }

    func respond(available: Int) throws {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                     headerFields: ["Content-Type": "application/json"]))
        let body = """
        {"unit":"micro_proton","balances":{"available":\(available),"paid":\(available),"earned":0,"promo":0,"held":0},
         "allowance":null,"checkoutOpen":true}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
