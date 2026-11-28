import AtumChat
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// S8 · One screen to save a newly generated recovery key (mockup M4 `key`):
/// the key, Save to Passwords first, Copy second, then out of the way. It is an
/// offer, never a blocker: closing keeps the pending record, chats keep
/// working, and Security's recovery row resumes it later.
struct RecoveryKeySaveView: View {
    enum Mode {
        /// After explicit setup, or resumed from Security.
        case offer
        /// The existing unsaved-key warning before sign-out. Confirming signs
        /// out; closing cancels the sign-out.
        case beforeSignOut(signOut: @MainActor () async -> Bool)
    }

    let design: LiveDesign
    let id: UUID
    let actions: SecurityActions
    let mode: Mode
    let onSaved: () -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key: String?
    @State private var keyMissing = false
    @State private var copied = false
    @State private var copyCount = 0
    @State private var busy = false
    @State private var platformSaveFailed = false
    @State private var notice: PhoneTrustRetryReason?

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }
    private var copy: SecurityCopy { SecurityCopy(design: design) }

    private var keyActions: PhoneTrustKeyActions {
        PhoneTrustKeyActions(
            platformSaveAvailable: PhoneTrustKeyActions.platformSaveAvailable(
                systemSupportsSave: actions.saveToPasswords != nil,
                scopeConfirmed: actions.saveToPasswords != nil,
                failedThisSession: platformSaveFailed),
            copied: copied)
    }

    private var isBeforeSignOut: Bool {
        if case .beforeSignOut = mode { return true }
        return false
    }

    var body: some View {
        TrustScreen(design: design, glyph: .keyRound, title: title, message: message) {
            VStack(spacing: kit.space(.s3)) {
                keyBox
                if let notice {
                    Text(noticeText(notice))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("security.key.notice")
                }
            }
        } actions: {
            if key != nil {
                actionButton(keyActions.primary, primary: true)
                if let secondary = keyActions.secondary {
                    actionButton(secondary, primary: false)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { close() }
                    .accessibilityLabel(copy.exported("src.matrix.chat-copy.copies.dismiss"))
                    .accessibilityIdentifier("security.key.close")
            }
        }
        .interactiveDismissDisabled(busy)
        .sensoryFeedback(.success, trigger: copyCount)
        .onAppear { reveal() }
        .onDisappear { key = nil }
        .onChange(of: scenePhase) { _, phase in
            // The key leaves memory when the app leaves the screen; the
            // pending record keeps it in the device-only Keychain.
            if phase == .background { key = nil }
            if phase == .active, key == nil, !keyMissing { reveal() }
        }
        .accessibilityIdentifier("security.key")
    }

    @ViewBuilder private var keyBox: some View {
        if let key {
            let groups = RecoveryKeyDisplay.value(key, sceneIsActive: scenePhase == .active)
                .split(separator: " ").map(String.init)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: kit.space(.s2)), count: 4),
                      spacing: kit.space(.s2)) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(verbatim: group)
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                }
            }
            .padding(kit.space(.s4))
            .frame(maxWidth: .infinity)
            .background(atum.kitColor(.surface, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
            .privacySensitive()
            .textSelection(.disabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy.exported("src.matrix.security-copy.copies.key"))
            .accessibilityValue(Text(verbatim: groups.joined(separator: " ")).speechSpellsOutCharacters())
            .accessibilityHidden(scenePhase != .active)
            .accessibilityIdentifier("security.key.value")
        } else if keyMissing {
            Text(copy.exported("src.matrix.security-copy.copies.revealFailed"))
                .font(.footnote)
                .foregroundStyle(atum.color(.danger, scheme: scheme))
        } else {
            AtomWait()
                .frame(width: 28, height: 28)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: PhoneTrustKeyActions.Action, primary: Bool) -> some View {
        let label = actionLabel(action)
        if primary {
            Button { perform(action) } label: {
                Group {
                    if busy { AtomWait().frame(width: 20, height: 20) } else { Text(label) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .disabled(busy)
            .accessibilityLabel(label)
            .accessibilityIdentifier("security.key.\(identifier(action))")
        } else {
            Button { perform(action) } label: {
                Text(label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier("security.key.\(identifier(action))")
        }
    }

    private func actionLabel(_ action: PhoneTrustKeyActions.Action) -> String {
        switch action {
        case .saveToPasswords: copy.text(.saveToPasswords)
        case .copy: copy.exported("src.matrix.security-copy.copies.copyKey")
        case .confirmSaved:
            copy.exported(isBeforeSignOut ? "desktop.dm.signOut" : "src.matrix.security-copy.copies.savedCheck")
        }
    }

    private func identifier(_ action: PhoneTrustKeyActions.Action) -> String {
        switch action {
        case .saveToPasswords: "save"
        case .copy: "copy"
        case .confirmSaved: "confirm"
        }
    }

    private var title: String {
        isBeforeSignOut ? copy.exported("src.matrix.mobile-copy.mobilePhoneCopy.recoveryTitle")
            : copy.text(.keyTitle)
    }

    private var message: String {
        isBeforeSignOut ? copy.exported("src.matrix.mobile-copy.mobilePhoneCopy.saveRecoveryBeforeSignOut")
            : copy.text(.keyBody)
    }

    private func noticeText(_ reason: PhoneTrustRetryReason) -> String {
        switch reason {
        case .busy: copy.text(.retryBusy)
        case .notReady: copy.text(.retryNotReady)
        case .storage: copy.text(.retryStorage)
        }
    }

    private func reveal() {
        if let value = actions.revealKey(id), !value.isEmpty {
            key = value
            keyMissing = false
        } else {
            keyMissing = true
        }
    }

    private func perform(_ action: PhoneTrustKeyActions.Action) {
        guard !busy else { return }
        notice = nil
        switch action {
        case .copy:
            guard let key else { return }
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: key]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
            )
            copied = true
            copyCount += 1
            AccessibilityNotification.Announcement(
                copy.exported("src.matrix.security-copy.copies.copied")).post()
        case .saveToPasswords:
            guard let save = actions.saveToPasswords,
                  let anchor = UIApplication.shared.trustPresentationAnchor else {
                platformSaveFailed = true
                return
            }
            busy = true
            Task {
                let result = await save(id, anchor)
                busy = false
                switch result {
                case .success: await finish()
                case .failure(.saveCancelled): break
                case .failure(.platformSaveUnavailable): platformSaveFailed = true
                case let .failure(failure): handle(failure)
                }
            }
        case .confirmSaved:
            busy = true
            Task {
                let result = await actions.confirmSaved(id)
                busy = false
                switch result {
                case .success: await finish()
                case let .failure(failure): handle(failure)
                }
            }
        }
    }

    private func handle(_ failure: PhoneTrustFailure) {
        if case let .retry(reason) = PhoneTrustSetupOutcome(setupFailure: failure) {
            notice = reason
        } else {
            close()
        }
    }

    private func finish() async {
        key = nil
        switch mode {
        case .offer:
            onSaved()
            close()
        case let .beforeSignOut(signOut):
            busy = true
            let signedOut = await signOut()
            busy = false
            if signedOut { close() } else { notice = .notReady }
        }
    }
}
