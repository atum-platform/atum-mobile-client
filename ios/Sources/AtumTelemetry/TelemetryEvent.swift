import Foundation

/// The three product events the phone reports. The name and properties are a
/// closed allowlist: no account, room, message or provider value can be added
/// by a call site.
public enum TelemetryEvent: Equatable, Sendable {
    public enum SignInOutcome: String, Equatable, Sendable {
        case completed
        case failed
        case cancelled
    }

    case appOpened
    case signInFinished(SignInOutcome)
    case firstMessageSent

    public var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .signInFinished: "signin_finished"
        case .firstMessageSent: "first_message_sent"
        }
    }

    public var signInOutcome: SignInOutcome? {
        guard case let .signInFinished(outcome) = self else { return nil }
        return outcome
    }

    public static let allowedNames: Set<String> = [
        "app_opened", "signin_finished", "first_message_sent",
    ]
}

/// Build configuration shared by both vendors. Values are sanitized before they
/// reach a payload; free text, paths and user identifiers are not accepted.
public struct TelemetryContext: Equatable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String
    public let environment: String

    public init(appVersion: String, buildNumber: String, osVersion: String, environment: String) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.environment = environment
    }
}

public enum TelemetrySanitizer {
    private static let distinctIDPattern = "^[0-9a-f]{32}$"
    private static let versionPattern = "^[0-9]+(?:\\.[0-9]+){0,2}(?:[-+][A-Za-z0-9.-]+)?$"
    private static let buildPattern = "^[0-9]{1,18}$"
    private static let osPattern = "^[0-9]+(?:\\.[0-9]+){0,3}$"
    private static let apiKeyPattern = "^[A-Za-z0-9._-]{8,200}$"

    public static func distinctID(_ value: String) -> String? {
        matches(distinctIDPattern, value) ? value : nil
    }

    public static func apiKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches(apiKeyPattern, trimmed) ? trimmed : nil
    }

    public static func version(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 32 && matches(versionPattern, trimmed) ? trimmed : "unknown"
    }

    public static func build(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches(buildPattern, trimmed) ? trimmed : "unknown"
    }

    public static func osVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 16 && matches(osPattern, trimmed) ? trimmed : "unknown"
    }

    public static func environment(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "production": "production"
        case "development": "development"
        default: "development"
        }
    }

    /// A source frame keeps only its file name. Framework paths, home
    /// directories and build-machine user names never leave the phone.
    public static func fileName(_ path: String) -> String {
        let cleaned = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned.count <= 120 else { return "unknown" }
        return cleaned
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A PostHog `/capture/` body. Only the allowlisted event, the anonymous
/// diagnostic ID and sanitized build facts are written. GeoIP enrichment is
/// disabled and `$ip` is sent as null so the capture endpoint does not derive a
/// location; the project must also discard client IP data (PostHog setting
/// "Discard client IP data").
public enum PostHogPayload {
    public static func capture(apiKey: String,
                               event: TelemetryEvent,
                               distinctID: String,
                               context: TelemetryContext,
                               timestamp: Date = Date()) -> Data? {
        guard let key = TelemetrySanitizer.apiKey(apiKey),
              let diagnosticID = TelemetrySanitizer.distinctID(distinctID),
              TelemetryEvent.allowedNames.contains(event.name) else {
            return nil
        }
        var properties: [String: Any] = [
            "$geoip_disable": true,
            "$ip": NSNull(),
            "$lib": "atum-mobile",
            "schema_version": 1,
            "app_version": TelemetrySanitizer.version(context.appVersion),
            "build_number": TelemetrySanitizer.build(context.buildNumber),
            "os_version": TelemetrySanitizer.osVersion(context.osVersion),
            "environment": TelemetrySanitizer.environment(context.environment),
        ]
        if let outcome = event.signInOutcome {
            properties["outcome"] = outcome.rawValue
        }
        let body: [String: Any] = [
            "api_key": key,
            "event": event.name,
            "distinct_id": diagnosticID,
            "timestamp": timestamp.ISO8601Format(),
            "properties": properties,
        ]
        guard JSONSerialization.isValidJSONObject(body) else { return nil }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
