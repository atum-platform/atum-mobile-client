import Foundation

/// W4 E3, as the coordinator decided it on 2026-10-11 (decision 5): a session
/// or custody failure never blocks the app or a chat. 0.20 agent, bot and new
/// people chats are plain rooms that need no keys; old encrypted history shows
/// its placeholders; the optional recovery row is offered quietly in Account
/// and the chat's info. Key custody state is never deleted or overwritten, so
/// a failure that custody alone could repair is never "fixed" by removing
/// anything: the phone keeps what it can show and tries again, and it never
/// spends the one-time refresh token when custody already holds a grant that
/// will do.
///
/// Before 0.20 any of these failures could land on a lock screen ("Thiết bị
/// này cần khôi phục.") whose only way out was a fresh sign-in, which custody
/// refuses while a record exists. Since coordinator decision 11 (2026-10-11)
/// a session custody can no longer renew shows the sign-in screen with an
/// expired-session notice; "Đăng nhập lại" moves the stranded records aside
/// (`StrandedSessionArchive`: never deleted or overwritten) and signs in as
/// a new installation beside them.
public enum MobileSessionContinuityPolicy {
    // MARK: Custody, read without spending

    /// What Matrix custody holds right now, read without spending anything
    /// (`MatrixSessionKeychain.resume(marker:)`).
    public enum CustodyGrant: Equatable, Sendable {
        /// A ready grant: its access token expires at this time.
        case ready(expiresAt: Date)
        /// Custody holds a record but will not hand out a grant: a refresh
        /// spend journaled and never finished (the hotfix's stranding risk),
        /// an unfinished preparation, or a record from another installation.
        /// No automatic retry can change it, and nothing removes it.
        case refused
        /// The keychain could not be read just now (locked, busy).
        case unreadable
    }

    /// Classifies a custody read. `read` returns the ready grant's expiry or
    /// throws what custody throws.
    public static func custodyGrant(reading read: () throws -> Date) -> CustodyGrant {
        do {
            return .ready(expiresAt: try read())
        } catch MatrixCustodyFailure.storageUnavailable {
            return .unreadable
        } catch OIDCGrantFailure.storageUnavailable {
            return .unreadable
        } catch {
            return .refused
        }
    }

    // MARK: Renewing the runtime

    /// How a runtime replacement gets its grant.
    public enum RenewalGrant: Equatable, Sendable {
        /// Custody's grant already outlives what the caller needs (a spend
        /// that completed but was never installed, or a session that only
        /// needs rebuilding): rebuild on it and spend nothing.
        case resumeStored
        /// Spend the refresh token for a new grant.
        case spend
        /// Custody refused: stop. No automatic attempt follows (`RenewalRetry`).
        case stop
        /// Custody could not be read: try again later, spending nothing.
        case retryLater
    }

    /// Decided before the working session is touched. `requiredLifetimeSeconds`
    /// is what the caller needs from the grant: the keep-alive's lead
    /// (`MobileMatrixSessionKeepAlivePolicy.refreshLeadSeconds`) for a renewal
    /// or a rebuild, a verification ceremony's minimum
    /// (`MobileMatrixVerificationPolicy.minimumSessionLifetimeSeconds`). Every
    /// caller asks only when the runtime's own grant falls short of that, so
    /// a stored grant that does not is the runtime's grant and is spent.
    public static func renewalGrant(custody: CustodyGrant, now: Date,
                                    requiredLifetimeSeconds: TimeInterval) -> RenewalGrant {
        switch custody {
        case .refused: return .stop
        case .unreadable: return .retryLater
        case let .ready(expiresAt):
            let remaining = expiresAt.timeIntervalSince(now)
            return remaining.isFinite && remaining > requiredLifetimeSeconds ? .resumeStored : .spend
        }
    }

    /// How one renewal attempt ended.
    public enum RenewalResult: String, Equatable, Sendable {
        /// The replacement runtime is installed.
        case renewed
        /// The account server could not be reached before anything was
        /// spent. Costs nothing; the keep-alive's own 30 s spacing applies.
        case unreachable
        /// A failure after the reachability check (custody unreadable, the
        /// runtime would not open, the renewed session was not current).
        case failed
        /// Custody refused (`CustodyGrant.refused`), before or after the attempt.
        case custodyRefused = "custody_refused"
        /// The session or installation changed during the attempt.
        case superseded
    }

    /// Automatic renewals (the foreground keep-alive and a session that
    /// reported itself invalid) after failures: 30 s, then 2 min, then every
    /// 10 min, never every 30 s forever. A custody refusal stops them until a
    /// renewal succeeds; the person can still ask (pull-to-refresh), which
    /// reads custody again and spends nothing while it refuses.
    public struct RenewalRetry: Equatable, Sendable {
        public static let spacingSeconds: [TimeInterval] = [30, 120, 600]

        public private(set) var consecutiveFailures = 0
        public private(set) var lastFailureAt: Date?
        public private(set) var custodyRefused = false

        public init() {}

