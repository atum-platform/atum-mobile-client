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
    @State private var copyCount = 0
    @State private var busy = false
    @State private var detent: PresentationDetent = .medium

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: kit.space(.s4)) {
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
                    .padding(.top, kit.space(.s2))
                }
                .padding(kit.space(.s4))
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
                .padding(kit.space(.s4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(atum.color(.bubble, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
                .privacySensitive()
                .textSelection(.disabled)
                .accessibilityLabel(copy("src.matrix.security-copy.copies.key"))
                .accessibilityValue(Text(verbatim: displayed).speechSpellsOutCharacters())
                .accessibilityHidden(scenePhase != .active)
                .accessibilityIdentifier("account.recovery.key")
        } else if loadFailed {
            VStack(alignment: .leading, spacing: kit.space(.s2)) {
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
                copied = true
                copyCount += 1
                let event = copyCount
                AccessibilityNotification.Announcement(copy("src.matrix.chat-copy.copies.copied")).post()
                Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
                    if copyCount == event { copied = false }
                }
            } label: {
                Label(copy(copied ? "src.matrix.chat-copy.copies.copied"
                           : "src.matrix.chat-copy.copies.copy"),
                      image: atum.symbol(copied ? .check : .copy))
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }
            .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme,
                                                 size: .regular))
            .sensoryFeedback(.success, trigger: copyCount)
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
    private var kit: AtumKit { design.kit }

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
        .sensoryFeedback(trigger: state) { _, state in
            switch state {
            case .done: .success
            case .rejected: .error
            default: nil
            }
        }
        .accessibilityIdentifier("account.restore.sheet")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: kit.space(.s4)) {
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
                .padding(.horizontal, kit.space(.s4))
                .frame(minHeight: 48)
                .background(atum.color(.bubble, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: kit.phoneRadius(.sm), style: .continuous))
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
            .padding(.top, kit.space(.s2))
        }
        .padding(kit.space(.s4))
    }

    private var doneContent: some View {
        VStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(.checkCircle))
                .font(.largeTitle).imageScale(.large)
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
            .padding(.top, kit.space(.s3))
        }
        .frame(maxWidth: .infinity)
        .padding(kit.space(.s6))
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
                AccessibilityNotification.Announcement(
                    copy("src.matrix.mobile-copy.mobilePhoneCopy.restoreDone")
                ).post()
            case .rejected:
                state = .rejected
            case .failed:
                state = .failed
            }
        }
    }

    private func copy(_ key: String) -> String { design.text(key) }
}


/// Settings › Encrypted messages › Private chats (chat parity S7–S9). The one
/// deliberate entry to trust: this iPhone's verification, its recovery key and
/// whether Private can be offered. Every outcome is a row value or one quiet
/// line here; nothing on sign-in, Home or a chat waits for it. The existing
/// restore sheet above is reused unchanged for "use my recovery key".
struct SecuritySheet: View {
    enum Route: Hashable {
        case verify
        case key(UUID)
    }

