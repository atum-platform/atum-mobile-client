import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// The public-handle directory calls for one assistant (AS-3, AS-5). Every
/// call names the assistant by its directory ID; the platform derives the
/// owner from the bearer.
struct AssistantHandleActions {
    let assistantID: NativeID
    let current: @MainActor () async throws -> AliasCurrentResponse
    let check: @MainActor (NativeHandle) async throws -> AgentAliasCheck
    let claim: @MainActor (AgentAliasClaimRequest) async throws -> AgentAliasAssignment
    let rename: @MainActor (AgentAliasRenameRequest) async throws -> AgentAliasAssignment

    var directoryCalls: AgentAliasDirectoryCalls {
        AgentAliasDirectoryCalls(current: { _ in try await current() },
                                 check: { handle, _ in try await check(handle) },
                                 claim: { try await claim($0) })
    }
}

/// The alias words, all from the pinned `shared.matrix-alias-copy` export.
@MainActor
struct AssistantHandleCopy {
    let design: LiveDesign

    func text(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text("shared.matrix-alias-copy.copy." + key, arguments: arguments)
    }

    func problem(_ problem: AgentHandleRules.Problem) -> String {
        text(problem.rawValue)
    }

    /// Desktop `failureText`: a rename's 429 names the day it may change
    /// again; every other refusal has its own line.
    func failure(_ refusal: AgentAliasRefusal, rename: Bool) -> String {
        switch refusal {
        case let .limit(seconds?) where rename && seconds > 0:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: design.locale)
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return text("tooSoon", [.text(formatter.string(from: Date().addingTimeInterval(TimeInterval(seconds))))])
        case .limit: return text("limit")
        case .invalid: return text("invalid")
        case .authentication: return text("authentication")
        case .denied: return text("denied")
        case .closed: return text("closed")
        case .missing: return text("missing")
        case .conflict: return text("conflict")
        case .unavailable: return text("failed")
        }
    }
}

/// The handle field both the create sheet and the card use: `@` before the
/// stem a person types and the fixed `_bot` after it, as desktop draws it.
struct AssistantHandleField: View {
    let design: LiveDesign
    @Binding var raw: String
    let placeholder: String
    let disabled: Bool
    let identifier: String
    var onCommit: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "@")
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
            TextField(placeholder, text: $raw)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .onSubmit(onCommit)
                .disabled(disabled)
                .accessibilityLabel(AssistantHandleCopy(design: design).text("botName"))
                .accessibilityIdentifier(identifier)
            Text(verbatim: AgentHandleRules.botSuffix)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        }
        .onChange(of: focused) { _, now in
            // Desktop folds the typing into its stem once the field is left.
            if !now, !raw.isEmpty { raw = AgentHandleRules.typedStem(raw) }
        }
    }
}

/// One check as typing pauses (desktop: 600 ms), only for a well-formed
/// handle. The answer is kept with the handle it was for, so a stale one is
/// never shown against newer typing.
struct AssistantHandleCheckState: Equatable {
    var handle: String
    var problem: AgentHandleRules.Problem?
    var failed: Bool

    static let pause: Duration = .milliseconds(600)
}

/// Desktop's assistant-card "Bot handle" section (`MatrixHandleEditor`,
/// `assistant-card.tsx:466-509`): the handle in use with Change, or "No bot
/// handle yet" with Choose; a field that checks as typing pauses; Save asks
/// to confirm, then claims a first handle or renames the one shown.
struct AssistantHandleEditor: View {
    let design: LiveDesign
    let assistantName: String
    let actions: AssistantHandleActions
    let disabled: Bool

    @State private var current: NativeHandle?
    @State private var loaded = false
    @State private var readFailed = false
    @State private var editing = false
    @State private var raw = ""
    @State private var checked: AssistantHandleCheckState?
    @State private var busy = false
    @State private var saved = false
    @State private var failure: String?
    @State private var confirming: Change?
    /// A change whose answer was lost: resent as it was, so the platform
    /// replays it instead of making a second change.
    @State private var unanswered: Change?
    @Environment(\.colorScheme) private var scheme

    private enum Change: Equatable {
        case claim(AgentAliasClaimRequest)
        case rename(AgentAliasRenameRequest)

