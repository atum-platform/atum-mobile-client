#if DEBUG
import AtumChat
import Foundation

/// `-AtumScripted <scenario>` (revamp plan §2.10), read once at launch. Debug
/// only: Release builds compile none of it, and tapping the icon passes no
/// arguments, so the owner never sees this mode.
///
/// A chat scenario opens on a `ScriptedTimelineSource` in place of the live
/// timeline: it is a `ChatTimelineSource`, so the real store takes it with
/// `LiveConversationStore.attach(source:)` and runs its core and pipeline
/// unchanged. A roster scenario feeds `ScriptedRoster` through the live
/// roster policies. The S1 chat screen and store read `selection` (WS1,
/// WS2); event times are relative to this launch.
@MainActor
enum AtumScriptedLaunch {
    private(set) static var selection: ScriptedSelection?

    static func configure(arguments: [String]) {
        selection = ScriptedScenarios.selection(arguments: arguments)
        guard let flag = arguments.firstIndex(of: "-AtumScriptedLeadIn"),
              flag + 1 < arguments.count,
              let seconds = TimeInterval(arguments[flag + 1]), seconds > 0,
              var chat = selection?.chat else { return }
        chat.steps = chat.steps.map { ScriptedStep(at: $0.at + seconds, $0.event) }
        selection?.chat = chat
    }

    /// A fresh source for the scenario's chat: the scenario starts over on
    /// every open, as a reopened live chat starts from the SDK cache.
    static func makeChatSource() -> ScriptedTimelineSource? {
        selection?.chat.map { ScriptedTimelineSource(script: $0) }
    }
}
#endif
