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
        let scripted = Self.scriptedFixture(request.content.userInfo)
        delivery.start(waitForDeadline: {
            try await Task.sleep(for: .seconds(20))
        }, onDeadline: { Self.log(.fetchTimeout) }, onFailure: {
            Self.log(NotificationFallbackReason.classify($0))
        }) {
            let fetched: FetchedNotification
            if let scripted {
                fetched = await ScriptedNotificationFixtures.fetched(scripted, roomID: payload.roomID.rawValue)
            } else {
                fetched = try await MatrixNotificationFetcher.shared.fetch(
                    roomID: payload.roomID.rawValue, eventID: payload.eventID.rawValue, copy: copy)
            }
            let rich = Self.content(fetched.result, generic: generic.content)
            guard let face = fetched.face else { return NotificationSnapshot(rich) }
            let communication = await CommunicationNotification.apply(face, to: rich, log: Self.log)
            if communication != nil { Self.logCommunication(face) }
            return NotificationSnapshot(communication ?? rich)
        }
    }

    /// Debug simulator builds only: `atum_scripted_notification` picks a
    /// compiled-in fixture so `xcrun simctl push` can show the communication
    /// layout without a live Matrix session. The key selects a fixture; no
    /// display string, image or URI is read from the push. Release and device
    /// builds compile this out.
    static func scriptedFixture(_ userInfo: [AnyHashable: Any]) -> ScriptedNotificationFixtures.Fixture? {
        #if DEBUG && targetEnvironment(simulator)
        return (userInfo["atum_scripted_notification"] as? String).flatMap(ScriptedNotificationFixtures.Fixture.init)
        #else
        return nil
        #endif
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
    /// Closed values only: the style and whether a picture or the monogram was used.
    private static func logCommunication(_ face: CommunicationFace) {
        let style = if case .group = face.plan.style { "group" } else { "person" }
        let image = face.image == nil ? "monogram" : "picture"
        logger.notice("communication_alert style=\(style, privacy: .public) image=\(image, privacy: .public)")
    }
    private static func log(_ reason: CommunicationFallback) {
        logger.notice("plain_alert reason=\(reason.rawValue, privacy: .public)")
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
