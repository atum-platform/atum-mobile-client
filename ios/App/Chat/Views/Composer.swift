import AtumChat
import AtumDesign
import AtumNativeAPI
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The composer (revamp plan B6, B11, B20, B21, B25, B26, §3.4). One glass
// pill in the chat screen's `.safeAreaBar(edge: .bottom)`: the field, which
// grows from one to six lines and then scrolls inside, the ink send circle,
// the reply or edit chip inside the pill, and the quiet people typing line
// above it. Every chat has one controls row under the field: `+` at the
// leading edge, then (assistant chats) the provider-backed model chip, the
// dictation mic, and the send circle when there is something to send. While
// my assistant works on a turn (review C1) the composer knows it
// (`AssistantTurnStop`): VoiceOver reads the pill as working, and in a host
// that can reach the platform's stop route (`AssistantTurnStopActions`) the
// empty circle becomes Stop, then shows "Stop requested…" or "Task stopped".
// STYLE §11's working placeholder ("Add to your request…") waits for its
// exported key. There is no focus control.
//
// It talks to the chat only through the frozen `ConversationStore`
// protocol: `draft`, `send()`, `replyTarget` / `cancelReply()`,
// `editTarget` / `cancelEdit()`, `typingLine`, and `handle(_:)` for the two
// follow inputs it owns (`.composerGrew`, `.keyboardWillShow`).

