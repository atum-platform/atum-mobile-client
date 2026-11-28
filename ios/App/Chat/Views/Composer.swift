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
// empty circle becomes Stop, then the disabled "Stopping…" control until the
// agent confirms (desktop #46, #87; `docs/ports/w4-e5-stop-wording.md`).
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
    /// The field's prompt when the host names its own (a thread says "Reply",
    /// desktop `MatrixComposer` with `threadRootId`); nil keeps "Message {chat}".
    var placeholder: String? = nil

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatMediaPresenter) private var mediaPresenter
    @Environment(\.chatMediaAccess) private var mediaAccess
    @Environment(\.chatAttachmentsClosedReason) private var attachmentsClosedReason
    @Environment(\.appBotPresentation) private var appBot
    @Environment(\.appBotPresenter) private var appBotPresenter
    @State private var photoSelection = [PhotosPickerItem]()
    @State private var attachSheetPresented = false
    @State private var dictation: ComposerDictation
    /// §3.4's 36 pt circle, grown with Dynamic Type (polish P3, audit issue 9)
    /// up to `maxCircle`, so the glyphs inside it can follow the text.
    @ScaledMetric(relativeTo: .body) private var scaledCircle: CGFloat = 36

    init(store: LiveConversationStore, design: LiveDesign, haptics: ChatHaptics,
         modelActions: AssistantModelActions?,
         modelDestinations: AssistantModelDestinationActions? = nil,
         modelRefreshToken: UInt64,
         modelPickerPresented: Binding<Bool>,
         turnStopActions: AssistantTurnStopActions? = nil,
         placeholder: String? = nil) {
        self.store = store
        self.design = design
        self.haptics = haptics
        self.modelActions = modelActions
        self.modelDestinations = modelDestinations
        self.modelRefreshToken = modelRefreshToken
        self._modelPickerPresented = modelPickerPresented
        self.turnStopActions = turnStopActions
        self.placeholder = placeholder
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
                turnNotice(line)
            } else {
                ComposerTypingLine(store: store, design: design)
            }
            ComposerMentionPicker(store: store, design: design)
            pill
        }
        // Polish P3 (audit issue 2): the lines above the pill (a refusal, the
        // stop notice, the typing line, the @ picker) come and go with a quick
        // fade instead of popping.
        .chatMotion(.quick, value: lineState)
        .padding(.horizontal, design.kit.space(.s3))
        .padding(.top, 6)
        .padding(.bottom, design.kit.space(.s2))
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
                    if showsStopButton {
                        stopButton
                    } else if showsSendButton {
                        sendButton
                    }
                }
                // The circle appearing never changes this controls row's
                // height; the text field grows independently above it.
                .frame(minHeight: circle)
            }
        }
        .padding(.horizontal, design.kit.space(.s1))
        .padding(.vertical, design.kit.space(.s1))
        .modifier(LiveGlass(design: design, radius: pillRadius))
        // Polish P3 (audit issue 2): send, Stop, "Stopping…", the mic's
        // listening state, the reply and edit chips and the field shrinking
        // back to one line after a send all move with `Motion.quick` instead
        // of swapping between frames. Outside the glass (fix round 2), so the
        // glass shape resizes in the same animation as what it holds and
        // nothing draws past its edge while a chip or the tray goes.
        .chatMotion(.quick, value: pillState)
        // The glass pill itself, for U7 and U8 (where the newest row sits,
        // no height jump on focus); its controls stay their own elements. A
        // container's accessibility frame is otherwise the union of its
        // children (measured: 24 pt for the field alone), so the shape gives
        // it the pill's own outline.
        .contentShape(.accessibility, RoundedRectangle(cornerRadius: pillRadius))
        .accessibilityElement(children: .contain)
        .accessibilityValue(store.canPresentTurnStop && turnStop.isWorking
                            ? ChatCopy.text(design, ChatCopy.Key.turnRunning) : "")
        .accessibilityIdentifier(Self.pillID)
    }

    /// What the pill shows; a change animates (`Motion.quick`).
    private struct PillState: Equatable {
        var reply: String?
        var editing: Bool
        var send: Bool
        var stop: AssistantTurnStop.Control
        var recording: Bool
        var attachments: Int
    }

    private var pillState: PillState {
        PillState(reply: store.replyTarget, editing: store.editTarget != nil, send: showsSendButton,
                  stop: stopControl, recording: dictation.isRecording,
                  attachments: store.mediaComposer.items.count)
    }

    /// What the lines above the pill show; a change animates (`Motion.quick`).
    private struct LineState: Equatable {
        var refusal: MediaAttachmentRefusal?
        var dictation: String?
        var turn: String?
        var mentions: Bool
    }

    private var lineState: LineState {
        LineState(refusal: store.mediaComposer.refusal, dictation: dictationRefusalLine, turn: turnLine,
                  mentions: !store.mentionSuggestions.isEmpty)
    }

    /// §3.4's circle at this text size: 36 pt at the default size, at most
    /// `maxCircle`, so the controls row stays one row.
    private var circle: CGFloat { min(max(scaledCircle, Self.minCircle), Self.maxCircle) }
    /// Every control's tap target: never under 44 pt.
    private var target: CGFloat { max(Self.minTarget, circle) }

    /// The room's Stop state (`LiveConversationStore.turnStop`).
    private var turnStop: AssistantTurnStop { store.turnStop.stop }

    private var pillRadius: Double { design.palette.radii["composerExpanded"] ?? 28 }

    /// B25: plain multi-line text. Return inserts a newline (no
    /// `submitLabel`, no `onSubmit`); only the circle sends.
    private var field: some View {
        TextField(placeholder ?? ChatCopy.text(design, ChatCopy.Key.composerPlaceholder, [.text(store.title)]),
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
                // Polish P3 (audit issue 9): the glyph follows the text (callout
                // is the old 16 pt at the default size), capped with the circle.
                .font(.callout)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                // Send ↔ Save morphs as one glyph.
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(design.color("onInk", scheme: scheme))
                .frame(width: circle, height: circle)
                .background(Circle().fill(design.color("ink", scheme: scheme)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel(ChatCopy.text(design, editing ? ChatCopy.Key.saveEdit : ChatCopy.Key.send))
        .accessibilityIdentifier(AccessibilityID.composerSend)
        .chatMotionTransition(ChatMotion.controlSwap)
    }

    /// Review C1 and Wave 4 E5: the send circle's Stop state as the desktop
    /// composer draws it. Idle: the ink circle with the stop glyph, "Stop".
    /// While a request is out or `stop_requested` is unconfirmed: a disabled
    /// ink capsule reading "Stopping…" (desktop `ak-btn--primary`). Once
    /// answered for this turn: the glyph again, disabled. Desktop dims a
    /// disabled Stop to 30 %.
    @ViewBuilder private var stopButton: some View {
        switch stopControl {
        case .hidden:
            EmptyView()
        case let .stop(enabled):
            Button(action: stopTurn) {
                Image(design.symbol("StopFilled"))
                    .font(.subheadline)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(design.color("onInk", scheme: scheme))
                    .frame(width: circle, height: circle)
                    .background(Circle().fill(design.color("ink", scheme: scheme)))
                    // The visual stays the circle and the row keeps its
                    // height; the target is 44 pt each way (review C7): 44 wide
                    // in the layout, and 4 pt above and below by its shape.
                    .frame(width: target, height: circle)
                    .contentShape(Rectangle().inset(by: -(target - circle) / 2))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : Self.disabledStopOpacity)
            .accessibilityLabel(ChatCopy.text(design, ChatCopy.Key.stopTurn))
            .accessibilityIdentifier(Self.stopID)
            .chatMotionTransition(ChatMotion.controlSwap)
        case .stopping:
            let stopping = ChatCopy.text(design, ChatCopy.Key.turnStopping)
            Button(action: stopTurn) {
                Text(stopping)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(design.color("onInk", scheme: scheme))
                    .padding(.horizontal, 14)
                    .frame(minHeight: circle)
                    .background(Capsule().fill(design.color("ink", scheme: scheme)))
                    .fixedSize()
                    .contentShape(Rectangle().inset(by: -(target - circle) / 2))
            }
            .buttonStyle(.plain)
            // A bar control: uncapped, the label ran 305 pt wide off a 402 pt
            // screen at AX XXXL (run 5). It stops at xxxLarge like the other
            // composer controls, and a long press shows it full size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer { Text(stopping) }
            .layoutPriority(1)
            .disabled(true)
            .opacity(Self.disabledStopOpacity)
            // Desktop `aria-label` and its `role="status"` text: VoiceOver
            // reads the control as "Stopping…", dimmed, and hears it once
            // when it starts (`announceStopping`).
            .accessibilityLabel(stopping)
            .accessibilityIdentifier(Self.stopID)
            .chatMotionTransition(ChatMotion.controlSwap)
        }
    }

    /// Desktop `NoticeBand` in the composer dock: one quiet glass band, the
    /// info glyph, ink text (`[data-matrix-composer-dock] > .notice-band`).
    private func turnNotice(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The glyph takes the text style of the line beside it.
            Image(design.symbol("Info"))
                .font(.subheadline)
                .foregroundStyle(design.color("soft", scheme: scheme))
                .accessibilityHidden(true)
            Text(line)
                .font(.subheadline)
                .foregroundStyle(design.color("ink", scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        // At the largest sizes an uncapped band filled half the screen and
        // pushed the pill's controls under the keyboard; it stops growing at
        // the first accessibility size, still well above body.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .modifier(LiveGlass(design: design, radius: Double(design.kit.radius(.lg))))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
        .accessibilityIdentifier(Self.turnLineID)
        .transition(.opacity)
    }

    /// Sends one stop for the turn shown, through the room's controller
    /// (`store.turnStop`), which outlives this view. A second tap while it is
    /// out does nothing, even after search rebuilt the composer; after a
    /// failure the retry re-sends the same request ID, so the platform
    /// (idempotent on owner and request ID) never sees two.
    private func stopTurn() {
        guard showsStopButton, let turnStopActions else { return }
        let store = store
        let haptics = haptics
        let sent = store.turnStop.tap(newRequestID: UUID().uuidString.lowercased(),
                                      send: turnStopActions.stop) { [weak store] _, result, accepted in
            if accepted, result == .failed, store?.canPresentTurnStop == true { haptics.failed() }
        }
        if sent != nil { haptics.stopped() }
    }

    private var showsStopButton: Bool { stopControl != .hidden }

    private var stopControl: AssistantTurnStop.Control {
        guard store.canPresentTurnStop, let turnStopActions, store.editTarget == nil else { return .hidden }
        if let target = turnStop.selection, turnStopActions.unavailableTargets.contains(target) { return .hidden }
        return turnStop.control(canSend: canSend)
    }

    private var turnLine: String? {
        guard store.canPresentTurnStop, turnStopActions != nil else { return nil }
        switch turnStop.notice {
        case .refused: return ChatCopy.text(design, ChatCopy.Key.turnStopRefused)
        case .scheduledStopped: return ChatCopy.text(design, ChatCopy.Key.scheduledStopped)
        case nil: return nil
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
                // title2 is the old 22 pt at the default size.
                .font(.title2.weight(.light))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(design.color("ink", scheme: scheme))
                .frame(width: circle, height: circle)
                .contentShape(Rectangle().inset(by: -(target - circle) / 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appBot?.composerAction?.label ?? ChatCopy.text(design, .addFiles))
        .accessibilityIdentifier(AccessibilityID.mediaAdd)
        .chatMotionTransition(ChatMotion.controlSwap)
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
                // title3 (20 pt at the default size) stands in for the old 19.
                .font(.title3.weight(.light))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(recording ? design.color("ground", scheme: scheme)
                                           : design.color("ink", scheme: scheme))
                .frame(width: circle, height: circle)
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
            // A new refusal replacing the last one fades over (`Motion.quick`);
            // its arrival is the composer's `lineState`.
            .chatMotion(.quick, value: refusal)
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

    /// §3.4: a 36 pt ink circle at the default text size, never smaller.
    private static let minCircle: CGFloat = 36
    /// The circle stops growing here (the Kit's phone control height), so a
    /// large text size never makes the controls row two rows.
    private static let maxCircle: CGFloat = 44
    /// The Kit's phone control height: the least a control may take to tap.
    private static let minTarget: CGFloat = 44
    static let stopID = "composer.stop"
    /// Desktop `disabled:opacity-30` on the composer Stop.
    static let disabledStopOpacity = 0.3
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
    /// The row a successful pick wrote, so the chip names it at once with
    /// that row's own name and mark. A newer readback that saves something
    /// else drops it (`PhoneModelPickerProjection.reconciled`).
    @State private var picked: PhoneModelPickerProjection.ChipPick?
    /// The account's subscription status, last read here or by the picker:
    /// the catalog that names a subscription model as the list names it.
    @State private var accountState = PhoneModelPickerAccount()
    /// W4-Y2: the assistant's Work selection, read (never written) so the
    /// chip names the plan model that answers, as desktop #143 does.
    @State private var work: PhoneModelPickerWorkSelection?
    /// A Work pick the picker saved in this session, until a fresh read.
    @State private var workPick: WorkModelSelection?
    /// A cloud pick the picker saved in this session: the server cleared the
    /// Work choice with it, so the last Work read no longer names the model.
    @State private var cloudPicked = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        let warning = workFace == nil
            ? face?.planUnavailable.map { PhoneModelPickerCopy(design: design).planWarning($0) } : nil
        // The desktop's chip (model-picker-spec.json `trigger`, #119): a plain
        // capsule, the answering model's mark before its name, weight 500,
        // no chevron. The name is `.subheadline` ink-2.
        Button { presented = true } label: {
            HStack(spacing: 6) {
                if warning != nil {
                    ProviderMark(design: design, art: .template(asset: atum.symbol(.alertCircle),
                                                                color: atum.color(.danger, scheme: scheme)))
                } else if let workFace {
                    AccountPlanMark(design: design, plan: workFace.plan, size: 16)
                } else if let markArt {
                    ProviderMark(design: design, art: markArt, size: 16)
                }
                Text(verbatim: label)
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.6 : 0.85)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(warning.map { "\(label) · \($0)" } ?? label)
        .accessibilityIdentifier(AccessibilityID.composerModel)
        .sheet(isPresented: $presented) {
            NavigationStack {
                PhoneConversationModelPicker(
                    design: design, actions: actions, destinations: destinations,
                    initialSnapshot: snapshot, initialDestination: destination,
                    onSnapshot: { adopt(offer: $0) },
                    onDestination: { adopt(destination: $0) },
                    accountState: accountState,
                    onPick: { row in
                        // A cloud pick the owner made: it replaced any Work choice.
                        workPick = nil
                        cloudPicked = true
                        picked = row.map {
                            .init(row: $0, destinationRevision: destination?.revision,
                                  offerRevision: snapshot?.revision)
                        }
                    },
                    onWorkPick: { choice in
                        picked = nil
                        cloudPicked = false
                        workPick = choice
                    }
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
        if let actions, case let .value(value) = await actions.read() { adopt(offer: value) }
        if let destinations, case let .value(value) = await destinations.read() { adopt(destination: value) }
        // The Work selection answers ahead of the cloud choice (desktop #143).
        // A read only: the chip never writes a Work or cloud choice.
        if work?.value == nil { work = destinations?.makeWorkSelection?() }
        if !Task.isCancelled, !presented, let work {
            await work.reload()
            if work.value?.readState == .ready {
                workPick = nil
                cloudPicked = false
                // The server clears the Work choice on every cloud write, so a
                // fresh read naming one is newer than any cloud pick held here.
                if work.value?.snapshot?.selection != nil { picked = nil }
            }
        }
        // A saved subscription or Work model is named by the account's
        // catalog, as the list names it (desktop `relayCurrentName`). An Atum
        // choice needs no read.
        if !Task.isCancelled, !presented,
           destination?.choice(for: Self.cloud)?.source.isSubscription == true || answeringWork != nil,
           let readAccount = destinations?.subscriptions?.read {
            await accountState.reload(readAccount)
        }
    }

    /// The Work model that answers: a pick just saved, else (unless a cloud
    /// pick was made since) the last Work read.
    private var answeringWork: WorkModelSelection? {
        if let workPick { return workPick }
        if cloudPicked { return nil }
        return PhoneModelPickerProjection.answeringWork(work?.value)
    }

    private var workFace: PhoneModelPickerProjection.WorkFace? {
        PhoneModelPickerProjection.workFace(answeringWork, reported: accountState.value?.workPlanHandoffs ?? [],
                                            state: work?.value)
    }

    private func adopt(offer: ManagedModelSnapshot) {
        snapshot = offer
        picked = PhoneModelPickerProjection.reconciled(picked, destination: destination, offer: offer)
    }

    /// The destination is the authority for the cloud's saved choice: a newer
    /// one that saves something else ends the pick's hold on the chip.
    private func adopt(destination value: ManagedModelDestinationSnapshot) {
        destination = value
        picked = PhoneModelPickerProjection.reconciled(picked, destination: value, offer: snapshot)
    }

    private static var cloud: ManagedModelDestinationID { try! ManagedModelDestinationID("cloud") }

    /// The chip's name and mark facts (`PhoneModelPickerProjection.chip`):
    /// a pick still current, else the saved choice's, never a raw id.
    private var face: PhoneModelPickerProjection.ChipFace? {
        PhoneModelPickerProjection.chip(pick: picked, destination: destination,
                                        offer: snapshot, account: accountState.value)
    }

    private var label: String { workFace?.name ?? face?.name ?? design.text("desktop.atum.settings.model") }

    /// The same mark the picker row draws, its connection label included.
    /// Nil (no mark) only while nothing names the choice yet.
    private var markArt: ProviderMark.Art? {
        face.map { ProviderMark.art(source: $0.source, connectionLabel: $0.connectionLabel) }
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
    let unavailableTargets: Set<AssistantTurnStopIntent.Target>
    let stop: @MainActor (AssistantTurnStopIntent) async -> AssistantTurnStopResult

    init(unavailableTargets: Set<AssistantTurnStopIntent.Target> = [],
         stop: @escaping @MainActor (AssistantTurnStopIntent) async -> AssistantTurnStopResult) {
        self.unavailableTargets = unavailableTargets
        self.stop = stop
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