        public mutating func record(_ result: RenewalResult, at now: Date) {
            switch result {
            case .renewed:
                self = RenewalRetry()
            case .failed:
                consecutiveFailures += 1
                lastFailureAt = now
            case .custodyRefused:
                custodyRefused = true
                lastFailureAt = now
            case .unreachable, .superseded:
                break
            }
        }

        /// Seconds before the next automatic attempt may run (0: now), or
        /// nil when custody refused and no automatic attempt runs.
        public func automaticWait(now: Date) -> TimeInterval? {
            if custodyRefused { return nil }
            guard consecutiveFailures > 0, let lastFailureAt else { return 0 }
            let spacing = Self.spacingSeconds[min(consecutiveFailures, Self.spacingSeconds.count) - 1]
            let elapsed = now.timeIntervalSince(lastFailureAt)
            // A clock that moved backwards never strands the retry.
            guard elapsed.isFinite, elapsed >= 0 else { return 0 }
            return max(0, spacing - elapsed)
        }
    }

    // MARK: Launch

    /// Where a launch failure happened.
    public enum LaunchFailure: Equatable, Sendable {
        /// No Matrix session could be opened. `custody` is what custody held
        /// afterwards (nil when the failure came before custody was read).
        case matrix(custody: CustodyGrant?)
        /// The Matrix runtime resumed but the account service's record is
        /// present (true), absent (false) or unreadable (nil). Every variant
        /// keeps the product open; the domain recovery policy decides whether
        /// Home shows its one reauthentication action.
        case domain(recordPresent: Bool?)
        /// No installation marker, but Matrix custody or account-service
        /// records survive (a reinstall keeps Keychain items): no session can
        /// open from them and every sign-in preflight refuses them
        /// (`StrandedSessionArchive.survivors()`).
        case recordsWithoutInstallation
    }

    /// What the app shows after a launch failure.
    public enum LaunchOutcome: Equatable, Sendable {
        /// Show the chats; agents, apps, Store and wallet stay unavailable
        /// (no domain client is built from a record that does not reconcile)
        /// until a renewal reconciles it.
        case productWithoutDomain
        /// A quiet "not connected, try again" state, tried again on each
        /// return to the foreground (`retriesLaunch`). Never the lock screen
        /// and never "this device needs recovery".
        case retryLaunch
        /// Custody refused, or records survive without their installation:
        /// the session can no longer be renewed on this phone. The sign-in
        /// screen with the expired-session notice ("Đăng nhập lại để tiếp
        /// tục") and "Đăng nhập lại" (`signInAgainStep`, coordinator decision
        /// 11); it never blames the network and never retries by itself.
        case sessionExpired
    }

    public static func outcome(for failure: LaunchFailure) -> LaunchOutcome {
        switch failure {
        case let .matrix(custody): custody == .refused ? .sessionExpired : .retryLaunch
        case .domain: .productWithoutDomain
        case .recordsWithoutInstallation: .sessionExpired
        }
    }

    // MARK: Signing in again (coordinator decision 11)

    /// What "Đăng nhập lại" on the expired-session screen does, decided again
    /// at the tap from custody read without spending.
    public enum SignInAgainStep: Equatable, Sendable {
        /// Custody holds a ready grant after all: nothing moves; launch again.
        case launchAgain
        /// The Keychain could not be read just now: nothing moves; stay.
        case retryLater
        /// Move the stranded records aside, never deleting or overwriting
        /// them (`StrandedSessionArchive`), then the normal sign-in, as a new
        /// installation beside them.
        case archiveThenSignIn
    }

    /// `custody` is nil when there is no installation marker (records that
    /// survived without one, or nothing at all: the archive then moves
    /// nothing and the sign-in starts).
    public static func signInAgainStep(custody: CustodyGrant?) -> SignInAgainStep {
        switch custody {
        case .ready: .launchAgain
        case .unreadable: .retryLater
        case .refused, nil: .archiveThenSignIn
        }
    }

    /// In the product after custody refused: seconds until the sign-in
    /// screen replaces the chats (0: now), or nil while custody has not
    /// refused. The working session keeps running until its access token
    /// expires (sends still go out); after that nothing can sync or send on
    /// it, so the expired-session screen with "Đăng nhập lại" shows
    /// (decision 11) instead of stale chats with the connection glyph.
    public static func secondsUntilSignIn(custodyRefused: Bool, sessionExpiresAt: Date, now: Date) -> TimeInterval? {
        guard custodyRefused else { return nil }
        let remaining = sessionExpiresAt.timeIntervalSince(now)
        return remaining.isFinite ? max(0, remaining) : 0
    }

    /// A launch that could not open a Matrix session is retried on a return
    /// to the foreground at most this often, so flapping in and out of the
    /// app cannot hammer the account server.
    public static let launchRetrySpacingSeconds: TimeInterval = 30

    /// Whether a return to the foreground retries a failed launch.
    public static func retriesLaunch(_ outcome: LaunchOutcome, now: Date, lastAttemptAt: Date?) -> Bool {
        guard outcome == .retryLaunch else { return false }
        guard let lastAttemptAt else { return true }
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        return !elapsed.isFinite || elapsed < 0 || elapsed >= launchRetrySpacingSeconds
    }
}
