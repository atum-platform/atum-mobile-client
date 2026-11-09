import AtumChat
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum RecoveryKeyDisplay {
    static func value(_ rawValue: String, sceneIsActive: Bool) -> String {
        let grouped = grouped(rawValue)
        guard !sceneIsActive else { return grouped }
        return grouped.map { $0 == " " ? " " : "•" }.reduce("") { $0 + String($1) }
    }

    static func grouped(_ value: String) -> String {
        let compact = value.filter { !$0.isWhitespace }
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.distance(from: start,
                                                                             to: compact.endIndex)))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }
}

struct RecoveryKeySheet: View {
    enum Mode { case show, saveBeforeSignOut }

    let design: LiveDesign
    let mode: Mode
    let load: @MainActor @Sendable () async -> RecoveryKeyLoadResult
    let primary: @MainActor @Sendable () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key: String?
    @State private var loadFailed = false
    @State private var copied = false
    @State private var busy = false
    @State private var detent: PresentationDetent = .medium

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(lead)
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    keyContent
                    copyButton
                    Button(action: runPrimary) {
                        Group {
                            if busy { AtomWait().frame(width: 20, height: 20) }
                            else { Text(primaryLabel) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .disabled(key == nil || busy)
                    .padding(.top, 8)
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel(copy("src.matrix.chat-copy.copies.dismiss"))
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
        .task { await loadKey() }
        .onAppear { if dynamicTypeSize.isAccessibilitySize { detent = .large } }
        .onChange(of: dynamicTypeSize) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
        .accessibilityIdentifier("account.recovery.key-sheet")
    }

    @ViewBuilder private var keyContent: some View {
        if let key {
            let displayed = RecoveryKeyDisplay.value(key, sceneIsActive: scenePhase == .active)
            Text(verbatim: displayed)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(atum.color(.bubble, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .privacySensitive()
                .textSelection(.disabled)
                .accessibilityLabel(copy("src.matrix.security-copy.copies.key"))
                .accessibilityValue(Text(verbatim: displayed).speechSpellsOutCharacters())
                .accessibilityHidden(scenePhase != .active)
                .accessibilityIdentifier("account.recovery.key")
        } else if loadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("src.matrix.chat-copy.copies.errorGeneric"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                Button(copy("src.matrix.chat-copy.copies.retry")) {
                    Task { await loadKey() }
                }
                .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme,
                                                     size: .regular))
            }
        } else {
            AtomWait()
                .frame(width: 28, height: 28)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var copyButton: some View {
        if let key {
            Button {
                UIPasteboard.general.setItems(
                    [[UTType.plainText.identifier: key]],
                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                copied = true
                AccessibilityNotification.Announcement(copy("src.matrix.chat-copy.copies.copied")).post()
                Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
                    copied = false
                }
            } label: {
                Label(copy(copied ? "src.matrix.chat-copy.copies.copied"
                           : "src.matrix.chat-copy.copies.copy"),
                      image: atum.symbol(copied ? .check : .copy))
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }
            .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme,
                                                 size: .regular))
            .accessibilityIdentifier("account.recovery.copy")
        }
    }

    private func loadKey() async {
        loadFailed = false
        key = nil
        switch await load() {
        case let .value(value) where !value.isEmpty: key = value
        default: loadFailed = true
        }
    }

    private func runPrimary() {
        guard key != nil, !busy else { return }
        busy = true
        Task {
            let succeeded = await primary()
            busy = false
            if succeeded { dismiss() }
        }
    }

    private var title: String {
        copy(mode == .show ? "src.matrix.security-copy.copies.recoveryTitle"
             : "src.matrix.mobile-copy.mobilePhoneCopy.recoveryTitle")
    }
    private var lead: String {
        copy(mode == .show ? "src.matrix.security-copy.copies.recoveryLead"
             : "src.matrix.mobile-copy.mobilePhoneCopy.saveRecoveryBeforeSignOut")
    }
    private var primaryLabel: String {
        copy(mode == .show ? "src.matrix.security-copy.copies.savedCheck"
             : "src.matrix.mobile-device-copy.mobileDeviceCopy.signOutActionsSignInLabel")
    }
    private func copy(_ key: String) -> String { design.text(key) }
}

struct RestoreMessagesSheet: View {
    let design: LiveDesign
    let restore: @MainActor @Sendable (String) async -> RecoveryRestoreResult
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var key = ""
    @State private var state = RestoreMessagesState.idle
    @State private var detent: PresentationDetent = .medium

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if state == .done { doneContent }
                else { form }
            }
            .navigationTitle(copy("src.matrix.chat-copy.copies.restoreMessages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel(copy("src.matrix.chat-copy.copies.dismiss"))
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(state.dismissIsDisabled)
        .onAppear { if dynamicTypeSize.isAccessibilitySize { detent = .large } }
        .onChange(of: dynamicTypeSize) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
        .accessibilityIdentifier("account.restore.sheet")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("shared.matrix-approval-copy.copies.noOtherDeviceHelp"))
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.restore.lead")
            SecureField(copy("src.matrix.security-copy.copies.key"), text: $key)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(runRestore)
                .disabled(state == .working)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(atum.color(.bubble, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(copy("src.matrix.security-copy.copies.key"))
                .accessibilityIdentifier("account.restore.field")
            if state == .rejected || state == .failed {
                Text(copy(state == .rejected
                    ? "shared.agent-conversation.copy.copies.restoreFailed"
                    : "src.matrix.chat-copy.copies.errorGeneric"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: runRestore) {
                Group {
                    if state == .working { AtomWait().frame(width: 20, height: 20) }
                    else { Text(copy("src.matrix.security-copy.copies.unlock")) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .working)
            .accessibilityLabel(state == .working
                ? copy("src.matrix.chat-copy.copies.decryption.reasons.restoring")
                : copy("src.matrix.security-copy.copies.unlock"))
            .accessibilityIdentifier("account.restore.submit")
            .padding(.top, 8)
        }
        .padding(16)
    }

    private var doneContent: some View {
        VStack(spacing: 12) {
            Image(atum.symbol(.checkCircle))
                .font(.system(size: 44))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Text(copy("src.matrix.mobile-copy.mobilePhoneCopy.restoreDone"))
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .multilineTextAlignment(.center)
            Button(copy("desktop.common.done")) {
                onDone()
                dismiss()
            }
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityIdentifier("account.restore.done")
    }

    private func runRestore() {
        guard state != .working else { return }
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        state = .working
        Task {
            switch await restore(candidate) {
            case .restored:
                state = .done
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AccessibilityNotification.Announcement(
                    copy("src.matrix.mobile-copy.mobilePhoneCopy.restoreDone")
                ).post()
            case .rejected:
                state = .rejected
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .failed:
                state = .failed
            }
        }
    }

    private func copy(_ key: String) -> String { design.text(key) }
}

