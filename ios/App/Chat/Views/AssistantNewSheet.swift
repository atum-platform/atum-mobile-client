import AtumChat
import AtumDesign
import AtumNativeAPI
import PhotosUI
import SwiftUI

/// What the create sheet finishes once the new assistant's room exists: its
/// persona, its bot handle and its photo. Each is its own write, retried on
/// its own; none ever creates a second assistant.
struct AssistantCreateFollowUp {
    let definition: AssistantDefinitionActions?
    let avatar: AssistantAvatarActions?
    let handles: AssistantHandleActions?
}

/// The new-assistant sheet, mirrored from desktop `NewAssistantDialog`
/// (`apps/desktop/src/matrix/agent-roster.tsx:207-855`): a display name with
/// its helper, a bot handle that follows the name until changed and is
/// checked as typing pauses, an optional photo, "Who they are" and "What they
/// do". Create makes the assistant through the durable lifecycle (one request
/// UUID, never a twin), then the sheet gives it the persona, the handle and
/// the photo, in that order. A step that fails keeps the sheet with Retry for
/// that step only; Done opens the chat and leaves the rest to the card.
/// Import a prepared profile is desktop-only (it reads the Mac's disk).
struct AssistantNewSheet: View {
    let design: LiveDesign
    let actions: HomeAssistantActions
    let openRoom: (String) -> Void

    private enum Phase: Equatable {
        case form, creating, starting, unavailable, failed
        /// The assistant exists; its follow-ups run or wait for Retry.
        case finishing
    }

    private enum Step: Equatable { case persona, handle, photo }

    private struct Created: Equatable {
        let roomID: String
        let name: String
        let chosenStem: String?
        let soul: String?
        let photo: AgentAvatarImage?
    }

    @State private var name = ""
    @State private var typedHandle: String?
    @State private var who = ""
    @State private var job = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: AgentAvatarImage?
    @State private var photoPreview: UIImage?
    @State private var photoUnreadable = false
    @State private var phase: Phase = .form
    @State private var nameProblem: String?
    @State private var handleCheck: AssistantHandleCheckState?
    @State private var created: Created?
    @State private var follow: AssistantCreateFollowUp?
    @State private var done: Set<Step> = []
    @State private var running: Step?
    @State private var failedStep: Step?
    @State private var pendingClaim: AgentAliasClaimRequest?
    @State private var task: Task<Void, Never>?
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var handleCopy: AssistantHandleCopy { AssistantHandleCopy(design: design) }

    private var normalizedName: String { AssistantNameCheck.normalized(name) }
    private var locked: Bool { phase == .creating || phase == .finishing }
    private var derivedStem: String {
        AgentHandleRules.stem(ofHandle: AgentHandleRules.suggested(forName: name))
    }
    private var handleStem: String { typedHandle.map(AgentHandleRules.typedStem) ?? derivedStem }
    private var fullHandle: String { AgentHandleRules.handle(fromStem: handleStem) }
    private var localHandleProblem: AgentHandleRules.Problem? {
        fullHandle.isEmpty ? nil : AgentHandleRules.localProblem(fullHandle)
    }
    private var showsHandle: Bool { actions.checkHandle != nil }

