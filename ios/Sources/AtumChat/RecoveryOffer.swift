import Foundation

/// Where the optional recovery row shows (W4 E3, plan §3.8; coordinator
/// decision 5, 2026-10-11). Recovery never blocks the app or a chat: 0.20
/// agent, bot and new people chats are plain rooms that need no keys, and old
/// encrypted history shows its placeholders (B19). The existing 0.20 row
/// (`src.matrix.mobile-copy.mobilePhoneCopy.recoverOldMessages`, "Nhập khóa
/// khôi phục để xem tin nhắn cũ") is offered quietly in Account and in the
/// chat's info, never as a lock screen; it opens the existing recovery-key
/// sheet. Nothing here touches key custody.
public enum RecoveryOffer {
    /// In an open chat: the account offers recovery (its key backup is not
    /// open on this phone), the chat is a people or group chat (agent and
    /// bot chats are plain; their old encrypted rooms are never opened), and
    /// a row on screen is a message this phone could not open.
    public static func inChat(kind: RoomKind, rows: [ChatRow], accountOffersRecovery: Bool) -> Bool {
        guard accountOffersRecovery, kind == .person || kind == .group else { return false }
        return rows.contains { row in
            switch row.item.kind {
            case .placeholder(.undecryptableOldHistory), .placeholder(.undecryptable): true
            default: false
            }
        }
    }
}
