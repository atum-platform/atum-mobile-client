import AtumChat
import MatrixRustSDK

enum RoomMentionMatrix {
    private final class Listener: RoomStateEventsListener {
        let continuation: AsyncStream<Void>.Continuation

        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func onUpdate(events: [RoomStateEvent]) { continuation.yield(()) }
    }

    static func permissionUpdates(in room: Room) -> (AsyncStream<Void>, TaskHandle) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = room.subscribeToStateEvents(eventType: .roomPowerLevels, listener: Listener(continuation))
        continuation.yield(())
        return (stream, handle)
    }

    static func canNotify(in room: Room) async -> Bool {
        guard room.membership() == .joined, room.successorRoom() == nil,
              let levels = try? await room.getPowerLevels(), room.membership() == .joined
        else { return false }
        let own = room.ownUserId()
        return (try? levels.canUserTriggerRoomNotification(userId: own)) == true
            && (try? levels.canUserSendMessage(userId: own, message: .roomMessage)) == true
    }

    /// The text and reply paths share this check immediately before enqueue.
    static func message(_ text: String, mentions: OutgoingMentions,
                        in room: Room) async throws -> RoomMessageEventContentWithoutRelation {
        let roomMention = mentions.room ? await canNotify(in: room) : false
        let formatted = mentions.formattedHTML.map { FormattedBody(format: .html, body: $0) }
        let content = try messageEventContentNew(msgtype: .text(
            content: TextMessageContent(body: text, formatted: formatted)))
        // Presence of an empty m.mentions suppresses the legacy @room push
        // rule. Ordinary text still uses the existing plain body.
        guard roomMention || !mentions.userIDs.isEmpty || text.lowercased().contains(RoomMentionRules.token)
        else { return content }
        return content.withMentions(mentions: Mentions(userIds: mentions.userIDs, room: roomMention))
    }
}
