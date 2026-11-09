import AtumChat
import AtumNativeAPI
import SwiftUI

// Direct messages inside a company (wire 1.5), Mattermost's pattern in native
// SwiftUI: a "Direct messages" section under Channels, "New message" with a people
// picker (one person is a DM, several a group, up to eight others), Add people
// (a new conversation with the larger group; history is not carried over), Hide,
// a read-only banner in place of the composer, and a privacy note. Who is in a
// conversation, and whether it is read-only, is the platform's word.

/// What the Workplace list does with conversations.
struct ConversationListActions {
    /// The company members the picker offers (never the caller).
    let people: (String) -> [ConversationPerson]
    /// New message: the picked people's member refs. The outcome says whether to open.
    let start: (String, [String]) async -> ConversationStartOutcome
    /// A row was tapped: show it again if hidden, then open its room.
    let open: (String, ConversationListRow) async -> Void
    let hide: (String, String, Bool) async -> Void
    /// Open a room the platform just made (after New message): company, then room. The company is
    /// checked again before navigating.
    let routeToRoom: (String, String) -> Void
}

/// What the open chat shows for a conversation.
struct ConversationChatPresentation: Equatable {
    let companyID: String
    let conversationID: String
    let title: String
    let isReadOnly: Bool
    /// The directory read behind this chat failed transiently: shown, but the composer, Add people
    /// and Hide are closed until a read succeeds.
    let isStale: Bool
    /// Add people is not offered on a read-only conversation, or one already at nine.
    let canAddPeople: Bool
    let canHide: Bool
    /// The privacy note above the composer, until the person's first message.
    let note: String?
    /// Replaces the composer on a read-only conversation.
    let banner: String?
    /// Everyone but the caller who is already in.
    let kept: ConversationKept
}

struct ConversationChatActions {
    /// The people Add people offers (the company's, except those already in).
    var people: (String, Set<String>) -> [ConversationPerson] = { _, _ in [] }
    /// A new conversation with the larger set; the source is untouched.
    var addPeople: (String, String, [String]) async -> ConversationStartOutcome = { _, _, _ in .failed(.lost) }
    var hide: (String, String) async -> Void = { _, _ in }
    var routeToRoom: (String, String) -> Void = { _, _ in }
}

// MARK: Section

/// The "Direct messages" section of the Workplace list.
struct ConversationSectionView: View {
    let design: LiveDesign
    let companyID: String
    let section: ConversationSectionPresentation
    let actions: ConversationListActions

    @State private var showsPicker = false
    @State private var showsHidden: Bool
    @Environment(\.colorScheme) private var scheme

