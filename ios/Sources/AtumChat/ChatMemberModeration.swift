import Foundation

/// What can be done about one person in a group's Members page, as on the desktop's members sheet
/// (`conversation-controls.tsx` `MemberAction`): block (Matrix ignore), remove (kick),
/// ban and unban. Remove, ban and unban follow the room's power levels as the Matrix
/// authorization rules check them, so the phone never offers an action the server would refuse.
public enum ChatMemberAction: String, Hashable, Sendable, CaseIterable {
    case block
    case unblock
    case remove
    case ban
    case unban
}

public struct ChatMemberModeration: Equatable, Sendable {
    public enum Membership: Equatable, Sendable {
        case joined
        case invited
        case banned
    }

    /// The signed-in person's power level in the room, and the levels the room asks for.
    public let ownPower: Int64
    public let kickLevel: Int64
    public let banLevel: Int64

    public init(ownPower: Int64, kickLevel: Int64, banLevel: Int64) {
        self.ownPower = ownPower
        self.kickLevel = kickLevel
        self.banLevel = banLevel
    }

    /// Matrix: a kick needs the kick level and more power than the target.
    public func mayRemove(targetPower: Int64, membership: Membership, isSelf: Bool) -> Bool {
        !isSelf && membership != .banned && ownPower >= kickLevel && ownPower > targetPower
    }

    /// Matrix: a ban needs the ban level and more power than the target.
    public func mayBan(targetPower: Int64, membership: Membership, isSelf: Bool) -> Bool {
        !isSelf && membership != .banned && ownPower >= banLevel && ownPower > targetPower
    }

    /// Matrix: lifting a ban is a leave on a banned member; it needs the ban level, then the kick
    /// level, and more power than the target.
    public func mayUnban(targetPower: Int64, membership: Membership, isSelf: Bool) -> Bool {
        !isSelf && membership == .banned && ownPower >= banLevel && ownPower >= kickLevel
            && ownPower > targetPower
    }

    /// The actions for one member, in the desktop's order. `mayBlock` is `ChatExitPolicy.mayIgnore`
    /// for this chat; `isBlocked` is whether the account already ignores them.
    public func actions(targetPower: Int64, membership: Membership, isSelf: Bool,
                        mayBlock: Bool, isBlocked: Bool) -> [ChatMemberAction] {
        var actions = [ChatMemberAction]()
        if mayBlock, !isSelf { actions.append(isBlocked ? .unblock : .block) }
        if mayRemove(targetPower: targetPower, membership: membership, isSelf: isSelf) { actions.append(.remove) }
        if mayBan(targetPower: targetPower, membership: membership, isSelf: isSelf) { actions.append(.ban) }
        if mayUnban(targetPower: targetPower, membership: membership, isSelf: isSelf) { actions.append(.unban) }
        return actions
    }
}