        var handle: NativeHandle {
            switch self {
            case let .claim(request): request.handle
            case let .rename(request): request.handle
            }
        }
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: AssistantHandleCopy { AssistantHandleCopy(design: design) }

    private var stem: String { AgentHandleRules.typedStem(raw) }
    private var full: String { AgentHandleRules.handle(fromStem: stem) }
    private var localProblem: AgentHandleRules.Problem? {
        full.isEmpty ? nil : AgentHandleRules.localProblem(full)
    }
    private var unchanged: Bool { current?.rawValue == full }
    private var available: Bool {
        localProblem == nil && checked?.handle == full && checked?.problem == nil && checked?.failed == false
    }
    private var canSave: Bool {
        loaded && !busy && !disabled && editing && available && !unchanged && unanswered == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(copy.text("loading"))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
                .frame(minHeight: 52)
                .padding(.horizontal, 16)
            } else if editing {
                editor
            } else {
                summary
            }
            if let failure {
                failureRow(failure)
            }
            if unanswered != nil {
                pendingRow
            }
        }
        .task { await load() }
        .task(id: full) { await check() }
        .alert(confirmTitle, isPresented: confirmBinding, presenting: confirming) { change in
            Button(copy.text("cancel"), role: .cancel) { confirming = nil }
            Button(confirmLabel(change)) { send(change) }
                .accessibilityIdentifier("assistant.card.handle.confirm")
        } message: { change in
            Text(confirmText(change))
        }
    }

    // MARK: Rows

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { summaryLabel; Spacer(minLength: 8); summaryControls }
                VStack(alignment: .leading, spacing: 8) { summaryLabel; summaryControls }
            }
            if saved {
                Label(copy.text("saved"), image: atum.symbol(.checkCircle))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityIdentifier("assistant.card.handle.saved")
            }
            Text(copy.text("botNameHelp"))
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(copy.text("botName"))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Text(current == nil ? copy.text("botNone") : copy.text("botCurrent"))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        }
    }

    private var summaryControls: some View {
        HStack(spacing: 8) {
            if let current {
                Text(verbatim: "@" + current.rawValue)
                    .font(.footnote.monospaced())
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant.card.handle")
            }
            Button(current == nil ? copy.text("botChoose") : copy.text("change")) { startEditing() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(disabled || busy || readFailed)
                .accessibilityIdentifier("assistant.card.handle.edit")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.text("botName"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
            AssistantHandleField(design: design, raw: $raw,
                                 placeholder: AgentHandleRules.stem(
                                     ofHandle: AgentHandleRules.suggested(forName: assistantName)),
                                 disabled: busy, identifier: "assistant.card.handle.field",
                                 onCommit: ask)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(atum.color(.ground, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            statusLine
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(copy.text("cancel")) { stopEditing() }
                    .disabled(busy)
                    .accessibilityIdentifier("assistant.card.handle.cancel")
                Button(copy.text("save")) { ask() }
                    .buttonStyle(.borderedProminent)
                    .tint(atum.color(.ink, scheme: scheme))
                    .foregroundStyle(atum.color(.onInk, scheme: scheme))
                    .disabled(!canSave)
                    .accessibilityIdentifier("assistant.card.handle.save")
            }
        }
        .padding(16)
    }

    @ViewBuilder private var statusLine: some View {
        if let status {
            Text(status)
                .font(.footnote)
                .foregroundStyle(statusIsProblem
                    ? atum.color(.danger, scheme: scheme) : atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.card.handle.status")
        } else if current != nil {
            Text(copy.text("rule"))
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String? {
        guard !full.isEmpty else { return nil }
        if unchanged { return copy.text("current") }
        if let localProblem { return copy.problem(localProblem) }
        guard let checked, checked.handle == full else { return copy.text("checking") }
        if checked.failed { return nil }
        if let problem = checked.problem { return copy.problem(problem) }
        return copy.text("available", [.text(full)])
    }

    private var statusIsProblem: Bool {
        guard !unchanged else { return false }
        return localProblem != nil || (checked?.handle == full && checked?.problem != nil)
    }

    private func failureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(atum.color(.danger, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(copy.text("refresh")) { Task { await load(force: true) } }
                .font(.footnote.weight(.semibold))
                .disabled(busy)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("assistant.card.handle.failure")
    }

    private var pendingRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("pending"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                if let unanswered {
                    Text(verbatim: copy.text("target") + ": " + assistantName + " · @" + unanswered.handle.rawValue)
                        .font(.caption)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(copy.text("retry")) { if let unanswered { send(unanswered) } }
                .font(.footnote.weight(.semibold))
                .disabled(busy)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("assistant.card.handle.pending")
    }

    // MARK: Confirm

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmTitle: String {
        if case .rename? = confirming { return copy.text("renameTitle") }
        return copy.text("claimTitle")
    }

    private func confirmLabel(_ change: Change) -> String {
        if case .rename = change { return copy.text("renameConfirm") }
        return copy.text("claimConfirm")
    }

    private func confirmText(_ change: Change) -> String {
        switch change {
        case let .claim(request):
            return copy.text("claimTextAgent", [.text(request.handle.rawValue), .text(assistantName)])
        case let .rename(request):
            return copy.text("renameTextAgent", [.text(request.from.rawValue), .text(request.handle.rawValue),
                                                 .text(assistantName)])
        }
    }

    // MARK: Work

    private func startEditing() {
        raw = current.map { AgentHandleRules.stem(ofHandle: $0.rawValue) }
            ?? AgentHandleRules.stem(ofHandle: AgentHandleRules.suggested(forName: assistantName))
        checked = nil
        failure = nil
        saved = false
        editing = true
    }

    private func stopEditing() {
        editing = false
        raw = ""
        checked = nil
    }

    @MainActor private func load(force: Bool = false) async {
        guard !loaded || force else { return }
        do {
            switch try await actions.current() {
            case .none: current = nil
            case let .assigned(handle, _): current = handle
            }
            readFailed = false
            failure = nil
        } catch {
            readFailed = true
            failure = copy.failure(AgentAliasRefusal.from(error), rename: false)
        }
        loaded = true
    }

    @MainActor private func check() async {
        guard editing, !full.isEmpty, localProblem == nil, !unchanged,
              let handle = try? NativeHandle(full) else { return }
        do { try await Task.sleep(for: AssistantHandleCheckState.pause) } catch { return }
        do {
            let answer = try await actions.check(handle)
            guard !Task.isCancelled, full == handle.rawValue else { return }
            checked = AssistantHandleCheckState(handle: handle.rawValue,
                                                problem: AgentHandleRules.checkProblem(answer.code?.rawValue),
                                                failed: false)
        } catch {
            guard !Task.isCancelled, full == handle.rawValue else { return }
            checked = AssistantHandleCheckState(handle: handle.rawValue, problem: nil, failed: true)
            failure = copy.failure(AgentAliasRefusal.from(error), rename: false)
        }
    }

    private func ask() {
        guard canSave, let handle = try? NativeHandle(full),
              let requestID = try? NativeID(UUID().uuidString.lowercased()) else { return }
        if let current {
            guard let request = try? AgentAliasRenameRequest(handle: handle, from: current,
                                                             requestId: requestID,
                                                             assistantId: actions.assistantID) else { return }
            confirming = .rename(request)
        } else {
            confirming = .claim(AgentAliasClaimRequest(handle: handle, requestId: requestID,
                                                       assistantId: actions.assistantID))
        }
    }

    private func send(_ change: Change) {
        confirming = nil
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let assignment: AgentAliasAssignment
                switch change {
                case let .claim(request): assignment = try await actions.claim(request)
                case let .rename(request): assignment = try await actions.rename(request)
                }
                unanswered = nil
                current = assignment.handle
                saved = true
                stopEditing()
            } catch {
                let refusal = AgentAliasRefusal.from(error)
                // A lost answer keeps the change, to resend exactly as it was;
                // a refusal is the platform's answer and clears it.
                if refusal == .unavailable { unanswered = change } else { unanswered = nil }
                if case .rename = change {
                    failure = copy.failure(refusal, rename: true)
                } else {
                    failure = copy.failure(refusal, rename: false)
                }
                if refusal == .conflict { checked = nil }
            }
        }
    }
}
