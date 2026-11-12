import AtumChat
import AtumDesign
import AtumNativeAPI
import PhotosUI
import SwiftUI

/// The assistant's identity as the card draws it. It is one value for the
/// chat's info sheet and for Settings > Assistants, so both surfaces show the
/// same face, name, handle and primary role.
struct AssistantCardIdentity: Equatable {
    let roomID: String
    let name: String
    let title: String?
    /// The platform's bot handle stem when `/agents` advertises one, for
    /// hosts without the directory editor (AS-5); nil shows the exported
    /// "no handle" line rather than inventing one.
    let botHandle: String?
    let isPrimary: Bool
    let avatar: LiveProductAvatar?
    let matrixAvatarURI: String?
    let avatarSHA256: String?
    let avatarCandidates: [LiveProductRemoteArt]

    init(roomID: String, name: String, title: String? = nil, botHandle: String? = nil,
         isPrimary: Bool = false, avatar: LiveProductAvatar? = nil,
         matrixAvatarURI: String? = nil, avatarSHA256: String? = nil,
         avatarCandidates: [LiveProductRemoteArt] = []) {
        self.roomID = roomID
        self.name = name
        self.title = title
        self.botHandle = botHandle
        self.isPrimary = isPrimary
        self.avatar = avatar
        self.matrixAvatarURI = matrixAvatarURI
        self.avatarSHA256 = avatarSHA256
        self.avatarCandidates = avatarCandidates
    }

    var avatarPhotoURL: URL? {
        if case let .photo(url, _)? = avatar { return url }
        return nil
    }

    func homeRow(name: String? = nil) -> HomeRow {
        HomeRow(id: roomID, kind: isPrimary ? .atum : .assistant, name: name ?? self.name,
                avatarURL: avatarPhotoURL, matrixAvatarURL: matrixAvatarURI,
                avatarSHA256: avatarSHA256, avatarCandidates: avatarCandidates,
                mark: avatar?.agentMark)
    }
}

/// The one assistant card, mirrored from the desktop's card: face and name
/// (renamed where they stand), Message, bot handle, what it helps with, its
/// personality, where it lives, its model, pet, skills and routines. Every
/// text field saves when the person leaves it; there is no Save button and no
/// second editor. `entry` only decides whether the card is drawn in place or
/// pushed; `AssistantCardNavigation` keeps that answer testable.
struct AssistantCard: View {
    let design: LiveDesign
    let identity: AssistantCardIdentity
    let entry: AssistantCardEntry
    let definition: AssistantDefinitionActions?
    let models: AssistantModelActions?
    let home: AssistantHomeActions?
    /// Used only when a build has the pre-placement model editor and no
    /// conversation model actions (scripted runs).
    let modelDestinations: AssistantModelDestinationActions?
    let avatar: AssistantAvatarActions?
    let routines: AssistantRoutineActions?
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let onMessage: (() -> Void)?
    /// Opens the Store on one shelf: Pet opens Pets and "Find more skills"
    /// opens Skills, as desktop's `openShelf` does. Nil in hosts without a
    /// Store, and then the card has no Pet row (desktop: no Store, no row).
    let onOpenStore: ((StoreSectionKind) -> Void)?
    /// The bot handle directory for this assistant (AS-5). Nil keeps the
    /// read-only handle line.
    let handles: AssistantHandleActions?
    /// Desktop's "Delete {name}…" (AS-4). Nil for the primary and in hosts
    /// that cannot reach the retire route.
    let retire: AssistantRetireActions?
    /// After the platform confirms the retirement: the host leaves the card.
    let onRetired: (() -> Void)?
    /// Opened from a "Rename…" entry: the name field takes focus at once.
    let startsRenaming: Bool

    @State private var snapshot: AgentDefinitionSnapshot?
    @State private var persona: AssistantPersona?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var nameEdit: AssistantCardEdit
    @State private var whatEdit = AssistantCardEdit(saved: "")
    @State private var whoEdit = AssistantCardEdit(saved: "")
    @State private var instructionsEdit = AssistantCardEdit(saved: "")
    @State private var personalityExpanded = false
    @State private var skillsExpanded = false
    @FocusState private var focused: Field?
    @State private var queued: [Field] = []
    @State private var writing = false
    @State private var note: Note?
    @State private var retryField: Field?
    @State private var conflict: AgentDefinitionSnapshot?
    @State private var modelSnapshot: ManagedModelSnapshot?
    @State private var modelPresented = false
    @State private var destinationsPresented = false
    @State private var routinesPresented = false
    @State private var photoItem: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var photoFailed = false
    @State private var photoSaved = false
    @State private var routineProbe: AgentRoutinesProbe?
    @State private var routineTask: Task<Void, Never>?
    @State private var routineTaskGeneration: UInt64 = 0
    @State private var routinePhase: AgentRoutinesProbe.Phase = .idle
    @State private var routineProbed = false
    @State private var petName: String?
    @State private var confirmsRetire = false
    @State private var retiring = false
    @State private var retireFailed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The session is offline or in error: desktop's card caption
    /// "You're offline. You can edit once you're connected."
    @Environment(\.showsConnectionGlyph) private var offline

    private enum Field: Hashable {
        case name, what, who, instructions
    }

