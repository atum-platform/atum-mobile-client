import Foundation

/// Small, platform-neutral policies shared by the live iOS adapter and its
/// host tests. These values are behavior contracts, not Matrix credentials or
/// SDK state.
public enum MobileMatrixVerificationStatus: Equatable, Sendable {
    case unknown
    case verified
    case unverified
}

public enum MobileMatrixTrustPolicy {
    /// Only an affirmative SDK verification result can authorize a send.
    public static func canSend(_ status: MobileMatrixVerificationStatus) -> Bool {
        status == .verified
    }
}

public enum MobileMatrixSASFormat: Equatable, Sendable {
    case emoji
    case decimal
}

public enum MobileMatrixSASPolicy {
    /// Matrix SAS is exactly seven emoji or three decimal values. Refuse any
    /// incomplete or future shape until the client deliberately supports it.
    public static func isComplete(format: MobileMatrixSASFormat, count: Int) -> Bool {
        switch format {
        case .emoji: count == 7
        case .decimal: count == 3
        }
    }

    /// The Matrix emoji SAS indices contain the same leading bits as the
    /// standard three-value decimal SAS. The pinned Swift SDK prefers the
    /// negotiated emoji callback and supplies those authenticated indices, so
    /// convert the representation without inventing or truncating a code.
    public static func decimals(fromEmojiIndices indices: [UInt8]) -> [UInt16]? {
        guard indices.count == 7, indices.allSatisfy({ $0 <= 63 }) else {
            return nil
        }

        let values = indices.map(UInt16.init)
        let byte0 = (values[0] << 2) | (values[1] >> 4)
        let byte1 = ((values[1] & 0x0f) << 4) | (values[2] >> 2)
        let byte2 = ((values[2] & 0x03) << 6) | values[3]
        let byte3 = (values[4] << 2) | (values[5] >> 4)
        let byte4 = ((values[5] & 0x0f) << 4) | (values[6] >> 2)

        return decimals(fromSASBytes: [UInt8(byte0), UInt8(byte1), UInt8(byte2),
                                       UInt8(byte3), UInt8(byte4)])
    }

    /// Matrix Client-Server API SAS decimal representation: split the first
    /// five HKDF bytes into three 13-bit values and add 1000 to each.
    public static func decimals(fromSASBytes bytes: [UInt8]) -> [UInt16]? {
        guard bytes.count == 5 else { return nil }
        let values = bytes.map(UInt16.init)
        return [
            ((values[0] << 5) | (values[1] >> 3)) + 1_000,
            (((values[1] & 0x07) << 10) | (values[2] << 2) | (values[3] >> 6)) + 1_000,
            (((values[3] & 0x3f) << 7) | (values[4] >> 1)) + 1_000
        ]
    }

    public static func validatedDecimals(_ values: [UInt16]) -> [UInt16]? {
        guard values.count == 3,
              values.allSatisfy({ (1_000...9_191).contains($0) }) else {
            return nil
        }
        return values
    }
}

public enum MobileMatrixVerificationPolicy {
    /// Each human-controlled leg may wait this long. The access grant must
    /// outlive both legs plus a small transport/refresh margin before a new
    /// ceremony starts; otherwise the phone can expire after the Mac accepts
    /// but before SAS symbols arrive.
    public static let phaseTimeoutSeconds: TimeInterval = 120
    public static let minimumSessionLifetimeSeconds: TimeInterval =
        (phaseTimeoutSeconds * 2) + 30

    public static func requiresRefresh(expiresAt: Date, now: Date) -> Bool {
        let remaining = expiresAt.timeIntervalSince(now)
        return !remaining.isFinite || remaining <= minimumSessionLifetimeSeconds
    }
}

public enum MobileMatrixHistoryPolicy {
    public static let initialPageCount = 4
    public static let initialPageSize: UInt16 = 50
    public static let maximumInitialEventCount = initialPageCount * Int(initialPageSize)
}

public enum MobileMatrixLeasePolicy {
    /// Pinned candidate SDK lease duration and the same release margin used by
    /// its cross-process restore conformance tests.
    public static let sdkLeaseMilliseconds: Int64 = 500
    public static let reopenDelayMilliseconds: Int64 = 750
}

