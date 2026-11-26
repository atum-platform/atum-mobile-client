import AtumChat
import SwiftUI
import UIKit

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
    /// A long message is about to open with Show more (`MessageFold`); the
    /// transcript keeps it where it is on screen and stops following the
    /// bottom, so the revealed text extends below.
    var opening: @MainActor (String) -> Void = { _ in }
    /// A long message was folded with Show less (`MessageFold`); the
    /// transcript brings its top back if it had scrolled away.
    var folded: @MainActor (String) -> Void = { _ in }
    /// P4: whether the transcript's own pan is moving the list. Each row is
    /// hosted in a collection cell that moves with the content, so a row's
    /// own "the finger moved 10 pt" rule never trips during a slow drag; the
    /// message menu asks this instead (`MessageMenuModifier`).
    var scroll = ChatScrollSignal.none
}

/// P4: the transcript's scrolling state, shared with every row's press
/// recognizers. The transcript sets `isScrolling` once and calls
/// `panBegan()` from `scrollViewWillBeginDragging`, which cancels any press
/// that has not yet opened its menu. A reference, so handing it to rows
/// never changes the environment.
@MainActor
final class ChatScrollSignal {
    /// Outside a transcript nothing scrolls the rows.
    static let none = ChatScrollSignal()

    var isScrolling: @MainActor () -> Bool = { false }
    private let presses = NSHashTable<UIGestureRecognizer>.weakObjects()
    private let waitingPresses = NSHashTable<UIGestureRecognizer>.weakObjects()

    /// A row's press recognizer, cancelled when the pan begins.
    /// `onlyWaiting`: only while it has not recognized yet (the menu
    /// follower keeps a press that has already opened the menu).
    func track(_ recognizer: UIGestureRecognizer, onlyWaiting: Bool) {
        (onlyWaiting ? waitingPresses : presses).add(recognizer)
    }

    func panBegan() {
        let waiting = waitingPresses.allObjects.filter { $0.state == .possible }
        let active = presses.allObjects.filter { $0.state != .failed && $0.state != .cancelled }
        for recognizer in waiting + active {
            // Disabling cancels a recognized press and fails one still waiting.
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
    }
}

extension EnvironmentValues {
    // P4: the transcript hosts each row in its own UIKit cell, and a cell's
    // SwiftUI graph does not inherit the chat screen's environment. Every key
    // a row reads must be listed in `TranscriptRowEnvironment.forwarded`
    // (TranscriptView.swift); `tests/test_transcript_row_environment.py`
    // fails when a key declared here is neither forwarded nor exempted.
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
