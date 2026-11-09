#if DEBUG
import Foundation

/// A scripted chat list: the rooms the SDK's room list would report and the
/// app catalog, as plain values (plan §2.10 `ScriptedRoster`). The app feeds
/// them through the same tested policies it uses for live rooms
/// (`MobileAgentRoomPolicy`, `MobileAppBotRoomPolicy.chooseChat`), so a
/// scenario proves the policy, not a hard-coded list.
public struct ScriptedRoster: Sendable {
    public var rooms: [ScriptedRosterRoom]
    public var apps: [ScriptedRosterApp]
    /// Desktop pointers (`io.atum.app_bot.dm.<appID>` account data), app ID
    /// → room ID.
    public var pointers: [String: String]
    /// Debug-only phone-local hidden-room fixture, used for the catalog app
    /// row that reopens an existing room.
    public var hiddenRoomIDs: Set<String>
    public var hiddenAt: Date?

    public init(rooms: [ScriptedRosterRoom], apps: [ScriptedRosterApp] = [],
                pointers: [String: String] = [:], hiddenRoomIDs: Set<String> = [],
                hiddenAt: Date? = nil) {
        self.rooms = rooms
        self.apps = apps
        self.pointers = pointers
        self.hiddenRoomIDs = hiddenRoomIDs
        self.hiddenAt = hiddenAt
    }
}

/// One room in the SDK's room list.
public struct ScriptedRosterRoom: Sendable {
    public enum Membership: Equatable, Sendable {
        case joined
        case invited(by: String)
    }

    public var roomID: String
    public var name: String
    /// The other members, joined or invited (not me).
    public var members: [String]
    public var isDirect: Bool
    public var encrypted: Bool
    public var membership: Membership
    public var latestTimestamp: Date?
    public var latestSenderID: String?
    public var latestBody: String
    public var latestPreviewContent: RowPreview.Content?
    public var latestSendState: RowPreview.SendState
    public var unreadCount: Int
    public var mentionCount: Int
    public var isFavourite: Bool
    public var isMarkedUnread: Bool
    public var isMuted: Bool
    /// The chat scenario this row opens, if any.
    public var opens: String?

    public init(roomID: String, name: String, members: [String], isDirect: Bool = true, encrypted: Bool = false,
                membership: Membership = .joined, latestTimestamp: Date? = nil, latestSenderID: String? = nil,
                latestBody: String = "", latestPreviewContent: RowPreview.Content? = nil,
                latestSendState: RowPreview.SendState = .sent,
                unreadCount: Int = 0, mentionCount: Int = 0, isFavourite: Bool = false,
                isMarkedUnread: Bool = false, isMuted: Bool = false, opens: String? = nil) {
        self.roomID = roomID
        self.name = name
        self.members = members
        self.isDirect = isDirect
        self.encrypted = encrypted
        self.membership = membership
        self.latestTimestamp = latestTimestamp
        self.latestSenderID = latestSenderID
        self.latestBody = latestBody
        self.latestPreviewContent = latestPreviewContent
        self.latestSendState = latestSendState
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isFavourite = isFavourite
        self.isMarkedUnread = isMarkedUnread
        self.isMuted = isMuted
        self.opens = opens
    }
}

/// One catalog app with a bot (`/apps`).
public struct ScriptedRosterApp: Equatable, Sendable {
    public var appID: String
    public var name: String
    public var botUserID: String

    public init(appID: String, name: String, botUserID: String) {
        self.appID = appID
        self.name = name
        self.botUserID = botUserID
    }
}

enum ScriptedRosters {
    typealias Cast = ScriptedCast

    static let catalog = [
        ScriptedRosterApp(appID: Cast.moonAppID, name: "Moon", botUserID: Cast.moon),
        ScriptedRosterApp(appID: Cast.andyAppID, name: "Andy", botUserID: Cast.andy)
    ]

    static func atumRoom(_ env: ScriptedEnvironment) -> ScriptedRosterRoom {
        ScriptedRosterRoom(roomID: "!atum-plain:atum.test", name: "Atum", members: [Cast.atum],
                           latestTimestamp: env.ago(minutes: 3), latestSenderID: Cast.me,
                           latestBody: "Tóm tắt lại giúp mình những việc còn lại hôm nay.",
                           opens: ScriptedScenario.chatLong.rawValue)
    }

    /// `bot.moon-no-room` (§4.2 item 1): Moon is in the catalog but this
    /// person has no plain room with it, only an old encrypted one (which
    /// the desktop pointer still names). No Moon row is listed and nothing
    /// opens the Store. Andy has a plain room with messages, so Andy's row
    /// is listed.
    static func botMoonNoRoom(_ env: ScriptedEnvironment) -> ScriptedRoster {
        ScriptedRoster(rooms: [
            atumRoom(env),
            ScriptedRosterRoom(roomID: "!andy-plain:atum.test", name: "Andy", members: [Cast.andy],
                               latestTimestamp: env.ago(minutes: 90), latestSenderID: Cast.andy,
                               latestBody: "Chào bạn, mình là Andy."),
            ScriptedRosterRoom(roomID: "!moon-encrypted-old:atum.test", name: "Moon", members: [Cast.moon],
                               encrypted: true, latestTimestamp: env.ago(minutes: 60 * 24 * 9),
                               latestSenderID: Cast.moon, latestBody: "")
        ], apps: catalog, pointers: [Cast.moonAppID: "!moon-encrypted-old:atum.test"])
    }

