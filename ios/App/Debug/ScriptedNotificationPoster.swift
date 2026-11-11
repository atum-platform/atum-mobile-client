#if DEBUG && targetEnvironment(simulator)
import AtumChat
import Foundation
import UserNotifications

/// Simulator proof of communication notifications. `xcrun simctl push` hands
/// the request straight to `usernotificationsd` and never launches the
/// notification service extension, so `-AtumPostScriptedNotifications dm,channel`
/// posts each fixture as a local notification built by the extension's own
/// code (`ScriptedNotificationFixtures`, `CommunicationNotification.apply`,
/// compiled into the app for this). Fixtures fire 7 s apart from 3 s and are
/// presented over the app itself (`owns`), so it is never suspended
/// mid-post. Debug simulator builds only.
enum ScriptedNotificationPoster {
    static let flag = "-AtumPostScriptedNotifications"
    private static let prefix = "scripted-"

    /// The foreground delegate shows these as banners.
    static func owns(_ identifier: String) -> Bool { identifier.hasPrefix(prefix) }

    static func configure(arguments: [String]) {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let fixtures = arguments[index + 1].split(separator: ",")
            .compactMap { ScriptedNotificationFixtures.Fixture(rawValue: String($0)) }
        Task { await post(fixtures) }
    }

    private static func post(_ fixtures: [ScriptedNotificationFixtures.Fixture]) async {
        let center = UNUserNotificationCenter.current()
        for (offset, fixture) in fixtures.enumerated() {
            let roomID = "!fixture-\(fixture.rawValue):fixture.test"
            let fetched = await ScriptedNotificationFixtures.fetched(fixture, roomID: roomID)
            guard case let .content(presentation) = fetched.result else { continue }
            let content = UNMutableNotificationContent()
            content.title = presentation.title
            content.subtitle = presentation.subtitle
            content.body = presentation.body
            content.threadIdentifier = roomID
            content.sound = .default
            var final: UNNotificationContent = content
            if let face = fetched.face, let updated = await CommunicationNotification.apply(face, to: content) {
                final = updated
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(3 + 7 * offset), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + fixture.rawValue,
                                                        content: final, trigger: trigger))
        }
    }
}
#endif
