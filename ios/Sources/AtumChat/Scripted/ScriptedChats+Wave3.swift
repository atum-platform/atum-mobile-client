#if DEBUG
import Foundation

extension ScriptedChats {
    /// The one message `chat.search` plants, and what the UI test types.
    public static let searchNeedle = "Hẹn gặp ở Đà Lạt nhé, mình đặt phòng rồi."

    /// HC-6: 140 messages, 40 cached at open, older pages of 20. One message,
    /// three pages back, says "Đà Lạt"; nothing else does, so the search has
    /// to walk history to find it ("da lat" finds it, marks folded).
    static func chatSearch(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatSearch.rawValue
        var all = longTranscript(name: name, context: assistant, messages: 140, env: env, seed: 31)
        let messages = all.indices.filter { all[$0].kind == .message }
        if messages.count > 45 {
            let index = messages[45]
            all[index].body = searchNeedle
            all[index].isOwn = true
            all[index].sender = Cast.me
            all[index].senderName = nil
        }
        let (initial, pages) = split(all, initialEvents: 40, pageEvents: 20)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, olderPages: pages,
                              replies: atumReplies, names: Cast.names)
    }
}
#endif
