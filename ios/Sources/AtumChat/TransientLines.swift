import Foundation

/// The client side of `atum.agent-turns/1.4` §3 (A7): a working line — the
/// agent's `io.atum.progress` notice — lives only while its turn works. A
/// client hides it once the turn has ended, even before the publisher's
/// redaction lands, so old history never shows "Đã chờ máy Mac của bạn."
///
/// This is the phone port of desktop's `shared/matrix-transient-lines.ts`:
/// pure, dependency-free, and the same rules. The app layer only renders what
/// this returns.
public enum TransientLines {
    /// The fixed "waiting/waited for your Mac" status lines older builds
    /// posted as ordinary notices (no marker). They are working text, so they
    /// are transient too.
    public static let retiredWaitLines: Set<String> = [
        "Waiting for your Mac.", "Đang chờ máy Mac của bạn.", "Macを待っています。", "正在等待你的 Mac。",
        "Waited for your Mac.", "Đã chờ máy Mac của bạn.", "Macを待ちました。", "已等待你的 Mac。",
        // Desktop `shared/matrix-status-line-copy.ts` (`waiting`, `waited`):
        // matched as retired working text, never shown by this rule.
        "Waiting for you on your Mac.", "Waited for you on your Mac.",
        "Đang chờ bạn trả lời trên máy Mac.", "Đã chờ bạn trả lời trên máy Mac.",
        "Macでの応答を待っています。", "Macでの応答を待ちました。",
        "正在等待你在 Mac 上回复。", "已等待你在 Mac 上回复。",
        "正在等待你在 Mac 上回覆。", "已等待你在 Mac 上回覆。"
    ]

    /// A progress line, or one of the retired fixed wait lines, sent by an
    /// agent.
    public static func isTransientLine(_ item: ChatItem, agents: Set<String>) -> Bool {
        guard !item.isOwn, agents.contains(item.sender), item.kind == .notice, !item.isRedacted else {
            return false
        }
        return item.isProgressLine || retiredWaitLines.contains(item.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the chat shows of `items`, in timeline order:
    /// - a non-own self-redaction with reason `Turn ended` shows nothing;
    ///   other redactions retain their deleted placeholder;
    /// - an agent's working line is hidden once its turn has ended: its marker
    ///   says `settled`, or the same agent posted a later message that is
    ///   neither a working line nor an interim remark (the answer, an outcome
    ///   notice). A line that is still the newest thing the agent said stays.
    public static func visibleItems(_ items: [ChatItem], agents: Set<String>) -> [ChatItem] {
        var ended = Set<String>()
        var kept: [ChatItem] = []
        kept.reserveCapacity(items.count)
        for item in items.reversed() {
            guard item.kind.isEventContent, item.kind != .roomState else {
                kept.append(item)
                continue
            }
            if item.isRedacted && item.redactedAsEndedTurn && !item.isOwn { continue }
            if item.isOwn || !agents.contains(item.sender) {
                kept.append(item)
                continue
            }
            if item.isRedacted {
                kept.append(item)
                continue
            }
            if isTransientLine(item, agents: agents) {
                if item.progress?.phase == .settled || ended.contains(item.sender) {
                    continue
                }
            } else if !item.interim && !isPending(item) && !isFailed(item) && !isUndecryptable(item) {
                ended.insert(item.sender)
            }
            kept.append(item)
        }
        return kept.reversed()
    }

    /// The one working line a chat shows under the typing bubble right now:
    /// the newest agent line that still lives. A line whose turn ended is
    /// already gone, so this is only what the turn is doing at this moment
    /// (or the fixed "waiting" line a legacy build posted).
    public static func workingLine(_ items: [ChatItem], agents: Set<String>,
                                   sender: String? = nil) -> ChatItem? {
        visibleItems(items, agents: agents).last { item in
            isTransientLine(item, agents: agents) && (sender == nil || item.sender == sender)
        }
    }

    private static func isPending(_ item: ChatItem) -> Bool {
        if case .sending = item.delivery { return true }
        return false
    }

    private static func isFailed(_ item: ChatItem) -> Bool {
        if case .failed = item.delivery { return true }
        return false
    }

    private static func isUndecryptable(_ item: ChatItem) -> Bool {
        switch item.kind {
        case .placeholder(.undecryptable), .placeholder(.undecryptableOldHistory): true
        default: false
        }
    }
}
