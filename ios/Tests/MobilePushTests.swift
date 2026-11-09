import XCTest
import Foundation
import AtumNativeAPI
import AtumPrototype

final class MobilePushTests: XCTestCase {
    private func edited(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: NativePushFixtures().data("apns.payload.json")) as? [String: Any])
        edit(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }
    func testEverySelectedProviderDisposition() throws {
        let fixtures = try NativePushFixtures()
        for entry in fixtures.manifest.fixtures {
            let data = try fixtures.data(entry.file)
            let decode: () throws -> Void = {
                switch entry.message {
                case "pusher.set.request": _ = try MobilePush.registration(data)
                case "pusher.delete.request": _ = try MobilePush.removal(data)
                case "apns.payload": _ = try MobilePush.payload(data)
                default: XCTFail("Unimplemented selected push message")
                }
            }
            if entry.expect == "accept" { XCTAssertNoThrow(try decode(), entry.file) }
            else { XCTAssertEqual(entry.expect, "reject"); XCTAssertThrowsError(try decode(), entry.file) }
        }
        XCTAssertThrowsError(try fixtures.data("../../contract.json"))
    }
    func testNativeTokenBuildsBothEnvironmentBodiesAndExplicitRemoval() throws {
        let fixtures = try NativePushFixtures()
        for file in ["pusher-set-prod.request.json", "pusher-set-dev.request.json"] {
            let source = try fixtures.data(file)
            let decoded = try MobilePush.registration(source)
            let body = try MobilePush.register(token: decoded.token, environment: decoded.environment, device: decoded.device, locale: decoded.locale)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: source) as? NSDictionary)
            let parsed = try MobilePush.registration(body)
            XCTAssertEqual(parsed.token, decoded.token)
            XCTAssertEqual(parsed.environment.appID, decoded.environment.appID)
            XCTAssertFalse(String(describing: decoded.token).contains("a3f1"))
        }
        let original = try MobilePush.removal(fixtures.data("pusher-delete.request.json"))
        let deleted = try MobilePush.removal(MobilePush.remove(token: original.token, environment: original.environment))
        XCTAssertEqual(deleted.token, original.token)
        XCTAssertEqual(deleted.environment.appID, original.environment.appID)
        let bytes = Data(repeating: 0xab, count: 32)
        let token = try APNsDeviceToken(bytes: bytes)
        for locale in [MobilePushLocale.vi, .en, .zh, .zhHant, .ja] {
            let request = try MobilePush.registration(MobilePush.register(token: token, environment: .production, device: .iPad, locale: locale))
            XCTAssertEqual(request.locale, locale)
            XCTAssertEqual(request.device, .iPad)
            XCTAssertEqual(request.environment.appID, "com.atum.mobile.ios.prod")
        }
        for length in [0, 31, 101] { XCTAssertThrowsError(try APNsDeviceToken(bytes: Data(repeating: 0, count: length))) }
        XCTAssertNoThrow(try APNsDeviceToken(bytes: Data(repeating: 0, count: 100)))
    }
    func testPayloadKeepsOnlyIDsAndIgnoresNonContentFutureFields() throws {
        let base = try NativePushFixtures().data("apns.payload.json")
        let payload = try MobilePush.payload(base)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: base) as? [String: Any])
        XCTAssertEqual(payload.roomID.rawValue, raw["room_id"] as? String)
        XCTAssertEqual(payload.eventID.rawValue, raw["event_id"] as? String)
        XCTAssertNil(payload.badge); XCTAssertNil(payload.missedCalls)
        let future = try edited { $0["future"] = ["version": 2, "items": ["non-content metadata"]] }
        XCTAssertEqual(try MobilePush.payload(future), payload)
        for key in ["body", "sender", "room_name", "title", "avatar_url", "user_id", "accessToken", "recoveryKey"] {
            let bad = try edited { $0["future"] = ["nested": [[key: "synthetic forbidden field"]]] }
            XCTAssertThrowsError(try MobilePush.payload(bad)) { XCTAssertEqual($0 as? ContractViolation, .forbiddenField) }
        }
    }
    func testPayloadIntegerIDAndAlertBounds() throws {
        for key in ["unread_count", "missed_calls"] {
            for bad in [-1, NativeAPI.maximumInteger + 1] {
                XCTAssertThrowsError(try MobilePush.payload(edited { $0[key] = bad }))
            }
            XCTAssertNoThrow(try MobilePush.payload(edited { $0[key] = NativeAPI.maximumInteger }))
            XCTAssertThrowsError(try MobilePush.payload(edited { $0[key] = NSNull() }))
        }
        for token in ["true", "3.0", "3e0"] {
            let source = String(decoding: try NativePushFixtures().data("apns.payload.json"), as: UTF8.self)
                .replacingOccurrences(of: "\"unread_count\": 3", with: "\"unread_count\": " + token)
            XCTAssertThrowsError(try MobilePush.payload(Data(source.utf8)))
        }
        for key in ["room_id", "event_id"] {
            for invalid in ["", "plain-id", String(repeating: "!", count: 1025), "!id with space"] {
                XCTAssertThrowsError(try MobilePush.payload(edited { $0[key] = invalid }))
            }
        }
        for bad in [0, 2, -1] {
            let data = try edited { var aps = $0["aps"] as! [String: Any]; aps["mutable-content"] = bad; $0["aps"] = aps }
            XCTAssertThrowsError(try MobilePush.payload(data))
        }
        for alert: Any in ["untrusted clear text", NSNull(), ["loc-key": "lowercase"], ["loc-key": String(repeating: "A", count: 65)]] {
            let data = try edited { var aps = $0["aps"] as! [String: Any]; aps["alert"] = alert; $0["aps"] = aps }
            XCTAssertThrowsError(try MobilePush.payload(data))
        }
        let withBadge = try edited { var aps = $0["aps"] as! [String: Any]; aps["badge"] = NativeAPI.maximumInteger; $0["aps"] = aps }
        XCTAssertEqual(try MobilePush.payload(withBadge).badge, NativeAPI.maximumInteger)
    }
    func testPusherCannotAddCredentialsOrReviveRemovalAsRegistration() throws {
        let fixtures = try NativePushFixtures()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures.data("pusher-set-dev.request.json")) as? [String: Any])
        json["data"] = ["url": MobilePush.gateway, "format": "event_id_only", "future": [["accessToken": "synthetic"]]]
        XCTAssertThrowsError(try MobilePush.registration(JSONSerialization.data(withJSONObject: json))) { XCTAssertEqual($0 as? ContractViolation, .forbiddenField) }
        XCTAssertThrowsError(try MobilePush.registration(fixtures.data("pusher-delete.request.json")))
        XCTAssertThrowsError(try MobilePush.removal(fixtures.data("pusher-set-dev.request.json")))
        var removal = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtures.data("pusher-delete.request.json")) as? [String: Any])
        removal.removeValue(forKey: "kind")
        XCTAssertThrowsError(try MobilePush.removal(JSONSerialization.data(withJSONObject: removal)))
    }
}
