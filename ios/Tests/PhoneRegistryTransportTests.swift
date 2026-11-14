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

/// device-service 1.3 negotiation: the list asks for phones explicitly, the
/// capability probe asks with a version no server publishes, and the pinned
/// controller keys are read from their public route.
@MainActor final class PhoneRegistryNegotiationTests: XCTestCase {
    func testListNegotiatesPhonesAndProbeReadsTheRefusal() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in "native-token" }, protocolClasses: [NegotiationProtocol.self])
        NegotiationProtocol.reset()
        NegotiationProtocol.answer = { _ in (200, Data("{\"deviceServices\":[]}".utf8)) }
        let list = try await client.listPhoneRegistrations()
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(NegotiationProtocol.seen.last?.version, "1.3")
        XCTAssertEqual(NegotiationProtocol.seen.last?.method, "GET")

        // A 1.3 server refuses the unknown probe version: supported.
        NegotiationProtocol.answer = { version in
            version == "0.0" ? (400, Data("{\"error\":\"matrix_400\",\"details\":{\"reason\":\"invalid\"}}".utf8))
                : (200, Data("{\"deviceServices\":[]}".utf8))
        }
        let supported = try await client.phoneRegistrySupported()
        XCTAssertTrue(supported)
        XCTAssertEqual(NegotiationProtocol.seen.last?.version, "0.0")
        // An older server ignores the header and lists Macs: not supported.
        NegotiationProtocol.answer = { _ in (200, Data("{\"deviceServices\":[]}".utf8)) }
        let legacy = try await client.phoneRegistrySupported()
        XCTAssertFalse(legacy)
        // A closed cloud gate is neither: it throws, and the caller stays closed.
        NegotiationProtocol.answer = { _ in (503, Data("{\"error\":\"matrix_503\"}".utf8)) }
        do { _ = try await client.phoneRegistrySupported(); XCTFail("503 read as an answer") }
        catch let error as PhoneRegistryError { XCTAssertEqual(error.error, .unavailable) }
        // A proxy's HTML 502 is an outage.
        NegotiationProtocol.answer = { _ in (502, Data("<html>".utf8)) }
        do { _ = try await client.listPhoneRegistrations(); XCTFail("502 read as an answer") }
        catch { XCTAssertEqual(error as? NativeDomainClientFailure, .transportUnavailable) }
    }

    func testRevokeAndEnrollCarryNoVersionHeaderAndControllerKeysAreRead() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in "native-token" }, protocolClasses: [NegotiationProtocol.self])
        NegotiationProtocol.reset()
        NegotiationProtocol.answer = { _ in (200, Data("{}".utf8)) }
        _ = try? await client.phoneDeviceServices(request: Data("{}".utf8))
        XCTAssertEqual(NegotiationProtocol.seen.last?.method, "POST")
        XCTAssertNil(NegotiationProtocol.seen.last?.version)
        _ = try? await client.phoneDeviceServices(revoking: UUID())
        XCTAssertEqual(NegotiationProtocol.seen.last?.method, "DELETE")
        XCTAssertNil(NegotiationProtocol.seen.last?.version)
        let active = String(repeating: "a", count: 43), retired = String(repeating: "r", count: 43)
        NegotiationProtocol.answer = { _ in (200, Data("""
            {"keys":[{"kid":"\(active)","alg":"Ed25519","publicKey":"x","state":"active","createdAt":1},
                     {"kid":"\(retired)","alg":"Ed25519","publicKey":"x","state":"retired","createdAt":1}]}
            """.utf8)) }
        let keys = try await client.phoneControllerKeyIDs()
        XCTAssertEqual(keys, [active])
        XCTAssertEqual(NegotiationProtocol.seen.last?.path, "/api/matrix/v1/cloud/controller-keys")
        XCTAssertNil(NegotiationProtocol.seen.last?.version)
    }
}

private final class NegotiationProtocol: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let path: String; let version: String? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var answer: (String?) -> (Int, Data) = { _ in (200, Data()) }
    static func reset() { seen = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let version = request.value(forHTTPHeaderField: "Atum-Device-Service-Version")
        Self.seen.append(Seen(method: request.httpMethod ?? "", path: request.url!.path, version: version))
        let (status, data) = Self.answer(version)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