    /// `bot.moon-notice`: a plain Moon room the desktop pointer names, which
    /// opens the Moon chat scenario.
    static func botMoonNotice(_ env: ScriptedEnvironment) -> ScriptedRoster {
        ScriptedRoster(rooms: [
            ScriptedRosterRoom(roomID: "!moon-plain:atum.test", name: "Moon", members: [Cast.moon],
                               latestTimestamp: env.ago(minutes: 4), latestSenderID: Cast.moon,
                               latestBody: "Cảm ơn bạn.", unreadCount: 1,
                               opens: ScriptedScenario.botMoonNotice.rawValue),
            atumRoom(env)
        ], apps: catalog, pointers: [Cast.moonAppID: "!moon-plain:atum.test"])
    }

    /// `home.roster` (S2 §5): the frozen visual roster and app-badge total 9.
    static func homeRoster(_ env: ScriptedEnvironment) -> ScriptedRoster {
        ScriptedRoster(rooms: [
            ScriptedRosterRoom(roomID: "!atum-plain:atum.test", name: "Atum", members: [Cast.atum],
                               latestTimestamp: env.ago(minutes: 2), latestSenderID: Cast.me,
                               latestBody: "Nhắc mình gọi cho mẹ lúc 7 giờ",
                               opens: ScriptedScenario.chatLong.rawValue),
            ScriptedRosterRoom(roomID: "!atum-encrypted-old:atum.test", name: "Atum", members: [Cast.atum],
                               encrypted: true, latestTimestamp: env.ago(minutes: 60 * 24 * 20),
                               latestSenderID: Cast.atum, latestBody: ""),
            ScriptedRosterRoom(roomID: "!luna-plain:atum.test", name: "Luna", members: [Cast.luna],
                               latestTimestamp: env.ago(minutes: 6), latestSenderID: Cast.luna,
                               latestBody: "Mình đã chuẩn bị xong.", unreadCount: 2),
            ScriptedRosterRoom(roomID: "!analyst-plain:atum.test", name: "Nhà phân tích",
                               members: [Cast.analyst]),
            ScriptedRosterRoom(roomID: "!lan:atum.test", name: "Lan", members: [Cast.lan],
                               encrypted: true, latestTimestamp: env.ago(minutes: 7), latestSenderID: Cast.lan,
                               latestBody: "Mai gặp nhé.", unreadCount: 1, isFavourite: true,
                               opens: ScriptedScenario.chatPeople.rawValue),
            ScriptedRosterRoom(roomID: "!gia-dinh:atum.test", name: "Gia đình",
                               members: [Cast.minh, Cast.lan], isDirect: false, encrypted: true,
                               latestTimestamp: env.ago(minutes: 9), latestSenderID: Cast.minh,
                               latestPreviewContent: .image, unreadCount: 5, mentionCount: 3,
                               opens: ScriptedScenarios.chatKinds),
            ScriptedRosterRoom(roomID: "!hoa:atum.test", name: "Hoa", members: [Cast.hoa], encrypted: true,
                               latestTimestamp: env.ago(minutes: 18), latestSenderID: Cast.hoa,
                               latestBody: "Mình gửi rồi nhé.", unreadCount: 4, isMuted: true),
            ScriptedRosterRoom(roomID: "!tuan:atum.test", name: "Tuấn", members: [Cast.tuan], encrypted: true,
                               latestTimestamp: env.ago(minutes: 35), latestSenderID: Cast.tuan,
                               latestBody: "Cảm ơn bạn.", isMarkedUnread: true),
            ScriptedRosterRoom(roomID: "!chi-mai:atum.test", name: "Chị Mai", members: [Cast.chiMai],
                               encrypted: true, latestTimestamp: env.ago(minutes: 42),
                               latestSenderID: Cast.me, latestBody: "Ok chị",
                               latestSendState: .sending),
            ScriptedRosterRoom(roomID: "!anh-khoa:atum.test", name: "Anh Khoa", members: [Cast.anhKhoa],
                               encrypted: true, latestTimestamp: env.ago(minutes: 55),
                               latestSenderID: Cast.me, latestBody: "Để em kiểm tra.",
                               latestSendState: .cannotBeSent),
            ScriptedRosterRoom(roomID: "!moon-plain:atum.test", name: "Moon", members: [Cast.moon],
                               latestTimestamp: env.ago(minutes: 65), latestSenderID: Cast.moon,
                               latestBody: "Hôm nay bạn sẽ có một ngày thuận lợi.",
                               latestPreviewContent: .appNotice([
                                   .init(localeIdentifier: "vi", text: "Hôm nay bạn sẽ có một ngày thuận lợi."),
                                   .init(localeIdentifier: "en", text: "A favourable day is ahead.")
                               ])),
            ScriptedRosterRoom(roomID: "!andy-plain:atum.test", name: "Andy", members: [Cast.andy],
                               latestTimestamp: env.ago(minutes: 60 * 50), latestSenderID: Cast.andy,
                               latestBody: "Chào bạn, mình là Andy.")
        ], apps: catalog, hiddenRoomIDs: ["!andy-plain:atum.test"], hiddenAt: env.reference)
    }

    static func homeInvite(_ env: ScriptedEnvironment) -> ScriptedRoster {
        ScriptedRoster(rooms: [
            atumRoom(env),
            ScriptedRosterRoom(
                roomID: "!dang-invite:atum.test", name: "Đặng", members: ["@dang:atum.test"],
                membership: .invited(by: "@dang:atum.test"), latestTimestamp: env.ago(minutes: 1)
            ),
        ])
    }

    static func homePinsFull(_ env: ScriptedEnvironment) -> ScriptedRoster {
        var roster = homeRoster(env)
        let pinned: Set<String> = [
            "!lan:atum.test", "!gia-dinh:atum.test", "!hoa:atum.test",
            "!tuan:atum.test", "!chi-mai:atum.test",
        ]
        for index in roster.rooms.indices {
            roster.rooms[index].isFavourite = pinned.contains(roster.rooms[index].roomID)
        }
        return roster
    }
}
#endif
