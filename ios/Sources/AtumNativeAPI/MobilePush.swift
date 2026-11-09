import Foundation

/// APNs environments, independent of StoreKit's transaction environment.
/// TestFlight always uses production APNs; development-signed builds use sandbox.
public enum MobileAPNSEnvironment: Sendable {
    case sandbox, production
    public var appID: String { self == .sandbox ? "com.atum.mobile.ios.dev" : "com.atum.mobile.ios.prod" }
    init(appID: String) throws {
        switch appID {
        case "com.atum.mobile.ios.dev": self = .sandbox
        case "com.atum.mobile.ios.prod": self = .production
        default: throw ContractViolation.invalidValue
        }
    }
}

public extension MobileAPNSEnvironment {
    /// Development-signed Debug builds talk to the APNs sandbox; Release builds
    /// (TestFlight, App Store) talk to production APNs.
    static func forBuild(isDebug: Bool) -> MobileAPNSEnvironment { isDebug ? .sandbox : .production }
}

public enum MobilePushDevice: String, Decodable, Sendable { case iPhone, iPad }
public enum MobilePushLocale: String, Decodable, Sendable {
    case vi, en, zh, ja, zhHant = "zh-hant"

    /// Maps a preferred-language tag (for example `vi-VN`, `zh-Hant-TW`) to
    /// the five product locales. Vietnamese is the default.
    public init(languageTag: String) {
        let tag = languageTag.lowercased().replacingOccurrences(of: "_", with: "-")
        if tag.hasPrefix("zh") {
            let traditional = tag.contains("hant") || tag.hasSuffix("-tw") || tag.hasSuffix("-hk") || tag.hasSuffix("-mo")
            self = traditional ? .zhHant : .zh
        } else if tag.hasPrefix("en") {
            self = .en
        } else if tag.hasPrefix("ja") {
            self = .ja
        } else {
            self = .vi
        }
    }
}

/// The pusher the SDK sets, taken field by field from the contract-b body
/// that `MobilePush.register` builds, so both stay one definition.
public struct MobilePusherFields: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let appID: String
    public let pushkey: String
    public let appDisplayName: String
    public let deviceDisplayName: String
    public let lang: String
    public let url: String
    public let format: String
    /// Canonical JSON of the generic default payload (never message text).
    public let defaultPayloadJSON: String
    public var description: String { "MobilePusherFields(app_id: \(appID), pushkey withheld)" }
    public var debugDescription: String { description }
}

/// Opaque routing material, never a chosen device name or a log value.
public struct APNsDeviceToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let hex: String
    public init(bytes: Data) throws {
        try self.init(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }
    fileprivate init(hex: String) throws {
        self.hex = try checkedString(hex, minimum: 64, maximum: 200, pattern: "[0-9a-f]+")
    }
    public var description: String { "APNs device token (withheld)" }
    public var debugDescription: String { description }
}

/// Consumer of the frozen contract-b wire, with no registration or transport.
public enum MobilePush {
    public static let gateway = "https://push.atumplatform.com/_matrix/push/v1/notify"
    private static let credentialFields: Set<String> = ["accessToken", "refreshToken", "token", "credential", "password", "leaseToken", "recoveryKey"]
    private static let contentFields: Set<String> = ["content", "sender", "sender_display_name", "room_name", "room_alias", "body", "title", "subtitle", "avatar_url", "msgtype", "user_id"]

    public static func payload(_ data: Data) throws -> MobilePushPayload {
        try NativeAPI.decode(MobilePushPayload.self, from: data, forbidden: credentialFields.union(contentFields))
    }
    public static func registration(_ data: Data) throws -> MobilePusherRegistration {
        try NativeAPI.decode(MobilePusherRegistration.self, from: data, forbidden: credentialFields)
    }
    public static func removal(_ data: Data) throws -> MobilePusherRemoval {
        try NativeAPI.decode(MobilePusherRemoval.self, from: data, forbidden: credentialFields)
    }
    public static func register(token: APNsDeviceToken, environment: MobileAPNSEnvironment,
                                device: MobilePushDevice, locale: MobilePushLocale) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "kind": "http", "app_id": environment.appID, "pushkey": token.hex,
            "app_display_name": "Atum", "device_display_name": device.rawValue, "lang": locale.rawValue, "append": false,
            "data": ["url": gateway, "format": "event_id_only",
                     "default_payload": ["aps": ["mutable-content": 1, "alert": ["loc-key": "ATUM_NEW_MESSAGE"]]]]
        ], options: .sortedKeys)
    }
    /// The same registration as `register`, split into the fields the SDK's
    /// set-pusher call takes. The body is re-validated against the contract.
    public static func pusherFields(token: APNsDeviceToken, environment: MobileAPNSEnvironment,
                                    device: MobilePushDevice, locale: MobilePushLocale) throws -> MobilePusherFields {
        let body = try register(token: token, environment: environment, device: device, locale: locale)
        _ = try registration(body)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let appID = json["app_id"] as? String, let pushkey = json["pushkey"] as? String,
              let appName = json["app_display_name"] as? String, let deviceName = json["device_display_name"] as? String,
              let lang = json["lang"] as? String, let data = json["data"] as? [String: Any],
              let url = data["url"] as? String, let format = data["format"] as? String,
              let payload = data["default_payload"] else { throw ContractViolation.invalidValue }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        return MobilePusherFields(appID: appID, pushkey: pushkey, appDisplayName: appName,
                                  deviceDisplayName: deviceName, lang: lang, url: url, format: format,
                                  defaultPayloadJSON: String(decoding: payloadData, as: UTF8.self))
    }
    public static func remove(token: APNsDeviceToken, environment: MobileAPNSEnvironment) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": NSNull(), "app_id": environment.appID, "pushkey": token.hex], options: .sortedKeys)
    }
}