    /// `initiallyShowsHidden` is for previews and the simulator harness.
    init(design: LiveDesign, companyID: String, section: ConversationSectionPresentation,
         actions: ConversationListActions, initiallyShowsHidden: Bool = false) {
        self.design = design
        self.companyID = companyID
        self.section = section
        self.actions = actions
        _showsHidden = State(initialValue: initiallyShowsHidden)
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: ConversationCopy { ConversationCopy(design: design) }

    var body: some View {
        Section {
            if section.isLoading {
                note(copy.loading)
            } else if section.failed {
                note(copy.failed).accessibilityIdentifier("conversations.failed")
            } else if section.rows.isEmpty && section.hidden.isEmpty {
                note(copy.none).accessibilityIdentifier("conversations.none")
            }
            if section.isStale {
                // The last read failed: these are the last good rows, and nothing can be sent.
                note(copy.failed).accessibilityIdentifier("conversations.stale")
            }
            ForEach(section.rows) { row in
                rowView(row)
            }
            if !section.hidden.isEmpty {
                hiddenHeader
                if showsHidden {
                    ForEach(section.hidden) { row in
                        rowView(row)
                    }
                }
            }
            if let notice = section.notice {
                Text(verbatim: notice)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .accessibilityIdentifier("conversations.notice")
            }
        } header: {
            HStack {
                Text(verbatim: copy.directMessages)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .textCase(nil)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("conversations.section")
                Spacer()
                Button { showsPicker = true } label: {
                    Image(atum.symbol(.plus))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(section.isStale || section.failed)
                .accessibilityLabel(copy.newMessage)
                .accessibilityIdentifier("conversations.new")
            }
            .padding(.top, 8)
            .padding(.bottom, -6)
        }
        .listSectionSeparator(.hidden)
        .sheet(isPresented: $showsPicker) {
            ConversationPickerSheet(
                design: design, mode: .new,
                people: actions.people(companyID),
                start: { await actions.start(companyID, $0) },
                routeToRoom: { actions.routeToRoom(companyID, $0) })
                .atumDesign(visual: atum)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var hiddenHeader: some View {
        Button { withAnimation(.snappy) { showsHidden.toggle() } } label: {
            HStack(spacing: 6) {
                Image(atum.symbol(showsHidden ? .chevronDown : .chevronRight))
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(verbatim: copy.hidden)
                    .font(.footnote.weight(.semibold))
                Text(verbatim: "\(section.hidden.count)")
                    .font(.footnote)
                Spacer()
            }
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(verbatim: showsHidden ? "" : "\(section.hidden.count)"))
        .accessibilityIdentifier("conversations.hidden")
    }

    private func rowView(_ item: ConversationListRow) -> some View {
        let row = item.row
        return Button {
            guard row.canOpen else { return }
            Task { await actions.open(companyID, item) }
        } label: {
            HStack(spacing: 10) {
                AtumAvatar(kind: row.kind == .dm ? .person : .group, name: row.title, size: 28)
                Text(verbatim: row.title)
                    .font(.body.weight(item.isBold ? .semibold : .regular))
                    .foregroundStyle(atum.color(item.isBold ? .ink : .soft, scheme: scheme))
                    .lineLimit(1)
                if row.kind == .groupDM {
                    Text(verbatim: copy.group(row.participantCount))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                switch row.state {
                case .readOnly:
                    Text(verbatim: copy.readOnlyTag)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityIdentifier("conversation.readonly." + row.id)
                case .settingUp:
                    Text(verbatim: copy.settingUp)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityIdentifier("conversation.settingup." + row.id)
                case .ready:
                    EmptyView()
                }
                HomeBadgeView(design: design, badge: item.badge, pinned: false)
                    .accessibilityIdentifier("conversation.badge." + row.id)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.canOpen)
        .opacity(row.canOpen ? 1 : 0.5)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) { hideButton(item) }
        .contextMenu { hideButton(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.rowLabel(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if !row.isHidden {
                Button(copy.hide) { Task { await actions.hide(companyID, row.id, true) } }
            }
        }
        .accessibilityIdentifier("conversation." + row.id)
    }

    /// Hide is the person's own view. A hidden row has no control of its own: opening it
    /// shows it again.
    @ViewBuilder
    private func hideButton(_ item: ConversationListRow) -> some View {
        let row = item.row
        if !row.isHidden {
            Button {
                Task { await actions.hide(companyID, row.id, true) }
            } label: {
                Label(copy.hide, image: atum.symbol(.eyeOff))
            }
            .tint(atum.color(.muted, scheme: scheme))
            .accessibilityIdentifier("conversation.hide." + row.id)
        }
    }
}

// MARK: Picker

/// New message / Add people: search the company's people and tick one (a DM) or
/// several (a group, up to eight others). Start is safe to press twice: the same
/// people always open the same conversation. A refusal keeps the picker open; a
/// lost answer turns the button into Retry, which sends the same request.
struct ConversationPickerSheet: View {
    enum Mode: Equatable {
        case new
        /// Add people: the people already in stay, a new conversation is made.
        case add(ConversationKept, sourceID: String)
    }

    let design: LiveDesign
    let mode: Mode
    let people: [ConversationPerson]
    /// The picked refs. Add people sends only the new ones; the kept are added by the caller.
    let start: ([String]) async -> ConversationStartOutcome
    let routeToRoom: (String) -> Void

    @State private var selected: [String]
    @State private var query = ""
    @State private var isStarting = false
    @State private var failure: ConversationRefusal?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// `initialSelected` and `initialFailure` are for previews and the simulator harness.
    init(design: LiveDesign, mode: Mode, people: [ConversationPerson],
         start: @escaping ([String]) async -> ConversationStartOutcome,
         routeToRoom: @escaping (String) -> Void,
         initialSelected: [String] = [], initialFailure: ConversationRefusal? = nil) {
        self.design = design
        self.mode = mode
        self.people = people
        self.start = start
        self.routeToRoom = routeToRoom
        _selected = State(initialValue: initialSelected)
        _failure = State(initialValue: initialFailure)
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: ConversationCopy { ConversationCopy(design: design) }
    private var keptCount: Int {
        if case let .add(kept, _) = mode { return kept.refs.count }
        return 0
    }
    private var visible: [ConversationPerson] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return people }
        return people.filter { person in
            [person.name, person.handle.map { "@" + $0 } ?? ""].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
    private var atLimit: Bool { !ConversationPeople.canAddAnother(selectedOthers: selected.count + keptCount) }
    private var canStart: Bool {
        ConversationPeople.canStart(selectedOthers: selected.count, keptOthers: keptCount) && !isStarting
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: explanation)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .accessibilityIdentifier("conversation.picker.hint")
                    if case let .add(kept, _) = mode {
                        Text(verbatim: kept.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                            .accessibilityIdentifier("conversation.picker.kept")
                    }
                    TextField(copy.searchPeople, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("conversation.picker.search")
                }
                .listRowBackground(atum.color(.cell, scheme: scheme))

                Section {
                    if people.isEmpty {
                        Text(verbatim: copy.nobody)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .accessibilityIdentifier("conversation.picker.nobody")
                    } else if visible.isEmpty {
                        Text(verbatim: copy.noMatch)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                    }
                    ForEach(visible) { person in
                        personRow(person)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !selected.isEmpty {
                            Text(verbatim: copy.peopleSelected(selected.count))
                                .accessibilityIdentifier("conversation.picker.count")
                        }
                        if atLimit {
                            Text(verbatim: copy.limit)
                                .accessibilityIdentifier("conversation.picker.limit")
                        }
                        if let failure {
                            Text(verbatim: copy.refusal(failure))
                                .foregroundStyle(atum.color(.danger, scheme: scheme))
                                .accessibilityIdentifier("conversation.picker.error")
                        }
                    }
                }
                .listRowBackground(atum.color(.cell, scheme: scheme))
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy.cancel) { dismiss() }
                        .accessibilityIdentifier("conversation.picker.cancel")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if isStarting { ProgressView() }
                        Text(verbatim: submitTitle)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(atum.color(.actionStrong, scheme: scheme))
                .disabled(!canStart)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(atum.color(.ground, scheme: scheme))
                .overlay(alignment: .top) {
                    Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
                }
                .accessibilityIdentifier("conversation.picker.start")
            }
            .sensoryFeedback(.error, trigger: failure)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("conversation.picker")
    }

    private var title: String {
        switch mode {
        case .new: copy.newMessage
        case .add: copy.addPeople
        }
    }

    private var explanation: String {
        switch mode {
        case .new: copy.newMessageHint
        case .add: copy.addNote
        }
    }

    private var submitTitle: String {
        if failure == .lost { return copy.retry }
        switch mode {
        case .new: return copy.start
        case .add: return copy.addConfirm
        }
    }

    private func personRow(_ person: ConversationPerson) -> some View {
        let isSelected = selected.contains(person.id)
        let disabled = !isSelected && atLimit
        return Button { toggle(person.id) } label: {
            HStack(spacing: 12) {
                AtumAvatar(kind: .person, name: person.name, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: person.name)
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    if let handle = person.handle {
                        Text(verbatim: "@" + handle)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                    }
                }
                Spacer(minLength: 8)
                Image(atum.symbol(isSelected ? .checkCircle : .circle))
                    .font(.title3)
                    .foregroundStyle(atum.color(isSelected ? .actionStrong : .muted, scheme: scheme))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isStarting)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: person.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("conversation.person." + person.id)
    }

    private func toggle(_ id: String) {
        failure = nil
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if !atLimit {
            selected.append(id)
        }
    }

    private func submit() {
        guard canStart else { return }
        isStarting = true
        failure = nil
        let picked = selected
        Task { @MainActor in
            let outcome = await start(picked)
            isStarting = false
            switch outcome {
            case let .opened(roomID):
                dismiss()
                routeToRoom(roomID)
            case .settingUp:
                // Made and listed; its row says "Setting up…" and opens when ready.
                dismiss()
            case let .failed(refusal):
                failure = refusal
            }
        }
    }
}

// MARK: Chat

/// In place of the composer on a read-only conversation: it can still be read.
struct ConversationReadOnlyBanner: View {
    let text: String
    let design: LiveDesign

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let atum = AtumVisualSystem(design: design)
        Text(verbatim: text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.conversation.readonly")
    }
}
