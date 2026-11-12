#if DEBUG
import Foundation

/// What `-AtumScripted <scenario>` opens: a chat, a chat list, or both.
public struct ScriptedSelection: Sendable {
    public var name: String
    /// The chat to open at launch, for chat scenarios.
    public var chat: ScriptedScript?
    /// The chat list, for roster scenarios.
    public var roster: ScriptedRoster?

    public init(name: String, chat: ScriptedScript?, roster: ScriptedRoster?) {
        self.name = name
        self.chat = chat
        self.roster = roster
    }
}

/// The scenario registry (plan §2.10). Names come from the frozen
/// `ScriptedScenario` enum, which gained S1's two names in the day-1
/// contract amendment (§5.3).
public enum ScriptedScenarios {
    /// S1: the long-press menu, reply and quote, reactions.
    public static let chatActions = ScriptedScenario.chatActions.rawValue
    /// S1: every B19 kind, image boxes and file rows.
    public static let chatKinds = ScriptedScenario.chatKinds.rawValue

    /// Every scenario name the app accepts.
    public static var allNames: [String] {
        ScriptedScenario.allCases.map(\.rawValue)
    }

    /// The name after `-AtumScripted`, whether or not the enum knows it
    /// (`AtumLaunchArguments` drops names it does not know).
    public static func name(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: AtumLaunchArguments.scriptedFlag),
              flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    /// The launch arguments a UI test passes for any scenario name.
    public static func arguments(name: String, disablesAnimations: Bool = true) -> [String] {
        (disablesAnimations ? [AtumLaunchArguments.noAnimationsFlag] : []) + [AtumLaunchArguments.scriptedFlag, name]
    }

    /// The scenario the launch arguments pick, built for this launch.
    public static func selection(arguments: [String], environment: ScriptedEnvironment = ScriptedEnvironment())
        -> ScriptedSelection? {
        name(in: arguments).flatMap { selection(named: $0, environment: environment) }
    }

    /// One scenario by name; nil for an unknown name.
    public static func selection(named name: String, environment env: ScriptedEnvironment = ScriptedEnvironment())
        -> ScriptedSelection? {
        func chat(_ script: ScriptedScript) -> ScriptedSelection {
            ScriptedSelection(name: name, chat: script, roster: nil)
        }
        guard let scenario = ScriptedScenario(rawValue: name) else { return nil }
        switch scenario {
        case .chatLong: return chat(ScriptedChats.chatLong(env))
        case .chatLongAnswer: return chat(ScriptedChats.chatLongAnswer(env))
        case .chatReplyAtBottom: return chat(ScriptedChats.chatReplyAtBottom(env))
        case .chatReplyScrolledUp: return chat(ScriptedChats.chatReplyScrolledUp(env))
        case .chatOwnOtherDevice: return chat(ScriptedChats.chatOwnOtherDevice(env))
        case .chatSend: return chat(ScriptedChats.chatSend(env))
        case .chatSendFails: return chat(ScriptedChats.chatSendFails(env))
        case .chatPaginate: return chat(ScriptedChats.chatPaginate(env))
        case .chatKeyboard: return chat(ScriptedChats.chatKeyboard(env))
        case .chatEmpty: return chat(ScriptedChats.chatEmpty(env))
        case .chatPeople: return chat(ScriptedChats.chatPeople(env))
        case .homeRoster:
            return ScriptedSelection(name: name, chat: nil, roster: ScriptedRosters.homeRoster(env))
        case .homeInvite:
            return ScriptedSelection(name: name, chat: nil, roster: ScriptedRosters.homeInvite(env))
        case .homePinsFull:
            return ScriptedSelection(name: name, chat: nil, roster: ScriptedRosters.homePinsFull(env))
        case .botMoonNoRoom:
            return ScriptedSelection(name: name, chat: nil, roster: ScriptedRosters.botMoonNoRoom(env))
        case .botMoonNotice:
            return ScriptedSelection(name: name, chat: ScriptedChats.botMoonNotice(env),
                                     roster: ScriptedRosters.botMoonNotice(env))
        case .botMoonNotices: return chat(ScriptedChats.botMoonNotices(env))
        case .botMoonNoticeEdited: return chat(ScriptedChats.botMoonNoticeEdited(env))
        case .botMoonNoticeSpoofed: return chat(ScriptedChats.botMoonNoticeSpoofed(env))
        case .botContinueOnMac: return chat(ScriptedChats.botContinueOnMac(env))
        case .botMoonChat: return chat(ScriptedChats.botMoonChat(env))
        case .botMoonEmpty: return chat(ScriptedChats.botMoonEmpty(env))
        case .botMoonRoomJoin: return chat(ScriptedChats.botMoonRoomJoin(env))
        case .botMoonRoomJoinFails: return chat(ScriptedChats.botMoonRoomJoinFails(env))
        case .botAccentFallback: return chat(ScriptedChats.botAccentFallback(env))
        case .chatMedia: return chat(ScriptedChats.chatMedia(env))
        case .chatMediaFiles: return chat(ScriptedChats.chatMediaFiles(env))
        case .chatMediaSend: return chat(ScriptedChats.chatMediaSend(env))
        case .chatMediaUpload: return chat(ScriptedChats.chatMediaUpload(env))
        case .chatMediaRefusal: return chat(ScriptedChats.chatMediaRefusal(env))
        case .chatMediaAnswers: return chat(ScriptedChats.chatMediaAnswers(env))
        case .chatActions: return chat(ScriptedChats.chatActions(env))
        case .chatKinds: return chat(ScriptedChats.chatKinds(env))
        case .chatTurnStop: return chat(ScriptedChats.chatTurnStop(env))
        case .chatSearch: return chat(ScriptedChats.chatSearch(env))
        case .chatTimelineParity: return chat(ScriptedChats.chatTimelineParity(env))
        case .chatTimelineReading: return chat(ScriptedChats.chatTimelineParity(env, reading: true))
        case .chatBubbles: return chat(ScriptedChats.chatBubbles(env))
        case .chatBubblesGroup: return chat(ScriptedChats.chatBubblesGroup(env))
        case .chatBubblesLive: return chat(ScriptedChats.chatBubblesLive(env))
        }
    }

    /// The rows a scenario shows after `seconds` with nobody touching it:
    /// for SwiftUI previews and spike seeds. Runs the player through the
    /// real reducer and projection.
    public static func rows(_ script: ScriptedScript, after seconds: TimeInterval = 0,
                            environment env: ScriptedEnvironment = ScriptedEnvironment(),
                            options: ProjectionOptions = .s1a) -> [ChatRow] {
        var player = ScriptedTimelinePlayer(script: script, reference: env.reference, calendar: env.calendar)
        var buffer = TimelineBuffer()
        var typing: [String] = []
        var outputs = player.open()
        outputs += player.advance(to: seconds)
        for output in outputs {
            switch output {
            case let .diffs(diffs): _ = try? buffer.apply(diffs)
            case let .typing(userIDs): typing = userIDs
            case .pagination: break
            }
        }
        let names = TypingNames.displayNames(typing, ownUserID: script.context.ownUserID, kind: script.context.kind,
                                             roomTitle: script.title, name: script.name(for:))
        let presentation = TypingNames.presentation(kind: script.context.kind, names: names)
        return Projection.rows(buffer.items, context: script.context, typingNames: presentation.rowNames,
                               options: options)
    }
}
#endif
