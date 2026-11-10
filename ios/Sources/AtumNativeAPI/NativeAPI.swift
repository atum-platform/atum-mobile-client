import Foundation

/// Consumer of the frozen mobile-native-api/v1 pack. No transport or authority.
public enum NativeAPI {
    public static let maximumInteger: Int64 = 9_007_199_254_740_991

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: data, forbidden: ["accessToken", "refreshToken", "token", "credential", "password", "leaseToken", "recoveryKey"])
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, forbidden: Set<String>) throws -> T {
        // Agent entries explicitly permit future fields; credentials remain
        // forbidden at every nesting level, including in those future fields.
        let json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        try rejectFields(json, forbidden: forbidden)
        let decoder = JSONDecoder()
        decoder.userInfo[rawJSONKey] = json
        return try decoder.decode(type, from: data)
    }

    private static func rejectFields(_ value: Any, forbidden: Set<String>) throws {
        if let object = value as? [String: Any] {
            guard forbidden.isDisjoint(with: object.keys) else { throw ContractViolation.forbiddenField }
            for child in object.values { try rejectFields(child, forbidden: forbidden) }
        } else if let array = value as? [Any] {
            for child in array { try rejectFields(child, forbidden: forbidden) }
        }
    }
}

/// Deliberately carries no server body or rejected value into logs/UI.
public enum ContractViolation: Error, Equatable {
    case forbiddenField, unknownField, missingField, invalidValue, invariant, statusMismatch, retryAfterRequired
}

struct Field: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private let rawJSONKey = CodingUserInfoKey(rawValue: "AtumNativeAPI.rawJSON")!

struct WireInteger: Decodable {
    let value: Int64
    init(from decoder: Decoder) throws {
        // JSONDecoder accepts 1.0 as Int64. The frozen provider's checker
        // requires an integer token, so validate its actual NSNumber type at
        // this typed field without restricting future agent metadata numbers.
        guard var node = decoder.userInfo[rawJSONKey] else { throw ContractViolation.invalidValue }
        for key in decoder.codingPath {
            if let index = key.intValue, let array = node as? [Any], array.indices.contains(index) { node = array[index] }
            else if let object = node as? [String: Any], let child = object[key.stringValue] { node = child }
            else { throw ContractViolation.invalidValue }
        }
        guard let number = node as? NSNumber,
              !["d", "f", "c", "B"].contains(String(cString: number.objCType)) else { throw ContractViolation.invalidValue }
        value = try decoder.singleValueContainer().decode(Int64.self)
    }
}

extension KeyedDecodingContainer where Key == Field {
    func closed(_ fields: Set<String>) throws {
        guard Set(allKeys.map(\.stringValue)).isSubset(of: fields) else { throw ContractViolation.unknownField }
    }
    func value<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        try decode(type, forKey: Field(key))
    }
    func nullable<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard contains(Field(key)) else { throw ContractViolation.missingField }
        return try decodeIfPresent(type, forKey: Field(key))
    }
    func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard contains(Field(key)) else { return nil }
        // Optional means absent, not null, unless the schema explicitly says so.
        return try decode(type, forKey: Field(key))
    }
    /// Presentation metadata is allowed to evolve independently of the
    /// identity that carries it. Missing, null, unknown-enum and malformed
    /// presentation values all become absent without weakening required
    /// authority fields decoded by `value`, `nullable` and `integer`.
    func lossyNullable<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard contains(Field(key)) else { return nil }
        return try? decodeIfPresent(type, forKey: Field(key))
    }
    func integer(_ key: String, minimum: Int64 = 0) throws -> Int64 {
        let value = try value(key, as: WireInteger.self).value
        guard (minimum...NativeAPI.maximumInteger).contains(value) else { throw ContractViolation.invalidValue }
        return value
    }
    func nullableInteger(_ key: String, minimum: Int64 = 0) throws -> Int64? {
        guard contains(Field(key)) else { throw ContractViolation.missingField }
        guard try !decodeNil(forKey: Field(key)) else { return nil }
        let value = try decode(WireInteger.self, forKey: Field(key)).value
        guard (minimum...NativeAPI.maximumInteger).contains(value) else { throw ContractViolation.invalidValue }
        return value
    }
    func string(_ key: String, minimum: Int = 0, maximum: Int, pattern: String? = nil) throws -> String {
        try checkedString(value(key), minimum: minimum, maximum: maximum, pattern: pattern)
    }
}

/// An open list whose elements evolve independently. `superDecoder()` consumes
/// exactly one source element even when that element's typed decoder throws,
/// so one new companion, provider or malformed presentation row cannot erase
/// every known row. The recursive credential scan in `NativeAPI.decode` still
/// runs over the complete JSON value before any item is discarded.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let sourceCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values = [Element]()
        var count = 0
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            count += 1
            if let value = try? Element(from: elementDecoder) { values.append(value) }
        }
        elements = values
        sourceCount = count
    }
}

func checkedString(_ value: String, minimum: Int = 0, maximum: Int, pattern: String? = nil) throws -> String {
    // Provider bounds count Unicode scalars, matching its JSON conformance
    // implementation; Swift Character counts would admit longer combining text.
    guard (minimum...maximum).contains(value.unicodeScalars.count) else { throw ContractViolation.invalidValue }
    if let pattern, value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) == nil {
        throw ContractViolation.invalidValue
    }
    return value
}

public struct NativeID: Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        rawValue = try checkedString(value, minimum: 36, maximum: 36, pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct NativeHandle: Codable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        rawValue = try checkedString(value, minimum: 3, maximum: 32, pattern: "[a-z][a-z0-9_]{2,31}")
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct NativeMatrixUser: Decodable, Hashable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws {
        rawValue = try checkedString(value, minimum: 4, maximum: 1024, pattern: "@[!-9;-~]+:[!-~]+")
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
}

public struct NativeTimestamp: Decodable, Hashable, Sendable {
    public let rawValue: String
    public init(from decoder: Decoder) throws {
        rawValue = try checkedString(decoder.singleValueContainer().decode(String.self), minimum: 20, maximum: 40,
            pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}(:[0-9]{2})?)")
    }
    /// Preserve the wire value; date conversion is presentation, not identity.
    public var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawValue) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawValue)
    }
}

public enum MicroProtonFormat {
    /// Desktop wholeProtons: clamp to zero, then floor. Integer division keeps
    /// large balances exact and never rounds spendable value up.
    public static func balance(_ amount: Int64, locale: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, amount) / 1_000_000))!
    }

    public static func string(_ amount: Int64, locale: String, showPositiveSign: Bool = false) -> String {
        // All six fractional digits survive; no Double conversion or wallet
        // arithmetic from transaction-history rows.
        let number = NSDecimalNumber(decimal: Decimal(amount) / Decimal(1_000_000))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        if showPositiveSign && amount > 0 { formatter.positivePrefix = "+" }
        return formatter.string(from: number)!
    }
}

/// A failed read never replaces a last successful value with zero or emptiness.
/// Instances must be owned by a single authenticated account in the live lane.
public struct NativeRead<Value> {
    public enum Condition: Equatable, Sendable { case loading, fresh, offline, failed, unavailable }
    public private(set) var value: Value?
    public private(set) var condition = Condition.loading
    public init() {}
    public var isStale: Bool { value != nil && condition != .fresh }
    public mutating func receive(_ value: Value) { self.value = value; condition = .fresh }
    public mutating func fail(_ condition: Condition) {
        precondition(condition != .fresh)
        self.condition = condition
    }
    public mutating func clear() { value = nil; condition = .loading }
}
