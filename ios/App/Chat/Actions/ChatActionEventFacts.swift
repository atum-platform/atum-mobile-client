import AtumChat
import MatrixRustSDK

enum ChatActionEventFacts {
    static func apply(from event: EventTimelineItem, to item: inout ChatItem, plainRoom: Bool) {
        guard event.isRemote, event.editSendState == nil, event.redactionSendState == nil,
              case .msgLike(let like) = event.content, case .message(let message) = like.kind
        else { return }
        switch item.kind {
        case .message, .notice: break
        default: return
        }
        item.hasRoomMention = message.mentions?.room == true
        guard plainRoom, item.progress == nil, item.botAPI == nil,
              event.eventTypeRaw == "m.room.message" else { return }
        switch message.msgType {
        case .text, .notice, .emote:
            item.linkPreviewURL = LinkPolicy.firstPreviewURL(in: message.body)
        default:
            break
        }
    }
}