/// The desktop-owned global account-data preference for one app's roster
/// shortcut. Canonical event type and content come from atum-app
/// `apps/desktop/src/matrix/app-shortcuts.ts`: `io.atum.app_shortcut.<appId>`
/// (lowercased app UUID) with `{version: 1, visibility: "shown"|"hidden"}`.
/// Unknown extra fields are presentation-additive and ignored here.
public enum MobileAppShortcutPolicy {
    public enum Visibility: String, Sendable {
        case shown
        case hidden
    }

    public static let prefix = "io.atum.app_shortcut."

    /// The exact global account-data event type, or nil for a malformed app
    /// ID. The catalog decoder already normalizes valid IDs; this boundary is
    /// still closed so no caller can synthesize an arbitrary event name.
    public static func eventType(appID: String) -> String? {
        let value = appID.lowercased()
        guard value.range(of: "\\A(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\\z",
                          options: .regularExpression) != nil else {
            return nil
        }
        return prefix + value
    }

    /// One successful read of the synchronized SDK state store. Nil content
    /// means "no event" (`absent`) only after this local session is ready and
    /// has completed its initial sync; before that point the same nil is a
    /// cache miss and callers keep the state `unknown`. Malformed content is
    /// always `unknown`, never a guessed default.
    public static func state(contentJSON: String?) -> MobileAppShortcutState {
        guard let contentJSON else { return .absent }
        struct Content: Decodable {
            let version: Int
            let visibility: String
        }
        guard let data = contentJSON.data(using: .utf8),
              let content = try? JSONDecoder().decode(Content.self, from: data),
              content.version == 1,
              let visibility = Visibility(rawValue: content.visibility) else {
            return .unknown
        }
        return visibility == .shown ? .shown : .hidden
    }

    /// Canonical v1 write body shared with the desktop. The closed enum is the
    /// only interpolated value, so this cannot become an arbitrary account-data
    /// writer.
    public static func contentJSON(visibility: Visibility) -> String {
        #"{"version":1,"visibility":"\#(visibility.rawValue)"}"#
    }
}

/// What the phone knows about the person's explicit app-shortcut choice.
/// `.absent` is only produced by a successful synchronized-store read with no
/// event after the local session is ready and has completed its initial sync.
/// `.unknown` covers pre-sync cache misses, loading, wrong-account/session
/// reads and malformed content; every consumer fails closed on it.
public enum MobileAppShortcutState: Equatable, Sendable {
    case unknown
    case absent
    case shown
    case hidden
}

/// Result of one explicit shortcut preference write. A write is successful to
/// the UI only after the synchronized SDK store reads back the exact requested
/// v1 value. `unconfirmed` is intentionally not success: the server may have
/// accepted the request while this device's cache is still stale.
public enum MobileAppShortcutWriteOutcome: Equatable, Sendable {
    case confirmed
    case unconfirmed
    case failed
    case stale
}

/// Narrow, testable write/readback sequence for the existing Matrix SDK
/// account-data API. The caller owns both fences: the runtime fence around the
/// SDK client and the account/session/generation fence around publication.
@MainActor
public enum MobileAppShortcutWritePolicy {
    public static func perform(
        visibility: MobileAppShortcutPolicy.Visibility,
        attempts: Int = 5,
        write: @MainActor (String) async throws -> Void,
        read: @MainActor () async throws -> String?,
        pause: @MainActor () async -> Void,
        isCurrent: @MainActor () -> Bool
    ) async -> MobileAppShortcutWriteOutcome {
        guard isCurrent() else { return .stale }
        do {
            try await write(MobileAppShortcutPolicy.contentJSON(visibility: visibility))
        } catch {
            return isCurrent() ? .failed : .stale
        }
        guard isCurrent() else { return .stale }

        let expected: MobileAppShortcutState = visibility == .shown ? .shown : .hidden
        for attempt in 0..<max(1, attempts) {
            do {
                let observed = MobileAppShortcutPolicy.state(contentJSON: try await read())
                guard isCurrent() else { return .stale }
                if observed == expected { return .confirmed }
            } catch {
                guard isCurrent() else { return .stale }
            }
            if attempt + 1 < max(1, attempts) { await pause() }
        }
        return .unconfirmed
    }
}

