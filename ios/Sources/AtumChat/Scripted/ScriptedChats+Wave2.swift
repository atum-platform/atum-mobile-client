#if DEBUG
import Foundation

extension ScriptedChats {
    static func chatMedia(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatMedia.rawValue
        let context = RoomContext(kind: .group, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let sizes: [(Double?, Double?, String)] = [
            (1600, 900, "landscape"), (900, 1600, "portrait"),
            (1200, 1200, "square"), (nil, nil, "unknown"), (700, 1400, "caption")
        ]
        for (index, value) in sizes.enumerated() {
            writer.add(.image(width: value.0, height: value.1),
                       from: index.isMultiple(of: 2) ? Cast.lan : Cast.me,
                       at: env.ago(minutes: Double(20 - index)),
                       body: value.2 == "caption" ? "Con đường nhỏ sau cơn mưa." : "",
                       media: scriptedMedia(name + ".image." + value.2,
                                            mimetype: "image/jpeg",
                                            filename: value.2 + ".jpg"))
        }
        writer.add(.image(width: 1200, height: 800), from: Cast.lan,
                   at: env.ago(minutes: 1),
                   media: scriptedMedia(name + ".image.fail-once",
                                        mimetype: "image/jpeg", filename: "retry.jpg"))
        return ScriptedScript(name: name, title: "Nhóm thử", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func chatMediaFiles(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatMediaFiles.rawValue
        let context = RoomContext(kind: .person, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let files = [
            ("bao-cao.pdf", "application/pdf"), ("ghi-chu.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            ("du-lieu.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            ("trinh-bay.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
            ("tai-lieu.zip", "application/zip"), ("doan-phim.mp4", "video/mp4"),
            ("ghi-am.m4a", "audio/mp4"), ("hinh.svg", "image/svg+xml"), ("du-lieu.bin", "application/octet-stream")
        ]
        for (index, file) in files.enumerated() {
            writer.add(.file(name: file.0), from: Cast.lan,
                       at: env.ago(minutes: Double(files.count - index)),
                       media: scriptedMedia(name + ".file." + String(index),
                                            mimetype: file.1, filename: file.0))
        }
        return ScriptedScript(name: name, title: "Lan", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func chatMediaSend(_ env: ScriptedEnvironment) -> ScriptedScript {
        ScriptedScript(name: ScriptedScenario.chatMediaSend.rawValue, title: "Lan",
                       context: RoomContext(kind: .person, ownUserID: Cast.me),
                       initial: [], names: Cast.names)
    }

    static func chatMediaUpload(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatMediaUpload.rawValue
        let context = RoomContext(kind: .person, ownUserID: Cast.me)
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        writer.add(.image(width: 1200, height: 900), from: Cast.me, at: env.ago(minutes: 4),
                   media: scriptedMedia(name + ".queued", mimetype: "image/jpeg", filename: "queued.jpg"),
                   delivery: .sending())
        writer.add(.image(width: 900, height: 1200), from: Cast.me, at: env.ago(minutes: 3),
                   media: scriptedMedia(name + ".progress", mimetype: "image/jpeg", filename: "progress.jpg"),
                   delivery: .sending(progress: 0.4))
        writer.add(.file(name: "bao-cao.pdf"), from: Cast.me, at: env.ago(minutes: 2),
                   media: scriptedMedia(name + ".file", mimetype: "application/pdf", filename: "bao-cao.pdf"),
                   delivery: .sending(progress: 0.7))
        writer.add(.image(width: 1000, height: 1000), from: Cast.me, at: env.ago(minutes: 1),
                   media: scriptedMedia(name + ".failed", mimetype: "image/jpeg", filename: "failed.jpg"),
                   delivery: .failed(isRecoverable: true))
        return ScriptedScript(name: name, title: "Lan", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func chatMediaRefusal(_ env: ScriptedEnvironment) -> ScriptedScript {
        ScriptedScript(name: ScriptedScenario.chatMediaRefusal.rawValue, title: "Lan",
                       context: RoomContext(kind: .person, ownUserID: Cast.me),
                       initial: [], names: Cast.names)
    }

    static func chatMediaAnswers(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.chatMediaAnswers.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        writer.add(.image(width: 1600, height: 900), from: Cast.moon, at: env.ago(minutes: 2),
                   body: "Bản đồ bầu trời hôm nay.",
                   media: scriptedMedia(name + ".answer.image", mimetype: "image/jpeg", filename: "sky.jpg"))
        writer.add(.file(name: "ghi-chu.pdf"), from: Cast.moon, at: env.ago(minutes: 1),
                   body: "Ghi chú của Moon.",
                   media: scriptedMedia(name + ".answer.file", mimetype: "application/pdf", filename: "ghi-chu.pdf"))
        return ScriptedScript(name: name, title: "Moon", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func botMoonNotices(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.botMoonNotices.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let codes = ["needs_setup", "needs_setup",
                     "needs_intake", "unsupported_content", "message_too_long", "cannot_read",
                     "unverified_sender", "needs_setup", "link_pending", "allowance_exhausted", "busy",
                     "rate_limited", "app_unavailable", "app_timeout", "outcome_unknown", "missed_while_offline",
                     "sent_before_link", "andy_group_declined", "joined", "now_group", "andy_leaving"]
        for (index, code) in codes.enumerated() {
            let action: String = switch code {
            case "needs_setup", "needs_intake": #"{"app":"moon","kind":"open_setup"}"#
            case "link_pending": #"{"app":"moon","kind":"open_app_route","route_id":"readings"}"#
            case "joined": #"{"app":"moon","kind":"open_bot_dm"}"#
            default: "null"
            }
            let meta = noticeEvent(code: code, action: action)
            writer.add(.notice, from: Cast.moon, at: env.ago(minutes: Double(codes.count - index)),
                       body: "Thông báo từ Moon.\nMoon notice.", appBotMeta: meta)
        }
        return ScriptedScript(name: name, title: "Moon", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func botMoonNoticeEdited(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.botMoonNoticeEdited.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let notice = writer.add(.notice, from: Cast.moon, at: env.ago(minutes: 1),
                                body: "Moon chưa trả lời.\nMoon has not answered.",
                                appBotMeta: noticeEvent(
                                    code: "needs_setup",
                                    action: #"{"app":"moon","kind":"open_setup"}"#
                                ))
        return ScriptedScript(
            name: name, title: "Moon", context: context, initial: writer.items,
            steps: [
                ScriptedStep(at: 8, .editNotice(
                    id: notice.id,
                    body: "Moon cần thêm thông tin.\nMoon needs more details.",
                    appBotMeta: noticeEvent(
                        code: "needs_intake",
                        action: #"{"app":"moon","kind":"open_setup"}"#
                    )
                )),
            ],
            names: Cast.names
        )
    }

    static func botMoonNoticeSpoofed(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.botMoonNoticeSpoofed.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let values: [(itemSender: String, eventSender: String, metadata: String)] = [
            (Cast.moon, Cast.andy,
             #"{"action":null,"app_id":"\#(Cast.moonAppID)","code":"needs_setup","kind":"notice","turn_id":null,"v":1}"#),
            (Cast.moon, Cast.moon,
             #"{"action":null,"app_id":"\#(Cast.moonAppID)","code":"needs_setup","extra":true,"kind":"notice","turn_id":null,"v":1}"#),
            (Cast.moon, Cast.moon,
             #"{"action":{"app":"moon","kind":"unknown"},"app_id":"\#(Cast.moonAppID)","code":"needs_setup","kind":"notice","turn_id":null,"v":1}"#),
            (Cast.moon, Cast.moon,
             #"{"action":{"app":"moon","kind":"open_app_route","route_id":"purchase"},"app_id":"\#(Cast.moonAppID)","code":"needs_setup","kind":"notice","turn_id":null,"v":1}"#)
        ]
        for (index, value) in values.enumerated() {
            writer.add(.notice, from: value.itemSender,
                       at: env.ago(minutes: Double(values.count - index)),
                       body: "Thông báo không được xác thực.",
                       appBotMeta: eventEnvelope(metadata: value.metadata, sender: value.eventSender))
        }
        return ScriptedScript(name: name, title: "Moon", context: context,
                              initial: writer.items, names: Cast.names)
    }

    static func botContinueOnMac(_ env: ScriptedEnvironment) -> ScriptedScript {
        botMoonNotice(env, named: ScriptedScenario.botContinueOnMac.rawValue,
                      code: "needs_setup", action: #"{"app":"moon","kind":"open_setup"}"#)
    }

    static func botMoonChat(_ env: ScriptedEnvironment) -> ScriptedScript {
        botMoonNotice(env, named: ScriptedScenario.botMoonChat.rawValue,
                      code: "link_pending", action: "null")
    }

    static func botMoonEmpty(_ env: ScriptedEnvironment) -> ScriptedScript {
        emptyBot(named: ScriptedScenario.botMoonEmpty.rawValue)
    }

    static func botMoonRoomJoin(_ env: ScriptedEnvironment) -> ScriptedScript {
        let name = ScriptedScenario.botMoonRoomJoin.rawValue
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        writer.add(from: Cast.moon, at: env.ago(minutes: 1), body: "Moon đã sẵn sàng trò chuyện.")
        return ScriptedScript(name: name, title: "Moon", context: context,
                              initial: writer.items, names: Cast.names)
    }
    static func botMoonRoomJoinFails(_ env: ScriptedEnvironment) -> ScriptedScript {
        emptyBot(named: ScriptedScenario.botMoonRoomJoinFails.rawValue)
    }
    static func botAccentFallback(_ env: ScriptedEnvironment) -> ScriptedScript {
        botMoonNotice(env, named: ScriptedScenario.botAccentFallback.rawValue,
                      code: "needs_setup", action: #"{"app":"moon","kind":"open_setup"}"#)
    }

    private static func emptyBot(named name: String) -> ScriptedScript {
        ScriptedScript(name: name, title: "Moon",
                       context: RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon]),
                       initial: [], names: Cast.names)
    }

    private static func botMoonNotice(_ env: ScriptedEnvironment, named name: String,
                                      code: String, action: String) -> ScriptedScript {
        let context = RoomContext(kind: .appBot, ownUserID: Cast.me, agentUserIDs: [Cast.moon])
        var writer = ScriptedWriter(scenario: name, context: context, calendar: env.calendar)
        let meta = noticeEvent(code: code, action: action)
        writer.add(.notice, from: Cast.moon, at: env.ago(minutes: 1),
                   body: "Thông báo từ Moon.\nMoon notice.", appBotMeta: meta)
        return ScriptedScript(name: name, title: "Moon", context: context,
                              initial: writer.items, names: Cast.names)
    }

    private static func scriptedMedia(_ handle: String, mimetype: String,
                                      filename: String) -> ChatMedia {
        ChatMedia(sourceHandle: "scripted:" + handle,
                  thumbnailSourceHandle: "scripted:thumbnail:" + handle,
                  mimetype: mimetype, filename: filename,
                  isAnimated: mimetype == "image/gif", byteSize: 1_024)
    }

    private static func noticeEvent(code: String, action: String) -> String {
        let metadata = #"{"action":\#(action),"app_id":"\#(Cast.moonAppID)","code":"\#(code)","kind":"notice","turn_id":null,"v":1}"#
        return eventEnvelope(metadata: metadata, sender: Cast.moon)
    }

    private static func eventEnvelope(metadata: String, sender: String) -> String {
        #"{"content":{"io.atum.app_bot":\#(metadata)},"sender":"\#(sender)"}"#
    }
}
#endif
