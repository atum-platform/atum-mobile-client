import Foundation

/// PENDING-COPY: proposed share.* keys, pending the design export. See share-extension.md.
enum SharePendingCopy {
    enum Key: String { case title, search, caption, send, cancel, queued, done, empty, failed, loading, queueHelp, reviewTitle, reviewBody, waitingTitle, waitingBody, retry, discard, later }
    static func text(_ key: Key) -> String {
        let vi = Locale.current.language.languageCode?.identifier == "vi"
        switch key {
        case .reviewTitle: return vi ? "Kiểm tra nội dung đã chia sẻ" : "Check your shared items"
        case .reviewBody: return vi ? "Một số mục có thể đã được gửi. Kiểm tra cuộc trò chuyện trước khi thử lại để tránh gửi trùng." : "Some items may already have been sent. Check your chats before retrying to avoid duplicates. Discard removes queued copies only."
        case .waitingTitle: return vi ? "Nội dung chia sẻ đang chờ" : "Shared items are waiting"
        case .waitingBody: return vi ? "Chưa thể gửi một số mục. Kiểm tra kết nối, giới hạn tệp và quyền truy cập cuộc trò chuyện rồi thử lại." : "Some items couldn’t be sent yet. Check your connection, file limits and access to the chats, then retry."
        case .retry: return vi ? "Thử lại" : "Retry remaining items"
        case .discard: return vi ? "Xóa bản đang chờ" : "Discard queued copies"
        case .later: return vi ? "Để sau" : "Later"
        case .title: return vi ? "Chia sẻ vào Atum" : "Share to Atum"
        case .search: return vi ? "Tìm cuộc trò chuyện" : "Search chats"
        case .caption: return vi ? "Thêm chú thích" : "Add a caption"
        case .send: return vi ? "Xếp hàng gửi" : "Queue share"
        case .cancel: return vi ? "Hủy" : "Cancel"
        case .queued: return vi ? "Đã xếp hàng. Mở Atum để gửi." : "Queued. Open Atum to send."
        case .done: return vi ? "Xong" : "Done"
        case .empty: return vi ? "Mở Atum và đăng nhập để tải cuộc trò chuyện." : "Open Atum and sign in to load your chats."
        case .failed: return vi ? "Không thể xếp hàng. Thử lại hoặc mở Atum." : "Couldn’t queue this share. Try again or open Atum."
        case .loading: return vi ? "Đang chuẩn bị…" : "Preparing…"
        case .queueHelp: return vi ? "Nội dung sẽ được gửi khi bạn mở Atum." : "Your share will send when you next open Atum."
        }
    }
}
