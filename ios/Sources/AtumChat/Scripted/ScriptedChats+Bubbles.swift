#if DEBUG
import Foundation

extension ScriptedChats {
    /// The long answer in `chat.bubbles` (row `row.chat.bubbles.long`).
    static let bubblesLongID = "chat.bubbles.long"
    /// Quân's long message in `chat.bubbles-group`.
    static let bubblesGroupLongID = "chat.bubbles-group.long"

    /// Bubble width, tight hug and the long-message fold (owner, 2026-11-11),
    /// in my assistant's chat: short lines both ways, my wrapped question, a
    /// long answer that is final when the chat opens (it starts folded),
    /// then my thanks and a wrapped four-line answer at the bottom.
    static func chatBubbles(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatBubbles.rawValue
        var writer = ScriptedWriter(scenario: name, context: assistant, calendar: env.calendar)
        writer.add(from: Cast.me, at: env.ago(minutes: 30), body: "Chào Atum")
        writer.add(from: Cast.atum, at: env.ago(minutes: 29), body: "Chào bạn! Mình giúp gì được?")
        let question = writer.add(from: Cast.me, at: env.ago(minutes: 20),
                                  body: "Lên giúp mình kế hoạch cả tuần tới nhé: việc chính mỗi ngày, giờ họp và những gì cần chuẩn bị trước.")
        let long = writer.add(from: Cast.atum, at: env.ago(minutes: 19), body: twoScreenAnswer(seed: 41),
                              replyTo: question.eventID)
        writer.add(from: Cast.me, at: env.ago(minutes: 10), body: "Cảm ơn nhé!", receipts: [Cast.atum])
        writer.add(from: Cast.atum, at: env.ago(minutes: 9),
                   body: "Không có gì! Mình đã lưu kế hoạch vào ghi chú của bạn. Nếu lịch họp thay đổi, cứ nhắn mình, mình sẽ sắp xếp lại các việc còn lại trong tuần cho phù hợp.")
        var items = writer.items
        rename(&items, long.id, to: bubblesLongID)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: items,
                              replies: atumReplies, names: Cast.names)
    }

    /// The same in a group, with faces: the far-side gap holds and the face
    /// gutter narrows bubbles on the near side; Quân's long message folds.
    static func chatBubblesGroup(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatBubblesGroup.rawValue
        let context = RoomContext(kind: .group, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        var random = ScriptedRandom(seed: 43)
        writer.add(from: Cast.quan, at: env.ago(minutes: 40), body: "Chào cả nhóm!")
        writer.add(from: Cast.huy, at: env.ago(minutes: 39), body: "Chào Quân")
        let long = writer.add(from: Cast.quan, at: env.ago(minutes: 35),
                              body: (0..<6).map { _ in ScriptedText.paragraph(&random, sentences: 4) }
                                  .joined(separator: "\n\n"))
        writer.add(from: Cast.huy, at: env.ago(minutes: 30),
                   body: "Mình đọc rồi, phần ngân sách cần xem lại một chút trước buổi họp thứ Năm.")
        writer.add(from: Cast.huy, at: env.ago(minutes: 29), body: "Ok?")
        writer.add(from: Cast.me, at: env.ago(minutes: 20),
                   body: "Mình sẽ gửi bảng ngân sách mới trước trưa mai để mọi người kịp xem.",
                   receipts: [Cast.quan, Cast.huy])
        writer.add(from: Cast.me, at: env.ago(minutes: 19), body: "👍")
        var items = writer.items
        rename(&items, long.id, to: bubblesGroupLongID)
        return ScriptedScript(name: name, title: "Nhóm thử", context: context, initial: items,
                              replies: ScriptedReplies(sender: Cast.quan, seenAfter: 1.5), names: Cast.names)
    }

    /// A fixed row ID for a test to find.
    private static func rename(_ items: inout [ChatItem], _ id: String, to fixed: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].id = fixed
        items[index].eventOrTransactionId = .event("$" + fixed)
    }
}
#endif
