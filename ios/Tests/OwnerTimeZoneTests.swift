import Foundation
import XCTest
@testable import AtumNativeAPI

@MainActor final class OwnerTimeZoneTests: XCTestCase {
    override func tearDown() {
        OwnerTimeZoneProtocol.state.reset()
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "owner-time-zone-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: Bookkeeping (send rule and acknowledgement)

    func testFirstReadSendsAndAnAcknowledgedZoneIsNotSentAgain() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())
        bookkeeper.begin(accountID: "@an:atum.test")

        let first = bookkeeper.report(deviceTimeZone: "Asia/Ho_Chi_Minh")
        XCTAssertEqual(first?.zone, "Asia/Ho_Chi_Minh")
        XCTAssertEqual(first?.accountID, "@an:atum.test")

        bookkeeper.record(first, acknowledgement: "Asia/Ho_Chi_Minh")
        XCTAssertNil(bookkeeper.report(deviceTimeZone: "Asia/Ho_Chi_Minh"))
        XCTAssertEqual(bookkeeper.acknowledgedZone(accountID: "@an:atum.test"),
                       "Asia/Ho_Chi_Minh")
    }

    func testAChangedZoneIsSentAndAMissingOrDifferentAckLeavesItToRetry() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())
        bookkeeper.begin(accountID: "@an:atum.test")
        bookkeeper.record(bookkeeper.report(deviceTimeZone: "Asia/Ho_Chi_Minh"),
                          acknowledgement: "Asia/Ho_Chi_Minh")

        let changed = bookkeeper.report(deviceTimeZone: "Asia/Tokyo")
        XCTAssertEqual(changed?.zone, "Asia/Tokyo")

        bookkeeper.record(changed, acknowledgement: nil)
        XCTAssertEqual(bookkeeper.report(deviceTimeZone: "Asia/Tokyo")?.zone, "Asia/Tokyo")

        bookkeeper.record(changed, acknowledgement: "Asia/Saigon")
        XCTAssertEqual(bookkeeper.report(deviceTimeZone: "Asia/Tokyo")?.zone, "Asia/Tokyo")
        XCTAssertEqual(bookkeeper.acknowledgedZone(accountID: "@an:atum.test"),
                       "Asia/Ho_Chi_Minh")
    }

    func testPerAccountValuesSurviveSwitchesAndEachAccountReportsOnce() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())

        bookkeeper.begin(accountID: "@an:atum.test")
        bookkeeper.record(bookkeeper.report(deviceTimeZone: "Asia/Tokyo"),
                          acknowledgement: "Asia/Tokyo")

        bookkeeper.begin(accountID: "@binh:atum.test")
        XCTAssertEqual(bookkeeper.report(deviceTimeZone: "Asia/Tokyo")?.accountID,
                       "@binh:atum.test")
        bookkeeper.record(bookkeeper.report(deviceTimeZone: "Asia/Tokyo"),
                          acknowledgement: "Asia/Tokyo")

        bookkeeper.begin(accountID: "@an:atum.test")
        XCTAssertNil(bookkeeper.report(deviceTimeZone: "Asia/Tokyo"))
        XCTAssertEqual(bookkeeper.acknowledgedZone(accountID: "@binh:atum.test"),
                       "Asia/Tokyo")
    }

    func testDelayedAckAfterAccountSwitchOrSignOutIsDiscarded() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())

        bookkeeper.begin(accountID: "@an:atum.test")
        let delayed = bookkeeper.report(deviceTimeZone: "Asia/Tokyo")
        bookkeeper.begin(accountID: "@binh:atum.test")
        bookkeeper.record(delayed, acknowledgement: "Asia/Tokyo")
        XCTAssertNil(bookkeeper.acknowledgedZone(accountID: "@an:atum.test"))

        bookkeeper.begin(accountID: "@an:atum.test")
        let signedOut = bookkeeper.report(deviceTimeZone: "Asia/Tokyo")
        bookkeeper.end(clearStoredValue: true)
        bookkeeper.record(signedOut, acknowledgement: "Asia/Tokyo")
        XCTAssertNil(bookkeeper.acknowledgedZone(accountID: "@an:atum.test"))
    }

    func testExplicitSignOutClearsTheZoneButAnInvoluntaryEndKeepsIt() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())
        bookkeeper.begin(accountID: "@an:atum.test")

        bookkeeper.record(bookkeeper.report(deviceTimeZone: "Asia/Tokyo"),
                          acknowledgement: "Asia/Tokyo")
        bookkeeper.end(clearStoredValue: false)
        bookkeeper.begin(accountID: "@an:atum.test")
        XCTAssertNil(bookkeeper.report(deviceTimeZone: "Asia/Tokyo"))

        bookkeeper.end(clearStoredValue: true)
        bookkeeper.begin(accountID: "@an:atum.test")
        XCTAssertEqual(bookkeeper.report(deviceTimeZone: "Asia/Tokyo")?.zone, "Asia/Tokyo")
    }

    func testInvalidZoneIsNeverReported() {
        let bookkeeper = OwnerTimeZoneBookkeeper(defaults: defaults())
        bookkeeper.begin(accountID: "@an:atum.test")

        for value in ["", "+07:00", "asia/saigon", "Asia/", "Asia//Saigon",
                      "Asia/Tokyo\n", String(repeating: "A", count: 65)] {
            XCTAssertNil(bookkeeper.report(deviceTimeZone: value), value)
        }
        XCTAssertNotNil(bookkeeper.report(deviceTimeZone: "Asia/Saigon"))
        XCTAssertNotNil(bookkeeper.report(deviceTimeZone: "UTC"))
    }

    // MARK: Wire (header on the roster read only, ack exposure)

    func testRosterReadCarriesTheZoneAndExposesTheAck() async throws {
        OwnerTimeZoneProtocol.state.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Time-Zone"),
                           "Asia/Saigon")
            return .json(Data("[]".utf8), headers: [
                "Content-Type": "application/json",
                "atum-time-zone-ack": "Asia/Saigon"
            ])
        }
        let read = try await client().agents(timeZone: "Asia/Saigon")
        XCTAssertTrue(read.response.agents.isEmpty)
        XCTAssertEqual(read.timeZoneAck, "Asia/Saigon")
        XCTAssertEqual(OwnerTimeZoneProtocol.state.requests.count, 1)
    }

    func testInvalidZoneSendsNoHeaderAndLeavesNoAck() async throws {
        for value in ["", "+07:00", "asia/saigon", String(repeating: "A", count: 65)] {
            OwnerTimeZoneProtocol.state.reset()
            OwnerTimeZoneProtocol.state.handler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Atum-Time-Zone"), value)
                return .json(Data("[]".utf8))
            }
            let read = try await client().agents(timeZone: value)
            XCTAssertNil(read.timeZoneAck)
        }
    }

    func testHeaderIsAbsentWhenNoZoneIsReportedAndOnOtherReads() async throws {
        OwnerTimeZoneProtocol.state.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Atum-Time-Zone"))
            if request.url?.path == "/api/matrix/v1/apps" {
                return .json(Data(#"{"profile":"atum.app-catalog/1","apps":[]}"#.utf8))
            }
            return .json(Data("[]".utf8))
        }
        _ = try await client().agents()
        let apps = try await client().apps()
        XCTAssertTrue(apps.apps.isEmpty)
        XCTAssertEqual(OwnerTimeZoneProtocol.state.requests.count, 2)
    }

    // MARK: System time-zone change

    func testTimeZoneChangeNotificationRunsTheRefreshOnce() async {
        let center = NotificationCenter()
        let observer = OwnerTimeZoneChangeObserver(center: center)
        let first = expectation(description: "first refresh")
        let second = expectation(description: "second refresh")
        var refreshes = 0
        observer.start {
            refreshes += 1
            if refreshes == 1 { first.fulfill() } else { second.fulfill() }
        }

        center.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(refreshes, 1)

        center.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(refreshes, 2)
        observer.stop()
    }

    private func client() -> NativeDomainClient {
        NativeDomainClient(testAuthorization: { _ in "p2-owner-tz-token" },
                           protocolClasses: [OwnerTimeZoneProtocol.self])
    }
}

private final class OwnerTimeZoneProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        static func json(_ data: Data,
                         headers: [String: String] = ["Content-Type": "application/json"]) -> Self {
            .init(headers: headers, chunks: [data])
        }
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var block: ((URLRequest) -> Reply)?
        private var observed: [URLRequest] = []
        var handler: ((URLRequest) -> Reply)? {
            get { lock.withLock { block } }
            set { lock.withLock { block = newValue } }
        }
        var requests: [URLRequest] { lock.withLock { observed } }
        func receive(_ request: URLRequest) -> Reply {
            let action = lock.withLock { observed.append(request); return block }
            return action?(request) ?? .init()
        }
        func reset() { lock.withLock { block = nil; observed = [] } }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.atumplatform.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in reply.chunks { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
