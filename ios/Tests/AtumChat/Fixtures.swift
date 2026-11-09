import Foundation
@testable import AtumChat

/// Synthetic timeline values. No real users, rooms or message content.
enum F {
    static let me = "@me:example.test"
    static let agent = "@agent:example.test"
    static let bot = "@moon-bot:example.test"
    static let friend = "@friend:example.test"
    static let other = "@other:example.test"

    static func assistantRoom() -> RoomContext {
        RoomContext(kind: .assistant, ownUserID: me, agentUserIDs: [agent])
    }

    static func botRoom() -> RoomContext {
        RoomContext(kind: .appBot, ownUserID: me, agentUserIDs: [bot])
    }

    /// A group with an app's bot (Moon) among its members.
    static func groupWithApp() -> RoomContext {
        RoomContext(kind: .group, ownUserID: me, agentUserIDs: [bot])
    }

    static func personRoom() -> RoomContext {
        RoomContext(kind: .person, ownUserID: me)
    }

    static func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60) }

    /// A message from this account sent on another device (remote).
    static func mine(_ id: String, _ body: String = "x", minute: Int = 0, replyTo: String? = nil) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: me, isOwn: true, timestamp: at(minute), delivery: .remote,
                 eventOrTransactionId: .event("$" + id), body: body, replyTo: replyTo)
    }

    /// A message sent from this device, still in the local echo phase.
    static func echo(_ id: String, _ body: String = "x", delivery: ChatDelivery = .sending()) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: me, isOwn: true, isLocalEcho: true, delivery: delivery,
                 eventOrTransactionId: .transaction("txn-" + id), body: body)
    }

    static func text(_ id: String, from sender: String, _ body: String = "x", minute: Int = 0,
                     replyTo: String? = nil, agents: Set<String> = [agent, bot],
                     threadRoot: String? = nil) -> ChatItem {
        let kind = ChatItem.Kind.message
        return ChatItem(id: id, kind: kind, sender: sender, timestamp: at(minute),
                        eventOrTransactionId: .event("$" + id), body: body, replyTo: replyTo,
                        threadRoot: threadRoot,
                        resultFor: ChatItem.resultFor(kind: kind, sender: sender, replyTo: replyTo,
                                                      agentUserIDs: agents))
    }

    static func notice(_ id: String, from sender: String, _ body: String = "status", replyTo: String? = nil) -> ChatItem {
        ChatItem(id: id, kind: .notice, sender: sender, eventOrTransactionId: .event("$" + id),
                 body: body, replyTo: replyTo)
    }

    static func divider(_ id: String) -> ChatItem { ChatItem(id: id, kind: .dayDivider(at(0))) }
    static func readMarker(_ id: String = "read-marker") -> ChatItem { ChatItem(id: id, kind: .readMarker) }
    static func start(_ id: String = "start") -> ChatItem { ChatItem(id: id, kind: .timelineStart) }

    static func ids(_ items: [ChatItem]) -> [String] { items.map(\.id) }
    static func ids(_ rows: [ChatRow]) -> [String] { rows.map(\.id) }
}
