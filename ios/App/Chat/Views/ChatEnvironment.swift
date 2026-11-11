import AtumChat
import SwiftUI

/// What every chat row reads from the environment (plan §2.6 "Rendering"):
/// the design, the copy, the row actions and the few view-only interactions.
/// Rows never rebuild closures in `body` and never reach for the store.

/// The design bundle and the chat's words for one chat screen.
@MainActor
struct ChatTheme {
    let design: LiveDesign
    let copy: ChatCopy
    /// The app's language for dates and times (B14, B16): the copy's locale,
    /// never the device locale.
    let locale: Locale

    init(design: LiveDesign) {
        self.design = design
        copy = ChatCopy(design: design)
        locale = Locale(identifier: design.locale)
    }

    func color(_ role: String, _ scheme: ColorScheme) -> Color { design.color(role, scheme: scheme) }

    /// Secondary words in the chat (sender lines, times, day dividers,
    /// quotes, "đã sửa", delivery words, notices, placeholders): `soft`. The
    /// accessibility audit fails `muted` at these small sizes; `muted` stays
    /// for glyphs, rules and the typing dots.
    func quiet(_ scheme: ColorScheme) -> Color { design.color("soft", scheme: scheme) }

    /// "14:05": the centred time label and the time in a row's
    /// accessibility label, in the app's language.
    func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }
}

/// View-only interactions a row hands up to the screen: no store state.
/// (The failed-send mark and the menu present through the screen's
/// `MessageActionsPresenter`, environment `messageActions`.)
@MainActor
struct ChatRowInteractions {
    /// B21: a quote was tapped; the transcript scrolls to the original if it
    /// is loaded.
    var showOriginal: @MainActor (String) -> Void = { _ in }
    /// A long message was folded with Show less (`MessageFold`); the
    /// transcript brings its top back if it had scrolled away.
    var folded: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var chatTheme: ChatTheme?
    @Entry var chatActions: ChatActions = .none
    /// This account's Matrix user ID: which reaction chips are mine (B22).
    @Entry var chatOwnUserID = ""
    /// The chat's avatar as Home shows it (`ChatAvatar`): the title capsule
    /// and the face beside the agent's last bubble.
    @Entry var chatRoomAvatar: LiveProductAvatar? = nil
    /// The room's resolved face (§9.1): its avatar, Matrix URI and kind.
    @Entry var chatRoomFace: ChatFace? = nil
    /// Joined members by user ID, for per-sender and reader faces. Empty
    /// until the cached member read lands.
    @Entry var chatMembers: [String: ChatInfoMember] = [:]
    /// Every assistant and app bot this chat knows (the room's agent, the
    /// account's agents, the catalog bots, members marked so): their
    /// messages get no Report. Nil (a host that cannot tell) offers none.
    @Entry var chatNonPersonSenders: Set<String>? = nil
    /// The chat's Matrix media thumbnail loader (`LiveMatrixSession`).
    @Entry var chatLoadMatrixThumbnail: ((String, Int) async -> Data?)? = nil
    /// The start of today (B14): day dividers relabel when it changes.
    @Entry var chatToday = Calendar.current.startOfDay(for: Date())
    @Entry var chatRowInteractions = ChatRowInteractions()
    /// Motion is off under Reduce Motion, and in Debug UI tests
    /// (`-AtumUITestNoAnimations`) so XCUITest sees an idle app.
    @Entry var chatReducesMotion = false
    /// Team space channels and conversations read like Slack (STYLE §10,
    /// FlowPhone3 › Team channel): flat runs, edge to edge, no bubbles.
    @Entry var chatFlatRuns = false
}

enum ChatMotion {
    /// The UI-test flag (Debug only): perpetual animations (the typing dots)
    /// would keep XCUITest from ever seeing the app idle.
    static let disabledForUITests: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(AtumLaunchArguments.noAnimationsFlag)
        #else
        return false
        #endif
    }()
}
