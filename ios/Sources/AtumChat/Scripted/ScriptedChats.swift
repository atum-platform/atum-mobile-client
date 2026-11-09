#if DEBUG
import Foundation

/// Where and when a scenario is built: event times are relative to the
/// launch, so day dividers read "Hôm nay" and "Hôm qua" on any day.
public struct ScriptedEnvironment: Sendable {
    public var reference: Date
    public var calendar: Calendar

    public init(reference: Date = Date(), calendar: Calendar = .current) {
        self.reference = reference
        self.calendar = calendar
    }

    func ago(minutes: Double) -> Date { reference.addingTimeInterval(-minutes * 60) }
}

/// The chat scenarios of plan §2.10 and §5.2. Timings are seconds after the
/// open; each scenario's doc names the checks it serves.
enum ScriptedChats {
    typealias Cast = ScriptedCast

    static let assistant = RoomContext(kind: .assistant, ownUserID: Cast.me, agentUserIDs: [Cast.atum])

    // MARK: chat.long (G-scroll, §2.4)

    /// 500 messages of mixed height (short lines, paragraphs, lists, long code
    /// blocks, image boxes, file rows, superseded working lines) over about
    /// eight days. 120 are cached at open; the rest come back in pages of 20
    /// as the person flings up, then the start of the room.
    ///
    /// The owner's 15-minute device check (§2.10) follows these times:
    /// - 4 s dots, 6 s a short answer at the bottom (check 2);
    /// - scroll up three screens before 20 s: three messages at 20–22 s and
    ///   the dots at 23 s arrive below; the pill reads 3 (check 3); dots stop
    ///   at 30 s;
    /// - back at the bottom by 38 s: my message from another device at 38 s,
    ///   a working line at 40 s edited in place at 43 s, and the answer at
    ///   46 s, which hides the working line (check 7);
    /// - my message from another device at 58 s, dots at 60 s, and an answer
    ///   about two screens tall at 62 s that stays pinned to its end (check 8).
    static func chatLong(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatLong.rawValue
        let all = longTranscript(name: name, context: assistant, messages: 500, env: env, seed: 1)
        let (initial, pages) = split(all, initialEvents: 120, pageEvents: 20)
        let question = all.last { $0.isOwn && $0.kind == .message }?.eventID
        let step = { (number: Int) in "\(name).step-\(String(format: "%02d", number))" }
        let steps: [ScriptedStep] = [
            ScriptedStep(at: 4, .typing([Cast.atum])),
            ScriptedStep(at: 6, .arrive(answer(step(1), "Xong rồi. Mình đã gửi bản tóm tắt vào ghi chú của bạn.",
                                              replyTo: question))),
            ScriptedStep(at: 6, .typing([])),
            ScriptedStep(at: 20, .arrive(answer(step(2), "Nhắc nhở: 15 phút nữa bạn có cuộc gọi với nhóm thiết kế."))),
            ScriptedStep(at: 21, .arrive(answer(step(3), "Mình cũng đã dời lịch chạy bộ sang 6 giờ sáng mai."))),
            ScriptedStep(at: 22, .arrive(answer(step(4), ScriptedText.paragraph(seed: 22, sentences: 4)))),
            ScriptedStep(at: 23, .typing([Cast.atum])),
            ScriptedStep(at: 30, .typing([])),
            ScriptedStep(at: 38, .arrive(mine(step(5), "Tóm tắt giúp mình tài liệu dài vừa gửi nhé."))),
            ScriptedStep(at: 40, .arrive(notice(step(6), "Đang xử lý…", replyTo: "$" + step(5)))),
            ScriptedStep(at: 43, .edit(id: step(6), body: "Đang xử lý… sắp xong")),
            ScriptedStep(at: 46, .arrive(answer(step(7), ScriptedText.paragraph(seed: 46, sentences: 3),
                                               replyTo: "$" + step(5)))),
            ScriptedStep(at: 58, .arrive(mine(step(8), "Viết chi tiết kế hoạch tuần tới giúp mình."))),
            ScriptedStep(at: 60, .typing([Cast.atum])),
            ScriptedStep(at: 62, .arrive(answer(step(9), twoScreenAnswer(seed: 62), replyTo: "$" + step(8)))),
            ScriptedStep(at: 62, .typing([]))
        ]
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, olderPages: pages,
                              steps: steps, replies: atumReplies, names: Cast.names)
    }

    // MARK: Building blocks

    static let atumReplies = ScriptedReplies(
        sender: Cast.atum, seenAfter: 1.0, typingAfter: 1.2, answerAfter: 3.0,
        bodies: ["Mình nhận được rồi, đây là câu trả lời ngắn.",
                 "Được, mình làm ngay.\n\n1. Bước một\n2. Bước hai\n3. Bước ba",
                 "Câu trả lời của mình có **chữ đậm**, *chữ nghiêng* và `mã`."]
    )

    /// A remote text message from the room's agent (or `sender`), for steps.
    static func answer(_ id: String, _ body: String, replyTo: String? = nil, sender: String = Cast.atum,
                       agents: Set<String> = [Cast.atum]) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: sender, senderName: Cast.names[sender],
                 eventOrTransactionId: .event("$" + id), body: body, replyTo: replyTo,
                 resultFor: ChatItem.resultFor(kind: .message, sender: sender, replyTo: replyTo, agentUserIDs: agents))
    }

    /// A message from my own account sent on another device (the Mac).
    static func mine(_ id: String, _ body: String) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: Cast.me, isOwn: true, eventOrTransactionId: .event("$" + id),
                 body: body)
    }

    static func notice(_ id: String, _ body: String, replyTo: String? = nil, sender: String = Cast.atum) -> ChatItem {
        ChatItem(id: id, kind: .notice, sender: sender, senderName: Cast.names[sender],
                 eventOrTransactionId: .event("$" + id), body: body, replyTo: replyTo)
    }

    /// About two screens of text at the default Dynamic Type size.
    static func twoScreenAnswer(seed: UInt64) -> String {
        var random = ScriptedRandom(seed: seed)
        let days = ["Thứ Hai", "Thứ Ba", "Thứ Tư", "Thứ Năm", "Thứ Sáu", "Thứ Bảy", "Chủ Nhật"]
        let parts = days.map { day in
            "**\(day)**\n\n" + ScriptedText.list(&random, items: 6)
        }
        return "Đây là kế hoạch tuần tới của bạn.\n\n" + parts.joined(separator: "\n\n")
    }

    /// One unit per event: the event with the virtual items just before it.
    /// The newest `initialEvents` are cached at open; older ones come in pages
    /// of `pageEvents`, newest page first.
    static func split(_ all: [ChatItem], initialEvents: Int, pageEvents: Int) -> (initial: [ChatItem], pages: [[ChatItem]]) {
        var units: [[ChatItem]] = []
        var pending: [ChatItem] = []
        for item in all {
            pending.append(item)
            if item.kind.isEventContent {
                units.append(pending)
                pending = []
            }
        }
        if !pending.isEmpty {
            if units.isEmpty { units.append(pending) } else { units[units.count - 1] += pending }
        }
        let initial = Array(units.suffix(initialEvents)).flatMap { $0 }
        var rest = Array(units.dropLast(initialEvents))
        var pages: [[ChatItem]] = []
        while !rest.isEmpty {
            let chunk = rest.suffix(pageEvents)
            pages.append(chunk.flatMap { $0 })
            rest.removeLast(chunk.count)
        }
        return (initial, pages)
    }

    /// A long assistant transcript ending with my unanswered question.
    static func longTranscript(name: String, context: RoomContext, messages: Int, env: ScriptedEnvironment,
                               seed: UInt64) -> [ChatItem] {
        var random = ScriptedRandom(seed: seed)
        // Times first: short gaps, an hour-plus pause now and then, nights.
        var offsets: [TimeInterval] = []
        var time: TimeInterval = 0
        for index in 0..<messages {
            offsets.append(time)
            var gapMinutes = Double(random.next(8) + 1)
            if index % 23 == 22 { gapMinutes = Double(75 + random.next(90)) }
            if index % 61 == 60 { gapMinutes = 14 * 60 }
            time += gapMinutes * 60
        }
        let end = offsets.last ?? 0
        let dates = offsets.map { env.reference.addingTimeInterval($0 - end - 180) }

        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        var next = 0
        func date() -> Date { defer { next += 1 }; return dates[min(next, dates.count - 1)] }
        var files = 0
        let last = messages - 1
        turns: while next < last {
            let question = writer.add(from: context.ownUserID, at: date(), body: random.pick(ScriptedText.questions))
            guard next < last else { break turns }
            if random.next(6) == 0 {
                writer.add(.notice, from: Cast.atum, at: date(), body: "Đang xử lý…", replyTo: question.eventID)
                guard next < last else { break turns }
            }
            let body: String
            let variant = random.next(10)
            switch variant {
            case 0, 1, 2:
                let count = random.next(2) + 1
                body = ScriptedText.paragraph(&random, sentences: count)
            case 3, 4:
                let count = random.next(3) + 3
                body = ScriptedText.paragraph(&random, sentences: count)
            case 5:
                let first = ScriptedText.paragraph(&random, sentences: 4)
                body = first + "\n\n" + ScriptedText.paragraph(&random, sentences: 3)
            case 6:
                let count = random.next(4) + 3
                body = ScriptedText.list(&random, items: count)
            case 7:
                body = ScriptedText.code(lines: random.next(31) + 10)
            case 8:
                let tall = random.next(2) == 0
                writer.add(.image(width: tall ? 1080 : 1600, height: tall ? 1920 : 1000), from: Cast.atum, at: date())
                guard next < last else { break turns }
                body = "Ảnh minh hoạ ở trên."
            default:
                files += 1
                writer.add(.file(name: "bao-cao-\(files).pdf"), from: Cast.atum, at: date())
                guard next < last else { break turns }
                body = "Mình đã đính kèm báo cáo."
            }
            writer.add(from: Cast.atum, at: date(), body: body, replyTo: question.eventID)
            if random.next(12) == 0, next < last {
                writer.add(from: context.ownUserID, at: date(), body: "Ok, cảm ơn nhé.")
            }
        }
        writer.add(from: context.ownUserID, at: date(), body: "Tóm tắt lại giúp mình những việc còn lại hôm nay.")
        return writer.items
    }

    /// A short assistant transcript of `messages` items ending with my
    /// question, newest at `minutesAgo` before the launch.
    static func shortTranscript(name: String, messages: Int, env: ScriptedEnvironment, seed: UInt64,
                                minutesAgo: Double = 2) -> [ChatItem] {
        longTranscript(name: name, context: assistant, messages: messages,
                       env: ScriptedEnvironment(reference: env.ago(minutes: minutesAgo - 3), calendar: env.calendar),
                       seed: seed)
    }
}

extension ScriptedText {
    /// A paragraph from a fixed seed, for step bodies.
    static func paragraph(seed: UInt64, sentences count: Int) -> String {
        var random = ScriptedRandom(seed: seed)
        return paragraph(&random, sentences: count)
    }
}
#endif