    private enum Note: Equatable {
        case saved
        case failed
        case changedElsewhere
        case refused(String)
    }

    init(design: LiveDesign, identity: AssistantCardIdentity, entry: AssistantCardEntry,
         definition: AssistantDefinitionActions?, models: AssistantModelActions?,
         home: AssistantHomeActions?, modelDestinations: AssistantModelDestinationActions?,
         avatar: AssistantAvatarActions?, routines: AssistantRoutineActions?,
         loadMatrixThumbnail: ((String, Int) async -> Data?)? = nil,
         onMessage: (() -> Void)? = nil, onOpenStore: ((StoreSectionKind) -> Void)? = nil,
         handles: AssistantHandleActions? = nil, retire: AssistantRetireActions? = nil,
         onRetired: (() -> Void)? = nil, startsRenaming: Bool = false) {
        self.design = design
        self.identity = identity
        self.entry = entry
        self.definition = definition
        self.models = models
        self.home = home
        self.modelDestinations = modelDestinations
        self.avatar = avatar
        self.routines = routines
        self.loadMatrixThumbnail = loadMatrixThumbnail
        self.onMessage = onMessage
        self.onOpenStore = onOpenStore
        self.handles = handles
        self.retire = identity.isPrimary ? nil : retire
        self.onRetired = onRetired
        self.startsRenaming = startsRenaming
        _nameEdit = State(initialValue: AssistantCardEdit(saved: identity.name,
                                                          requirement: .nonEmpty))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: AssistantCardCopy { AssistantCardCopy(design: design) }

    private var editable: Bool {
        snapshot?.definition != nil && definition != nil && !loading
    }

    private var displayName: String {
        snapshot?.assistant.displayName ?? identity.name
    }

    private var capabilities: AssistantCardCapabilities {
        AssistantCardCapabilities(
            canMessage: onMessage != nil,
            persona: persona?.kind ?? .template,
            hasHome: home != nil,
            hasModel: models != nil || modelDestinations != nil,
            hasPet: AssistantCardLayout.showsPet(storeAvailable: onOpenStore != nil),
            hasSkills: AssistantCardLayout.showsSkills(count: skills.count),
            hasRoutines: routines != nil,
            canRetire: retire != nil
        )
    }

    private var rows: [AssistantCardRow] {
        AssistantCardLayout.rows(for: identity.isPrimary ? .primary : .other,
                                 capabilities: capabilities)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                band
                offlineCaption
                handleSection
                personaSection
                rowsSection
                retireSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(entry == .settingsRoster
                         ? copy.text(.sheetLabel, [.text(identity.name)]) : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if let focused {
                    Button(copy.text(.undo)) {
                        revert(focused)
                        self.focused = nil
                    }
                    .accessibilityIdentifier("assistant.card.keyboard.revert")
                }
                Spacer()
                Button(copy.text(.done)) { focused = nil }
                    .accessibilityIdentifier("assistant.card.keyboard.done")
            }
        }
        .task { await load() }
        .task {
            // "Rename…": the field takes focus once the card has its name.
            guard startsRenaming else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if definition?.rename != nil { focused = .name }
        }
        .alert(retireCopy.text(.agentRetireTitle, name: displayName), isPresented: $confirmsRetire) {
            Button(retireCopy.text(.agentCancel), role: .cancel) {}
            Button(retireCopy.text(.agentRetireConfirm), role: .destructive) { retireNow() }
                .accessibilityIdentifier("assistant.card.retire.confirm")
        } message: {
            Text(retireCopy.text(.agentRetireBody, name: displayName))
        }
        .onChange(of: photoItem) { _, item in
            if let item { loadPhoto(item) }
        }
        .onChange(of: focused) { old, new in
            guard let old, old != new else { return }
            enqueue(old)
        }
        .onDisappear {
            routineTask?.cancel()
            routineTask = nil
            routineProbe?.cancel()
            routineProbed = false
            routinePhase = .idle
            enqueueAllDirty()
        }
        .sheet(isPresented: $modelPresented) {
            NavigationStack {
                if let models {
                    PhoneConversationModelPicker(
                        design: design,
                        actions: models,
                        destinations: modelDestinations,
                        initialSnapshot: modelSnapshot,
                        onSnapshot: { value in modelSnapshot = value }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(copy.text(.done)) { modelPresented = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $destinationsPresented) {
            NavigationStack {
                if let modelDestinations {
                    PhoneModelDestinationsPicker(design: design, actions: modelDestinations)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(copy.text(.done)) { destinationsPresented = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $routinesPresented) {
            NavigationStack {
                if let routines {
                    AssistantRoutinesView(design: design, assistantName: displayName,
                                          actions: routines)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(copy.text(.done)) { routinesPresented = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            avatarBlock
            nameField
            if let title = identity.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
            if note == .saved {
                Label(copy.text(.saved), image: atum.symbol(.checkCircle))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityIdentifier("assistant.card.saved")
            }
            Text(copy.text(.privacy, [.text(displayName)]))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .multilineTextAlignment(.center)
            if let onMessage {
                // Desktop's card pill: a quiet capsule with the chat glyph.
                Button(action: onMessage) {
                    HStack(spacing: 6) {
                        Image(atum.symbol(.messageCircle))
                            .accessibilityHidden(true)
                        Text(copy.text(.message))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .background(atum.kitColor(.fillQuiet, scheme: scheme), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("assistant.card.message")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var avatarBlock: some View {
        let face = HomeAvatar(row: identity.homeRow(name: displayName), size: 88,
                              loadMatrixThumbnail: loadMatrixThumbnail)
        if let avatar, !savingPhoto {
            PhotosPicker(selection: $photoItem, matching: .images) {
                face.overlay(alignment: .bottom) {
                    Text(copy.text(.avatarBand))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(atum.color(.onInk, scheme: scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(atum.color(.ink, scheme: scheme).opacity(0.72),
                                    in: Capsule())
                        .padding(.bottom, 4)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy.text(.avatarLabel, [.text(displayName)]))
            .accessibilityIdentifier("assistant.card.photo")
        } else {
            face
                .overlay {
                    if savingPhoto { ProgressView().controlSize(.small) }
                }
        }
        if identity.avatarPhotoURL != nil, avatar != nil {
            Button(copy.text(.photoRemove)) {
                Task { @MainActor in await savePhoto(nil) }
            }
            .font(.footnote)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .disabled(savingPhoto)
            .accessibilityIdentifier("assistant.card.photo.remove")
        }
        if photoFailed {
            Text(copy.text(.photoError))
                .font(.footnote)
                .foregroundStyle(atum.color(.danger, scheme: scheme))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("assistant.card.photo.failed")
        } else if photoSaved {
            Text(copy.text(.saved))
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityIdentifier("assistant.card.photo.saved")
        }
    }

    private var nameField: some View {
        TextField("", text: $nameEdit.draft)
            .focused($focused, equals: .name)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { focused = nil }
            .disabled(definition?.rename == nil || snapshot == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focused == .name ? atum.color(.cell, scheme: scheme) : .clear)
            }
            .accessibilityLabel(copy.text(.nameLabel, [.text(displayName)]))
            .accessibilityIdentifier("assistant.card.name")
    }

    @ViewBuilder private var offlineCaption: some View {
        if offline {
            Text(copy.text(.offline))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
                .accessibilityIdentifier("assistant.card.offline")
        }
    }

    // MARK: Persona

    @ViewBuilder private var band: some View {
        switch note {
        case .failed:
            noteBand(text: copy.text(.saveFailed), retry: true,
                     identifier: "assistant.card.save-failed")
        case let .refused(message):
            noteBand(text: message, retry: false, identifier: "assistant.card.name-refused")
        case .changedElsewhere:
            noteBand(text: copy.text(.changedElsewhere, [.text(displayName)]), retry: true,
                     identifier: "assistant.card.changed-elsewhere")
        case .saved, nil:
            EmptyView()
        }
    }

    private func noteBand(text: String, retry: Bool, identifier: String) -> some View {
        HStack(spacing: 8) {
            Image(atum.symbol(.alertCircle))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if retry {
                Button(copy.text(.retry)) {
                    if let field = retryField { enqueue(field) }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .foregroundStyle(atum.color(.danger, scheme: scheme))
        .padding(12)
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 12)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var personaSection: some View {
        if loadFailed, snapshot == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.text(.loadFailed, [.text(displayName)]))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                Button(copy.text(.retry)) { Task { await loadDefinition(force: true) } }
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 12)
        } else if let persona {
            VStack(alignment: .leading, spacing: 10) {
                if persona.kind == .custom {
                    instructionField
                } else {
                    purposeField
                    personalityRow
                }
                Text(copy.text(.footnote))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                if loading, snapshot == nil {
                    ProgressView().controlSize(.small)
                }
                if snapshot?.definition == nil, !loading, !loadFailed {
                    Text(copy.text(.setupRowNotReady))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .accessibilityIdentifier("assistant.card.setup")
                }
            }
            .padding(16)
            .background(atum.color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 12)
        }
    }

    private var purposeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.text(.purposeLabel, [.text(displayName)]))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
            TextField(copy.text(.purposePlaceholder), text: $whatEdit.draft, axis: .vertical)
                .lineLimit(3...10)
                .focused($focused, equals: .what)
                .disabled(!editable)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityIdentifier("assistant.card.purpose")
        }
    }

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.text(.instructions))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
            TextField(copy.text(.instructions), text: $instructionsEdit.draft, axis: .vertical)
                .lineLimit(3...12)
                .focused($focused, equals: .instructions)
                .disabled(!editable)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityIdentifier("assistant.card.instructions")
        }
    }

    private var personalityRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if personalityExpanded {
                    focused = nil
                    enqueue(.who)
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    personalityExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(copy.text(.personality))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    Spacer(minLength: 8)
                    Text(whoValue)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .lineLimit(1)
                    Image(atum.symbol(personalityExpanded ? .chevronDown
                                                                   : .chevronRight))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!editable)
            .accessibilityIdentifier("assistant.card.personality")
            if personalityExpanded {
                TextField(copy.text(.personalityPlaceholder), text: $whoEdit.draft, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($focused, equals: .who)
                    .disabled(!editable)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .padding(.top, 4)
                    .accessibilityIdentifier("assistant.card.personality.field")
            }
        }
    }

    private var whoValue: String {
        let value = whoEdit.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? copy.text(.personalityEmpty) : value
    }

    // MARK: Rows

    private var rowsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleRows.enumerated()), id: \.element) { index, row in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                rowView(row)
            }
        }
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The header draws the face, name and Message; the persona section draws
    /// its fields. Only the remaining rows belong in the grouped cell.
    private var visibleRows: [AssistantCardRow] {
        rows.filter { row in
            switch row {
            case .home, .model, .pet, .skills, .routines: true
            case .photo, .name, .message, .handle, .purpose, .personality, .instructions, .retire:
                false
            }
        }
    }

    @ViewBuilder private func rowView(_ row: AssistantCardRow) -> some View {
        switch row {
        case .photo, .name, .message, .retire:
            EmptyView()
        case .handle:
            EmptyView()
        case .purpose:
            EmptyView()
        case .personality:
            EmptyView()
        case .instructions:
            EmptyView()
        case .home:
            if let home {
                AssistantHomeCardControl(design: design, assistantName: displayName, actions: home)
            }
        case .model:
            modelRow
        case .pet:
            petRow
        case .skills:
            skillsRow
        case .routines:
            routinesRow
        }
    }

    private var handleRow: some View {
        HStack(spacing: 8) {
            Text(AssistantCardStandaloneCopy.botName(design))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Spacer(minLength: 8)
            if let handle = identity.botHandle, !handle.isEmpty {
                Text(verbatim: "@" + handle)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant.card.handle")
            } else {
                Text(AssistantCardStandaloneCopy.botNone(design))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityIdentifier("assistant.card.handle")
            }
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var modelRow: some View {
        if models != nil || modelDestinations != nil {
            Button {
                if models != nil { modelPresented = true } else { destinationsPresented = true }
            } label: {
                cardRow(label: AssistantCardStandaloneCopy.model(design), value: modelValue)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.card.model")
        }
    }

    private var modelValue: String? {
        guard let snapshot = modelSnapshot else { return nil }
        let choice = snapshot.choice
        return snapshot.models.first(where: { $0.alias == choice.model })?.displayName
            ?? choice.model
    }

    /// Desktop's Pet row: "Pet · {name}", or "Choose" when this assistant
    /// has no pet to show; it opens the Store's Pets shelf.
    private var petRow: some View {
        Button {
            onOpenStore?(.pets)
        } label: {
            cardRow(label: copy.text(.pet), value: petName ?? copy.text(.petChoose))
        }
        .buttonStyle(.plain)
        .disabled(onOpenStore == nil)
        .accessibilityIdentifier("assistant.card.pet")
    }

    private var skills: [PortableSkillReference] {
        snapshot?.definition?.skills ?? []
    }

    /// Desktop's "Skills · N" row, drawn only when there are skills: the
    /// value is the count alone, the names read as people say them
    /// (`skillLabel`), and "Find more skills" opens the Skills shelf.
    /// `skillsLabel` ("Skills, 3") is the row's accessibility label, as on
    /// desktop, never its visible value.
    private var skillsRow: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { skillsExpanded.toggle() }
            } label: {
                cardRow(label: copy.text(.skills), value: "\(skills.count)")
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(design.text(AssistantCardCopyKey.skillsLabel.rawValue,
                                            arguments: [.number(Int64(skills.count))]))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("assistant.card.skills")
            if skillsExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(skills, id: \.name) { skill in
                        Text(verbatim: AssistantSkillLabel.label(skill.name))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let onOpenStore {
                        Divider()
                        Button { onOpenStore(.skills) } label: {
                            HStack(spacing: 8) {
                                Text(copy.text(.findSkills))
                                Spacer(minLength: 8)
                                Image(atum.symbol(.arrowUpRight))
                                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .accessibilityIdentifier("assistant.card.skills.find")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var routinesRow: some View {
        if let routines {
            Button { routinesPresented = true } label: {
                cardRow(label: copy.text(.routines), value: routineStatus)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("assistant.card.routines")
            .onAppear { startRoutineProbe(using: routines) }
        }
    }

    /// One line at ordinary sizes. At the accessibility sizes the value moves
    /// under its label and wraps, so neither is clipped.
    private func cardRow(label: String, value: String?) -> some View {
        HStack(spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let value, !value.isEmpty {
                        Text(verbatim: value)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            } else {
                Text(label)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Spacer(minLength: 8)
                if let value, !value.isEmpty {
                    Text(verbatim: value)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .lineLimit(1)
                }
            }
            Image(atum.symbol(.chevronRight))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    // MARK: Load and save

    @MainActor private func load() async {
        loading = true
        await loadDefinition(force: false)
        loading = false
        async let model: Void = loadModel()
        async let pet: Void = loadPet()
        _ = await (model, pet)
    }

    /// Desktop reads the pet only where the row is drawn (with a Store) and
    /// keeps "Choose" when the read fails.
    @MainActor private func loadPet() async {
        guard onOpenStore != nil, let pet = definition?.pet else { return }
        petName = await pet.read()
    }

    @MainActor private func loadDefinition(force: Bool) async {
        guard let definition, force || snapshot == nil, !loadFailed || force else {
            if definition == nil {
                persona = AssistantPersonaPolicy.parse("", primary: identity.isPrimary)
            }
            return
        }
        loadFailed = false
        switch await definition.read() {
        case let .value(value):
            apply(value)
        case .failed:
            loadFailed = true
            if snapshot == nil {
                persona = AssistantPersonaPolicy.parse("", primary: identity.isPrimary)
            }
        }
    }

    @MainActor private func loadModel() async {
        guard let models, modelSnapshot == nil else { return }
        if case let .value(value) = await models.read() {
            modelSnapshot = value
        }
    }

    @MainActor private func apply(_ value: AgentDefinitionSnapshot) {
        snapshot = value
        conflict = nil
        loadFailed = false
        let parsed = AssistantPersonaPolicy.parse(value.definition?.soul ?? "",
                                                  primary: identity.isPrimary)
        persona = parsed
        nameEdit = AssistantCardEdit(saved: value.assistant.displayName,
                                      requirement: .nonEmpty)
        whatEdit = AssistantCardEdit(saved: parsed.what)
        whoEdit = AssistantCardEdit(saved: parsed.who)
        instructionsEdit = AssistantCardEdit(saved: parsed.instructions)
    }

    @ViewBuilder private var handleSection: some View {
        Group {
            if let handles {
                AssistantHandleEditor(design: design, assistantName: displayName, actions: handles,
                                      disabled: offline)
            } else {
                handleRow
            }
        }
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.bottom, 12)
    }

    // MARK: Retire (AS-4)

    private var retireCopy: AssistantRetireCopy { AssistantRetireCopy(design: design) }

    /// Desktop's delete section: its own group after the rows, the one
    /// destructive line, and a confirmation that says it is final. Nothing
    /// changes on the phone until the platform confirms; a failure keeps the
    /// card as it was and says so.
    @ViewBuilder private var retireSection: some View {
        if rows.contains(.retire), retire != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button(role: .destructive) {
                    retireFailed = false
                    confirmsRetire = true
                } label: {
                    HStack(spacing: 8) {
                        Text(copy.text(.deleteRow, [.text(displayName)]))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if retiring { ProgressView().controlSize(.small) }
                    }
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .frame(minHeight: 52)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(retiring || offline)
                .background(atum.color(.cell, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("assistant.card.retire")
                if retireFailed {
                    Text(retireCopy.text(.agentRetireFailed))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("assistant.card.retire.failed")
                }
            }
            .padding(.top, 12)
        }
    }

    private func retireNow() {
        guard let retire, !retiring else { return }
        retiring = true
        retireFailed = false
        Task { @MainActor in
            let result = await retire.retire()
            retiring = false
            switch result {
            case .retired: onRetired?()
            case .failed: retireFailed = true
            }
        }
    }

    private func revert(_ field: Field) {
        switch field {
        case .name: nameEdit.revert()
        case .what: whatEdit.revert()
        case .who: whoEdit.revert()
        case .instructions: instructionsEdit.revert()
        }
    }

    private func enqueue(_ field: Field) {
        if !queued.contains(field) { queued.append(field) }
        guard !writing else { return }
        writing = true
        Task { @MainActor in
            while !queued.isEmpty {
                let next = queued.removeFirst()
                await save(next)
            }
            writing = false
        }
    }

    private func enqueueAllDirty() {
        if nameEdit.isDirty { enqueue(.name) }
        if whatEdit.isDirty { enqueue(.what) }
        if whoEdit.isDirty { enqueue(.who) }
        if instructionsEdit.isDirty { enqueue(.instructions) }
    }

    @MainActor private func save(_ field: Field) async {
        guard let base = conflict ?? snapshot else { return }
        if field == .name {
            await saveName(base)
        } else {
            await savePersona(field, base: base)
        }
    }

    @MainActor private func saveName(_ base: AgentDefinitionSnapshot) async {
        guard let rename = definition?.rename else {
            if nameEdit.isDirty { nameEdit.revert() }
            return
        }
        guard let value = nameEdit.pendingSave() else {
            if nameEdit.isDirty { nameEdit.revert() }
            return
        }
        guard value.unicodeScalars.count <= 40 else {
            note = .refused(copy.text(.problemsTooLong))
            retryField = .name
            return
        }
        note = nil
        retryField = nil
        let result = await rename(base, value)
        switch result {
        case let .renamed(value):
            conflict = nil
            snapshot = value
            nameEdit.accept(value.assistant.displayName)
            note = .saved
        case let .refused(reason):
            note = .refused(refusal(reason, name: value))
            retryField = .name
        case let .conflict(latest):
            conflict = latest
            if let latest, let soul = latest.definition?.soul {
                persona = AssistantPersonaPolicy.parse(soul, primary: identity.isPrimary)
            }
            note = .changedElsewhere
            retryField = .name
        case .failed:
            note = .failed
            retryField = .name
        }
    }

    @MainActor private func savePersona(_ field: Field, base: AgentDefinitionSnapshot) async {
        guard let definition, let currentPersona = persona, var value = base.definition else { return }
        let edit: AssistantCardEdit = switch field {
        case .what: whatEdit
        case .who: whoEdit
        case .instructions: instructionsEdit
        case .name: nameEdit
        }
        guard edit.pendingSave() != nil else { return }
        let soul = AssistantPersonaPolicy.render(
            currentPersona,
            name: base.assistant.displayName,
            who: whoEdit.draft,
            what: whatEdit.draft,
            instructions: instructionsEdit.draft
        )
        guard soul != value.soul else { return }
        value.soul = soul
        note = nil
        retryField = nil
        let result = await definition.save(base, value)
        switch result {
        case let .saved(saved):
            conflict = nil
            snapshot = saved
            let parsed = AssistantPersonaPolicy.parse(saved.definition?.soul ?? "",
                                                      primary: identity.isPrimary)
            persona = parsed
            switch field {
            case .what: whatEdit.accept(parsed.what)
            case .who: whoEdit.accept(parsed.who)
            case .instructions: instructionsEdit.accept(parsed.instructions)
            case .name: break
            }
            note = .saved
        case let .conflict(latest):
            conflict = latest
            if let latest, let soul = latest.definition?.soul {
                persona = AssistantPersonaPolicy.parse(soul, primary: identity.isPrimary)
            }
            note = .changedElsewhere
            retryField = field
        case .failed:
            note = .failed
            retryField = field
        }
    }

    private func refusal(_ reason: AssistantNameRefusal, name: String) -> String {
        switch reason {
        case .reserved: return copy.text(.primaryTip)
        case .taken: return copy.text(.problemsDuplicate, [.text(name)])
        case .invalid: return copy.text(.saveFailed)
        }
    }

    // MARK: Photo and routines

    private func loadPhoto(_ item: PhotosPickerItem) {
        guard let avatar else { return }
        Task { @MainActor in
            photoFailed = false
            photoSaved = false
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let prepared = try? AssistantAvatarPhoto.prepare(data) else {
                photoItem = nil
                photoFailed = true
                return
            }
            let result = await avatar.save(prepared)
            photoItem = nil
            switch result {
            case .saved: photoSaved = true
            case .failed: photoFailed = true
            }
        }
    }

    @MainActor private func savePhoto(_ image: AgentAvatarImage?) async {
        guard let avatar else { return }
        savingPhoto = true
        photoFailed = false
        photoSaved = false
        let result = await avatar.save(image)
        savingPhoto = false
        switch result {
        case .saved: photoSaved = true
        case .failed: photoFailed = true
        }
    }

    private func startRoutineProbe(using routines: AssistantRoutineActions) {
        guard !routineProbed else { return }
        routineProbed = true
        let probe = routineProbe ?? AgentRoutinesProbe(read: routines.read)
        routineProbe = probe
        guard routineTask == nil else { return }
        routineTaskGeneration &+= 1
        let generation = routineTaskGeneration
        routineTask = Task { @MainActor in
            defer {
                if routineTaskGeneration == generation { routineTask = nil }
            }
            guard let phase = await probe.probe(), !Task.isCancelled else { return }
            routinePhase = phase
        }
    }

    private var routineStatus: String? {
        switch routinePhase {
        case .preparing: return copy.text(.setupRowWorking)
        case .legacyPending: return nil
        case .failed: return copy.text(.retry)
        case .ready:
            guard let count = routineProbe?.routineCount else { return nil }
            return copy.routineCount(count)
        case .idle, .loading: return nil
        }
    }
}

/// The card's words from the pinned desktop export. Keys stay in one place so
/// the coordinator can see exactly what the phone reads.
enum AssistantCardCopyKey: String {
    case menuEdit = "src.matrix.assistant-card.copy.assistantCardCopies.menuEdit"
    case deleteRow = "src.matrix.assistant-card.copy.assistantCardCopies.deleteRow"
    case sheetLabel = "src.matrix.assistant-card.copy.assistantCardCopies.sheetLabel"
    case done = "src.matrix.assistant-card.copy.assistantCardCopies.done"
    case message = "src.matrix.assistant-card.copy.assistantCardCopies.message"
    case privacy = "src.matrix.assistant-card.copy.assistantCardCopies.privacy"
    case avatarBand = "src.matrix.assistant-card.copy.assistantCardCopies.avatarBand"
    case avatarLabel = "src.matrix.assistant-card.copy.assistantCardCopies.avatarLabel"
    case photoRemove = "src.matrix.assistant-card.copy.assistantCardCopies.photoRemove"
    case photoError = "src.matrix.assistant-card.copy.assistantCardCopies.photoError"
    case photoSaving = "src.matrix.roster-create-copy.copies.photoSaving"
    case nameLabel = "src.matrix.assistant-card.copy.assistantCardCopies.nameLabel"
    case nameField = "src.matrix.assistant-card.copy.assistantCardCopies.nameField"
    case nameHelper = "src.matrix.assistant-card.copy.assistantCardCopies.nameHelper"
    case nameLeft = "src.matrix.assistant-card.copy.assistantCardCopies.nameLeft"
    case primaryTip = "src.matrix.assistant-card.copy.assistantCardCopies.primaryTip"
    case renamed = "src.matrix.assistant-card.copy.assistantCardCopies.renamed"
    case undo = "src.matrix.assistant-card.copy.assistantCardCopies.undo"
    case undone = "src.matrix.assistant-card.copy.assistantCardCopies.undone"
    case saved = "src.matrix.assistant-card.copy.assistantCardCopies.saved"
    case saving = "src.matrix.assistant-card.copy.assistantCardCopies.saving"
    case saveFailed = "src.matrix.assistant-card.copy.assistantCardCopies.saveFailed"
    case retry = "src.matrix.assistant-card.copy.assistantCardCopies.retry"
    case changedElsewhere = "src.matrix.assistant-card.copy.assistantCardCopies.changedElsewhere"
    case offline = "src.matrix.assistant-card.copy.assistantCardCopies.offline"
    case loadFailed = "src.matrix.assistant-card.copy.assistantCardCopies.loadFailed"
    case purposeLabel = "src.matrix.assistant-card.copy.assistantCardCopies.purposeLabel"
    case purposePlaceholder = "src.matrix.assistant-card.copy.assistantCardCopies.purposePlaceholder"
    case personality = "src.matrix.assistant-card.copy.assistantCardCopies.personality"
    case personalityEmpty = "src.matrix.assistant-card.copy.assistantCardCopies.personalityEmpty"
    case personalityPlaceholder = "src.matrix.assistant-card.copy.assistantCardCopies.personalityPlaceholder"
    case instructions = "src.matrix.assistant-card.copy.assistantCardCopies.instructions"
    case footnote = "src.matrix.assistant-card.copy.assistantCardCopies.footnote"
    case pet = "src.matrix.assistant-card.copy.assistantCardCopies.pet"
    case petChoose = "src.matrix.assistant-card.copy.assistantCardCopies.petChoose"
    case skills = "src.matrix.assistant-card.copy.assistantCardCopies.skills"
    case skillsLabel = "src.matrix.assistant-card.copy.assistantCardCopies.skillsLabel"
    case skillsLabelZero = "src.matrix.assistant-card.copy.assistantCardCopies.skillsLabel.count=0"
    case skillsLabelOne = "src.matrix.assistant-card.copy.assistantCardCopies.skillsLabel.count=1"
    case findSkills = "src.matrix.assistant-card.copy.assistantCardCopies.findSkills"
    case routines = "src.matrix.assistant-card.copy.assistantCardCopies.routines"
    /// Not in this pin yet: read behind `design.copy.contains` (`routineCount`).
    case routineCount = "src.matrix.assistant-card.copy.assistantCardCopies.routineCount"
    case addRoutine = "src.matrix.assistant-card.copy.assistantCardCopies.addRoutine"
    case routineEmpty = "src.matrix.assistant-card.copy.assistantCardCopies.routineEmpty"
    case routineLegacyPending = "src.matrix.assistant-card.copy.assistantCardCopies.routineLegacyPending"
    case routineTitle = "src.matrix.assistant-card.copy.assistantCardCopies.routineTitle"
    case routineInstruction = "src.matrix.assistant-card.copy.assistantCardCopies.routineInstruction"
    case routineSchedule = "src.matrix.assistant-card.copy.assistantCardCopies.routineSchedule"
    case routineOnce = "src.matrix.assistant-card.copy.assistantCardCopies.routineOnce"
    case routineDaily = "src.matrix.assistant-card.copy.assistantCardCopies.routineDaily"
    case routineWeekly = "src.matrix.assistant-card.copy.assistantCardCopies.routineWeekly"
    case routineMonthly = "src.matrix.assistant-card.copy.assistantCardCopies.routineMonthly"
    case routineDate = "src.matrix.assistant-card.copy.assistantCardCopies.routineDate"
    case routineTime = "src.matrix.assistant-card.copy.assistantCardCopies.routineTime"
    case routineWeekdays = "src.matrix.assistant-card.copy.assistantCardCopies.routineWeekdays"
    case routineMonthDay = "src.matrix.assistant-card.copy.assistantCardCopies.routineMonthDay"
    case routineTimezone = "src.matrix.assistant-card.copy.assistantCardCopies.routineTimezone"
    case routineNotifications = "src.matrix.assistant-card.copy.assistantCardCopies.routineNotifications"
    case routineEnabled = "src.matrix.assistant-card.copy.assistantCardCopies.routineEnabled"
    case routinePause = "src.matrix.assistant-card.copy.assistantCardCopies.routinePause"
    case routineResume = "src.matrix.assistant-card.copy.assistantCardCopies.routineResume"
    case routineRunNow = "src.matrix.assistant-card.copy.assistantCardCopies.routineRunNow"
    case routineHistory = "src.matrix.assistant-card.copy.assistantCardCopies.routineHistory"
    case routineNext = "src.matrix.assistant-card.copy.assistantCardCopies.routineNext"
    case routinePaused = "src.matrix.assistant-card.copy.assistantCardCopies.routinePaused"
    case routineDelete = "src.matrix.assistant-card.copy.assistantCardCopies.routineDelete"
    case routineDeleteBody = "src.matrix.assistant-card.copy.assistantCardCopies.routineDeleteBody"
    case routineConflict = "src.matrix.assistant-card.copy.assistantCardCopies.routineConflict"
    case routineRunsEmpty = "src.matrix.assistant-card.copy.assistantCardCopies.routineRunsEmpty"
    case routineCompleted = "src.matrix.assistant-card.copy.assistantCardCopies.routineCompleted"
    case routineStopped = "src.matrix.assistant-card.copy.assistantCardCopies.routineStopped"
    case routineSkipped = "src.matrix.assistant-card.copy.assistantCardCopies.routineSkipped"
    case routineFailed = "src.matrix.assistant-card.copy.assistantCardCopies.routineFailed"
    case routineWaiting = "src.matrix.assistant-card.copy.assistantCardCopies.routineWaiting"
    case problemsDuplicate = "src.matrix.assistant-card.copy.assistantCardCopies.problems.duplicate"
    case problemsTooLong = "src.matrix.assistant-card.copy.assistantCardCopies.problems.tooLong"
    case setupRow = "src.matrix.assistant-card.copy.assistantCardCopies.setupRow"
    case setupRowNotReady = "src.matrix.assistant-card.copy.assistantCardCopies.setupRowNotReady"
    case setupRowWorking = "src.matrix.assistant-card.copy.assistantCardCopies.setupRowWorking"
}

@MainActor
struct AssistantCardCopy {
    let design: LiveDesign

    func text(_ key: AssistantCardCopyKey,
              _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }

    /// A routine word the pin may not carry yet: the pin first, then
    /// desktop's own value in the app language (`AssistantRoutinePendingCopy`).
    func routine(_ key: AssistantRoutinePendingCopy.Key, name: String? = nil) -> String {
        if design.copy.contains(key.exportKey) {
            return design.text(key.exportKey, words: name.map { [$0] } ?? [])
        }
        return AssistantRoutinePendingCopy.text(key, locale: design.locale, name: name)
    }

    /// An AS-6 routine word: the pin first, then desktop's own value in the
    /// app language (`AssistantRoutinePolishCopy`).
    func polish(_ key: AssistantRoutinePolishCopy.Key, _ arguments: [String] = []) -> String {
        if design.copy.contains(key.exportKey) {
            return design.text(key.exportKey, words: arguments)
        }
        return AssistantRoutinePolishCopy.text(key, locale: design.locale, arguments: arguments)
    }

    /// Desktop `matrixRoutineScheduleWords`: "Every day at 8:00".
    func scheduleWords(_ routine: AgentRoutine) -> String {
        AssistantRoutineWords.schedule(Self.shape(routine.schedule), timezone: routine.timezone,
                                       locale: design.locale, resolve: { polish($0, $1) })
    }

    /// Desktop `matrixRoutineNextWords`, or nil for "Paused".
    func nextWords(_ routine: AgentRoutine, now: Date = Date()) -> String? {
        AssistantRoutineWords.next(
            at: routine.nextRunAt.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            enabled: routine.enabled, timezone: routine.timezone, deviceTimeZone: .current,
            now: now, locale: design.locale, resolve: { polish($0, $1) })
    }

    static func shape(_ schedule: AgentRoutineSchedule) -> AssistantRoutineScheduleShape {
        switch schedule {
        case let .once(runAt): .once(runAt)
        case let .daily(hour, minute): .daily(hour: hour, minute: minute)
        case let .weekly(hour, minute, weekdays): .weekly(hour: hour, minute: minute, weekdays: weekdays)
        case let .monthly(day, hour, minute): .monthly(day: day, hour: hour, minute: minute)
        case .unsupported: .other
        }
    }

    /// The value beside "Routines": "3 routines", "No routines", "Chưa có".
    func routineCount(_ count: Int) -> String {
        let key = AssistantCardCopyKey.routineCount.rawValue
        if design.copy.contains(key) { return design.text(key, arguments: [.number(Int64(max(0, count)))]) }
        return AssistantRoutinePendingCopy.count(count, locale: design.locale)
    }
}

enum AssistantRetireResult: Equatable { case retired, failed }

/// Retiring one non-primary assistant (AS-4): the platform's one call, then
/// the host takes its chat off the list.
struct AssistantRetireActions {
    let retire: @MainActor () async -> AssistantRetireResult
}

/// Desktop's delete and name-refusal words: the pin first, then desktop's
/// own `t.matrixShell` values in the app language (`AssistantShellPendingCopy`).
@MainActor
struct AssistantRetireCopy {
    let design: LiveDesign

    func text(_ key: AssistantShellPendingCopy.Key, name: String? = nil) -> String {
        if design.copy.contains(key.exportKey) {
            return design.text(key.exportKey, words: name.map { [$0] } ?? [])
        }
        return AssistantShellPendingCopy.text(key, locale: design.locale, name: name)
    }
}

/// The card's pet read: the name of the pet this assistant has, or nil for
/// "Choose" (none saved, hidden, not nameable, or the read failed).
struct AssistantPetActions {
    let read: () async -> String?
}

/// The few card words that live outside the assistant-card export group, plus
/// the one home place word (`cloudPlace`) the mobile pin does not carry yet.
/// It is derived from the existing cloud word, so no new translation is
/// invented; promoting the desktop key is a follow-up.
@MainActor
enum AssistantCardStandaloneCopy {
    static func botName(_ design: LiveDesign) -> String {
        design.text("shared.matrix-alias-copy.copy.botName")
    }

    static func botNone(_ design: LiveDesign) -> String {
        design.text("shared.matrix-alias-copy.copy.botNone")
    }

    static func model(_ design: LiveDesign) -> String {
        design.text("desktop.atum.settings.model")
    }
}