    let design: LiveDesign
    let actions: SecurityActions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = [Route]()
    @State private var snapshot: MatrixSecuritySnapshot?
    @State private var loaded = false
    @State private var outcome: PhoneTrustSetupOutcome?
    @State private var settingUp = false
    @State private var restorePresented = false
    @State private var toast: String?
    @State private var toastCount = 0

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }
    private var copy: SecurityCopy { SecurityCopy(design: design) }

    private var keyStatus: PhoneTrustKeyStatus? {
        snapshot.map {
            PhoneTrustKeyStatus(recoveryEnabled: $0.recoveryEnabled, backupEnabled: $0.backupEnabled,
                                recoveryKeyConfirmed: $0.recoveryKeyConfirmed, pendingSaveID: $0.pendingSaveID)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text(copy.text(.securityLead))
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    if let snapshot {
                        verificationRow(verified: snapshot.sessionVerified)
                        if let keyStatus { keyRow(keyStatus) }
                    } else if loaded {
                        Text(copy.exported("src.matrix.chat-copy.copies.errorGeneric"))
                            .foregroundStyle(atum.color(.danger, scheme: scheme))
                    } else {
                        AtomWait()
                            .frame(width: 24, height: 24)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                } footer: {
                    if let line = footerLine {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("security.sheet.line")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme))
            .navigationTitle(copy.text(.securityTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel(copy.exported("src.matrix.chat-copy.copies.dismiss"))
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .atumDesign(design)
        .overlay(alignment: .bottom) {
            if let toast {
                TrustToast(design: design, text: toast)
                    .padding(.bottom, kit.space(.s8))
                    .motionTransition(.opacity)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $restorePresented, onDismiss: { Task { await refresh() } }) {
            RestoreMessagesSheet(design: design, restore: actions.restore,
                                 onDone: { restorePresented = false })
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty { Task { await refresh() } }
        }
        .accessibilityIdentifier("security.sheet")
    }

    // MARK: Rows

    @ViewBuilder private func verificationRow(verified: Bool) -> some View {
        let value = copy.exported(verified ? "src.matrix.security-copy.copies.verified"
                                  : "src.matrix.security-copy.copies.notVerified")
        if verified {
            statusRow(glyph: .deviceMobile, title: copy.text(.thisIPhone), value: value,
                      identifier: "security.sheet.device")
        } else {
            AtumSettingsRow(glyph: .deviceMobile, title: copy.text(.thisIPhone), value: value,
                            indicator: .push, identifier: "security.sheet.device") {
                outcome = nil
                path.append(.verify)
            }
        }
    }

    @ViewBuilder private func keyRow(_ status: PhoneTrustKeyStatus) -> some View {
        let title = copy.exported("src.matrix.security-copy.copies.recoveryTitle")
        switch status {
        case .on:
            statusRow(glyph: .keyRound, title: title,
                      value: copy.exported("src.matrix.security-copy.copies.recoveryOn"),
                      identifier: "security.sheet.key")
        case let .notSaved(id):
            AtumSettingsRow(glyph: .keyRound, title: title, value: copy.text(.keyNotSaved),
                            indicator: .push, identifier: "security.sheet.key") {
                path.append(.key(id))
            }
        case .onElsewhere:
            AtumSettingsRow(glyph: .keyRound, title: title,
                            value: copy.exported("src.matrix.security-copy.copies.recoveryOn"),
                            indicator: .push, identifier: "security.sheet.key") {
                restorePresented = true
            }
        case .notSetUp:
            if settingUp {
                statusRow(glyph: .keyRound, title: title,
                          value: copy.exported("src.matrix.security-copy.copies.working"),
                          identifier: "security.sheet.key")
            } else {
                AtumSettingsRow(glyph: .keyRound, title: title,
                                value: copy.exported("src.matrix.security-copy.copies.recoveryOff"),
                                indicator: .push, identifier: "security.sheet.key") {
                    keyRowTapped()
                }
            }
        }
    }

    /// A row that only states something: no button, no caret.
    private func statusRow(glyph: AtumGlyph, title: String, value: String,
                           identifier: String) -> some View {
        HStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(glyph))
                .font(.title3.weight(.light))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Spacer(minLength: kit.space(.s2))
            Text(value)
                .font(.body)
                .foregroundStyle(atum.kitColor(.ink3, scheme: scheme))
        }
        .frame(minHeight: 52)
        .listRowBackground(atum.kitColor(.surface, scheme: scheme))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var footerLine: String? {
        if let outcome {
            switch outcome {
            case .verifyFirst: return copy.text(.verifyFirstBody)
            case .useExistingKey: return copy.text(.existingBody)
            case .setUpOnAnotherDevice: return PhoneFirstTrustUnavailable.line(copy)
            case .retry(.busy): return copy.text(.retryBusy)
            case .retry(.notReady): return copy.text(.retryNotReady)
            case .retry(.storage): return copy.text(.retryStorage)
            case .key, .closed: return nil
            }
        }
        return snapshot?.canCreatePrivateChat == true ? copy.text(.readyBody) : nil
    }

    // MARK: Actions

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .verify:
            if let driver = actions.verification() {
                DeviceVerificationView(
                    design: design, driver: driver, entry: .request,
                    useRecoveryKey: {
                        path.removeAll()
                        restorePresented = true
                    },
                    onConfirmed: { show(copy.text(.confirmedToast)) },
                    close: { path.removeAll() }
                )
            }
        case let .key(id):
            RecoveryKeySaveView(design: design, id: id, actions: actions, mode: .offer,
                                onSaved: { show(copy.text(.keySavedToast)) },
                                close: { path.removeAll() })
        }
    }

    private func keyRowTapped() {
        if outcome == .useExistingKey {
            restorePresented = true
        } else {
            runSetup()
        }
    }

    private func runSetup() {
        guard !settingUp else { return }
        settingUp = true
        outcome = nil
        Task {
            let result = await actions.setup()
            settingUp = false
            switch result {
            case let .success(id):
                await refresh()
                path.append(.key(id))
            case let .failure(failure):
                let next = PhoneTrustSetupOutcome(setupFailure: failure)
                if next == .closed { dismiss(); return }
                outcome = next
                await refresh()
            }
        }
    }

    private func refresh() async {
        let next = await actions.snapshot()
        snapshot = next
        loaded = true
        // A settled state retires a stale line (for example, verified after
        // the emoji flow, or recovery restored with the key).
        if let next, outcome == .verifyFirst, next.sessionVerified { outcome = nil }
        if let next, outcome == .useExistingKey, next.recoveryKeyConfirmed { outcome = nil }
    }

    private func show(_ text: String) {
        withMotion(.quick) { toast = text }
        toastCount += 1
        let event = toastCount
        AccessibilityNotification.Announcement(text).post()
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if toastCount == event { withMotion(.quick) { toast = nil } }
        }
    }
}

/// Phone-first trust (`.crossSigningBootstrapUnavailable`): the account has no
/// identity yet and this build has no safe phone-first setup. Automatic setup
/// was tested and kept off (28 Nov 2026). Security shows one honest line — set
/// up from another signed-in device, or later — with no button. Kept in one
/// place so a future decided route replaces it without other edits.
enum PhoneFirstTrustUnavailable {
    @MainActor static func line(_ copy: SecurityCopy) -> String {
        copy.text(.setUpElsewhereBody)
    }
}
