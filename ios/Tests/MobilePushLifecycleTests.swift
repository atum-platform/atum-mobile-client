import XCTest
import Foundation
import AtumNativeAPI
import AtumPrototype

/// S3 push hardening: the pusher must not outlive its session, a token
/// rotation must set the new pusher before deleting the old one, and the APNs
/// environment comes from the signed profile, cross-checked against the build.
/// The transport spy stands in for the live Matrix client.
@MainActor
final class MobilePushLifecycleTests: XCTestCase {
    private enum Call: Equatable {
        case set(pushkey: String, appID: String)
        case remove(pushkey: String, appID: String)
    }

    private enum SpyFailure: Error { case refused }

    @MainActor
    private final class TransportSpy: MobilePusherTransport {
        private(set) var calls: [Call] = []
        var failSet = false
        var failRemove = false
        func setPusher(_ fields: MobilePusherFields) async throws {
            if failSet { throw SpyFailure.refused }
            calls.append(.set(pushkey: fields.pushkey, appID: fields.appID))
        }
        func removePusher(pushkey: String, appID: String) async throws {
            if failRemove { throw SpyFailure.refused }
            calls.append(.remove(pushkey: pushkey, appID: appID))
        }
    }

    private let devAppID = "com.atum.mobile.ios.dev"
    private let prodAppID = "com.atum.mobile.ios.prod"

