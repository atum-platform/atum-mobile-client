import Foundation
import XCTest
@testable import AtumNativeAPI

@MainActor final class PhoneRegistryTransportTests: XCTestCase {
    func testTransportStatusesAndAllowlist() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in "native-token" }, protocolClasses: [PhoneRegistryProtocol.self])
        for status in [201, 200, 400, 401, 403, 404, 409, 503] {
            PhoneRegistryProtocol.status = status
            do {
                let data = try await client.phoneDeviceServices(request: Data("{}".utf8))
                XCTAssertTrue([200, 201].contains(status))
                XCTAssertEqual(data, Data("{}".utf8))
            } catch let error as PhoneRegistryError {
                XCTAssertEqual(error.error.rawValue, "matrix_\(status)")
                XCTAssertEqual(error.details?.reason, "invalid")
            }
        }
        PhoneRegistryProtocol.status = 200
        _ = try await client.phoneDeviceServices()
        _ = try await client.phoneDeviceServices(revoking: UUID())
    }
}
private final class PhoneRegistryProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-token")
        XCTAssertTrue(request.url!.path.hasPrefix("/api/matrix/v1/device-services"))
        let data = Self.status < 300 ? Data("{}".utf8) : Data("{\"error\":\"matrix_\(Self.status)\",\"details\":{\"reason\":\"invalid\"}}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
