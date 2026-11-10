/// Debug-only launch arguments (plan §2.10). The owner never passes any:
/// tapping the icon starts the normal app.
public struct AtumLaunchArguments: Equatable, Sendable {
    /// Turns off UIKit and SwiftUI animations so UI-test frame checks are
    /// stable.
    public static let noAnimationsFlag = "-AtumUITestNoAnimations"
    /// `-AtumScripted <scenario>` picks a synthetic timeline.
    public static let scriptedFlag = "-AtumScripted"
    public static let scriptedPinsFullFlag = "-AtumScriptedPinsFull"
    public static let scriptedMediaRefusalFlag = "-AtumScriptedMediaRefusal"
    public static let scriptedMissingAccentFlag = "-AtumScriptedMissingAccent"
    public static let scriptedSlowFileDownloadFlag = "-AtumScriptedSlowFileDownload"
    /// `-AtumScriptedTurnStop <answer>` gives a scripted assistant chat a
    /// stop route that answers `stopped`, `stop_requested`, `completed` or
    /// `failed`; `failed-then-stopped` fails once, then stops. Without it a
    /// scripted chat, like a live one without the route, offers no Stop.
    public static let scriptedTurnStopFlag = "-AtumScriptedTurnStop"

    public var disablesAnimations: Bool
    public var scriptedScenario: ScriptedScenario?

    public init(_ arguments: [String]) {
        disablesAnimations = arguments.contains(Self.noAnimationsFlag)
        if let flag = arguments.firstIndex(of: Self.scriptedFlag), flag + 1 < arguments.count {
            scriptedScenario = ScriptedScenario(rawValue: arguments[flag + 1])
        } else {
            scriptedScenario = nil
        }
    }

    /// The arguments a UI test passes for a scenario.
    public static func arguments(scenario: ScriptedScenario?, disablesAnimations: Bool = true) -> [String] {
        var values: [String] = []
        if disablesAnimations { values.append(noAnimationsFlag) }
        if let scenario { values += [scriptedFlag, scenario.rawValue] }
        return values
    }
}

/// The synthetic scenarios of plan §2.10. The data lives in
/// `Sources/AtumChat/Scripted`; only the names are frozen here. `chat.actions`
/// and `chat.kinds` joined in the S1 day-1 contract amendment.
public enum ScriptedScenario: String, CaseIterable, Sendable {
    case chatLong = "chat.long"
    case chatLongAnswer = "chat.long-answer"
    case chatReplyAtBottom = "chat.reply-at-bottom"
    case chatReplyScrolledUp = "chat.reply-scrolled-up"
    case chatOwnOtherDevice = "chat.own-other-device"
    case chatSend = "chat.send"
    case chatSendFails = "chat.send-fails"
    case chatPaginate = "chat.paginate"
    case chatKeyboard = "chat.keyboard"
    case chatEmpty = "chat.empty"
    case chatPeople = "chat.people"
    case homeRoster = "home.roster"
    case homeInvite = "home.invite"
    case homePinsFull = "home.pins-full"
    case botMoonNoRoom = "bot.moon-no-room"
    case botMoonNotice = "bot.moon-notice"
    case botMoonNotices = "bot.moon-notices"
    case botMoonNoticeEdited = "bot.moon-notice-edited"
    case botMoonNoticeSpoofed = "bot.moon-notice-spoofed"
    case botContinueOnMac = "bot.continue-on-mac"
    case botMoonChat = "bot.moon-chat"
    case botMoonEmpty = "bot.moon-empty"
    case botMoonRoomJoin = "bot.moon-room-join"
    case botMoonRoomJoinFails = "bot.moon-room-join-fails"
    case botAccentFallback = "bot.accent-fallback"
    case chatMedia = "chat.media"
    case chatMediaFiles = "chat.media-files"
    case chatMediaSend = "chat.media-send"
    case chatMediaUpload = "chat.media-upload"
    case chatMediaRefusal = "chat.media-refusal"
    case chatMediaAnswers = "chat.media-answers"
    /// S1: the long-press menu, reply and quote, reactions.
    case chatActions = "chat.actions"
    /// S1: every B19 kind, image boxes and file rows.
    case chatKinds = "chat.kinds"
    /// Review C1: my assistant keeps working on what I send and never
    /// answers, for the composer's working state and Stop.
    case chatTurnStop = "chat.turn-stop"
}
