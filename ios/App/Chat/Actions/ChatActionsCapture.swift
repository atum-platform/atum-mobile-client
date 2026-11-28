#if DEBUG
import AtumChat
import SwiftUI
import UIKit

/// Debug only: `-AtumScriptedChatActions <mode>` on a scripted group chat
/// (`-AtumScripted chat.bubbles-group`) draws the chat parity ML6 surfaces
/// from fixed data so a simulator capture needs no homeserver. It uses the
/// real views; only the destinations, the link metadata, the mention power
/// and the upgrade links are synthetic. Release builds compile none of this.
struct ScriptedChatActionsCapture: ViewModifier {
    enum Mode: String { case forward, forwardFile = "forward-file", link, mention, upgradeOld = "upgrade-old",
                           upgradeNew = "upgrade-new", upgradeFailed = "upgrade-failed" }

    static let flag = "-AtumScriptedChatActions"
    static var mode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return Mode(rawValue: arguments[index + 1])
    }

    let store: LiveConversationStore
    let design: LiveDesign

    @State private var forward: ForwardPickerRequest?
    @State private var cards: ChatLinkPreviewCards?

    func body(content: Content) -> some View {
        switch Self.mode {
        case nil:
            content
        case .forward?, .forwardFile?:
            content
                .sheet(item: $forward) { request in
                    ForwardPickerSheet(model: Self.picker(request, file: Self.mode == .forwardFile),
                                       design: design, refreshKey: 0, loadThumbnail: nil)
                        .atumDesign(design)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(600))
                    forward = ForwardPickerRequest(eventID: "$capture", sourceName: "Huy")
                }
        case .link?:
            content
                .environment(\.chatLinkPreviews, cards)
                .onAppear { cards = Self.cards(store: store) }
        case .mention?:
            content
                .task {
                    try? await Task.sleep(for: .milliseconds(400))
                    store.scriptRoomMentionPermission(true)
                    store.draft = "Nhắc cả nhóm @"
                }
        case .upgradeOld?:
            content.safeAreaBar(edge: .top) {
                RoomUpgradeBand(state: RoomUpgradeBandState(continuity: .init(successor: .join(roomID: "!new:x"))),
                                design: design, busy: false, follow: {}, openEarlier: {})
            }
        case .upgradeNew?:
            content.safeAreaBar(edge: .top) {
                RoomUpgradeBand(state: RoomUpgradeBandState(continuity: .init(earlierRoomID: "!old:x")),
                                design: design, busy: false, follow: {}, openEarlier: {})
            }
        case .upgradeFailed?:
            content.safeAreaBar(edge: .top) {
                RoomUpgradeBand(state: RoomUpgradeBandState(continuity: .init(successor: .waitingForState)),
                                design: design, busy: false, follow: {}, openEarlier: {})
            }
        }
    }

    private static func event(_ content: String) -> String {
        #"{"type":"m.room.message","content":"# + content + "}"
    }

    private static func picker(_ request: ForwardPickerRequest, file: Bool) -> ForwardPickerModel {
        let text = #"{"msgtype":"m.text","body":"Mình đọc rồi, phần ngân sách cần xem lại một chút trước buổi họp thứ Năm."}"#
        let encryptedFile = #"{"msgtype":"m.file","body":"ngan-sach-q4.xlsx","filename":"ngan-sach-q4.xlsx","#
            + #""info":{"mimetype":"application/vnd.ms-excel","size":482133},"file":{"url":"mxc://capture.invalid/f","#
            + #""v":"v2","iv":"aXY","hashes":{"sha256":"aGFzaA"},"key":{"kty":"oct","alg":"A256CTR","k":"aw","#
            + #""key_ops":["encrypt","decrypt"],"ext":true}}}"#
        let json = event(file ? encryptedFile : text)
        let targets: [RoomForwarding.Target] = [
            .init(id: "!a:x", name: "Nhóm Marketing", avatarURL: nil, isEncrypted: true, refusal: nil),
            .init(id: "!b:x", name: "Lan Phạm", avatarURL: nil, isEncrypted: true, refusal: nil),
            .init(id: "!c:x", name: "Atum", avatarURL: nil, isEncrypted: true, refusal: nil),
            .init(id: "!d:x", name: "Hội thảo mở", avatarURL: nil, isEncrypted: false,
                  refusal: file ? .encryptedAttachment : nil),
        ]
        return ForwardPickerModel(sourceName: request.sourceName, teamName: nil) {
            let preview = try ForwardContent(originalEvent: json, latestEvent: json)
            return ForwardPickerSession(preview: preview, targets: { _ in targets },
                                        send: { _ in .sent(eventID: "$sent") })
        }
    }

    /// Cards under one of Huy's messages and under my own reply.
    private static func cards(store: LiveConversationStore) -> ChatLinkPreviewCards {
        let rows = store.snapshot.rows.map(\.item).filter { $0.kind == .message && $0.eventID != nil }
        let theirs = rows.last { !$0.isOwn && $0.body.count < 200 }?.eventID
        let mine = rows.last { $0.isOwn }?.eventID
        var urls = [String: URL]()
        if let theirs { urls[theirs] = URL(string: "https://example.com/bao-cao/ngan-sach-q4") }
        if let mine { urls[mine] = URL(string: "https://www.example.org/lich-hop") }
        let links = urls
        return ChatLinkPreviewCards(url: { item in item.eventID.flatMap { links[$0] } }, read: { item in
            guard let url = item.eventID.flatMap({ links[$0] }) else { return nil }
            let mineCard = item.eventID == mine
            let json = mineCard
                ? #"{"og:title":"Lịch họp tuần này","og:site_name":"example.org"}"#
                : #"{"og:title":"Báo cáo ngân sách quý 4","og:description":"Tổng hợp chi phí, dự báo và các hạng mục cần duyệt trước buổi họp thứ Năm.","og:site_name":"Example News"}"#
            return LinkPreview.Metadata(json: json)?.card(url: url, image: mineCard ? nil : picture())
        })
    }

    private static func picture() -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 135), format: format).image { context in
            let colors = [UIColor(hue: 0.58, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: 0.68, saturation: 0.6, brightness: 0.55, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 240, y: 135), options: [])
            }
        }
        return image.pngData()
    }
}
#endif
