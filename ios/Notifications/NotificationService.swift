import Foundation
import UserNotifications
import AtumNativeAPI

/// First native path: no approved public account configuration is bundled yet.
/// Do not select a session/store from a notification or attempt a refresh.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(Self.genericContent(userInfo: request.content.userInfo, bundle: .main))
    }

    override func serviceExtensionTimeWillExpire() {
        // Completion is synchronous. No pending work or retained handler exists.
    }

    static func genericContent(userInfo: [AnyHashable: Any], bundle: Bundle) -> UNNotificationContent {
        // Build fresh content so an invalid payload cannot supply display text,
        // sender, attachments, actions, sound, thread or account authority.
        let content = UNMutableNotificationContent()
        content.body = bundle.localizedString(forKey: "ATUM_NEW_MESSAGE", value: nil, table: nil)
        if let data = try? JSONSerialization.data(withJSONObject: userInfo),
           let payload = try? MobilePush.payload(data), payload.localizationKey == "ATUM_NEW_MESSAGE" {
            content.userInfo = ["room_id": payload.roomID.rawValue, "event_id": payload.eventID.rawValue]
            content.badge = payload.badge.map { NSNumber(value: $0) }
            content.threadIdentifier = payload.roomID.rawValue
            content.sound = .default
        }
        return content
    }
}
