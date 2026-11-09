import Foundation

/// The `willPresent` decision for an incoming room notification (S2 §3.6).
/// App/notification-framework adapters map `presentation` to their APIs.
public enum PushPresentation {
    public enum Screen: Equatable, Sendable {
        case chat(roomID: String)
        case homeRoot
        case other
    }

    public enum Option: Equatable, Hashable, Sendable { case banner, list, sound }

    public enum Decision: Equatable, Sendable {
        case suppress
        case present(Set<Option>)
    }

    public static let foregroundOptions: Set<Option> = [.banner, .list, .sound]

    /// S2 §3.6: Home-root notifications are suppressed because the live row
    /// and `Badge` update in place. Muting is server/NotificationSettings
    /// policy and is intentionally not duplicated in foreground routing.
    public static func decide(screen: Screen, notificationRoomID: String) -> Decision {
        switch screen {
        case let .chat(roomID) where roomID == notificationRoomID:
            return .suppress
        case .homeRoot:
            return .suppress
        case .chat, .other:
            return .present(foregroundOptions)
        }
    }
}
