import AtumChat
import AtumNativeAPI
import Observation
import SwiftUI

/// Settings › Your devices › Approve on this iPhone (phone approvals slice 2b,
/// `phone-approvals-ux.md` §2.6, §2.9, §4.7). Enrolment, its state, and
/// removal. The page drives `PhoneApprovalLifecycle`; it never touches a key.
@MainActor @Observable
final class PhoneApprovalSettingsModel {
    enum Busy: Equatable { case settingUp, removing }

    let owner: String
    private(set) var status: PhoneApprovalStatus = .unavailable
    private(set) var authentication: PhoneApprovalAuthentication
    private(set) var busy: Busy?
    private(set) var failure: PhoneApprovalSetupFailure?
    /// The revocation could not be recorded, so nothing was removed.
    private(set) var removeFailed = false
    /// Bumped on every finished attempt, for announcements.
    private(set) var outcomeToken = 0

    @ObservationIgnored private let lifecycle: PhoneApprovalLifecycle
    @ObservationIgnored private let identity: @MainActor () async -> PhoneApprovalMatrixIdentity?
    @ObservationIgnored private let device: @MainActor () -> PhoneApprovalDeviceFacts

    init(owner: String, lifecycle: PhoneApprovalLifecycle,
         identity: @escaping @MainActor () async -> PhoneApprovalMatrixIdentity?,
         device: @escaping @MainActor () -> PhoneApprovalDeviceFacts) {
        self.owner = owner
        self.lifecycle = lifecycle
        self.identity = identity
        self.device = device
        authentication = device().authentication
        Task { @MainActor [weak self] in
            guard let self else { return }
            let local = await lifecycle.status(owner: owner)
            if self.busy == nil, self.status == .unavailable { self.status = local }
        }
    }

    /// Fail closed: hidden while the server has not advertised phone
    /// registration and this iPhone holds none.
    var showsRow: Bool { status != .unavailable }

    /// Re-reads the device, retries owed revocations and reconciles with the server.
    func refresh() async {
        authentication = device().authentication
        guard busy == nil else { return }
        let next = await lifecycle.refresh(owner: owner)
        if busy == nil { status = next }
    }

    func setUp(reason: String) async {
        guard busy == nil else { return }
        authentication = device().authentication
        busy = .settingUp
        failure = nil
        removeFailed = false
        defer { busy = nil; outcomeToken &+= 1 }
        guard let identity = await identity() else {
            failure = .generic
            return
        }
        do {
            status = try await lifecycle.setUp(owner: owner, identity: identity, device: device(), reason: reason)
        } catch {
            failure = error
            status = await lifecycle.status(owner: owner)
            if error == .unavailable { status = .unavailable }
        }
    }

    func remove() async {
        guard busy == nil else { return }
        busy = .removing
        failure = nil
        removeFailed = false
        defer { busy = nil; outcomeToken &+= 1 }
        do { status = try await lifecycle.remove(owner: owner) } catch { removeFailed = true }
    }

    /// Sign-out: false keeps credentials (the revocation could not be recorded).
    func signOut() async -> Bool {
        let allowed = await lifecycle.signOut(owner: owner)
        if allowed { status = .unavailable }
        return allowed
    }

    func retryRevocations() async { await lifecycle.retryRevocations(owner: owner) }
}

/// Export first, then the phone's five-locale PENDING-COPY.
@MainActor
enum PhoneApprovalCopy {
    static func text(_ key: PhoneApprovalPendingCopy.Key, design: LiveDesign, argument: String? = nil) -> String {
        if design.copy.contains(key.exportKey) {
            return design.text(key.exportKey, arguments: argument.map { [.text($0)] } ?? [])
        }
        return PhoneApprovalPendingCopy.text(key, locale: design.locale, argument: argument)
    }

    static func setUpLabel(_ authentication: PhoneApprovalAuthentication, design: LiveDesign) -> String {
        switch authentication {
        case .touchID: text(.setUpTouchID, design: design)
        case .passcodeOnly: text(.setUpPasscode, design: design)
        case .faceID, .noPasscode: text(.setUpFaceID, design: design)
        }
    }

    static func failure(_ failure: PhoneApprovalSetupFailure, design: LiveDesign) -> String {
        switch failure {
        case .cancelled: text(.enrollCancelled, design: design)
        case .noPrompt: text(.enrollNoPrompt, design: design)
        case .noPasscode: text(.noPasscode, design: design)
        case .offline: text(.enrollOffline, design: design)
        case .refused, .unavailable: text(.enrollRefused, design: design)
        case .generic: text(.enrollGeneric, design: design)
        }
    }

    /// "On · since 14 Nov 2026", or the exported "Not set up".
    static func value(_ status: PhoneApprovalStatus, design: LiveDesign) -> String {
        switch status {
        case let .on(since):
            let date = since.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(Locale(identifier: design.locale)))
            return text(.settingsOn, design: design, argument: date)
        case .off, .needsSetUpAgain, .unavailable:
            return design.text(SecurityCopyKey.recoveryOff)
        }
    }

    /// The short value on the Your devices row: "On" or "Not set up".
    static func rowValue(_ status: PhoneApprovalStatus, design: LiveDesign) -> String {
        if case .on = status { return design.text(SecurityCopyKey.recoveryOn) }
        return design.text(SecurityCopyKey.recoveryOff)
    }
}

