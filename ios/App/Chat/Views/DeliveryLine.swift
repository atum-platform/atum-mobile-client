import AtumChat
import SwiftUI

/// Under my message (B7, B8, B10): a clock while it sends, "Chưa gửi được"
/// with a warning glyph when it failed (tapping it offers "Thử lại" and
/// "Xóa"), "Đã gửi" or "Đã xem" on my newest settled message. The quiet "Chưa có
/// câu trả lời." line is gone (owner real use, 10-17: uncertain-outcome
/// lines go; Kit gap spec §3.2): the working line and the answer speak.
///
/// The words are in the bubble's accessibility label; only the failed mark
/// is its own (actionable) element. B26's warning on a failed send is the
/// composer's (`SendFailureWatch`), so it plays once whichever row fails.
struct DeliveryLine: View {
    let row: ChatRow
    let kind: RoomKind

    @Environment(\.chatTheme) private var theme
    @Environment(\.messageActions) private var presenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatOwnUserID) private var ownUserID
    @Environment(\.chatRoomFace) private var roomFace
    @Environment(\.chatMembers) private var members

    var body: some View {
        if let theme {
            mark(theme)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private func mark(_ theme: ChatTheme) -> some View {
        let muted = theme.color("muted", scheme)
        switch row.delivery {
        case .none:
            EmptyView()
        case .sending:
            Image(theme.design.symbol("Clock"))
                .font(.caption)
                .foregroundStyle(muted)
                .accessibilityHidden(true)
        case .failed:
            Button {
                presenter?.showFailedSend(row)
            } label: {
                Label {
                    Text(theme.copy.text(.notSent))
                } icon: {
                    Image(theme.design.symbol("AlertCircle"))
                }
                .font(.footnote)
                .foregroundStyle(theme.color("danger", scheme))
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.sendFailed)
        case .sent:
            // Kit: "Đã gửi" as a quiet caption, no glyph.
            Text(theme.copy.text(.sent))
                .font(.caption)
                .foregroundStyle(muted)
                .accessibilityHidden(true)
        case let .seen(readerCount):
            ReaderAvatarMarks(userIDs: row.item.receiptUserIDs.filter { $0 != ownUserID },
                              readerCount: readerCount, kind: kind, roomFace: roomFace, members: members,
                              scheme: scheme, theme: theme)
        }
    }
}

/// §9.1 Seen: up to three stacked reader squircle avatars and "+N" under the
/// message whose receipt they sit on (Element X's model). The row's
/// accessibility label already says "Đã xem"/"Đã xem · N", so the faces are
/// decorative.
private struct ReaderAvatarMarks: View {
    let userIDs: [String]
    let readerCount: Int
    let kind: RoomKind
    let roomFace: ChatFace?
    let members: [String: ChatInfoMember]
    let scheme: ColorScheme
    let theme: ChatTheme

    private var shown: [String] { Array(userIDs.prefix(3)) }
    private var extra: Int { max(readerCount - shown.count, 0) }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -7) {
                ForEach(shown, id: \.self) { userID in
                    let face = ChatFace.reader(userID, kind: kind, roomFace: roomFace, members: members)
                    ChatFaceView(face: face, size: 18)
                        .overlay {
                            // The ring follows the face's frame: an app's is a squircle.
                            AtumAvatar.shape(for: face.kind, size: 18)
                                .strokeBorder(theme.color("ground", scheme), lineWidth: 1.5)
                        }
                }
            }
            if extra > 0 {
                Text(verbatim: "+\(extra)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.quiet(scheme))
            }
        }
        .frame(minHeight: 20)
        .accessibilityHidden(true)
    }
}
