import Foundation

/// Where the APNs environment came from: the signed `aps-environment` in the
/// embedded provisioning profile, or the build flag when no profile is
/// readable (simulator, unsigned assembly).
public enum MobilePushEnvironmentSource: String, Equatable, Sendable {
    case provisioningProfile = "provisioning_profile"
    case buildFlag = "build_flag"
}

/// Closed refusal reasons. Safe for the flow log: no token, no identifiers.
public enum MobilePushRegistrationRefusal: String, Equatable, Sendable {
    case provisioningProfileMismatch = "provisioning_profile_mismatch"
}

public enum MobilePushEnvironmentDecision: Equatable, Sendable {
    case use(MobileAPNSEnvironment, source: MobilePushEnvironmentSource)
    case refuse(reason: MobilePushRegistrationRefusal)
}

/// Chooses the APNs environment for one registration attempt.
public enum MobilePushEnvironmentPolicy {
    /// The signed profile environment wins when it is readable; the build
    /// flag only cross-checks it. A readable profile that disagrees with the
    /// build flag refuses registration: that combination means a
    /// development-signed build (sandbox token) would otherwise hand the
    /// production app ID a token APNs answers with `BadDeviceToken`. With no
    /// readable profile the build flag is the only signal, as before.
    public static func decide(build: MobileAPNSEnvironment,
                              signed: MobileAPNSEnvironment?) -> MobilePushEnvironmentDecision {
        guard let signed else { return .use(build, source: .buildFlag) }
        guard signed == build else { return .refuse(reason: .provisioningProfileMismatch) }
        return .use(signed, source: .provisioningProfile)
    }
}

/// Reads the `aps-environment` entitlement out of an embedded provisioning
/// profile. A profile is a CMS envelope whose property-list payload is stored
/// verbatim inside the DER structure; scanning for the plist bytes is the
/// dependency-free way to read them on-device (iOS exposes no public CMS
/// decoder to apps). iOS installed this bundle only after validating the same
/// profile, so these are the bytes it validated.
public enum MobileProvisioningProfile {
    public static func apnsEnvironment(inProfile data: Data) -> MobileAPNSEnvironment? {
        guard let plist = plistPayload(inProfile: data),
              let root = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil))
                  as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else { return nil }
        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }

    private static func plistPayload(inProfile data: Data) -> Data? {
        let opening = Data("<?xml".utf8), closing = Data("</plist>".utf8)
        guard let start = data.range(of: opening),
              let end = data.range(of: closing, in: start.upperBound..<data.endIndex) else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}

/// The two server mutations the phone performs for its own pusher. The app
/// passes the live Matrix client; tests pass a spy.
@MainActor
public protocol MobilePusherTransport {
    /// Set the pusher described by the contract-b fields.
    func setPusher(_ fields: MobilePusherFields) async throws
    /// Delete the pusher with these identifiers. Both values come from
    /// `MobilePusherFields`; neither is logged or persisted here.
    func removePusher(pushkey: String, appID: String) async throws
}

/// What happened to a previous pusher while rotating to a new one.
public enum MobilePushPreviousPusher: Equatable, Sendable {
    case none
    case removed
    case removalFailed
}

public enum MobilePushRegistrationOutcome: Equatable, Sendable {
    case set(environment: MobileAPNSEnvironment, source: MobilePushEnvironmentSource,
             previous: MobilePushPreviousPusher)
    /// The same token for the same environment is already registered.
    case unchanged
    case refused(reason: MobilePushRegistrationRefusal)
    /// APNs handed over bytes that are not a device token.
    case invalidToken
    /// The transport call failed. Carries no error text, so a log line built
    /// from this value can never echo SDK output.
    case failed
}

public enum MobilePushSignOutOutcome: Equatable, Sendable {
    case removed
    case nothingRegistered
    case removalFailed
}

/// Owns the phone's one pusher identity, in memory, for the life of the
/// process. Token rotation sets the new pusher and only then deletes the old
/// one; sign-out deletes before the caller ends the session. Every mutation
/// is best effort: outcomes are closed values, never thrown errors, and never
/// the token.
@MainActor
public final class MobilePushCoordinator {
    private struct Registered: Equatable {
        let token: APNsDeviceToken
        let environment: MobileAPNSEnvironment
        let fields: MobilePusherFields
    }

    private var registered: Registered?

    public init() {}

    /// APNs gave the phone a token: register it, choosing the environment
    /// from the signed profile cross-checked against the build.
    public func receive(tokenBytes: Data, build: MobileAPNSEnvironment,
                        signed: MobileAPNSEnvironment?, device: MobilePushDevice,
                        locale: MobilePushLocale,
                        using transport: any MobilePusherTransport) async -> MobilePushRegistrationOutcome {
        guard let token = try? APNsDeviceToken(bytes: tokenBytes) else { return .invalidToken }
        switch MobilePushEnvironmentPolicy.decide(build: build, signed: signed) {
        case let .use(environment, source):
            return await set(token: token, environment: environment, source: source,
                             device: device, locale: locale, using: transport)
        case let .refuse(reason):
            return .refused(reason: reason)
        }
    }

    /// Sign-out: delete the registered pusher before the caller ends the
    /// session. A failed removal keeps the identity so a sign-out that rolls
    /// back and is retried later still deletes it; a successful one forgets
    /// it.
    public func signOut(using transport: any MobilePusherTransport) async -> MobilePushSignOutOutcome {
        guard let entry = registered else { return .nothingRegistered }
        guard await remove(entry, using: transport) else { return .removalFailed }
        registered = nil
        return .removed
    }

    private func set(token: APNsDeviceToken, environment: MobileAPNSEnvironment,
                     source: MobilePushEnvironmentSource, device: MobilePushDevice,
                     locale: MobilePushLocale,
                     using transport: any MobilePusherTransport) async -> MobilePushRegistrationOutcome {
        guard let fields = try? MobilePush.pusherFields(token: token, environment: environment,
                                                        device: device, locale: locale) else {
            return .failed
        }
        if let registered, registered.fields.pushkey == fields.pushkey,
           registered.fields.appID == fields.appID {
            return .unchanged
        }
        do {
            try await transport.setPusher(fields)
        } catch {
            return .failed
        }
        let previous = registered
        registered = Registered(token: token, environment: environment, fields: fields)
        guard let previous else {
            return .set(environment: environment, source: source, previous: .none)
        }
        let removed = await remove(previous, using: transport)
        return .set(environment: environment, source: source, previous: removed ? .removed : .removalFailed)
    }

    private func remove(_ entry: Registered, using transport: any MobilePusherTransport) async -> Bool {
        // Build and decode the contract's removal body first, so the app and
        // the gateway keep one definition of a pusher removal and both
        // identifiers are validated before the authenticated delete.
        guard let body = try? MobilePush.remove(token: entry.token, environment: entry.environment),
              (try? MobilePush.removal(body)) != nil else {
            return false
        }
        do {
            try await transport.removePusher(pushkey: entry.fields.pushkey, appID: entry.fields.appID)
            return true
        } catch {
            return false
        }
    }
}
