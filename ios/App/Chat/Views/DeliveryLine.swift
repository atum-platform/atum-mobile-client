import AtumChat
import SwiftUI

/// The quiet line under a bubble, as desktop draws it (`MatrixSendState`,
/// `data-matrix-run-time` and the answer toolbar in `src/matrix/app.tsx`):
/// "14:05 · đã sửa · ✓ Đã gửi" in one row.
/// - The clock under the last bubble of each run and under every answer of
///   my agent (TL-4, `RowGrouping.showsTime`); never in a team space's flat
///   runs, whose header carries it.
/// - "đã sửa" for people's edits, mine included (TL-5,
///   `RowGrouping.showsEdited`).
/// - My delivery mark (B7, B8): a clock while it sends, "Chưa gửi được" with
///   a warning glyph when it failed (tapping it offers "Thử lại" and "Xóa"),
///   a check and "Đã gửi" on my newest message once it settled, and the
///   readers' faces under the message each receipt names.
/// - Copy, after the time, under the newest answer.
/// The quiet "Chưa có câu trả lời." line is gone (owner real use, 10-17:
/// uncertain-outcome lines go; Kit gap spec §3.2): the working line and the
/// answer speak.
///
/// The words are in the bubble's accessibility label; only the failed mark,
/// the readers and Copy are their own (actionable) elements. B26's warning on
/// a failed send is the composer's (`SendFailureWatch`), so it plays once
/// whichever row fails.
struct DeliveryLine: View {
    let row: ChatRow
    let kind: RoomKind
    /// The newest answer in an assistant or app chat: Copy follows the time.
    var isLatestAnswer = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.messageActions) private var presenter
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatOwnUserID) private var ownUserID
    @Environment(\.chatRoomFace) private var roomFace
    @Environment(\.chatMembers) private var members
    @Environment(\.chatFlatRuns) private var flat

    /// Whether the line has anything to show; the bubble row draws it only
    /// then.
    static func shows(_ row: ChatRow, isLatestAnswer: Bool, flat: Bool) -> Bool {
        row.delivery != .none || row.grouping.showsEdited
            || (!flat && (row.grouping.showsTime || isLatestAnswer))
    }

    var body: some View {
        if let theme {
            let quiet = theme.quiet(scheme)
            let showsTime = row.grouping.showsTime && !flat
            let showsEdited = row.grouping.showsEdited
            let hasMark = row.delivery != .none
            HStack(spacing: 4) {
                if showsTime {
                    Text(verbatim: theme.time(row.item.timestamp))
                        .font(.caption)
                        .foregroundStyle(quiet)
                        .accessibilityHidden(true)
                }
                if showsTime && (showsEdited || hasMark) { separator(quiet) }
                if showsEdited {
                    Text(theme.copy.text(.edited))
                        .font(.caption)
                        .foregroundStyle(quiet)
                        .accessibilityHidden(true)
                }
                if showsEdited && hasMark { separator(quiet) }
                mark(theme)
                if isLatestAnswer && !flat {
                    LatestAnswerCopyRow(itemID: row.id)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("delivery.line.\(row.id)")
        }
    }

    private func separator(_ color: Color) -> some View {
        Text(verbatim: "·")
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityHidden(true)
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
            // Desktop `send-state.tsx`: a small check, then "Đã gửi", muted.
            HStack(spacing: 4) {
                Image(theme.design.symbol("Check"))
                    .font(.caption2)
                Text(theme.copy.text(.sent))
                    .font(.caption)
            }
            .foregroundStyle(theme.quiet(scheme))
            .accessibilityHidden(true)
        case let .seen(readerCount):
            ReaderAvatarMarks(readers: readers, readerCount: readerCount, kind: kind, roomFace: roomFace,
                              members: members, scheme: scheme, theme: theme)
        }
    }

    /// The projection's readers; a row the core composed itself carries
    /// only the receipt IDs.
    private var readers: [ChatReader] {
        if !row.readers.isEmpty { return row.readers }
        return row.item.receiptUserIDs.filter { $0 != ownUserID }.map { ChatReader(userID: $0) }
    }
}

/// §9.1 Seen, as desktop's `MatrixSendState` draws it
/// (`src/matrix/send-state.tsx`): the readers' own faces under the message
/// their receipt names, the first three in receipt order, 16 pt and
/// overlapping by 6 pt, then "+N" for the rest. Tapping them lists every
/// reader's name (desktop's tooltip). The row's accessibility label already
/// says "Đã xem"/"Đã xem · N"; the button adds the names.
struct ReaderAvatarMarks: View {
    let readers: [ChatReader]
    let readerCount: Int
    let kind: RoomKind
    let roomFace: ChatFace?
    let members: [String: ChatInfoMember]
    let scheme: ColorScheme
    let theme: ChatTheme

    @State private var showsNames = false

    /// Desktop `SEEN_AVATARS`.
    static let shownFaces = 3
    static let faceSize: CGFloat = 16
    static let overlap: CGFloat = 6

    private struct ReaderFace: Identifiable {
        let id: String
        let face: ChatFace
    }

    private var readerFaces: [ReaderFace] {
        readers.map { ReaderFace(id: $0.userID,
                                 face: ChatFace.reader($0, kind: kind, roomFace: roomFace, members: members)) }
    }

    var body: some View {
        let faces = readerFaces
        let shown = Array(faces.prefix(Self.shownFaces))
        let extra = max(max(readerCount, faces.count) - shown.count, 0)
        let names = faces.map(\.face.name).joined(separator: ", ")
        Button {
            showsNames = true
        } label: {
            HStack(spacing: 4) {
                HStack(spacing: -Self.overlap) {
                    ForEach(shown) { entry in
                        ChatFaceView(face: entry.face, size: Self.faceSize)
                    }
                }
                if extra > 0 {
                    Text(verbatim: "+\(extra)")
                        .font(.caption)
                        .foregroundStyle(theme.quiet(scheme))
                }
            }
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(names.isEmpty)
        .popover(isPresented: $showsNames, arrowEdge: .top) {
            Text(verbatim: names)
                .font(.footnote)
                .foregroundStyle(theme.design.kit.color(.ink, scheme: scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .presentationCompactAdaptation(.popover)
                .accessibilityIdentifier("delivery.seen.names")
        }
        .accessibilityLabel(kind == .assistant ? theme.copy.text(.seen)
                            : theme.copy.text(.seenBy, .number(Int64(max(readerCount, faces.count)))))
        .accessibilityValue(names)
        .accessibilityIdentifier("delivery.seen")
    }
}
