import AtumChat
import AtumNativeAPI
import Foundation
import UserNotifications

enum LivePushRouting {
    /// The notification service extension reduces a validated payload to these
    /// routing fields. Refuse malformed/unbounded values again in the app: a
    /// notification tap is navigation intent, never room authority.
    static func roomID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let value = userInfo["room_id"] as? String,
              (3...255).contains(value.utf8.count), value.first == "!",
              value.contains(":"), !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }

    static func options(for decision: PushPresentation.Decision) -> UNNotificationPresentationOptions {
        switch decision {
        case .suppress:
            return []
        case let .present(options):
            var result: UNNotificationPresentationOptions = []
            if options.contains(.banner) { result.insert(.banner) }
            if options.contains(.list) { result.insert(.list) }
            if options.contains(.sound) { result.insert(.sound) }
            return result
        }
    }

    static func deliveredIdentifiers(for roomID: String,
                                     notifications: [UNNotification]) -> [String] {
        notifications.compactMap { notification in
            belongs(notification.request.content.userInfo, to: roomID)
                ? notification.request.identifier
                : nil
        }
    }

    static func belongs(_ userInfo: [AnyHashable: Any], to roomID: String) -> Bool {
        Self.roomID(from: userInfo) == roomID
    }

    static func removeDeliveredNotifications(for roomID: String,
                                             center: UNUserNotificationCenter = .current()) async {
        let delivered = await center.deliveredNotifications()
        let identifiers = deliveredIdentifiers(for: roomID, notifications: delivered)
        if !identifiers.isEmpty { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    }
}

/// The APNs environment this build registers with. The signed
/// `aps-environment` in the embedded provisioning profile is authoritative;
/// the build flag cross-checks it and is the only signal when no profile is
/// readable (simulator, unsigned assembly).
enum LivePushEnvironment {
    static var build: MobileAPNSEnvironment {
        #if DEBUG
        .forBuild(isDebug: true)
        #else
        .forBuild(isDebug: false)
        #endif
    }

    static func signed(bundle: Bundle = .main) -> MobileAPNSEnvironment? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return MobileProvisioningProfile.apnsEnvironment(inProfile: data)
        #endif
    }
}
