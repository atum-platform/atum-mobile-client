import Foundation

/// S5's display-only button policy.  It has no catalog, network or view
/// dependency: the app supplies the already-resolved catalog facts.
public enum AppBotNoticeButtons {
    public struct Notice: Equatable, Hashable, Sendable {
        public var id: String
        public var message: AppBotMessage

        public init(id: String, message: AppBotMessage) {
            self.id = id
            self.message = message
        }
    }

    public struct Context: Equatable, Sendable {
        /// The chat showing the notices, if it already has a Matrix room.
        public var currentRoomID: String?
        /// The current app's setup state from its catalog/API facts.
        public var botIsSetUp: Bool
        /// The current app's catalog purchase route, held on iOS.
        public var purchaseRouteID: String?
        /// Known P0 catalog bot rooms, keyed by an action's catalog app slug.
        /// Absence means the target catalog/room is unavailable and the button
        /// must not appear.
        public var botRoomIDByApp: [String: String]

        public init(currentRoomID: String?, botIsSetUp: Bool,
                    purchaseRouteID: String?, botRoomIDByApp: [String: String]) {
            self.currentRoomID = currentRoomID
            self.botIsSetUp = botIsSetUp
            self.purchaseRouteID = purchaseRouteID
            self.botRoomIDByApp = botRoomIDByApp
        }
    }

    /// The visible action by stable notice ID.  `notices` must be oldest to
    /// newest, matching timeline display order.  An action family is claimed
    /// before its other hide rules run, so an old button never reappears when
    /// its newest successor is intentionally hidden.
    public static func actions(for notices: [Notice], context: Context) -> [String: AppBotMessage.Action] {
        var visible: [String: AppBotMessage.Action] = [:]
        var claimedKinds = Set<AppBotMessage.Action.Kind>()

        for notice in notices.reversed() {
            guard let action = notice.message.action,
                  claimedKinds.insert(action.kind).inserted,
                  notice.message.code != .allowanceExhausted else { continue }

            switch action {
            case .openSetup:
                guard !context.botIsSetUp else { continue }
            case let .openAppRoute(_, routeID):
                guard !LinkPolicy.holdsAppRoute(routeID, purchaseRouteID: context.purchaseRouteID) else { continue }
            case let .openBotDM(app):
                guard let targetRoomID = context.botRoomIDByApp[app], !targetRoomID.isEmpty,
                      targetRoomID != context.currentRoomID else { continue }
            }
            visible[notice.id] = action
        }
        return visible
    }
}