/// The composer pill. The chat screen places it with
/// `.safeAreaBar(edge: .bottom) { ChatComposer(...) }` and gives it the
/// screen's `ChatHaptics`, whose `actions(of:)` the screen gives its rows and
/// `messageActionSheets`, so reaction toggles tick too.
struct ChatComposer: View {
    let store: LiveConversationStore
    let design: LiveDesign
    let haptics: ChatHaptics
    let modelActions: AssistantModelActions?
    let modelDestinations: AssistantModelDestinationActions?
    let modelRefreshToken: UInt64
    @Binding var modelPickerPresented: Bool
    /// Stop for my assistant's turn; nil where the stop route is not
    /// reachable, and then no Stop is drawn.
    let turnStopActions: AssistantTurnStopActions?

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatMediaPresenter) private var mediaPresenter
    @Environment(\.chatMediaAccess) private var mediaAccess
    @Environment(\.chatAttachmentsClosedReason) private var attachmentsClosedReason
    @Environment(\.chatReducesMotion) private var reduceMotion
    @Environment(\.appBotPresentation) private var appBot
    @Environment(\.appBotPresenter) private var appBotPresenter
    @State private var photoSelection = [PhotosPickerItem]()
    @State private var attachSheetPresented = false
    @State private var dictation: ComposerDictation
    @State private var turn = ComposerTurnModel()

    init(store: LiveConversationStore, design: LiveDesign, haptics: ChatHaptics,
         modelActions: AssistantModelActions?,
         modelDestinations: AssistantModelDestinationActions? = nil,
         modelRefreshToken: UInt64,
         modelPickerPresented: Binding<Bool>,
         turnStopActions: AssistantTurnStopActions? = nil) {
        self.store = store
        self.design = design
        self.haptics = haptics
        self.modelActions = modelActions
        self.modelDestinations = modelDestinations
        self.modelRefreshToken = modelRefreshToken
        self._modelPickerPresented = modelPickerPresented
        self.turnStopActions = turnStopActions
        self._dictation = State(initialValue: ComposerDictation(
            engine: SpeechDictationEngine(localeIdentifier: design.locale)
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refusal = store.mediaComposer.refusal {
                refusalLine(refusal)
            } else if let line = dictationRefusalLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(design.color("danger", scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .accessibilityIdentifier(AccessibilityID.composerDictationRefusal)
                    .transition(.opacity)
            } else if let line = turnLine {
                // An honest stop state: only what the platform answered.
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(design.color("soft", scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .accessibilityIdentifier(Self.turnLineID)
                    .transition(.opacity)
            } else {
                ComposerTypingLine(store: store, design: design)
            }
            ComposerMentionPicker(store: store, design: design)
            pill
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // B3: the composer growing (a new line, a chip, the typing line)
        // keeps the newest row visible while following. Handed over after
        // the layout pass: the store reads and writes its observed follow
        // state in `handle(_:)`, and doing that inside layout makes UIKit's
        // observation tracking lay the screen out again.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { old, new in
            if new > old + 0.5 { Task { @MainActor in store.handle(.composerGrew) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            store.handle(.keyboardWillShow)
        }
        // "Trả lời" and "Sửa" bring the keyboard up on the pill.
        .onChange(of: store.replyTarget) { _, target in
            if target != nil { focused = true }
        }
        // HC-4: a starter chip filled the draft.
        .onChange(of: store.composerFocusRequest) { _, _ in focused = true }
        .onChange(of: store.editTarget) { _, target in
            if target != nil {
                dictation.cancel()
                focused = true
            }
        }
        .onDisappear { dictation.cancel() }
        // The microphone is for the foreground only (Control Center, a call
        // banner and the app switcher all leave `.active`).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dictation.cancel() }
        }
        .onChange(of: dictation.refusal) { _, refusal in
            guard let refusal else { return }
            AccessibilityNotification.Announcement(ComposerDictationCopy.refusal(design, refusal)).post()
        }
        .background { SendFailureHaptic(store: store, haptics: haptics) }
        .background { TurnSignalWatch(store: store, turn: turn) }
        .chatHaptics(haptics)
        .photosPicker(
            isPresented: Binding(get: { mediaPresenter?.photoPickerPresented ?? false },
                                 set: { mediaPresenter?.photoPickerPresented = $0 }),
            selection: $photoSelection,
            maxSelectionCount: max(1, MediaAttachmentPolicy.maximumItems - store.mediaComposer.items.count),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .fileImporter(
            isPresented: Binding(get: { mediaPresenter?.fileImporterPresented ?? false },
                                 set: { mediaPresenter?.fileImporterPresented = $0 }),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .task { store.mediaComposer.setUploadLimit(await mediaAccess.uploadLimit()) }
        .onChange(of: store.mediaComposer.refusal) { _, refusal in
            guard let refusal else { return }
            AccessibilityNotification.Announcement(refusalText(refusal)).post()
        }
    }

    private var pill: some View {
        VStack(alignment: .leading, spacing: 4) {
            ComposerChipRow(store: store, design: design)
            AttachmentTray(state: store.mediaComposer, design: design)
            field
                .padding(.horizontal, 8)
            if showsBottomControls {
                HStack(alignment: .center, spacing: 8) {
                    if showsAddButton { addButton }
                    Spacer(minLength: 0)
                    if modelActions != nil || modelDestinations != nil {
                        ComposerModelChoiceButton(
                            design: design, actions: modelActions,
                            destinations: modelDestinations,
                            refreshToken: modelRefreshToken,
                            presented: $modelPickerPresented
                        )
                    }
                    if showsMicButton { micButton }
                    if showsSendButton {
                        sendButton
                    } else if showsStopButton {
                        stopButton
                    }
                }
                // The circle appearing never changes this controls row's
                // height; the text field grows independently above it.
                .frame(minHeight: Self.circle)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .modifier(LiveGlass(design: design, radius: pillRadius))
        // The glass pill itself, for U7 and U8 (where the newest row sits,
        // no height jump on focus); its controls stay their own elements. A
        // container's accessibility frame is otherwise the union of its
        // children (measured: 24 pt for the field alone), so the shape gives
        // it the pill's own outline.
        .contentShape(.accessibility, RoundedRectangle(cornerRadius: pillRadius))
        .accessibilityElement(children: .contain)
        .accessibilityValue(turn.stop.isWorking ? ChatCopy.text(design, ChatCopy.Key.turnRunning) : "")
        .accessibilityIdentifier(Self.pillID)
    }

    private var pillRadius: Double { design.palette.radii["composerExpanded"] ?? 28 }

    /// B25: plain multi-line text. Return inserts a newline (no
    /// `submitLabel`, no `onSubmit`); only the circle sends.
    private var field: some View {
        TextField(ChatCopy.text(design, ChatCopy.Key.composerPlaceholder, [.text(store.title)]),
                  text: Binding(get: { store.draft }, set: { store.draft = $0 }),
                  axis: .vertical)
            .lineLimit(1...ComposerRules.maximumLines)
            .font(.body)
            .focused($focused)
            .padding(.vertical, 7)
            .accessibilityIdentifier(AccessibilityID.composerField)
            // A vertical field keeps the height of the largest text size it
            // has shown: after Dynamic Type goes back down, the pill stayed
            // two lines tall (G-scroll check 6 screenshots, and the layout
            // moved under the accessibility audit). A new field per size;
            // the draft lives in the store, so nothing is lost.
            .id(dynamicTypeSize)
    }

    private var sendButton: some View {
        let editing = store.editTarget != nil
        return Button(action: send) {
            Image(design.symbol(editing ? "Check" : "ArrowUp"))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(design.color("onInk", scheme: scheme))
                .frame(width: Self.circle, height: Self.circle)
                .background(Circle().fill(design.color("ink", scheme: scheme)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel(ChatCopy.text(design, editing ? ChatCopy.Key.saveEdit : ChatCopy.Key.send))
        .accessibilityIdentifier(AccessibilityID.composerSend)
    }

    /// Review C1: the send circle's Stop state, the same ink circle with the
    /// stop glyph (desktop FlowChat-2). Disabled while a request is out.
    private var stopButton: some View {
        let stopping = turn.stop.phase == .stopping
        return Button(action: stopTurn) {
            Image(design.symbol("StopFilled"))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(design.color("onInk", scheme: scheme))
                .frame(width: Self.circle, height: Self.circle)
                .background(Circle().fill(design.color("ink", scheme: scheme)))
                // The visual stays a 36 pt circle and the row keeps its
                // height; the target is 44 pt each way (review C7): 44 wide
                // in the layout, and 4 pt above and below by its shape.
                .frame(width: Self.target, height: Self.circle)
                .contentShape(Rectangle().inset(by: -(Self.target - Self.circle) / 2))
        }
        .buttonStyle(.plain)
        .disabled(!turn.stop.offersStop)
        .opacity(stopping ? 0.4 : 1)
        .accessibilityLabel(ChatCopy.text(design, ChatCopy.Key.stopTurn))
        .accessibilityIdentifier(Self.stopID)
        .transition(.opacity)
    }

    /// Sends one stop for the turn shown. A second tap while it is out does
    /// nothing; after a failure the retry re-sends the same request ID, so
    /// the platform (idempotent on owner and request ID) never sees two.
    private func stopTurn() {
        guard let turnStopActions,
              let intent = turn.stop.beginStop(newRequestID: UUID().uuidString.lowercased()) else { return }
        haptics.stopped()
        Task { @MainActor in
            let result = await turnStopActions.stop(intent)
            turn.stop.resolve(result, for: intent)
            // Not stopped: Stop comes back and the warning says so; the
            // turn stays shown as in progress.
            if result == .failed { haptics.failed() }
        }
    }

    private var showsStopButton: Bool {
        guard turnStopActions != nil, store.editTarget == nil else { return false }
        switch turn.stop.phase {
        case .working, .failed, .stopping: return true
        case .idle, .stopped, .finishing: return false
        }
    }

    private var turnLine: String? {
        guard turnStopActions != nil else { return nil }
        switch turn.stop.phase {
        case .stopping: return ChatCopy.text(design, ChatCopy.Key.turnStopRequested)
        case .stopped: return ChatCopy.text(design, ChatCopy.Key.turnStopped)
        default: return nil
        }
    }

    /// B6: the store clears the draft in this same frame and queues the text;
    /// nothing is disabled and the field keeps focus, so the keyboard stays.
    private func send() {
        guard canSend else { return }
        // Words still being recognised must not land in the next draft.
        dictation.cancel()
        store.send()
        haptics.sent()
    }

    private var showsAddButton: Bool {
        ComposerRules.showsAddButton(kind: store.kind, isEditing: store.editTarget != nil,
                                     hasAppComposerAction: appBot?.composerAction != nil)
    }

    private var showsMicButton: Bool { ComposerRules.showsMicButton(isEditing: store.editTarget != nil) }

    private var dictationRefusalLine: String? {
        dictation.refusal.map { ComposerDictationCopy.refusal(design, $0) }
    }

    private var showsSendButton: Bool {
        ComposerRules.canSend(store.draft) || !store.mediaComposer.items.isEmpty
    }

    private var showsBottomControls: Bool {
        showsAddButton || showsMicButton || modelActions != nil
            || modelDestinations != nil || showsSendButton || showsStopButton
    }

    private var canSend: Bool {
        if store.editTarget != nil { return ComposerRules.canSend(store.draft) }
        return ComposerRules.canSend(store.draft) || store.mediaComposer.canSend
    }

    /// The + opens the attach sheet (FlowPhone3 › Attach): recent photos,
    /// then Photos and Files, and the app's own action in an app chat.
    private var addButton: some View {
        Button { attachSheetPresented = true } label: {
            Image(design.symbol("Plus"))
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(design.color("ink", scheme: scheme))
                .frame(width: Self.circle, height: Self.circle)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appBot?.composerAction?.label ?? ChatCopy.text(design, .addFiles))
        .accessibilityIdentifier(AccessibilityID.mediaAdd)
        .transition(.opacity)
        .sheet(isPresented: $attachSheetPresented) {
            AttachSheet(design: design,
                        appAction: appComposerAction,
                        closedReason: attachmentsClosedReason,
                        offersFiles: ComposerRules.addMenuOffersFiles(kind: store.kind),
                        isFull: store.mediaComposer.isFull,
                        photo: { item in Task { await importPhotos([item]) } },
                        openPhotos: { mediaPresenter?.photoPickerPresented = true },
                        openFiles: { mediaPresenter?.fileImporterPresented = true })
                .atumDesign(design)
        }
    }

    private var appComposerAction: (label: String, run: () -> Void)? {
        guard let appBot, let action = appBot.composerAction else { return nil }
        let presenter = appBotPresenter
        return (action.label, {
            if presenter?.openRoute(appBot, action.routeID) != true {
                presenter?.continueRequest = AppBotContinueRequest(app: appBot, kind: .route)
            }
        })
    }

    /// Dictation: tap to listen, tap again to stop. The recognised words are
    /// appended to the draft; nothing is sent.
    private var micButton: some View {
        let recording = dictation.isRecording
        return Button {
            dictation.clearRefusal()
            dictation.toggle(draft: { store.draft }, setDraft: { store.draft = $0 })
        } label: {
            Image(design.symbol("Mic"))
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(recording ? design.color("ground", scheme: scheme)
                                           : design.color("ink", scheme: scheme))
                .frame(width: Self.circle, height: Self.circle)
                .background(Circle().fill(recording ? design.color("ink", scheme: scheme) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .requesting || dictation.state == .finishing)
        .accessibilityLabel(ComposerDictationCopy.micLabel(design, recording: recording))
        .accessibilityValue(ComposerDictationCopy.micValue(design, recording: recording))
        .accessibilityAddTraits(recording ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.composerMic)
    }

    private func refusalLine(_ refusal: MediaAttachmentRefusal) -> some View {
        Text(refusalText(refusal))
            .font(.footnote)
            .foregroundStyle(design.color("danger", scheme: scheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 16)
            .accessibilityIdentifier(AccessibilityID.mediaRefusal)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: refusal)
    }

    private func refusalText(_ refusal: MediaAttachmentRefusal) -> String {
        if let number = refusal.numberArgument {
            return ChatCopy.text(design, refusal.copyKey, [.number(Int64(number))])
        }
        return ChatCopy.text(design, refusal.copyKey)
    }

    private func importPhotos(_ values: [PhotosPickerItem]) async {
        store.mediaComposer.beginSelection()
        let slots = max(0, MediaAttachmentPolicy.maximumItems - store.mediaComposer.items.count)
        if values.count > slots { store.mediaComposer.showTooMany() }
        for item in values.prefix(slots) {
            let name = item.itemIdentifier ?? "photo"
            guard let id = store.mediaComposer.reserve(.photo, name: name) else { break }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                await store.mediaComposer.finishPhoto(id: id, data: Data(), filename: name,
                                                      type: item.supportedContentTypes.first)
                continue
            }
            await store.mediaComposer.finishPhoto(id: id, data: data, filename: name,
                                                  type: item.supportedContentTypes.first)
        }
        photoSelection = []
        focused = true
    }

    private func importFiles(_ result: Result<[URL], any Error>) {
        guard case let .success(urls) = result else { return }
        store.mediaComposer.beginSelection()
        let slots = max(0, MediaAttachmentPolicy.maximumItems - store.mediaComposer.items.count)
        if urls.count > slots { store.mediaComposer.showTooMany() }
        for url in urls.prefix(slots) {
            guard let id = store.mediaComposer.reserve(.file, name: url.lastPathComponent) else { break }
            Task { await store.mediaComposer.finishFile(id: id, url: url) }
        }
        focused = true
    }

    /// §3.4: a 36 pt ink circle.
    private static let circle: CGFloat = 36
    /// The Kit's phone control height: the least a control may take to tap.
    private static let target: CGFloat = 44
    static let stopID = "composer.stop"
    static let turnLineID = "composer.turn"
    /// The pill's accessibility identifier (WS3's own, beside the frozen
    /// `composer.field` and `composer.send`).
    static let pillID = "composer.pill"
}

/// The always-visible assistant composer chip. Its name comes from the last
/// decoded server snapshot; before capability is known it says only “Model”
/// and opens the truthful loading/unavailable state instead of inventing a
/// saved choice.
private struct ComposerModelChoiceButton: View {
    let design: LiveDesign
    /// The 1.1 offer: eligibility and thinking levels. Nil when that read is
    /// not available; the 1.3/1.4 destination read still names the choice.
    let actions: AssistantModelActions?
    /// The 1.3/1.4 destination defaults: the authority for the cloud choice
    /// and the connected subscriptions. Either read alone keeps the chip.
    let destinations: AssistantModelDestinationActions?
    let refreshToken: UInt64
    @Binding var presented: Bool

    @State private var snapshot: ManagedModelSnapshot?
    @State private var destination: ManagedModelDestinationSnapshot?
    /// The row a successful pick wrote, so the chip names it at once.
    @State private var pickedModel: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        // FlowPhone: a plain capsule, the model's name in `.subheadline`
        // ink-2 and a caret-down; no globe, no chevron-right.
        Button { presented = true } label: {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.6 : 0.85)
                Image(atum.symbol(.chevronDown))
                    .font(.system(size: 11, weight: .regular))
            }
            .font(.subheadline)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(AccessibilityID.composerModel)
        .sheet(isPresented: $presented) {
            NavigationStack {
                PhoneConversationModelPicker(
                    design: design, actions: actions, destinations: destinations,
                    initialSnapshot: snapshot, initialDestination: destination,
                    onSnapshot: { snapshot = $0 },
                    onDestination: { destination = $0 },
                    onPick: { pickedModel = $0 }
                )
                // KitPhone › Sheet: a trailing close circle, not a text button.
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { presented = false } label: {
                            atum.barIcon(.close)
                        }
                        .accessibilityLabel(ChatCopy.text(design, .dismiss))
                        .accessibilityIdentifier("composer.model.close")
                    }
                }
            }
            // FlowPhone2 › Model sheet: a native half sheet (glass on iOS 26)
            // with a grabber; it can grow for the subscription list.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .atumDesign(visual: atum)
        }
        .task(id: refreshToken) { await read() }
    }

    private func read() async {
        if let actions, case let .value(value) = await actions.read() { snapshot = value }
        if let destinations, case let .value(value) = await destinations.read() { destination = value.snapshot }
    }

    private var label: String {
        if let pickedModel, let name = ManagedModelLineup.productName(for: pickedModel) {
            return name
        }
        if let pickedModel { return pickedModel }
        if let choice = destination?.choice(for: cloudDestination),
           let name = ManagedModelLineup.productName(for: choice.model) {
            return name
        }
        if let choice = destination?.choice(for: cloudDestination), choice.source != .atum {
            return choice.model
        }
        if let alias = snapshot?.choice.model,
           let name = ManagedModelLineup.productName(for: alias) {
            return name
        }
        if let model = destination?.recommended.model,
           let name = ManagedModelLineup.productName(for: model) {
            return name
        }
        return design.text("desktop.atum.settings.model")
    }

    private var cloudDestination: ManagedModelDestinationID {
        try! ManagedModelDestinationID("cloud")
    }
}

/// B11: "X đang soạn tin…" above the pill in every chat but my assistant's
/// (desktop `MatrixTypingLine`, app bots included). My assistant's chat shows
/// the working atom as the transcript's last row instead, and its
/// `typingLine` is always `.nobody`.
private struct ComposerTypingLine: View {
    let store: any ConversationStore
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let copy = ComposerRules.typingCopy(store.typingLine, locale: Locale(identifier: design.locale)) {
            // `soft`, the chat's colour for small secondary words: the
            // accessibility audit fails `muted` at footnote sizes.
            Text(text(copy))
                .font(.footnote)
                .foregroundStyle(design.color("soft", scheme: scheme))
                .lineLimit(1)
                .padding(.leading, 16)
                .accessibilityIdentifier("composer.typing")
        }
    }

    private func text(_ copy: TypingLineCopy) -> String {
        switch copy {
        case let .one(name): ChatCopy.text(design, ChatCopy.Key.typingOne, [.text(name)])
        case let .some(names): ChatCopy.text(design, ChatCopy.Key.typingSome, [.text(names)])
        case .many: ChatCopy.text(design, ChatCopy.Key.typingMany)
        }
    }
}

/// The reply chip (B21) or the edit chip (B20, people chats) inside the
/// pill, with a 2 pt rule like the quote it will become. It reads the rows
/// only while a target is set, so the composer does not follow the
/// transcript otherwise.
private struct ComposerChipRow: View {
    let store: any ConversationStore
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if store.editTarget != nil {
            let chip = ComposerRules.editChip(editTarget: store.editTarget, rows: store.snapshot.rows)
            row(title: ChatCopy.text(design, ChatCopy.Key.editing), preview: chip?.preview ?? .none,
                cancelLabel: ChatCopy.Key.cancelEdit, id: "composer.edit") { store.cancelEdit() }
        } else if store.replyTarget != nil {
            let chip = ComposerRules.replyChip(replyTarget: store.replyTarget, rows: store.snapshot.rows,
                                               kind: store.kind, roomTitle: store.title)
            row(title: title(chip?.who ?? .unnamed), preview: chip?.preview ?? .none,
                cancelLabel: ChatCopy.Key.cancelReply, id: "composer.reply") { store.cancelReply() }
        }
    }

    private func title(_ who: ComposerChip.Who) -> String {
        switch who {
        case .me: ChatCopy.text(design, ChatCopy.Key.replyingTo, [.text(ChatCopy.text(design, ChatCopy.Key.you))])
        case let .named(name): ChatCopy.text(design, ChatCopy.Key.replyingTo, [.text(name)])
        case .unnamed: ChatCopy.text(design, ChatCopy.Key.reply)
        }
    }

    private func row(title: String, preview: ComposerChip.Preview, cancelLabel: ChatCopy.Key, id: String,
                     cancel: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(design.color("ink", scheme: scheme))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                if let line = previewText(preview) {
                    Text(verbatim: line)
                        .font(.footnote)
                        .foregroundStyle(design.color("soft", scheme: scheme))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(design.symbol("X"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(design.color("muted", scheme: scheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ChatCopy.text(design, cancelLabel))
            .accessibilityIdentifier(id + ".cancel")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .padding(.trailing, 4)
    }

    private func previewText(_ preview: ComposerChip.Preview) -> String? {
        switch preview {
        case let .text(line): line
        case .photo: ChatCopy.text(design, ChatCopy.Key.photo)
        case let .file(name): name
        case .none: nil
        }
    }
}

// MARK: - Haptics (B26)

/// The chat screen's haptic triggers (B26): a light impact on send, one
/// warning on a failed send, a selection tick on a reaction toggle; nothing
/// for messages that arrive while I am in the chat. The context menu keeps
/// the system's own haptic. One per chat screen: the composer applies the
/// feedback; rows and the menu tick reactions through `actions(of:)`.
@MainActor
@Observable
final class ChatHaptics {
    private(set) var sends = 0
    private(set) var failures = 0
    private(set) var reactions = 0
    private(set) var stops = 0

    /// The store the cached actions wrap, held weakly and compared by
    /// identity: a freed store's address can be reused by a new one, so an
    /// `ObjectIdentifier` alone could hand the new store the old actions,
    /// whose weak captures are nil (reply, delete, retry and react would do
    /// nothing).
    @ObservationIgnored private weak var tickingStore: AnyObject?
    @ObservationIgnored private var tickingActions: ChatActions?

    func sent() { sends &+= 1 }
    func failed() { failures &+= 1 }
    func reactionToggled() { reactions &+= 1 }
    func stopped() { stops &+= 1 }

    /// The store's row actions with the reaction tick, built once per store
    /// so rows always get the same value (a fresh `ChatActions` on every
    /// screen render would look like a new environment value to every row).
    func actions(of store: any ConversationStore) -> ChatActions {
        if let tickingActions, let tickingStore, tickingStore === store { return tickingActions }
        let actions = store.actions.tickingReactions(self)
        tickingStore = store
        tickingActions = actions
        return actions
    }
}

extension View {
    /// B26's three feedbacks, driven by `haptics`.
    func chatHaptics(_ haptics: ChatHaptics) -> some View {
        sensoryFeedback(.impact(weight: .light), trigger: haptics.sends)
            .sensoryFeedback(.warning, trigger: haptics.failures)
            .sensoryFeedback(.selection, trigger: haptics.reactions)
            .sensoryFeedback(.impact(weight: .light), trigger: haptics.stops)
    }
}

extension ChatActions {
    /// The same actions, with a selection tick on every reaction toggle, from
    /// the menu's palette or a reaction chip (B22, B26).
    @MainActor
    func tickingReactions(_ haptics: ChatHaptics) -> ChatActions {
        var actions = self
        let toggle = toggleReaction
        actions.toggleReaction = { [weak haptics] itemID, key in
            haptics?.reactionToggled()
            toggle(itemID, key)
        }
        return actions
    }
}

/// What a host that can reach the platform's stop route does with one stop
/// request: `POST /api/matrix/v1/cloud/stop` (`CloudTurnStop`) for the room's
/// agent, mapped to `AssistantTurnStopResult`. Anything short of a confirmed
/// reply is `.failed`.
struct AssistantTurnStopActions {
    let stop: @MainActor (AssistantTurnStopIntent) async -> AssistantTurnStopResult
}

/// The composer's turn state, observed on its own so the pill re-renders
/// only when the phase changes, never on each snapshot.
@MainActor
@Observable
final class ComposerTurnModel {
    var stop = AssistantTurnStop()
}

/// Reads the transcript for my assistant's turn (`AssistantTurnSignal`),
/// invisibly, as `SendFailureHaptic` does.
private struct TurnSignalWatch: View {
    let store: any ConversationStore
    let turn: ComposerTurnModel

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: store.snapshot, initial: true) { _, snapshot in
                var next = turn.stop
                next.observe(AssistantTurnSignal.read(snapshot.rows, kind: store.kind))
                if next != turn.stop { turn.stop = next }
            }
    }
}

/// Watches the rows for a send of mine that fails while the chat is open
/// (`SendFailureWatch`), invisibly, so the pill itself never re-renders on
/// a new snapshot.
private struct SendFailureHaptic: View {
    let store: any ConversationStore
    let haptics: ChatHaptics
    @State private var watch = SendFailureWatch()

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: store.snapshot, initial: true) { _, snapshot in
                if watch.observe(snapshot) { haptics.failed() }
            }
    }
}


/// The `@` member picker: a short list above the pill while the end of the
/// draft is an `@word`. A pick replaces that word with the person's name and
/// the send carries `m.mentions.user_ids` for it (see `MentionRules`). The list
/// shows only names and handles, so it adds no copy.
struct ComposerMentionPicker: View {
    let store: LiveConversationStore
    let design: LiveDesign

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let suggestions = store.mentionSuggestions
        if !suggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(suggestions) { candidate in
                    Button { store.pickMention(candidate) } label: {
                        HStack(spacing: 10) {
                            Image(design.symbol("UserCircle"))
                                .font(.title3)
                                .foregroundStyle(design.color("muted", scheme: scheme))
                                .accessibilityHidden(true)
                            Text(verbatim: candidate.name)
                                .font(.body)
                                .foregroundStyle(design.color("ink", scheme: scheme))
                                .lineLimit(1)
                            if let handle = candidate.handle {
                                Text(verbatim: "@" + handle)
                                    .font(.footnote)
                                    .foregroundStyle(design.color("soft", scheme: scheme))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("composer.mention." + candidate.userID)
                }
            }
            .modifier(LiveGlass(design: design, radius: 20))
            .padding(.horizontal, 4)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer.mentions")
        }
    }
}
