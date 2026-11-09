import Foundation

/// B12 across a new session's typing controller (WS1 store wiring). The store
/// builds a new `TypingController` on every attach: opening a chat and every
/// token renewal (about every 4 minutes). Only editing a non-empty draft sends
/// a typing notice, so the saved draft is told to the new controller only
/// while the person is still typing it: the last edit is inside the typing-out
/// pause (`TypingNoticePolicy.pauseSeconds`). A chat opened with a saved
/// draft, or a renewal while nobody touches the draft, sends nothing, so the
/// other person never sees "đang soạn tin…" for a draft nobody is typing.
///
/// Times are monotonic seconds (`ProcessInfo.systemUptime` in the app), the
/// same clock as `TypingNoticePolicy`.
public enum DraftTypingReplay {
    public static func replays(draft: String, lastEditAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let lastEditAt else { return false }
        let elapsed = now - lastEditAt
        return elapsed.isFinite && elapsed >= 0 && elapsed < TypingNoticePolicy.pauseSeconds
    }
}
