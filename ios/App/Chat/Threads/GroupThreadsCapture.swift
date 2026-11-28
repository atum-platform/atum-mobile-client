#if DEBUG
import AtumChat
import AtumNativeAPI
import SwiftUI

/// Debug only: `-AtumScriptedGroupThreads <transcript|thread|list|pins>` on a
/// scripted group chat (`-AtumScripted chat.bubbles-group`) draws the chat
/// parity M2/S5 states from fixed rows, so a simulator capture can be set
/// beside the mockups without a homeserver. It uses the real views; only the
/// thread and pin data are synthetic (the "thread" capture reuses the scripted
/// transcript as replies under its first message). Release builds compile none
/// of this.
struct ScriptedGroupThreadsCapture: ViewModifier {
    enum Mode: String { case transcript, thread, list, pins }

    static let flag = "-AtumScriptedGroupThreads"
    static var mode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Mode(rawValue: arguments[index + 1])
    }

    let store: LiveConversationStore
    let design: LiveDesign
    let title: String

    func body(content: Content) -> some View {
        let live = Self.live(store: store, threadFirst: Self.mode == .thread)
        switch Self.mode {
        case nil:
            content
        case .transcript?:
            content
                .environment(\.chatThreadSummaries,
                             ChatThreadSummaries(mode: .transcript, threads: live.summaries, open: { _ in }))
                .environment(\.chatPinMenu, live.pinMenu.map { ChatPinMenu(context: $0) { _, _ in } })
        case .thread?:
            ChatScreen(store: store, design: design, mediaAccess: ScriptedMediaAccess.access,
                       thread: GroupThreadScreen.chrome(design: design, place: title, followed: false,
                                                        pending: false, toggle: {}))
                .environment(\.chatThreadSummaries,
                             ChatThreadSummaries(mode: .insideThread(rootID: live.threads?.first?.root.eventID ?? ""),
                                                 threads: live.summaries, open: { _ in }))
        case .list?:
            GroupThreadListContent(design: design, live: live, place: title, members: [:], onOpen: { _ in })
        case .pins?:
            RoomPinnedMessagesPage(design: design, actions: RoomPinsPanelActions(live: live, jump: { _ in }),
                                   members: [:], close: {})
        }
    }

    /// Two threads from the scripted rows: one under another person's long
    /// message, one under my own (right-aligned, the owner's Q5 default).
    private static func live(store: LiveConversationStore, threadFirst: Bool) -> GroupRoomLive {
        let rows = store.snapshot.rows.map(\.item).filter { $0.kind == .message && $0.eventID != nil }
        let others = rows.filter { !$0.isOwn }
        let rootA = threadFirst ? others.first : (others.first { $0.body.count > 200 } ?? others.first)
        let rootB = rows.first { $0.isOwn }
        func message(_ item: ChatItem, at: Date? = nil) -> CompanyThreadMessage {
            CompanyThreadMessage(eventID: item.eventID ?? "", senderID: item.sender, senderName: item.senderName,
                                 isOwn: item.isOwn, body: item.body,
                                 sentAt: Int64((at ?? item.timestamp).timeIntervalSince1970 * 1000))
        }
        func replier(not sender: String) -> ChatItem? { others.first { $0.sender != sender } }
        var threads = [CompanyThread]()
        if let rootA {
            threads.append(CompanyThread(roomID: store.roomID, root: message(rootA),
                                         latest: replier(not: rootA.sender).map { message($0, at: Date()) },
                                         replyCount: 3, unread: true))
        }
        if let rootB {
            threads.append(CompanyThread(roomID: store.roomID, root: message(rootB),
                                         latest: replier(not: rootB.sender).map {
                                             message($0, at: Date().addingTimeInterval(-86_400))
                                         },
                                         replyCount: 2))
        }
        if let rootA, let rootB {
            threads.append(CompanyThread(roomID: store.roomID,
                                         root: CompanyThreadMessage(eventID: "$capture-older", senderID: rootB.sender,
                                                                    senderName: rootB.senderName, isOwn: true,
                                                                    body: "Menu copy, second pass",
                                                                    sentAt: Int64(Date().addingTimeInterval(-4 * 86_400)
                                                                        .timeIntervalSince1970 * 1000)),
                                         latest: message(rootA), replyCount: 5))
        }
        let pinned = [rootA, rootB].compactMap { $0 }
        let ids = pinned.compactMap(\.eventID) + ["$capture-unavailable"]
        let pinRows = pinned.map { item in
            CompanyPinnedRow(eventID: item.eventID ?? "",
                             summary: CompanyEventSummary(senderID: item.sender, senderName: item.senderName,
                                                          body: item.body,
                                                          sentAt: Int64(item.timestamp.timeIntervalSince1970 * 1000),
                                                          threadRootID: nil),
                             isOwn: item.isOwn)
        } + [CompanyPinnedRow(eventID: "$capture-unavailable", summary: nil, isOwn: false)]
        return GroupRoomLive.capture(roomID: store.roomID, threads: threads,
                                     pins: RoomPinSnapshot(eventIDs: ids, canChange: true, awaitingSync: false),
                                     pinRows: pinRows)
    }
}
#endif
