// Lifecycle adapted from Element X iOS's Apache-2.0 notification service pattern.
// Copyright 2022 New Vector Ltd. Modifications Copyright 2026 Anka Ventures Vietnam Company Limited.
// Licensed under the Apache License, Version 2.0; see Vendor/Notices/ElementX-NSE.md.
import Foundation
import os
import UserNotifications
import AtumNativeAPI
import AtumChat

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var pending: [UUID: PushDelivery<NotificationSnapshot>] = [:]

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let generic = NotificationSnapshot(Self.genericContent(userInfo: request.content.userInfo, bundle: .main))
        guard let payload = Self.payload(request.content.userInfo) else {
            Self.log(.invalidPayload)
            contentHandler(generic.content)
            return
        }
        let id = UUID()
        let delivery = PushDelivery<NotificationSnapshot>(fallback: generic) { [weak self] content in
            self?.lock.withLock { _ = self?.pending.removeValue(forKey: id) }
            contentHandler(content.content)
        }
        let shouldStart = lock.withLock {
            guard !expired else { return false }
            pending[id] = delivery
            return true
        }
        guard shouldStart else { delivery.expire(onDelivery: { Self.log(.systemExpiry) }); return }
        let copy = Self.copy(bundle: .main)
        delivery.start(waitForDeadline: {
            try await Task.sleep(for: .seconds(20))
        }, onDeadline: { Self.log(.fetchTimeout) }, onFailure: {
            Self.log(NotificationFallbackReason.classify($0))
        }) {
            let result = try await MatrixNotificationFetcher.shared.fetch(
                roomID: payload.roomID.rawValue, eventID: payload.eventID.rawValue, copy: copy)
            return NotificationSnapshot(Self.content(result, generic: generic.content))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let deliveries = lock.withLock {
            expired = true
            return Array(pending.values)
        }
        deliveries.forEach { $0.expire(onDelivery: { Self.log(.systemExpiry) }) }
    }

    private static let logger = Logger(subsystem: "com.atum.mobile.notifications", category: "rich-push")
    private static func log(_ reason: NotificationFallbackReason) {
        logger.notice("generic_alert reason=\(reason.rawValue, privacy: .public)")
    }

    static func payload(_ userInfo: [AnyHashable: Any]) -> MobilePushPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let payload = try? MobilePush.payload(data), payload.localizationKey == "ATUM_NEW_MESSAGE" else { return nil }
        return payload
    }

    static func genericContent(userInfo: [AnyHashable: Any], bundle: Bundle) -> UNNotificationContent {
        // Never accept display strings, attachments or authority from the push.
        let content = UNMutableNotificationContent()
        content.body = bundle.localizedString(forKey: "ATUM_NEW_MESSAGE", value: nil, table: nil)
        if let payload = payload(userInfo) {
            content.userInfo = ["room_id": payload.roomID.rawValue, "event_id": payload.eventID.rawValue]
            content.badge = payload.badge.map { NSNumber(value: $0) }
            content.threadIdentifier = payload.roomID.rawValue
            content.sound = .default
        }
        return content
    }

    static func content(_ result: RichPushPresentation.Result, generic: UNNotificationContent) -> UNNotificationContent {
        switch result {
        case .generic: return generic
        case .suppress:
            // Element X discards filtered/self/redacted events with an empty
            // alert, retaining the badge so unread state can still reconcile.
            let content = UNMutableNotificationContent()
            content.badge = generic.badge
            return content
        case let .content(presentation):
            guard let content = generic.mutableCopy() as? UNMutableNotificationContent else { return generic }
            content.title = presentation.title; content.subtitle = presentation.subtitle; content.body = presentation.body
            return content
        }
    }

    static func copy(bundle: Bundle) -> RichPushPresentation.Copy {
        func optional(_ key: String) -> String? {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            return value == key || value.isEmpty ? nil : value
        }
        return .init(generic: bundle.localizedString(forKey: "ATUM_NEW_MESSAGE", value: nil, table: nil),
                     unnamed: optional("ATUM_PUSH_UNNAMED"), image: optional("ATUM_PUSH_IMAGE"),
                     video: optional("ATUM_PUSH_VIDEO"), audio: optional("ATUM_PUSH_AUDIO"), file: optional("ATUM_PUSH_FILE"),
                     sticker: optional("ATUM_PUSH_STICKER"), invite: optional("ATUM_PUSH_INVITE"))
    }
}

/// UserNotifications content has no Sendable annotation. Only an immutable
/// copy crosses tasks; mutable content is built locally and never shared.
private struct NotificationSnapshot: @unchecked Sendable {
    let content: UNNotificationContent
    init(_ content: UNNotificationContent) {
        self.content = content.copy() as! UNNotificationContent
    }
}
