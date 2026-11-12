#if DEBUG
import Foundation

/// The focused scenarios: one behaviour each, short timings for UI tests.
extension ScriptedChats {
    /// U1 open at the bottom with dividers and grouping; G-scroll check 8 and
    /// B3: an answer about two screens tall arrives at the bottom (dots at
    /// 1.5 s, answer at 3 s) and stays pinned to its end.
    static func chatLongAnswer(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatLongAnswer.rawValue
        let initial = shortTranscript(name: name, messages: 30, env: env, seed: 2)
        let question = initial.last { $0.isOwn && $0.kind == .message }?.eventID
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, steps: [
            ScriptedStep(at: 1.5, .typing([Cast.atum])),
            ScriptedStep(at: 3, .arrive(answer("\(name).answer", twoScreenAnswer(seed: 3), replyTo: question))),
            ScriptedStep(at: 3, .typing([]))
        ], replies: atumReplies, names: Cast.names)
    }

    /// B17 and G-scroll check 7: a working line at 1.5 s, edited in place at
    /// 3 s, dots at 4 s, and at 5.5 s the answer to the same message, which
    /// hides the working line. `chat.reply-at-bottom.working` is the line,
    /// `chat.reply-at-bottom.answer` the answer.
    static func chatReplyAtBottom(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatReplyAtBottom.rawValue
        let initial = shortTranscript(name: name, messages: 20, env: env, seed: 4)
        let question = initial.last { $0.isOwn && $0.kind == .message }?.eventID
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, steps: [
            ScriptedStep(at: 1.5, .arrive(notice("\(name).working", "Đang xử lý…", replyTo: question,
                                                  progress: ChatProgress(phase: .working)))),
            ScriptedStep(at: 3, .edit(id: "\(name).working", body: "Đang xử lý… sắp xong")),
            ScriptedStep(at: 4, .typing([Cast.atum])),
            ScriptedStep(at: 5.5, .arrive(answer("\(name).answer", ScriptedText.paragraph(seed: 5, sentences: 3),
                                                 replyTo: question))),
            ScriptedStep(at: 5.5, .typing([]))
        ], replies: atumReplies, names: Cast.names)
    }

    /// U3 and G-scroll check 3: many screens of history; scroll up three
    /// screens within 5 s. Three answers arrive at 5, 5.5 and 6 s, then the
    /// dots at 6.5 s; the top row stays put and the pill reads 3. The dots
    /// stop at 15 s with no fourth message.
    static func chatReplyScrolledUp(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatReplyScrolledUp.rawValue
        let initial = shortTranscript(name: name, messages: 150, env: env, seed: 6)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, steps: [
            ScriptedStep(at: 5, .arrive(answer("\(name).new-1", "Nhắc nhở: cuộc gọi lúc 3 giờ."))),
            ScriptedStep(at: 5.5, .arrive(answer("\(name).new-2", "Mình đã cập nhật lịch tuần sau."))),
            ScriptedStep(at: 6, .arrive(answer("\(name).new-3", ScriptedText.paragraph(seed: 7, sentences: 3)))),
            ScriptedStep(at: 6.5, .typing([Cast.atum])),
            ScriptedStep(at: 15, .typing([]))
        ], replies: atumReplies, names: Cast.names)
    }

    /// §2.5 `chat.own-other-device`: scroll up within 5 s. At 5 s a message
    /// from my own account sent on the Mac arrives: the pill counts it (1)
    /// and the view does not move.
    static func chatOwnOtherDevice(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatOwnOtherDevice.rawValue
        let initial = shortTranscript(name: name, messages: 150, env: env, seed: 8)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, steps: [
            ScriptedStep(at: 5, .arrive(mine("\(name).from-mac", "Gửi từ máy Mac: nhắc mình mua quà sinh nhật.")))
        ], replies: atumReplies, names: Cast.names)
    }

    /// U4 and U4b. A send is accepted after 1.5 s, so U4's first check after
    /// the tap finds the clock even on a slow simulator; the remote copy
    /// lands 0.15 s later, and Atum's receipt 2.5 s after that, so "Đã gửi"
    /// shows from 1.5 s to about 4.15 s, then "Đã xem". The dots start at
    /// about 5.65 s and the answer lands at about 7.65 s, after U4b's checks.
    static func chatSend(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatSend.rawValue
        return ScriptedScript(name: name, title: "Atum", context: assistant,
                              initial: shortTranscript(name: name, messages: 12, env: env, seed: 9),
                              sends: .succeeds(after: 1.5), replies: sendReplies, names: Cast.names)
    }

    /// Review C1: Atum reads what I send and keeps typing; no answer comes,
    /// so the turn stays in progress for the composer's Stop.
    static func chatTurnStop(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatTurnStop.rawValue
        return ScriptedScript(name: name, title: "Atum", context: assistant,
                              initial: shortTranscript(name: name, messages: 6, env: env, seed: 21),
                              sends: .succeeds(after: 0.5),
                              replies: ScriptedReplies(sender: Cast.atum, seenAfter: 0.8, typingAfter: 1.2),
                              names: Cast.names)
    }

    /// Atum in `chat.send`: the receipt, the dots and the answer wait long
    /// enough for U4b to see "Đã gửi" before "Đã xem".
    static let sendReplies = ScriptedReplies(sender: Cast.atum, seenAfter: 2.5, typingAfter: 4, answerAfter: 6,
                                             bodies: atumReplies.bodies)

    /// U5 and B8: a send that goes out fails recoverably after 0.6 s ("Chưa
    /// gửi được") and disables the room's queue, so later sends wait with the
    /// clock; "Thử lại" re-enables the queue, which resends it 1.5 s later
    /// with no update in between (as the pinned SDK: re-enabling a queue
    /// emits nothing, so any clock in that gap is the store's own); "Xóa"
    /// removes the row and leaves the queue disabled, so the store must
    /// re-enable it or what waited behind stays sending. The last cached
    /// message is a parked (unrecoverable) failure from an earlier run (D8),
    /// retried with `retrySend`, which does show the clock again.
    static func chatSendFails(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatSendFails.rawValue
        var initial = shortTranscript(name: name, messages: 10, env: env, seed: 10, minutesAgo: 6)
        let parkedID = "\(name).parked"
        initial.append(ChatItem(id: parkedID, kind: .message, sender: Cast.me, isOwn: true, isLocalEcho: true,
                                timestamp: env.ago(minutes: 4), delivery: .failed(isRecoverable: false),
                                eventOrTransactionId: .transaction("txn-" + parkedID),
                                body: "Tin này chưa gửi được từ lần trước."))
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial,
                              sends: .failsRecoverably(after: 0.6, retryAfter: 1.5), replies: atumReplies,
                              names: Cast.names)
    }

    /// U6 and B5: two screens cached, five older pages of 20, then the start
    /// of the room.
    static func chatPaginate(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatPaginate.rawValue
        let all = longTranscript(name: name, context: assistant, messages: 140, env: env, seed: 11)
        let (initial, pages) = split(all, initialEvents: 40, pageEvents: 20)
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: initial, olderPages: pages,
                              replies: atumReplies, names: Cast.names)
    }

    /// U7 and U8: a few screens and no events, for the keyboard and the
    /// composer growing to six lines.
    static func chatKeyboard(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatKeyboard.rawValue
        return ScriptedScript(name: name, title: "Atum", context: assistant,
                              initial: shortTranscript(name: name, messages: 40, env: env, seed: 12),
                              replies: atumReplies, names: Cast.names)
    }

    /// U10 and B2: an empty room at its start; the greeting shows.
    static func chatEmpty(_: ScriptedEnvironment) -> ScriptedScript {
        ScriptedScript(name: ScriptedScenario.chatEmpty.rawValue, title: "Atum", context: assistant, initial: [],
                       replies: atumReplies, names: Cast.names)
    }

    /// B11, B12, B16 (§2.7: no name on the other person's bubbles) and the
    /// people "Đã xem": a 1:1 chat with Minh Anh. Dots never show: her
    /// typing is the line above the composer (3 s to 6 s), then her message.
    /// My sends are seen after 1.5 s and answered at 5 s.
    static func chatPeople(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatPeople.rawValue
        let context = RoomContext(kind: .person, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let lines: [(String, String)] = [
            (Cast.minhAnh, "Chào bạn, cuối tuần này rảnh không?"),
            (Cast.me, "Rảnh nè, có chuyện gì vậy?"),
            (Cast.minhAnh, "Nhóm định đi cà phê sáng Chủ Nhật."),
            (Cast.minhAnh, "Bạn đi cùng nhé?"),
            (Cast.me, "Ok, mấy giờ?"),
            (Cast.minhAnh, "Khoảng 9 giờ, ở quán cũ."),
            (Cast.me, "Được, mình sẽ tới."),
            (Cast.minhAnh, "Nhớ mang cuốn sách hôm trước nhé."),
            (Cast.me, "Ừ, mình để sẵn trong túi rồi."),
            (Cast.minhAnh, "Tuyệt!")
        ]
        for (index, line) in lines.enumerated() {
            writer.add(from: line.0, at: env.ago(minutes: Double(60 * 26 - index * 3)), body: line.1)
        }
        let book = writer.items.last { $0.body.hasPrefix("Ừ, mình để sẵn") }?.eventID
        writer.add(from: Cast.minhAnh, at: env.ago(minutes: 40), body: "Cảm ơn bạn nhiều!", replyTo: book)
        writer.add(from: Cast.minhAnh, at: env.ago(minutes: 38), body: "Sáng mai mình gọi bạn nhé.", isEdited: true)
        writer.add(from: Cast.me, at: env.ago(minutes: 30), body: "Ok bạn.",
                   reactions: [ChatReaction(key: "👍", senderIDs: [Cast.minhAnh])], receipts: [Cast.minhAnh])
        return ScriptedScript(name: name, title: "Minh Anh", context: context, initial: writer.items, steps: [
            ScriptedStep(at: 3, .typing([Cast.minhAnh])),
            ScriptedStep(at: 6, .arrive(answer("\(name).new", "Mai gặp nhé!", sender: Cast.minhAnh, agents: []))),
            ScriptedStep(at: 6, .typing([]))
        ], replies: ScriptedReplies(sender: Cast.minhAnh, seenAfter: 1.5, typingAfter: 2.5, answerAfter: 5,
                                    bodies: ["Ok bạn 👍", "Để mình xem rồi báo lại nhé."], answersAsReply: false),
                              names: Cast.names)
    }

    /// `chat.actions` (S1): the long-press menu in an assistant chat (B20),
    /// reply and quote (B21), reactions (B22). The answer directly under its
    /// question shows no quote; the answer with my other message in between
    /// shows one. My messages can be deleted; answers offer "Chọn văn bản".
    static func chatActions(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenarios.chatActions
        var writer = ScriptedWriter(scenario: name, context: assistant, calendar: env.calendar)
        let intro = writer.add(from: Cast.me, at: env.ago(minutes: 30), body: "Viết giúp mình đoạn giới thiệu ngắn về dự án.")
        writer.add(from: Cast.atum, at: env.ago(minutes: 29),
                   body: "**Dự án Góc Phố** là một ứng dụng nhỏ giúp nhóm bạn hẹn gặp nhau.\n\n" +
                       "- Tạo lịch chung trong vài giây\n- Nhắc trước giờ hẹn\n- Gợi ý địa điểm gần mọi người\n\n" +
                       "Bạn có thể đọc thêm tại https://atumplatform.com.",
                   replyTo: intro.eventID, reactions: [ChatReaction(key: "👍", senderIDs: [Cast.me])])
        let conclusion = writer.add(from: Cast.me, at: env.ago(minutes: 20), body: "Cảm ơn! Còn phần kết luận?")
        writer.add(from: Cast.me, at: env.ago(minutes: 19), body: "À, thêm một ý về ngân sách nữa.")
        writer.add(from: Cast.atum, at: env.ago(minutes: 18),
                   body: "Kết luận: dự án cần ba tháng và ngân sách vừa phải; mình đã thêm ý về ngân sách.",
                   replyTo: conclusion.eventID)
        writer.add(from: Cast.me, at: env.ago(minutes: 10), body: "Ok, tuyệt.",
                   reactions: [ChatReaction(key: "❤️", senderIDs: [Cast.atum])], receipts: [Cast.atum])
        return ScriptedScript(name: name, title: "Atum", context: assistant, initial: writer.items,
                              replies: atumReplies, names: Cast.names)
    }

    /// `chat.kinds` (S1): every B19 kind in a group, from yesterday to today:
    /// text, emote, a person's notice, image boxes with and without a size,
    /// file, video and audio rows, deleted, both undecryptable groups and the
    /// unsupported placeholder, sticker, poll and location bodies, hidden room
    /// state, the read marker, a quote, an edit, and my message seen by two
    /// ("Đã xem · 2").
    static func chatKinds(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenarios.chatKinds
        let context = RoomContext(kind: .group, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        var minutes = 26.0 * 60
        func at() -> Date {
            minutes -= 7
            return env.ago(minutes: minutes)
        }
        writer.add(.roomState, from: Cast.lan, at: at())
        writer.add(from: Cast.lan, at: at(), body: "Chào cả nhóm!")
        writer.add(from: Cast.huy, at: at(), body: "vẫy tay chào mọi người")
        writer.add(.notice, from: Cast.quan, at: at(), body: "Quân đã đổi giờ họp sang 4 giờ.")
        writer.add(.image(width: 1200, height: 900), from: Cast.lan, at: at())
        writer.add(.image(width: nil, height: nil), from: Cast.huy, at: at())
        writer.add(.file(name: "bao-cao-quy-3.pdf"), from: Cast.quan, at: at())
        writer.add(.file(name: "clip-buoi-hop.mp4"), from: Cast.lan, at: at())
        writer.add(.file(name: "ghi-am.m4a"), from: Cast.huy, at: at())
        minutes = 3 * 60
        writer.add(.roomState, from: Cast.huy, at: at())
        writer.add(.placeholder(.redacted), from: Cast.huy, at: at())
        writer.add(.placeholder(.undecryptableOldHistory), from: Cast.quan, at: at())
        writer.add(.placeholder(.undecryptable), from: Cast.lan, at: at())
        writer.add(.placeholder(.unsupported), from: Cast.huy, at: at())
        writer.readMarker()
        writer.add(from: Cast.lan, at: at(), body: "🎉")
        writer.add(from: Cast.quan, at: at(), body: "Thứ Sáu đi ăn trưa không?")
        writer.add(from: Cast.huy, at: at(), body: "Quán cà phê Góc Phố")
        let mine = writer.add(from: Cast.me, at: at(), body: "Mình đi được, hẹn 12 giờ nhé.",
                              receipts: [Cast.lan, Cast.huy])
        writer.add(from: Cast.lan, at: at(), body: "Ok, 12 giờ.", replyTo: mine.eventID)
        writer.add(from: Cast.quan, at: at(), body: "Mình tới muộn mười phút.", isEdited: true)
        return ScriptedScript(name: name, title: "Nhóm thử", context: context, initial: writer.items,
                              replies: ScriptedReplies(sender: Cast.lan, seenAfter: 1.5), names: Cast.names)
    }

    /// `bot.moon-notice` (§4.2 item 3; S5 adds buttons): a plain Moon room.
    /// The bot's notice body is "vi line, newline, en line" with
    /// `io.atum.app_bot` metadata; S1 shows one line. An answer carries an
    /// allowed link and a PayOS link (the `LinkPolicy` hold). Dots at 3 s,
    /// an answer at 5 s.
    static func botMoonNotice(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.botMoonNotice.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        writer.add(from: Cast.moon, at: env.ago(minutes: 50), body: "Chào bạn, mình là Moon.")
        let question = writer.add(from: Cast.me, at: env.ago(minutes: 45), body: "Hôm nay của mình thế nào?")
        let metadata = #"{"action":{"app":"moon","kind":"open_setup"},"app_id":"\#(Cast.moonAppID)","code":"needs_setup","kind":"notice","turn_id":null,"v":1}"#
        let meta = #"{"content":{"io.atum.app_bot":\#(metadata)},"sender":"\#(Cast.moon)"}"#
        writer.add(.notice, from: Cast.moon, at: env.ago(minutes: 44),
                   body: "Để Moon trả lời, bạn cần bắt đầu một lần trên Atum cho máy tính.\nTo get answers from Moon, set it up once in Atum for Mac.",
                   replyTo: question.eventID, appBotMeta: meta)
        let again = writer.add(from: Cast.me, at: env.ago(minutes: 5), body: "Mình đã bắt đầu rồi.")
        writer.add(from: Cast.moon, at: env.ago(minutes: 4),
                   body: "Cảm ơn bạn. Xem thêm tại https://atumplatform.com/moon.\n\nThanh toán: https://pay.payos.vn/web/scripted-test",
                   replyTo: again.eventID)
        return ScriptedScript(name: name, title: "Moon", context: context, initial: writer.items, steps: [
            ScriptedStep(at: 3, .typing([Cast.moon])),
            ScriptedStep(at: 5, .arrive(answer("\(name).answer", "Hôm nay là một ngày tốt để bắt đầu việc mới.",
                                               sender: Cast.moon, agents: [Cast.moon]))),
            ScriptedStep(at: 5, .typing([]))
        ], replies: ScriptedReplies(sender: Cast.moon, seenAfter: 1, typingAfter: 1.2, answerAfter: 4,
                                    bodies: ["Moon đã nhận được tin của bạn."]),
                              names: Cast.names)
    }
}
#endif