    /// 32 bytes of one value as the contract's lowercase hex pushkey.
    private func hex(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func receive(_ push: MobilePushCoordinator, _ byte: UInt8,
                         build: MobileAPNSEnvironment, signed: MobileAPNSEnvironment?,
                         spy: TransportSpy) async -> MobilePushRegistrationOutcome {
        await push.receive(tokenBytes: Data(repeating: byte, count: 32), build: build,
                           signed: signed, device: .iPhone, locale: .vi, using: spy)
    }

    // MARK: Sign-out removes

    func testSignOutDeletesTheRegisteredPusherBeforeTheSessionEnds() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()

        let registered = await receive(push, 0x11, build: .sandbox, signed: .sandbox, spy: spy)
        XCTAssertEqual(registered, .set(environment: .sandbox, source: .provisioningProfile, previous: .none))
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x11), appID: devAppID)])

        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x11), appID: devAppID),
                                   .remove(pushkey: hex(0x11), appID: devAppID)])

        // A second sign-out has nothing left to delete.
        let again = await push.signOut(using: spy)
        XCTAssertEqual(again, .nothingRegistered)
        XCTAssertEqual(spy.calls.count, 2)
    }

    func testSignOutWithoutARegistrationDoesNothing() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        let outcome = await push.signOut(using: spy)
        XCTAssertEqual(outcome, .nothingRegistered)
        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testFailedRemovalKeepsTheIdentitySoASignOutCanBeRetried() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        _ = await receive(push, 0x11, build: .sandbox, signed: .sandbox, spy: spy)

        spy.failRemove = true
        let failed = await push.signOut(using: spy)
        XCTAssertEqual(failed, .removalFailed)

        spy.failRemove = false
        let retried = await push.signOut(using: spy)
        XCTAssertEqual(retried, .removed)
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x11), appID: devAppID),
                                   .remove(pushkey: hex(0x11), appID: devAppID)])
    }

    // MARK: Rotation sets then removes

    func testTokenRotationSetsTheNewPusherThenDeletesTheOld() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        _ = await receive(push, 0x11, build: .sandbox, signed: .sandbox, spy: spy)

        let rotated = await receive(push, 0x22, build: .sandbox, signed: .sandbox, spy: spy)
        XCTAssertEqual(rotated, .set(environment: .sandbox, source: .provisioningProfile, previous: .removed))
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x11), appID: devAppID),
                                   .set(pushkey: hex(0x22), appID: devAppID),
                                   .remove(pushkey: hex(0x11), appID: devAppID)])

        // The same token again is a no-op, as before.
        let unchanged = await receive(push, 0x22, build: .sandbox, signed: .sandbox, spy: spy)
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(spy.calls.count, 3)

        // Sign-out then removes the token that is actually registered.
        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(spy.calls.last, .remove(pushkey: hex(0x22), appID: devAppID))
    }

    func testEnvironmentChangeRotatesEvenWhenTheTokenIsUnchanged() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        _ = await receive(push, 0x11, build: .sandbox, signed: .sandbox, spy: spy)

        // The same phone token moves from the dev app ID to the prod one:
        // set prod first, then delete the dev pusher.
        let rotated = await receive(push, 0x11, build: .production, signed: .production, spy: spy)
        XCTAssertEqual(rotated, .set(environment: .production, source: .provisioningProfile, previous: .removed))
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x11), appID: devAppID),
                                   .set(pushkey: hex(0x11), appID: prodAppID),
                                   .remove(pushkey: hex(0x11), appID: devAppID)])
    }

    func testRotationKeepsTheNewPusherWhenTheOldOneCannotBeDeleted() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        _ = await receive(push, 0x11, build: .sandbox, signed: .sandbox, spy: spy)

        spy.failRemove = true
        let rotated = await receive(push, 0x22, build: .sandbox, signed: .sandbox, spy: spy)
        XCTAssertEqual(rotated, .set(environment: .sandbox, source: .provisioningProfile, previous: .removalFailed))

        // The new pusher is the registered one; a later removal targets it.
        spy.failRemove = false
        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(spy.calls.last, .remove(pushkey: hex(0x22), appID: devAppID))
    }

    // MARK: Environment selection

    func testProfileDrivesEnvironmentSelectionWithTheBuildFlagAsCrossCheck() {
        let development = Self.profile(apsEnvironment: "development")
        let production = Self.profile(apsEnvironment: "production")
        XCTAssertEqual(MobileProvisioningProfile.apnsEnvironment(inProfile: development), .sandbox)
        XCTAssertEqual(MobileProvisioningProfile.apnsEnvironment(inProfile: production), .production)
        XCTAssertNil(MobileProvisioningProfile.apnsEnvironment(inProfile: Data()))
        XCTAssertNil(MobileProvisioningProfile.apnsEnvironment(inProfile: Data("not a profile".utf8)))
        XCTAssertNil(MobileProvisioningProfile.apnsEnvironment(inProfile: Self.profile(apsEnvironment: "invalid")))

        // A matching signed profile wins, with the build flag confirming it.
        XCTAssertEqual(MobilePushEnvironmentPolicy.decide(build: .sandbox, signed: .sandbox),
                       .use(.sandbox, source: .provisioningProfile))
        XCTAssertEqual(MobilePushEnvironmentPolicy.decide(build: .production, signed: .production),
                       .use(.production, source: .provisioningProfile))
        // No readable profile (simulator, unsigned assembly): the build flag
        // is the only signal, as before.
        XCTAssertEqual(MobilePushEnvironmentPolicy.decide(build: .sandbox, signed: nil),
                       .use(.sandbox, source: .buildFlag))
        XCTAssertEqual(MobilePushEnvironmentPolicy.decide(build: .production, signed: nil),
                       .use(.production, source: .buildFlag))
    }

    func testMismatchedSignedEnvironmentRegistersNothing() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()

        // Development-signed Release build: the profile says development, the
        // build (Release) says production. Registering would hand a sandbox
        // token to the production app ID.
        let outcome = await receive(push, 0x11, build: .production, signed: .sandbox, spy: spy)
        XCTAssertEqual(outcome, .refused(reason: .provisioningProfileMismatch))
        XCTAssertTrue(spy.calls.isEmpty)

        // Nothing was registered, so nothing is removed on sign-out.
        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .nothingRegistered)
        XCTAssertTrue(spy.calls.isEmpty)

        // A previous registration survives a refused attempt untouched.
        _ = await receive(push, 0x22, build: .sandbox, signed: .sandbox, spy: spy)
        let refused = await receive(push, 0x33, build: .production, signed: .sandbox, spy: spy)
        XCTAssertEqual(refused, .refused(reason: .provisioningProfileMismatch))
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x22), appID: devAppID)])
        let removedAfterRefusal = await push.signOut(using: spy)
        XCTAssertEqual(removedAfterRefusal, .removed)
        XCTAssertEqual(spy.calls.last, .remove(pushkey: hex(0x22), appID: devAppID))
    }

    func testCoordinatorRegistersTheProfileDerivedEnvironment() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        let signed = MobileProvisioningProfile.apnsEnvironment(inProfile: Self.profile(apsEnvironment: "development"))
        XCTAssertEqual(signed, .sandbox)

        let outcome = await receive(push, 0x5a, build: .sandbox, signed: signed, spy: spy)
        XCTAssertEqual(outcome, .set(environment: .sandbox, source: .provisioningProfile, previous: .none))
        XCTAssertEqual(spy.calls, [.set(pushkey: hex(0x5a), appID: devAppID)])
    }

    // MARK: Contract fixtures and closed outcomes

    func testFixtureRegistrationDrivesSetThenRemovalThroughTheCoordinator() async throws {
        let fixtures = try NativePushFixtures()
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixtures.data("pusher-set-dev.request.json")) as? [String: Any])
        let pushkey = try XCTUnwrap(raw["pushkey"] as? String)
        let appID = try XCTUnwrap(raw["app_id"] as? String)
        let bytes = try XCTUnwrap(Data(hexEncoded: pushkey))

        let spy = TransportSpy()
        let push = MobilePushCoordinator()
        let registered = await push.receive(tokenBytes: bytes, build: .sandbox, signed: .sandbox,
                                            device: .iPhone, locale: .vi, using: spy)
        XCTAssertEqual(registered, .set(environment: .sandbox, source: .provisioningProfile, previous: .none))
        XCTAssertEqual(spy.calls, [.set(pushkey: pushkey, appID: appID)])

        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(spy.calls.last, .remove(pushkey: pushkey, appID: appID))

        // No outcome description ever carries token material.
        XCTAssertFalse(String(describing: registered).contains(String(pushkey.prefix(8))))
        XCTAssertFalse(String(describing: removed).contains(String(pushkey.prefix(8))))
    }

    func testTransportAndTokenFailuresStayClosedAndCarryNoErrorText() async {
        let spy = TransportSpy()
        let push = MobilePushCoordinator()

        // Bytes that are not a device token never reach the transport.
        let invalid = await push.receive(tokenBytes: Data([0x00, 0x01]), build: .sandbox,
                                         signed: .sandbox, device: .iPhone, locale: .vi, using: spy)
        XCTAssertEqual(invalid, .invalidToken)
        XCTAssertTrue(spy.calls.isEmpty)

        // A failed set leaves no registration behind and echoes no error text.
        spy.failSet = true
        let failed = await push.receive(tokenBytes: Data(repeating: 0x33, count: 32), build: .sandbox,
                                        signed: .sandbox, device: .iPhone, locale: .vi, using: spy)
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(String(describing: failed), "failed")
        XCTAssertFalse(String(describing: failed).contains(hex(0x33).prefix(8)))
        let removed = await push.signOut(using: spy)
        XCTAssertEqual(removed, .nothingRegistered)

        // Rotation outcomes also carry only closed values.
        spy.failSet = false
        _ = await push.receive(tokenBytes: Data(repeating: 0x44, count: 32), build: .sandbox,
                               signed: .sandbox, device: .iPhone, locale: .vi, using: spy)
        let refused = await push.receive(tokenBytes: Data(repeating: 0x55, count: 32), build: .production,
                                         signed: .sandbox, device: .iPhone, locale: .vi, using: spy)
        XCTAssertEqual(refused, .refused(reason: .provisioningProfileMismatch))
        XCTAssertFalse(String(describing: refused).contains(hex(0x55).prefix(8)))
    }

    // MARK: Helpers

    /// Synthetic profile bytes: a CMS envelope keeps the property list
    /// verbatim, so the reader must find it between arbitrary DER bytes.
    private static func profile(apsEnvironment value: String) -> Data {
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>Synthetic Profile</string>
        <key>Entitlements</key><dict>
        <key>application-identifier</key><string>TEAMID.com.atum.mobile</string>
        <key>aps-environment</key><string>\(value)</string>
        </dict>
        </dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09, 0x2a, 0x86])
        data.append(Data(payload.utf8))
        data.append(Data([0x00, 0x00, 0xa0, 0x82]))
        return data
    }
}

private extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