/// The page itself.
struct PhoneApprovalSettingsPage: View {
    let design: LiveDesign
    let model: PhoneApprovalSettingsModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsRemoval = false

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        List {
            Section {
                statusRow
            } footer: {
                Text(footerText)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .textCase(nil)
                    .accessibilityIdentifier("approvals.settings.help")
            }
            if hasNotices {
                Section { notices }
            }
            if let action = action {
                Section { actionRow(action) }
                    .listRowBackground(action == .remove ? atum.kitColor(.surface, scheme: scheme) : Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(copy(.settingsTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .onChange(of: model.outcomeToken) { _, _ in announceOutcome() }
        .accessibilityIdentifier("approvals.settings.page")
    }

    // MARK: Rows

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(atum.symbol(.shield))
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text(copy(.settingsTitle))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(PhoneApprovalCopy.value(model.status, design: design))
                    .font(.body)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 52)
        .listRowBackground(atum.kitColor(.surface, scheme: scheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy(.settingsTitle) + ", " + PhoneApprovalCopy.value(model.status, design: design))
        .accessibilityIdentifier("approvals.settings.status")
    }

    private var footerText: String {
        var text = copy(.settingsHelp)
        if model.authentication == .passcodeOnly { text += " " + copy(.settingsPreferFaceID) }
        return text
    }

    private var showsNoPasscode: Bool {
        model.authentication == .noPasscode && !isOn
    }

    private var isOn: Bool {
        if case .on = model.status { return true }
        return false
    }

    private var hasNotices: Bool {
        showsNoPasscode || model.status == .needsSetUpAgain || model.failure != nil || model.removeFailed
    }

    @ViewBuilder private var notices: some View {
        if showsNoPasscode {
            notice(glyph: .alertCircle, title: copy(.noPasscode), help: copy(.noPasscodeHelp),
                   identifier: "approvals.settings.notice.no-passcode")
        }
        if model.status == .needsSetUpAgain {
            notice(glyph: .keyRound, title: copy(.keyMissing), help: copy(.keyMissingHelp),
                   identifier: "approvals.settings.notice.key-missing")
        }
        if let failure = model.failure, failure != .noPasscode {
            notice(glyph: .alertCircle, title: PhoneApprovalCopy.failure(failure, design: design), help: nil,
                   identifier: "approvals.settings.failure")
        }
        if model.removeFailed {
            notice(glyph: .alertCircle, title: design.text(SecurityCopyKey.error), help: nil,
                   identifier: "approvals.settings.remove-failed")
        }
    }

    private func notice(glyph: AtumGlyph, title: String, help: String?, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(atum.symbol(glyph))
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let help {
                    Text(help)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .listRowBackground(atum.kitColor(.surface, scheme: scheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, help].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier(identifier)
    }

    private enum Action: Equatable { case setUp, setUpAgain, remove }

    private var action: Action? {
        switch model.status {
        case .on: return .remove
        case .off: return model.authentication == .noPasscode ? nil : .setUp
        case .needsSetUpAgain: return model.authentication == .noPasscode ? nil : .setUpAgain
        case .unavailable: return nil
        }
    }

    @ViewBuilder private func actionRow(_ action: Action) -> some View {
        switch action {
        case .setUp, .setUpAgain:
            let label = action == .setUpAgain ? copy(.setUpAgain)
                : PhoneApprovalCopy.setUpLabel(model.authentication, design: design)
            Button {
                Task { await model.setUp(reason: copy(.enrollReason)) }
            } label: {
                HStack(spacing: 10) {
                    if model.busy == .settingUp {
                        AtomWait().frame(width: 20, height: 20).accessibilityHidden(true)
                        Text(copy(.settingsSettingUp))
                    } else {
                        Text(label)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .disabled(model.busy != nil)
            .accessibilityIdentifier("approvals.settings.setup")
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        case .remove:
            Button { confirmsRemoval = true } label: {
                HStack(spacing: 12) {
                    Image(atum.symbol(.trash))
                        .font(.body)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(copy(.settingsRemove))
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.busy == .removing {
                        AtomWait().frame(width: 20, height: 20)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy != nil)
            .accessibilityIdentifier("approvals.settings.remove")
            // Removing is the safe direction: no Face ID, one question.
            .confirmationDialog(Text(copy(.settingsRemoveTitle)), isPresented: $confirmsRemoval,
                                titleVisibility: .visible) {
                Button(copy(.settingsRemove), role: .destructive) { Task { await model.remove() } }
                    .accessibilityIdentifier("approvals.settings.confirm-remove")
                Button(design.text(SecurityCopyKey.cancel), role: .cancel) {}
            } message: {
                Text(copy(.settingsRemoveConfirm))
            }
        }
    }

    private func announceOutcome() {
        let words: String
        if let failure = model.failure {
            words = PhoneApprovalCopy.failure(failure, design: design)
        } else if model.removeFailed {
            words = design.text(SecurityCopyKey.error)
        } else {
            words = PhoneApprovalCopy.value(model.status, design: design)
        }
        AccessibilityNotification.Announcement(words).post()
    }

    private func copy(_ key: PhoneApprovalPendingCopy.Key) -> String {
        PhoneApprovalCopy.text(key, design: design)
    }
}

/// The row in Settings › Your devices, under This iPhone (UX §4.7).
struct PhoneApprovalSettingsRow: View {
    let design: LiveDesign
    let model: PhoneApprovalSettingsModel
    let open: () -> Void

    var body: some View {
        AtumSettingsRow(glyph: .shield,
                        title: PhoneApprovalCopy.text(.settingsTitle, design: design),
                        value: PhoneApprovalCopy.rowValue(model.status, design: design),
                        indicator: .push,
                        identifier: "approvals.settings.row",
                        action: open)
    }
}
