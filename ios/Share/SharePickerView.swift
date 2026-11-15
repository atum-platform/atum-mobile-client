import AtumNativeAPI
import SwiftUI

/// The share sheet: Cancel, the title with the selected count, and Send; then what is
/// being shared, a caption, search, Recent and every other chat. Send queues durably
/// and the sheet confirms "Queued. Open Atum to send." until the owner taps Done.
/// The controller owns dismissal (`finish`, `cancel`); the model owns every rule.
struct SharePickerView: View {
    @Bindable var model: ShareComposerModel
    let avatars: ShareAvatarSource
    let finish: () -> Void
    let cancel: () -> Void

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let kit {
            NavigationStack {
                Group {
                    if model.phase == .queued { SharePickerQueued(done: finish) } else { picker(kit) }
                }
                .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar(kit) }
            }
            .tint(kit.color(.ink, scheme: scheme))
        }
    }

    private var sections: SharePickerSections {
        SharePickerSections.make(all: model.recentChats, matches: model.chats, search: model.search,
                                 suggested: model.suggestedChatID)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ kit: AtumKit) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(verbatim: SharePendingCopy.text(.title))
                    .font(kit.font(.headline))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                if model.phase != .queued, !model.selection.isEmpty {
                    Text(verbatim: SharePickerCopy.selected(model.selection.count))
                        .font(kit.font(.caption))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .accessibilityIdentifier("share.selectedCount")
                }
            }
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        if model.phase != .queued {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: cancel) { Text(verbatim: SharePickerCopy.text(.cancel)) }
                    .accessibilityIdentifier("share.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .queuing {
                    ProgressView().accessibilityIdentifier("share.queuing")
                } else {
                    Button { model.send() } label: { Text(verbatim: SharePickerCopy.text(.send)) }
                        .disabled(!model.canSend)
                        .accessibilityHint(Text(verbatim: SharePendingCopy.text(.queueHelp)))
                        .accessibilityIdentifier("share.send")
                }
            }
        }
    }

    // MARK: Picker

    private func picker(_ kit: AtumKit) -> some View {
        let sections = sections
        let surface = kit.color(.surface, scheme: scheme)
        let editable = model.phase == .loading || model.phase == .ready
        return List {
            Section {
                if !model.items.isEmpty || model.phase == .loading {
                    SharePreviewStrip(items: model.items, isLoading: model.phase == .loading,
                                      progress: model.progress, stagedFile: model.stagedFile(for:))
                        .listRowInsets(EdgeInsets(top: kit.space(.s2), leading: kit.space(.s4),
                                                  bottom: kit.space(.s2), trailing: kit.space(.s4)))
                }
                TextField(text: $model.caption, axis: .vertical) {
                    Text(verbatim: SharePendingCopy.text(.caption))
                }
                .font(kit.font(.body))
                .foregroundStyle(kit.color(.ink, scheme: scheme))
                .lineLimit(1...5)
                .disabled(!editable)
                .accessibilityIdentifier("share.caption")
            } footer: {
                Text(verbatim: SharePendingCopy.text(.queueHelp))
                    .font(kit.font(.caption))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
            .listRowBackground(surface)

            if let error = model.error {
                Section {
                    SharePickerNotice(glyph: .alert, text: error, tone: .danger)
                        .accessibilityIdentifier("share.error")
                }
                .listRowBackground(surface)
            }
            if model.recentChats.isEmpty, model.phase != .loading, model.phase != .failed {
                Section {
                    SharePickerNotice(glyph: .alert, text: SharePendingCopy.text(.empty), tone: .neutral)
                        .accessibilityIdentifier("share.noChats")
                }
                .listRowBackground(surface)
            }
            if model.isAtSelectionLimit, model.phase != .queuing {
                Section {
                    SharePickerNotice(glyph: .alert, text: SharePendingCopy.text(.limit), tone: .neutral)
                        .accessibilityIdentifier("share.limit")
                }
                .listRowBackground(surface)
            }
            if !sections.recent.isEmpty {
                Section {
                    rows(sections.recent, editable: editable)
                } header: {
                    header(SharePickerCopy.text(.recent), kit: kit).accessibilityIdentifier("share.section.recent")
                }
                .listRowBackground(surface)
            }
            if !sections.chats.isEmpty {
                Section {
                    rows(sections.chats, editable: editable)
                } header: {
                    if !sections.isSearching {
                        header(SharePickerCopy.text(.chats), kit: kit).accessibilityIdentifier("share.section.chats")
                    }
                }
                .listRowBackground(surface)
            }
            if sections.isSearching, sections.isEmpty {
                Section {
                    Text(verbatim: SharePickerCopy.text(.empty))
                        .font(kit.font(.body))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("share.searchEmpty")
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(verbatim: SharePickerCopy.text(.search)))
    }

    @ViewBuilder
    private func rows(_ chats: [ShareChat], editable: Bool) -> some View {
        ForEach(chats) { chat in
            let selected = model.selection.contains(chat.id)
            SharePickerRow(chat: chat, isSelected: selected, avatars: avatars) { model.toggle(chat) }
                .disabled(!editable || (!selected && model.isAtSelectionLimit))
        }
    }

    private func header(_ title: String, kit: AtumKit) -> some View {
        Text(verbatim: title)
            .font(kit.font(.callout).weight(.semibold))
            .foregroundStyle(kit.color(.ink3, scheme: scheme))
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The success state: durable intake, never a delivery claim.
struct SharePickerQueued: View {
    let done: () -> Void

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let kit {
            ScrollView {
                VStack(spacing: kit.space(.s4)) {
                    Image(share: .checkCircle)
                        .font(.system(size: 56))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .accessibilityHidden(true)
                    VStack(spacing: kit.space(.s2)) {
                        Text(verbatim: SharePendingCopy.text(.queued))
                            .font(kit.font(.title))
                            .foregroundStyle(kit.color(.ink, scheme: scheme))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("share.queued")
                        Text(verbatim: SharePendingCopy.text(.queueHelp))
                            .font(kit.font(.body))
                            .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    }
                    .multilineTextAlignment(.center)
                    Button(action: done) {
                        Text(verbatim: SharePickerCopy.text(.done)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.atumPrimary)
                    .accessibilityIdentifier("share.done")
                }
                .padding(.horizontal, kit.space(.s6))
                .padding(.top, kit.space(.s12))
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                AccessibilityNotification.Announcement(SharePendingCopy.text(.queued)).post()
            }
        }
    }
}

/// A quiet inline notice (the Kit's: neutral panel, only the icon takes the tone).
struct SharePickerNotice: View {
    enum Tone { case neutral, danger }
    let glyph: SharePickerDesign.Glyph
    let text: String
    let tone: Tone

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let kit {
            HStack(alignment: .firstTextBaseline, spacing: kit.space(.s3)) {
                Image(share: glyph)
                    .font(kit.font(.headline))
                    .foregroundStyle(kit.color(tone == .danger ? .danger : .ink2, scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(kit.font(.body))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The extension could not open its queue or design tokens: say so, and still offer Cancel.
struct SharePickerUnavailable: View {
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Text(verbatim: SharePendingCopy.text(.failed))
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: cancel) { Text(verbatim: SharePickerCopy.text(.cancel)) }
                    }
                }
        }
    }
}