/// Unknown future non-content fields are ignored, as contract b §11 requires.
/// Recursive content/credential fields are refused before this decoder runs.
public struct MobilePushPayload: Decodable, Equatable, Sendable {
    public let roomID: MatrixRoomID, eventID: MatrixEventID
    public let unreadCount, missedCalls, badge: Int64?
    public let localizationKey: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        roomID = try c.value("room_id"); eventID = try c.value("event_id")
        unreadCount = c.contains(Field("unread_count")) ? try c.integer("unread_count") : nil
        missedCalls = c.contains(Field("missed_calls")) ? try c.integer("missed_calls") : nil
        let aps = try c.value("aps", as: APS.self)
        badge = aps.badge; localizationKey = aps.alert.localizationKey
    }
    private struct APS: Decodable {
        let badge: Int64?
        let alert: Alert
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            guard try c.integer("mutable-content") == 1 else { throw ContractViolation.invalidValue }
            badge = c.contains(Field("badge")) ? try c.integer("badge") : nil
            alert = try c.value("alert")
        }
    }
    private struct Alert: Decodable {
        let localizationKey: String
        init(from decoder: Decoder) throws {
            localizationKey = try decoder.container(keyedBy: Field.self).string("loc-key", minimum: 1, maximum: 64, pattern: "[A-Z][A-Z0-9_]*")
        }
    }
}

public struct MobilePusherRegistration: Decodable, Sendable {
    public let token: APNsDeviceToken
    public let environment: MobileAPNSEnvironment
    public let device: MobilePushDevice
    public let locale: MobilePushLocale
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["kind", "app_id", "pushkey", "app_display_name", "device_display_name", "lang", "append", "data"])
        guard try c.value("kind", as: String.self) == "http",
              try c.value("app_display_name", as: String.self) == "Atum",
              try c.value("append", as: Bool.self) == false else { throw ContractViolation.invalidValue }
        token = try APNsDeviceToken(hex: c.value("pushkey"))
        environment = try MobileAPNSEnvironment(appID: c.value("app_id"))
        device = try c.value("device_display_name"); locale = try c.value("lang")
        _ = try c.value("data", as: PusherData.self)
    }
    private struct PusherData: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["url", "format", "default_payload"])
            guard try c.value("url", as: String.self) == MobilePush.gateway,
                  try c.value("format", as: String.self) == "event_id_only" else { throw ContractViolation.invalidValue }
            _ = try c.value("default_payload", as: DefaultPayload.self)
        }
    }
    private struct DefaultPayload: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["aps"])
            _ = try c.value("aps", as: DefaultAPS.self)
        }
    }
    private struct DefaultAPS: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["mutable-content", "alert"])
            guard try c.integer("mutable-content") == 1 else { throw ContractViolation.invalidValue }
            _ = try c.value("alert", as: DefaultAlert.self)
        }
    }
    private struct DefaultAlert: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["loc-key"])
            _ = try c.string("loc-key", minimum: 1, maximum: 64, pattern: "[A-Z][A-Z0-9_]*")
        }
    }
}

public struct MobilePusherRemoval: Decodable, Sendable {
    public let token: APNsDeviceToken
    public let environment: MobileAPNSEnvironment
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["kind", "app_id", "pushkey"])
        guard try c.nullable("kind", as: String.self) == nil else { throw ContractViolation.invalidValue }
        token = try APNsDeviceToken(hex: c.value("pushkey"))
        environment = try MobileAPNSEnvironment(appID: c.value("app_id"))
    }
}
