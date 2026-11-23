#if DEBUG
import Foundation

extension ScriptedChats {
    /// `chat.agent-desk` (W4-E3, desktop #51's agent tab), my assistant's chat
    /// with nothing touched: my question, a file Atum sent back, my next
    /// question five minutes ago, and Atum's live working line on it with a
    /// two-step checklist. No answer comes, so the line stays live for the
    /// desk's Now; typing stops at 100 s.
    static func chatAgentDesk(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatAgentDesk.rawValue
        var initial = shortTranscript(name: name, messages: 4, env: env, seed: 41, minutesAgo: 12)
        let fileID = "\(name).file"
        initial.append(ChatItem(
            id: fileID, kind: .file(name: "ke-hoach-q4.pdf"), sender: Cast.atum, senderName: Cast.names[Cast.atum],
            timestamp: env.ago(minutes: 8), eventOrTransactionId: .event("$" + fileID), body: "ke-hoach-q4.pdf",
            media: ChatMedia(sourceHandle: "scripted:" + fileID, mimetype: "application/pdf",
                             filename: "ke-hoach-q4.pdf", isAnimated: false, byteSize: 48_128)))
        let questionID = "\(name).question"
        initial.append(ChatItem(id: questionID, kind: .message, sender: Cast.me, isOwn: true,
                                timestamp: env.ago(minutes: 5), eventOrTransactionId: .event("$" + questionID),
                                body: "Viết tóm tắt kế hoạch quý 4 giúp mình nhé.", receiptUserIDs: [Cast.atum]))
        var line = notice("\(name).working", "Đang soạn bản tóm tắt…\n✓ Đọc kế hoạch quý 4\n• Viết bản tóm tắt",
                          replyTo: "$" + questionID)
        line.timestamp = env.ago(minutes: 1)
        line.progress = ChatProgress(phase: .working, kind: "activity", revision: 2)
        initial.append(line)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial,
                              steps: [ScriptedStep(at: 100, .typing([]))], names: Cast.names)
    }
}
#endif