/// One fenced refresh pass of the explicit app-shortcut preferences. The
/// pinned SDK exposes only a synchronized state-store read, not a network
/// fetch or a custom-event observer, so a nil result before this local
/// session has completed its initial sync is a cache miss, not proof of
/// absence. Before that point every candidate stays `.unknown`, any previous
/// value is discarded, and no read is attempted. `isCurrent` must fence the
/// account, runtime, session and readiness that started the pass; a read that
/// loses the fence is dropped entirely instead of publishing a late result.
@MainActor
public enum MobileAppShortcutRefreshPolicy {
    public static func states(
        existing: [AppCatalogID: MobileAppShortcutState],
        candidates: [AppCatalogID],
        canReadCachedAccountData: Bool,
        read: @MainActor (AppCatalogID) async -> MobileAppShortcutState,
        isCurrent: @MainActor () -> Bool
    ) async -> [AppCatalogID: MobileAppShortcutState]? {
        let ids = Set(candidates)
        var states = existing.filter { ids.contains($0.key) }
        for id in candidates where states[id] == nil {
            states[id] = .unknown
        }
        guard canReadCachedAccountData else {
            for id in candidates {
                states[id] = .unknown
            }
            return states
        }
        for id in candidates {
            let state = await read(id)
            guard isCurrent() else { return nil }
            if states[id] != state {
                states[id] = state
            }
        }
        return states
    }
}

public enum MobileAppRosterPolicy {
    /// One row the effective server roster asks this phone to draw.
    public enum Entry: Equatable, Sendable {
        /// An available app. A bot entry still needs an existing chat to open;
        /// the phone never creates or guesses one.
        case shortcut(AppDescriptor)
        /// Presentation-only catalog entry. It has no bot, room, launch,
        /// consent or link operation and stays inert.
        case comingSoon(AppDescriptor)

        public var app: AppDescriptor {
            switch self {
            case let .shortcut(app), let .comingSoon(app): app
            }
        }
    }

    /// The server's effective default roster with the person's explicit
    /// Matrix account-data choice applied first:
    ///
    /// - `hidden` always removes the app row;
    /// - `shown` keeps an eligible live or coming-soon row even when the
    ///   server default is false;
    /// - `absent` follows effective `roster_default` (or an explicit
    ///   `m.favourite` pin on the chosen chat);
    /// - `unknown`/loading never guesses a default and removes the row.
    ///
    /// `roster_default` is the only source of default inclusion: bot
    /// identities no longer bypass it. The client's old three-entry suggestion
    /// cap is deliberately gone; the effective server default owns the set.
    /// `roster_order` and then the app UUID order the rows. Consumed app rows
    /// are excluded exactly as before.
    public static func entries(
        from apps: [AppDescriptor],
        excluding consumed: Set<AppCatalogID> = [],
        pinned: Set<AppCatalogID> = [],
        shortcuts: [AppCatalogID: MobileAppShortcutState] = [:]
    ) -> [Entry] {
        let sorted = apps.sorted { left, right in
            left.rosterOrder == right.rosterOrder
                ? left.appID.rawValue < right.appID.rawValue
                : left.rosterOrder < right.rosterOrder
        }
        return sorted.compactMap { app in
            guard !consumed.contains(app.appID) else { return nil }
            let preference = shortcuts[app.appID] ?? .unknown
            let includeByDefault = app.rosterDefault || pinned.contains(app.appID)
            switch preference {
            case .hidden, .unknown:
                return nil
            case .shown:
                return entry(for: app)
            case .absent:
                guard includeByDefault else { return nil }
                return entry(for: app)
            }
        }
    }

