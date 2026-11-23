import AtumNativeAPI
import SwiftUI

/// The account's one-time "training is off" confirmation for using a ChatGPT
/// plan with Google data (desktop `chatgpt-training-confirm.tsx`). Both reads
/// go to the platform; the phone keeps no copy of the answer.
struct ChatGPTTrainingActions {
    /// nil when the read failed: a failed read never counts as confirmed.
    let read: () async -> ChatGPTTrainingStatus?
    let confirm: (_ connectionID: String) async -> ChatGPTTrainingConfirmResult
}

/// The words of the confirmation, from the pinned export
/// (`src/matrix/chatgpt-training-copy.ts`). The checkbox and transfer
/// sentences are the server's `chatgpt-google-v1` /
/// `chatgpt-google-transfer-v1` wording, which the platform hashes per
/// language: they are shown exactly as exported and never rewritten here.
enum ChatGPTTrainingCopyKey: String, CaseIterable {
    case title = "src.matrix.chatgpt-training-copy.COPY.title"
    case checkbox = "src.matrix.chatgpt-training-copy.COPY.checkbox"
    case helper = "src.matrix.chatgpt-training-copy.COPY.helper"
    case transfer = "src.matrix.chatgpt-training-copy.COPY.transfer"
    case confirm = "src.matrix.chatgpt-training-copy.COPY.confirm"
    case keep = "src.matrix.chatgpt-training-copy.COPY.keep"
    case saving = "src.matrix.chatgpt-training-copy.COPY.saving"
    case failed = "src.matrix.chatgpt-training-copy.COPY.failed"
    case stale = "src.matrix.chatgpt-training-copy.COPY.stale"
}

/// The ChatGPT pick's gate (desktop `chooseRoute`, `model-picker.tsx`): a
/// ChatGPT plan model is written only after the platform says the account's
/// confirmation is current. Until the person confirms, nothing is written and
/// the saved model stays as it is.
enum ChatGPTTrainingGate {
    enum Decision: Equatable {
        /// Not a ChatGPT pick (nil), or the confirmation is current: write it
        /// under the consent decision the platform reported.
        case write(ChatGPTTrainingConsent?)
        /// Ask once, in the picker, for this connection.
        case ask(ChatGPTTrainingStatus)
        /// The phone could not learn the answer: write nothing.
        case failed
    }

    /// The desktop asks only when the account's assistants touch Google, a
    /// fact it keeps on the Mac (Google services connected there, or the
    /// owner's Google fence ever seen). The phone cannot observe that latch,
    /// so it asks whenever the confirmation is not current. Over-asking once
    /// is safe; assuming consent is not.
    @MainActor
    static func decide(source: ManagedModelDestinationSource,
                       training: ChatGPTTrainingActions?) async -> Decision {
        guard source == .chatGPTPlan else { return .write(nil) }
        guard let training, let status = await training.read() else { return .failed }
        if let consent = status.consent { return .write(consent) }
        return .ask(status)
    }
}

/// A ChatGPT pick held on the confirmation card, with the status the card
/// read and the selection it belongs to: once the picker closes or another
/// pick starts, the card's confirmation never starts this pick's write.
struct PendingChatGPTTraining {
    let row: PhoneModelPickerProjection.Row
    let status: ChatGPTTrainingStatus
    let selection: ModelPickerLifetime.Token
}

/// The confirmation, inside the picker where ChatGPT was chosen: one unticked
/// box, its helper, the transfer line and two actions. Never a modal and never
/// a second picker. Confirm stays disabled until the person ticks the box;
/// Keep leaves the saved model as it is. Only the person's press sends the
/// confirmation, for the connection the card read.
struct ChatGPTTrainingConfirmView: View {
    let design: LiveDesign
    let actions: ChatGPTTrainingActions
    let onConfirmed: (ChatGPTTrainingStatus) -> Void
    let onKeep: () -> Void

    @State private var ticked = false
    @State private var saving = false
    @State private var notice: Notice?
    @State private var connectionID: String?
    @AccessibilityFocusState private var boxFocused: Bool
    @Environment(\.colorScheme) private var scheme

    enum Notice: String { case failed, stale }

    init(design: LiveDesign, actions: ChatGPTTrainingActions, status: ChatGPTTrainingStatus,
         onConfirmed: @escaping (ChatGPTTrainingStatus) -> Void, onKeep: @escaping () -> Void) {
        self.design = design
        self.actions = actions
        self.onConfirmed = onConfirmed
        self.onKeep = onKeep
        _connectionID = State(initialValue: status.connectionID)
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: text(.title))
                    .font(.body.weight(.medium))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("chatgpt.training.title")

                checkbox

                Text(verbatim: text(.helper))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chatgpt.training.helper")
                Text(verbatim: text(.transfer))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chatgpt.training.transfer")

                if let notice {
                    Text(verbatim: text(notice == .stale ? .stale : .failed))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chatgpt.training.notice." + notice.rawValue)
                }

                VStack(spacing: 4) {
                    Button {
                        Task { await confirm() }
                    } label: {
                        Text(verbatim: text(saving ? .saving : .confirm))
                    }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .disabled(!ticked || saving)
                    .accessibilityIdentifier("chatgpt.training.confirm")

                    Button {
                        onKeep()
                    } label: {
                        Text(verbatim: text(.keep))
                    }
                    .buttonStyle(AtumQuietButtonStyle(atum: atum, scheme: scheme))
                    .disabled(saving)
                    .accessibilityIdentifier("chatgpt.training.keep")
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(atum.color(.ground, scheme: scheme))
        .accessibilityIdentifier("chatgpt.training")
        .onAppear {
            // The card's one focus in this state is the box the person has to tick.
            boxFocused = true
        }
    }

    /// The box and its sentence are one control: tapping either ticks it.
    /// VoiceOver reads it as the system's own toggle, in the system's words.
    private var checkbox: some View {
        Button {
            ticked.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(atum.symbol(ticked ? .checkCircle : .circle))
                    .font(.title3)
                    .foregroundStyle(atum.color(ticked ? .ink : .soft, scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: text(.checkbox))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityRepresentation {
            Toggle(isOn: $ticked) { Text(verbatim: text(.checkbox)) }
                .disabled(saving)
        }
        .accessibilityFocused($boxFocused)
        .accessibilityIdentifier("chatgpt.training.checkbox")
        .onChange(of: ticked) {
            if notice == .failed { notice = nil }
        }
    }

    /// One press (`ChatGPTTrainingPress`): a card that lost its connection
    /// after a 409 reads the status again before it confirms anything.
    @MainActor private func confirm() async {
        guard ticked, !saving else { return }
        saving = true
        notice = nil
        defer { saving = false }
        switch await ChatGPTTrainingPress.confirm(connectionID: connectionID, read: actions.read,
                                                  confirm: actions.confirm) {
        case let .confirmed(status):
            onConfirmed(status)
        case let .askAgain(fresh):
            // A new relay connection: untick and let the person confirm for it.
            connectionID = fresh
            ticked = false
            notice = .stale
        case let .failed(kept):
            connectionID = kept
            notice = .failed
        }
    }

    private func text(_ key: ChatGPTTrainingCopyKey) -> String { design.text(key.rawValue) }
}
