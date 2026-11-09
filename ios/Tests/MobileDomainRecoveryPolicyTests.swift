import XCTest
@testable import AtumNativeAPI

final class MobileDomainRecoveryPolicyTests: XCTestCase {
    private typealias Policy = MobileDomainRecoveryPolicy

    func testInterruptedOrRefusedGrantRequiresDomainOnlyReauthentication() throws {
        for failure in [OIDCGrantFailure.reauthenticationRequired,
                        .refreshInterrupted, .invalidResponse, .invalidIdentity] {
            XCTAssertEqual(Policy.state(for: failure), .reauthenticationRequired)
        }
        let body = Data("{\"error\":\"matrix_401\"}".utf8)
        let unauthorized = try NativeHTTPFailure(status: 401, headers: [:], body: body)
        XCTAssertEqual(Policy.state(for: NativeDomainClientFailure.http(unauthorized)),
                       .reauthenticationRequired)
        XCTAssertEqual(Policy.state(for: NativeDomainClientFailure.authenticationRefused),
                       .reauthenticationRequired)
        XCTAssertEqual(Policy.state(for: OIDCFailure.subjectMismatch),
                       .reauthenticationRequired)
    }

    func testDiscoveryTransportAndStorageFailuresStayRetryable() {
        XCTAssertEqual(Policy.state(for: MASHTTPFailure.transportUnavailable),
                       .temporarilyUnavailable)
        XCTAssertEqual(Policy.state(for: MASHTTPFailure.cancelled),
                       .temporarilyUnavailable)
        XCTAssertEqual(Policy.state(for: OIDCGrantFailure.storageUnavailable),
                       .temporarilyUnavailable)
        XCTAssertEqual(Policy.state(for: NativeDomainClientFailure.transportUnavailable),
                       .temporarilyUnavailable)
        XCTAssertEqual(Policy.state(for: OIDCFailure.invalidConfiguration),
                       .temporarilyUnavailable)
    }
}