    /// A catalog entry is eligible for a row only when it has a real
    /// presentation surface. A coming-soon entry is inert but eligible by
    /// design; an available app still cannot claim a surface it does not have.
    private static func entry(for app: AppDescriptor) -> Entry? {
        switch app.effectiveRosterState {
        case .comingSoon:
            return .comingSoon(app)
        case .available:
            if app.bot != nil {
                guard app.availability == .available else { return nil }
                return .shortcut(app)
            }
            guard app.availability == .available,
                  app.hasSurface || app.matrixRoomContext == .addressedOnly else {
                return nil
            }
            return .shortcut(app)
        }
    }

    public static func defaultRows(
        from apps: [AppDescriptor],
        excluding consumed: Set<AppCatalogID> = [],
        pinned: Set<AppCatalogID> = [],
        shortcuts: [AppCatalogID: MobileAppShortcutState] = [:]
    ) -> [AppDescriptor] {
        entries(from: apps, excluding: consumed, pinned: pinned, shortcuts: shortcuts).map(\.app)
    }
}

/// SDK-neutral recovery facts. `incomplete` means the account has a key
/// backup this phone has not opened yet; it never means the phone cannot chat.
public enum MobileMatrixRecoveryStatus: Equatable, Sendable {
    case unknown
    case ready
    case incomplete
    case unavailable
}

public enum MobileDeviceTrustPhase: Equatable, Sendable {
    case checking
    case actionRequired
    case ready
}

/// What the phone asks of its owner (0.19.4 quiet recovery). Only an
/// unverified phone has a required step. A verified phone whose old history is
/// still locked is ready: it may chat, and opening old messages with the
/// recovery key stays an optional, owner-started action.
public enum MobileDeviceTrustPolicy {
    public static func phase(verification: MobileMatrixVerificationStatus,
                             recovery _: MobileMatrixRecoveryStatus) -> MobileDeviceTrustPhase {
        switch verification {
        case .unknown: .checking
        case .unverified: .actionRequired
        case .verified: .ready
        }
    }

    /// A verified phone is never asked to verify again, whatever its history
    /// state: that repeat request is the nag the owner reported. An unknown
    /// state may still be resolved by an owner-started request.
    public static func shouldRequestVerification(
        verification: MobileMatrixVerificationStatus,
        recovery _: MobileMatrixRecoveryStatus
    ) -> Bool {
        verification != .verified
    }

    /// The single optional entry for opening old messages with the recovery key.
    /// 0.20: chats no longer depend on this phone being verified, so any phone
    /// whose account has a key backup it has not opened gets the entry.
    public static func offersHistoryRecovery(verification _: MobileMatrixVerificationStatus,
                                             recovery: MobileMatrixRecoveryStatus) -> Bool {
        recovery == .incomplete
    }
}

/// Closed log codes for the recovery-key step that decide what the owner sees.
public enum MobileRecoveryKeyFailureCode: String, Sendable, CaseIterable {
    /// The text is not shaped like a recovery key.
    case keyFormatInvalid = "sdk_recovery_key_invalid"
    /// The SDK's secret storage rejected the key: it is not this account's key.
    case keyRejected = "sdk_recovery_secret_storage"
    /// The key was accepted and saved; the phone is still opening old messages.
    case acceptedStillRestoring = "sdk_recovery_not_ready"
}

/// What the optional "restore messages" sheet shows after the owner's key
/// attempt fails. Only a key the SDK rejected is called a wrong key; an
/// accepted key that is still restoring is never reported as a failure; every
/// other error is a plain "try again" with the key field kept.
public enum MobileManualRecoveryKeyPolicy {
    public enum Presentation: Equatable, Sendable {
        case retryKey
        case stillRestoring
        case genericRetry
    }

    /// How long "restoring" stays after an accepted key before the sheet
    /// returns to its normal state.
    public static let pendingWaitSeconds: TimeInterval = 60

    public static func presentation(forFailureCode code: String) -> Presentation {
        switch MobileRecoveryKeyFailureCode(rawValue: code) {
        case .keyFormatInvalid, .keyRejected: .retryKey
        case .acceptedStillRestoring: .stillRestoring
        case nil: .genericRetry
        }
    }
}
