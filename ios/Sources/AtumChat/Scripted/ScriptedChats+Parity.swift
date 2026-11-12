#if DEBUG
import Foundation

extension ScriptedChats {
    /// `chat.timeline-parity` (desktop parity, 2026-11-11), my assistant's
    /// chat with nothing touched:
    /// - at open, Atum's receipt sits on my last message: its Seen face;
    /// - 3 s, Atum types: the working atom alone (desktop
    ///   `MatrixAgentWorking` with no line);
    /// - 6 s, its working line "Đang chạy tác vụ…" arrives as an
    ///   `io.atum.progress` notice replying to my message, and takes the
    ///   typing row's place;
    /// - 8 s, the line is edited in place with a two-step checklist.
    /// No answer comes, so the line stays live for captures; typing stops at
    /// 100 s.
    static func chatTimelineParity(_ env: ScriptedEnvironment, reading: Bool = false) -> ScriptedScript {
        let name = (reading ? ScriptedScenario.chatTimelineReading : .chatTimelineParity).rawValue
        let activity = reading ? "Đang đọc…" : "Đang chạy tác vụ…"
        var initial = shortTranscript(name: name, messages: 6, env: env, seed: 31, minutesAgo: 4)
        let questionID = "\(name).question"
        initial.append(ChatItem(id: questionID, kind: .message, sender: Cast.me, isOwn: true,
                                timestamp: env.ago(minutes: 1), eventOrTransactionId: .event("$" + questionID),
                                body: "Tóm tắt giúp mình báo cáo quý 3 nhé.", receiptUserIDs: [Cast.atum]))
        let lineID = "\(name).working"
        var line = notice(lineID, activity, replyTo: "$" + questionID)
        // Match the SDK's full event envelope so a screenshot also exercises
        // the marker shape that was missed by the original phone parser.
        line.progress = AtumTurnMarkers.parse(json: #"{"type":"m.room.message","content":{"msgtype":"m.notice","io.atum.progress":{"phase":"working","kind":"activity","revision":1}}}"#).progress
        var interim = answer("\(name).interim", "Mình sẽ đọc báo cáo và tóm tắt các điểm chính.",
                             replyTo: "$" + questionID)
        interim.interim = true
        let steps: [ScriptedStep] = [
            ScriptedStep(at: 3, .typing([Cast.atum])),
            ScriptedStep(at: 5, .arrive(interim)),
            ScriptedStep(at: 6, .arrive(line)),
            ScriptedStep(at: 8, .edit(id: lineID, body: reading ? activity : activity + "\n✓ Đọc báo cáo quý 3\n• Viết bản tóm tắt")),
            // Scripted chats end their typing (`ScriptedTests`), long after the captures.
            ScriptedStep(at: 100, .typing([]))
        ]
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, steps: steps,
                              names: Cast.names)
    }
}
#endif
