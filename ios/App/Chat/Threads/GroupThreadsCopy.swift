import AtumDesign
import AtumNativeAPI
import Foundation

/// The words of group threads and shared pins (chat parity S4/S5). Every
/// value is an exported desktop key except `allThreads`, which desktop #156
/// (`56d4483c`, `apps/desktop/src/matrix/thread-copy.ts`) added after the
/// pinned export: it reads the export first and falls back to
/// `GroupThreadsPendingCopy` (verbatim desktop values), like
/// `CompanyThreadsCopy`.
@MainActor
struct GroupThreadsCopy {
    let design: LiveDesign

    private var threads: CompanyThreadsCopy { CompanyThreadsCopy(design: design) }
    private static let pinned = "src.matrix.mobile-copy.mobileScreensCopy.teamSpace.pinned."

    // MARK: Threads

    var thread: String { threads.thread }
    var threadsTitle: String { threads.threads }
    var follow: String { threads.follow }
    var unfollow: String { threads.unfollow }
    var unread: String { threads.unread }
    var noThreads: String { threads.noThreads }
    var threadUnavailable: String { threads.threadUnavailable }
    var threadOptions: String { threads.text("src.matrix.thread-copy.copy.threadOptions") }
    /// M2 thread composer: "Reply in thread".
    var replyInThread: String { design.text("src.matrix.thread-copy.copy.replyInThread") }
    /// "N replies", the exported plural.
    func replies(_ count: Int) -> String { threads.panelReplies(count) }
    var allThreads: String {
        let key = "src.matrix.thread-copy.copy.allThreads"
        if design.copy.contains(key) { return design.text(key) }
        let table = GroupThreadsPendingCopy.tables[key]
        return table?[design.locale] ?? table?["en"] ?? key
    }
    var loadMore: String { threads.loadMore }

    // MARK: Pins

    var pinnedMessages: String { design.text(Self.pinned + "pinnedMessages") }
    var noPinnedMessages: String { design.text(Self.pinned + "noPinnedMessages") }
    var pinnedMessageUnavailable: String { design.text(Self.pinned + "pinnedMessageUnavailable") }
    var unpinMessage: String { design.text(Self.pinned + "unpinMessage") }
    var showPinnedMessage: String { design.text(Self.pinned + "showPinnedMessage") }
    func pinnedCount(_ count: Int) -> String {
        design.text(Self.pinned + "pinnedMessageCount", arguments: [.number(Int64(count))])
    }

    // MARK: Shared

    var tryAgain: String { design.text("src.matrix.person-info-copy.copy.tryAgain") }
    var errorGeneric: String { design.text("src.matrix.chat-copy.copies.errorGeneric") }
    var dismiss: String { ChatCopy.text(design, .dismiss) }
}

// GENERATED from atum-desktop PR #156 head 56d4483ce2173faae5a2e9393cc0843b5e2e8fca
// (`apps/desktop/src/matrix/thread-copy.ts`, verbatim). PENDING-COPY: not in the
// pinned design export yet; `GroupThreadsCopy` reads the export first, so the next
// repin replaces it with no wording change. Never hand-edit a value.
enum GroupThreadsPendingCopy {
    static let tables: [String: [String: String]] = [
        "src.matrix.thread-copy.copy.allThreads": [
            "en": "All threads",
            "vi": "Tất cả chuỗi thảo luận",
            "ja": "すべてのスレッド",
            "zh": "所有讨论串",
            "zh-Hant": "所有討論串",
        ],
    ]
}
