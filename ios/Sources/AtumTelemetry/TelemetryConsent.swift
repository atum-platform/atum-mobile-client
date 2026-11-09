import CryptoKit
import Foundation

/// Local reporting preferences. Both switches are ON for a fresh install; a
/// recorded `false` survives relaunch and upgrade. A missing or unreadable
/// value is the distributed default (ON), never an inferred opt-out.
public final class TelemetryConsent {
    public static let crashReportsKey = "com.atum.mobile.reporting.crash-reports-enabled"
    public static let usageDataKey = "com.atum.mobile.reporting.usage-data-enabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var crashReportsEnabled: Bool { read(TelemetryConsent.crashReportsKey) }
    public var usageDataEnabled: Bool { read(TelemetryConsent.usageDataKey) }

    public func setCrashReportsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: TelemetryConsent.crashReportsKey)
    }

    public func setUsageDataEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: TelemetryConsent.usageDataKey)
    }

    private func read(_ key: String) -> Bool {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return true
        }
        return value.boolValue
    }
}

/// Anonymous analytics identifiers. The raw installation UUID never leaves the
/// phone; PostHog receives a 32-character SHA-256-derived diagnostic ID, exactly
/// as the desktop reports its own installation.
public enum TelemetryInstallation {
    public static let identifierKey = "com.atum.mobile.reporting.installation-id"

    public static func loadOrCreate(in defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: identifierKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = UUID()
        defaults.set(created.uuidString.lowercased(), forKey: identifierKey)
        return created
    }

    public static func analyticsID(for installation: UUID) -> String {
        let seed = Data(("atum-analytics-v1\0" + installation.uuidString.lowercased()).utf8)
        let hex = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }
}

/// The first-message marker is claimed once per installation. Turning analytics
/// off before the first message leaves the marker unclaimed, so a later opt-in
/// can still report the real first send.
public final class TelemetryFirstEventStore {
    public static let firstMessageSentKey = "com.atum.mobile.reporting.first-message-sent"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasClaimedFirstMessageSent: Bool {
        defaults.bool(forKey: TelemetryFirstEventStore.firstMessageSentKey)
    }

    public func claimFirstMessageSent() -> Bool {
        guard !hasClaimedFirstMessageSent else {
            return false
        }
        defaults.set(true, forKey: TelemetryFirstEventStore.firstMessageSentKey)
        return true
    }
}