    private var canCreate: Bool {
        guard !locked else { return false }
        return actions.pending || !normalizedName.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text(copy("src.matrix.roster-create-copy.copies.assistantIntro"))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                TextField(copy("desktop.atum.agents.namePlaceholder"), text: $name)
                    .focused($nameFocused)
                    .disabled(actions.pending || locked || phase == .starting)
                    .accessibilityLabel(copy(AssistantCardCopyKey.nameField.rawValue))
                    .accessibilityIdentifier("home.newAssistant.name")
                if let nameProblem {
                    Text(verbatim: nameProblem)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.newAssistant.name.problem")
                }
            } header: {
                Text(copy(AssistantCardCopyKey.nameField.rawValue))
            } footer: {
                Text(copy(AssistantCardCopyKey.nameHelper.rawValue))
            }
            if showsHandle {
                handleSection
            }
            photoSection
            Section {
                TextField(copy("desktop.atum.agents.personaPlaceholder"), text: $who, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(locked)
                    .accessibilityIdentifier("home.newAssistant.who")
            } header: {
                Text(copy("desktop.atum.agents.personaLabel"))
            }
            Section {
                TextField(copy("desktop.atum.agents.jobPlaceholder"), text: $job, axis: .vertical)
                    .lineLimit(3...8)
                    .disabled(locked)
                    .accessibilityIdentifier("home.newAssistant.job")
            } header: {
                Text(copy("desktop.atum.agents.jobLabel"))
            }
            Section {
                Text(copy("src.matrix.roster-create-copy.copies.assistantCloudDisclosure"))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.newAssistant.disclosure")
            }
            if let notice {
                Section {
                    Text(verbatim: notice.text)
                        .foregroundStyle(notice.quiet ? atum.color(.muted, scheme: scheme)
                                                      : atum.color(.danger, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.newAssistant.notice")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy("src.matrix.roster-create-copy.copies.newAssistant"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let created, running == nil {
                // Desktop: once the assistant exists, Cancel becomes Done and
                // closing is done with it; its card offers the rest later.
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy("desktop.common.done")) { openRoom(created.roomID) }
                        .accessibilityIdentifier("home.newAssistant.done")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { primaryButton }
        .onAppear {
            if actions.pending { phase = .starting } else { nameFocused = true }
        }
        .onChange(of: name) { _, _ in
            nameProblem = nil
            if phase == .unavailable || phase == .failed { phase = .form }
        }
        .onChange(of: photoItem) { _, item in
            if let item { loadPhoto(item) }
        }
        .task(id: showsHandle && !locked ? fullHandle : "") { await checkHandle() }
        .onDisappear { task?.cancel(); task = nil }
    }

    // MARK: Sections

    private var handleSection: some View {
        Section {
            AssistantHandleField(
                design: design,
                raw: Binding(get: { typedHandle ?? derivedStem },
                             set: { typedHandle = $0 }),
                placeholder: derivedStem.isEmpty ? handleCopy.text("botName") : derivedStem,
                disabled: locked,
                identifier: "home.newAssistant.handle"
            )
            if let status = handleStatus {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: status.text)
                        .font(.footnote)
                        .foregroundStyle(status.problem ? atum.color(.danger, scheme: scheme)
                                                        : atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.newAssistant.handle.status")
                    if let numbered = numberedSuggestion {
                        Button(handleCopy.text("botTry", [.text(numbered)])) {
                            typedHandle = AgentHandleRules.stem(ofHandle: numbered)
                        }
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("home.newAssistant.handle.try")
                    }
                }
            }
        } header: {
            Text(handleCopy.text("botName"))
        } footer: {
            Text(handleCopy.text("botNameHelp"))
        }
    }

    private var photoSection: some View {
        Section {
            HStack(spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Text(copy(photo == nil ? "src.matrix.roster-create-copy.copies.photoChoose"
                                               : "src.matrix.roster-create-copy.copies.photoChange"))
                    }
                    .disabled(locked)
                    .accessibilityIdentifier("home.newAssistant.photo")
                    if photo != nil {
                        Button(copy("src.matrix.roster-create-copy.copies.photoRemove"), role: .destructive) {
                            photo = nil
                            photoPreview = nil
                            photoItem = nil
                        }
                        .disabled(locked)
                        .accessibilityIdentifier("home.newAssistant.photo.remove")
                    }
                }
                .buttonStyle(.borderless)
            }
            if photoUnreadable {
                Text(copy(AssistantCardCopyKey.photoError.rawValue))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(copy("src.matrix.roster-create-copy.copies.photo"))
        }
    }

    @ViewBuilder private var preview: some View {
        // Its face beside the name it will go by: the initial follows the
        // typing until a photo is chosen. Assistants are circles (ruling 2).
        AtumAvatar(kind: .assistant, name: normalizedName,
                   art: photoPreview.map { AtumAvatarArt(image: Image(uiImage: $0)) }, size: 48)
            .accessibilityHidden(true)
    }

    private var primaryButton: some View {
        Button { primaryAction() } label: {
            HStack(spacing: 8) {
                if phase == .creating || running != nil {
                    ProgressView().tint(atum.color(.onInk, scheme: scheme))
                }
                Text(verbatim: primaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
        .disabled(primaryDisabled)
        .accessibilityIdentifier("home.newAssistant.create")
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(atum.color(.ground, scheme: scheme))
        .overlay(alignment: .top) {
            Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
        }
    }

    // MARK: Words

    private var primaryLabel: String {
        if phase == .creating { return copy("src.matrix.roster-create-copy.copies.assistantStarting") }
        if running == .photo { return copy("src.matrix.roster-create-copy.copies.photoSaving") }
        if running != nil { return copy("src.matrix.roster-create-copy.copies.assistantStarting") }
        switch failedStep {
        case .photo?: return copy("src.matrix.roster-create-copy.copies.photoRetry")
        case .handle?, .persona?: return copy("desktop.common.retry")
        case nil: break
        }
        return phase == .starting ? copy("desktop.common.retry")
            : copy("src.matrix.roster-create-copy.copies.createAssistant")
    }

    private var primaryDisabled: Bool {
        if created != nil { return running != nil || failedStep == nil }
        return !canCreate
    }

    private var notice: (text: String, quiet: Bool)? {
        if let created, let failedStep {
            switch failedStep {
            case .persona: return (copy(AssistantCardCopyKey.saveFailed.rawValue), false)
            case .handle:
                return (design.text("src.matrix.roster-create-copy.copies.handleFailed",
                                    arguments: [.text(created.name)]), false)
            case .photo:
                return (design.text("src.matrix.roster-create-copy.copies.photoFailed",
                                    arguments: [.text(created.name)]), false)
            }
        }
        switch phase {
        case .form, .creating, .finishing: return nil
        case .starting: return (copy("src.matrix.roster-create-copy.copies.assistantStarting"), true)
        case .unavailable: return (copy("src.matrix.roster-create-copy.copies.assistantUnavailable"), false)
        case .failed: return (copy("src.matrix.roster-create-copy.copies.assistantCreateFailed"), false)
        }
    }

    private var handleStatus: (text: String, problem: Bool)? {
        guard !fullHandle.isEmpty, !locked else { return nil }
        if let localHandleProblem { return (handleCopy.problem(localHandleProblem), true) }
        guard let handleCheck, handleCheck.handle == fullHandle else {
            return (handleCopy.text("checking"), false)
        }
        if handleCheck.failed { return nil }
        if let problem = handleCheck.problem { return (handleCopy.problem(problem), true) }
        return (handleCopy.text("available", [.text(fullHandle)]), false)
    }

    /// Offered only when the plain handle is taken: the same with a short number.
    private var numberedSuggestion: String? {
        guard !locked, handleCheck?.handle == fullHandle, handleCheck?.problem == .unavailable,
              !handleStem.isEmpty else { return nil }
        return AgentHandleRules.numbered(stem: handleStem)
    }

    private func copy(_ key: String) -> String { design.text(key) }

    // MARK: Work

    @MainActor private func checkHandle() async {
        guard showsHandle, !locked, !fullHandle.isEmpty, localHandleProblem == nil,
              let check = actions.checkHandle, let handle = try? NativeHandle(fullHandle) else { return }
        do { try await Task.sleep(for: AssistantHandleCheckState.pause) } catch { return }
        let answer = try? await check(handle)
        guard !Task.isCancelled, fullHandle == handle.rawValue else { return }
        handleCheck = AssistantHandleCheckState(
            handle: handle.rawValue,
            problem: answer.flatMap { AgentHandleRules.checkProblem($0.code?.rawValue) },
            failed: answer == nil
        )
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            photoUnreadable = false
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let prepared = try? AssistantAvatarPhoto.prepare(data) else {
                photoItem = nil
                photoUnreadable = true
                return
            }
            photo = prepared
            photoPreview = Data(base64Encoded: prepared.base64).flatMap(UIImage.init(data:))
        }
    }

    private func primaryAction() {
        if created != nil {
            guard running == nil, failedStep != nil else { return }
            failedStep = nil
            continueFollowUps()
        } else {
            create()
        }
    }

    private func create() {
        guard canCreate else { return }
        if !actions.pending,
           let problem = AssistantNameCheck.problem(name, others: actions.names) {
            nameProblem = problemText(problem, name: normalizedName)
            return
        }
        task?.cancel()
        phase = .creating
        nameProblem = nil
        let submitted = normalizedName
        // The handle, the persona and the photo as they were when Create was
        // pressed. An empty or unusable handle falls back to the name's own
        // candidates rather than stopping the creation.
        let stem = !fullHandle.isEmpty && localHandleProblem == nil && showsHandle ? handleStem : nil
        let soul = AssistantCreatePersona.soul(name: submitted, who: String(who.prefix(AssistantCreatePersona.answerMaximum)),
                                               job: String(job.prefix(AssistantCreatePersona.answerMaximum)))
        let chosenPhoto = photo
        task = Task { @MainActor in
            let result = await actions.create(submitted)
            guard !Task.isCancelled else { return }
            task = nil
            switch result {
            case let .openRoom(roomID):
                // A resumed setup (an earlier sheet's UUID) has no answers of
                // this sheet to apply: its chat simply opens.
                guard !submitted.isEmpty else { openRoom(roomID); return }
                created = Created(roomID: roomID, name: submitted,
                                  chosenStem: stem, soul: soul, photo: chosenPhoto)
                follow = actions.followUp?(roomID)
                phase = .finishing
                continueFollowUps()
            case .starting: phase = .starting
            case .unavailable: phase = .unavailable
            case let .name(reason):
                phase = .form
                nameProblem = refusalText(reason, name: submitted)
            case .failed: phase = .failed
            }
        }
    }

    private func continueFollowUps() {
        guard let created else { return }
        task = Task { @MainActor in
            defer { running = nil }
            if created.soul != nil, !done.contains(.persona), let definition = follow?.definition {
                running = .persona
                guard await writePersona(created, definition: definition) else {
                    failedStep = .persona
                    return
                }
            }
            done.insert(.persona)
            if !done.contains(.handle), let handles = follow?.handles {
                running = .handle
                let outcome = await AgentHandleClaimWalk.run(
                    assistantID: handles.assistantID,
                    groups: AgentHandleRules.candidates(name: created.name, chosenStem: created.chosenStem),
                    pending: pendingClaim,
                    calls: handles.directoryCalls,
                    requestID: { (try? NativeID(UUID().uuidString.lowercased()))! },
                    onAttempt: { pendingClaim = $0 }
                )
                if outcome.isRetryable {
                    // Only a lost answer is resent as it was; any other
                    // refusal starts the walk over on Retry.
                    if outcome != .refused(.unavailable) { pendingClaim = nil }
                    failedStep = .handle
                    return
                }
                pendingClaim = nil
            }
            done.insert(.handle)
            if let image = created.photo, !done.contains(.photo), let avatar = follow?.avatar {
                running = .photo
                guard await avatar.save(image) == .saved else {
                    failedStep = .photo
                    return
                }
            }
            done.insert(.photo)
            guard !Task.isCancelled else { return }
            openRoom(created.roomID)
        }
    }

    /// The two answers become the new assistant's instructions, written over
    /// the platform's default with the same revisions every card write uses.
    @MainActor private func writePersona(_ created: Created,
                                         definition: AssistantDefinitionActions) async -> Bool {
        guard let soul = created.soul else { return true }
        for _ in 0..<2 {
            guard case let .value(snapshot) = await definition.read(),
                  var value = snapshot.definition else { return false }
            if value.soul == soul { return true }
            value.soul = soul
            switch await definition.save(snapshot, value) {
            case .saved: return true
            case .conflict: continue
            case .failed: return false
            }
        }
        return false
    }

    private func problemText(_ problem: AssistantNameCheck.Problem, name: String) -> String {
        let base = "src.matrix.assistant-card.copy.assistantCardCopies.problems."
        switch problem {
        case .duplicate: return design.text(base + "duplicate", arguments: [.text(name)])
        case .empty: return copy(base + "empty")
        case .tooLong: return copy(base + "tooLong")
        case .reserved: return copy(base + "reserved")
        case .checkMark: return copy(base + "checkMark")
        }
    }

    /// The platform's reason, in the card's own lines (lane 3 D-1).
    private func refusalText(_ reason: AssistantNameRefusal, name: String) -> String {
        switch reason {
        case .reserved: return problemText(.reserved, name: name)
        case .taken: return problemText(.duplicate, name: name)
        case .invalid: return AssistantRetireCopy(design: design).text(.agentNameRefused)
        }
    }
}
