import Foundation

/// The additive A38 report carried by the native roster read.
/// `spec/owner-time-zone/v1` owns the wire shape; this type only enforces it
/// locally so an invalid value never reaches a request header.
public enum OwnerTimeZoneContract {
    public static let requestHeader = "Atum-Time-Zone"
    public static let acknowledgementHeader = "Atum-Time-Zone-Ack"
    public static let maximumLength = 64

    private static let pattern =
        "^[A-Z][A-Za-z0-9_+-]{0,63}(/[A-Z][A-Za-z0-9_+-]{0,63}){0,2}$"

    /// The exact rule of `configuration.ts` / `render.py TIME_ZONE`: ASCII
    /// IANA grammar, at most 64 bytes, no offsets and no lowercase names.
    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
              let match = value.range(of: pattern, options: .regularExpression),
              match.lowerBound == value.startIndex, match.upperBound == value.endIndex
        else { return false }
        return true
    }
}

/// One roster read's captured account, session generation and sent zone. The
/// acknowledgement is recorded only against this exact context.
public struct OwnerTimeZoneReport: Equatable, Sendable {
    public let accountID: String
    public let sessionGeneration: UInt64
    public let zone: String
}

/// Per-account `lastAckedTimeZone` bookkeeping (A38 §1, phone).
///
/// The stored value survives account switches: it is keyed by account ID and
/// removed only by an explicit sign-out. A delayed response is discarded by
/// the generation check, so an old read cannot overwrite a newer account's
/// state.
@MainActor
public final class OwnerTimeZoneBookkeeper {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private var accountID: String?
    private var sessionGeneration: UInt64 = 0

    public init(defaults: UserDefaults = .standard,
                keyPrefix: String = "atum.owner-time-zone.acked.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Starts (or continues) one signed-in session. Repeating the same account
    /// is idempotent; changing accounts advances the generation so responses
    /// from the previous account can no longer record an ack.
    public func begin(accountID: String) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        sessionGeneration &+= 1
    }

    /// Ends the active session. An explicit sign-out clears this account's
    /// stored value; an involuntary end keeps it for the next sign-in.
    public func end(clearStoredValue: Bool) {
        sessionGeneration &+= 1
        if clearStoredValue, let accountID {
            defaults.removeObject(forKey: key(accountID))
        }
        accountID = nil
    }

    /// The zone to send on the next roster read, or nil when there is nothing
    /// to report (no account, invalid device zone, or already acknowledged).
    public func report(deviceTimeZone: String) -> OwnerTimeZoneReport? {
        guard let accountID, OwnerTimeZoneContract.isValid(deviceTimeZone) else { return nil }
        guard defaults.string(forKey: key(accountID)) != deviceTimeZone else { return nil }
        return OwnerTimeZoneReport(accountID: accountID,
                                   sessionGeneration: sessionGeneration,
                                   zone: deviceTimeZone)
    }

    /// Stores the zone only when the acknowledgement echoes it and the
    /// response still belongs to this account and session generation.
    public func record(_ report: OwnerTimeZoneReport?, acknowledgement: String?) {
        guard let report, let acknowledgement,
              acknowledgement == report.zone,
              OwnerTimeZoneContract.isValid(acknowledgement),
              report.accountID == accountID,
              report.sessionGeneration == sessionGeneration else { return }
        defaults.set(acknowledgement, forKey: key(report.accountID))
    }

    public func acknowledgedZone(accountID: String) -> String? {
        defaults.string(forKey: key(accountID))
    }

    private func key(_ accountID: String) -> String {
        keyPrefix + accountID
    }
}

/// The one observer added for A38. A system time-zone change triggers the
/// caller's existing foreground refresh; there is no timer and no retry loop.
/// The injected center keeps the wiring testable.
@MainActor
public final class OwnerTimeZoneChangeObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    public init(center: NotificationCenter = .default) {
        self.center = center
    }

    public func start(handler: @escaping @MainActor @Sendable () -> Void) {
        guard token == nil else { return }
        token = center.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange,
                                   object: nil, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
    }

    public func stop() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
