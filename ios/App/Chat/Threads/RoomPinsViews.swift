import AtumChat
import AtumNativeAPI
import SwiftUI

// Chat parity S5: a person or group chat's shared pinned messages, pushed in
// the details sheet (existing kit, no mockup). Everyone in the chat can read
// the list; Unpin shows only with current power and waits while a write is
// reaching sync. Rows follow the snapshot's order; an event this phone cannot
// show stays as "This pinned message is unavailable."

/// "Pinned messages" with its count, in the details sheet.
struct RoomPinsInfoRow: View {
    let design: LiveDesign
    let live: GroupRoomLive

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let copy = GroupThreadsCopy(design: design)
        NavigationLink(value: ChatPanelPolicy.Page.pinnedMessages) {
            HStack(spacing: design.kit.space(.s3)) {
                Image(AtumVisualSystem(design: design).symbol(.pin))
                Text(verbatim: copy.pinnedMessages)
                Spacer(minLength: design.kit.space(.s2))
                if let count = live.pins?.eventIDs.count, count > 0 {
                    Text(verbatim: count.formatted())
                        .foregroundStyle(design.kit.color(.ink3, scheme: scheme))
                        .accessibilityLabel(Text(verbatim: copy.pinnedCount(count)))
                }
            }
            .foregroundStyle(design.kit.color(.ink, scheme: scheme))
        }
        .accessibilityIdentifier("info.pinned.open")
    }
}

struct RoomPinnedMessagesPage: View {
    let design: LiveDesign
    let actions: RoomPinsPanelActions
    let members: [String: ChatInfoMember]
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var live: GroupRoomLive { actions.live }
    private var copy: GroupThreadsCopy { GroupThreadsCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        let rows = live.pinRows
        let menu = live.pinMenu
        let mayUnpin = menu.map { $0.canChange && !$0.awaitingSync } ?? false
        List {
            if let rows, !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        pinRow(row, mayUnpin: mayUnpin)
                            .listRowBackground(atum.color(.cell, scheme: scheme))
                    }
                } header: {
                    HStack(spacing: design.kit.space(.s2)) {
                        Text(verbatim: copy.pinnedCount(rows.count))
                        if menu?.awaitingSync == true { ProgressView().controlSize(.mini) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if rows == nil, live.pinRowsFailed || live.pinsFailed {
                GroupThreadsMessage(design: design, text: copy.errorGeneric, actionTitle: copy.tryAgain) {
                    Task { await live.loadPinRows() }
                }
                .accessibilityIdentifier("info.pinned.failed")
            } else if rows == nil {
                ProgressView()
            } else if rows?.isEmpty == true {
                GroupThreadsMessage(design: design, text: copy.noPinnedMessages)
                    .accessibilityIdentifier("info.pinned.empty")
            }
        }
        .navigationTitle(copy.pinnedMessages)
        .navigationBarTitleDisplayMode(.inline)
        // A page pushed inside the panel: the system Back only (P6 rule).
        // Each newer snapshot (sync, another client, a local write) re-reads
        // the rows; an older read never replaces a newer list.
        .task(id: live.pins) { await live.loadPinRows() }
        .refreshable { await live.loadPinRows() }
        .sensoryFeedback(.error, trigger: live.pinNotice)
        .alert(copy.errorGeneric, isPresented: Binding(get: { live.pinNotice != nil },
                                                       set: { if !$0 { live.pinNotice = nil } })) {
            Button(copy.dismiss, role: .cancel) {}
        }
        .accessibilityIdentifier("info.pinned")
    }

    @ViewBuilder private func pinRow(_ row: CompanyPinnedRow, mayUnpin: Bool) -> some View {
        let kit = design.kit
        let writing = live.pinWrites.contains(row.eventID)
        let content = VStack(alignment: .leading, spacing: kit.space(.s1)) {
            if let summary = row.summary {
                HStack(spacing: kit.space(.s2)) {
                    Text(verbatim: name(summary, isOwn: row.isOwn))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .lineLimit(1)
                    Spacer(minLength: kit.space(.s2))
                    Text(verbatim: GroupThreadsTime.label(ThreadSummaryCapsule.date(summary.sentAt),
                                                          locale: design.locale))
                        .font(.footnote)
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    if writing { ProgressView().controlSize(.mini) }
                }
                Text(verbatim: summary.body)
                    .font(.body)
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .lineLimit(3)
            } else {
                Text(verbatim: copy.pinnedMessageUnavailable)
                    .font(.body)
                    .italic()
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
        }
        .padding(.vertical, kit.space(.s1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        Group {
            if row.summary != nil {
                Button {
                    close()
                    actions.jump(row)
                } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: copy.showPinnedMessage))
            } else {
                content
            }
        }
        .swipeActions(edge: .trailing) {
            if mayUnpin, !writing {
                Button { live.setPinned(false, eventID: row.eventID) } label: {
                    Label { Text(verbatim: copy.unpinMessage) } icon: { Image(atum.symbol(.pinOff)) }
                }
                .accessibilityIdentifier("info.pinned.unpin." + row.eventID)
            }
        }
        .contextMenu {
            if row.summary != nil {
                Button {
                    close()
                    actions.jump(row)
                } label: {
                    Label { Text(verbatim: copy.showPinnedMessage) } icon: { Image(atum.symbol(.arrowBackUp)) }
                }
            }
            if mayUnpin, !writing {
                Button { live.setPinned(false, eventID: row.eventID) } label: {
                    Label { Text(verbatim: copy.unpinMessage) } icon: { Image(atum.symbol(.pinOff)) }
                }
            }
        }
        .accessibilityIdentifier("info.pinned.row." + row.eventID)
    }

    private func name(_ summary: CompanyEventSummary, isOwn: Bool) -> String {
        if isOwn { return ChatCopy.text(design, .you) }
        if let member = members[summary.senderID], !member.name.isEmpty { return member.name }
        return summary.senderName ?? MatrixPersonName.localpart(summary.senderID)
    }
}
