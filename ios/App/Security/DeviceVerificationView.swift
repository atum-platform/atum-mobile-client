import AtumChat
import SwiftUI

/// S7 · Confirm this iPhone by emoji against another of the account's own
/// devices (mockup M4: confirm, emoji, mismatch, done). Optional and reached
/// deliberately: from Security, or from the quiet incoming banner. The native
/// engine owns every transition; this view only renders its state and passes
/// the attempt ID back with each action, so a stale tap has no authority.
struct DeviceVerificationView: View {
    enum Entry: Equatable {
        /// The person chose Compare emoji: request immediately.
        case request
        /// The person tapped the incoming banner: accept that invitation.
        case accept(UUID)
        /// Show whatever the engine is doing.
        case observe
    }

    let design: LiveDesign
    let driver: any DeviceVerificationDriver
    var entry: Entry = .observe
    /// Nil hides "Use recovery key instead".
    var useRecoveryKey: (() -> Void)? = nil
    let onConfirmed: () -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false
    /// Set once this presentation has seen a live attempt. A finished result
    /// left over from an earlier attempt neither closes nor confirms it.
    @State private var sawLiveAttempt = false
    @State private var settled = false
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }
    private var copy: SecurityCopy { SecurityCopy(design: design) }

    private var state: MatrixSASVerification.State { driver.state }
    private var screen: PhoneTrustSASScreen {
        let native = PhoneTrustSASScreen(stage: state.stage)
        guard !sawLiveAttempt, state.attemptID == nil else { return native }
        // Before this presentation's own attempt: never an earlier outcome.
        return entry == .observe ? .start : .waiting
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen.allowsCancel, let id = state.attemptID {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(copy.exported("src.matrix.security-copy.copies.cancel")) {
                            Task { await driver.cancel(id) }
                        }
                        .accessibilityIdentifier("security.verify.cancel")
                    }
                }
            }
            .motion(.quick, value: screen)
            .sensoryFeedback(trigger: screen) { _, screen in
                switch screen {
                case .confirmed: .success
                case .ended(.mismatch): .error
                default: nil
                }
            }
            .task { await begin() }
            .onChange(of: state.attemptID, initial: true) { _, id in
                if id != nil { sawLiveAttempt = true }
            }
            .onChange(of: screen) { _, screen in settle(screen) }
            .accessibilityIdentifier("security.verify")
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .start:
            TrustScreen(design: design, glyph: .deviceMobile,
                        title: copy.text(.confirmTitle), message: copy.text(.confirmStartBody)) {
                EmptyView()
            } actions: {
                primary(copy.exported("src.matrix.security-copy.copies.start"), id: "security.verify.start") {
                    Task { await run { await driver.request() } }
                }
                recoveryKeyAction
            }
        case .waiting, .dismissed, .confirmed:
            TrustScreen(design: design, glyph: .deviceMobile,
                        title: copy.text(.confirmTitle), message: copy.text(.confirmWaitingBody)) {
                AtomWait()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityHidden(true)
            } actions: {
                recoveryKeyAction
            }
        case let .incoming(deviceName):
            TrustScreen(design: design, glyph: .deviceMobile, title: copy.text(.incomingTitle),
                        message: deviceName.map { copy.text(.incomingBody, $0) }
                            ?? copy.text(.incomingBodyUnnamed)) {
                EmptyView()
            } actions: {
                if let id = state.attemptID {
                    primary(copy.exported("src.matrix.security-copy.copies.emoji"), id: "security.verify.accept") {
                        Task { await run { await driver.accept(id) } }
                    }
                    quiet(copy.exported(AtumCopyKey.notNow.rawValue), id: "security.verify.decline") {
                        Task { await driver.cancel(id) }
                    }
                }
            }
        case .compare, .confirming:
            TrustScreen(design: design, glyph: nil, title: copy.text(.compareTitle),
                        message: screen == .compare ? copy.text(.compareBody)
                            : copy.exported("src.matrix.security-copy.copies.waiting")) {
                emojiGrid
                    .opacity(screen == .confirming ? 0.5 : 1)
                if screen == .confirming {
                    AtomWait()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .padding(.top, kit.space(.s4))
                        .accessibilityHidden(true)
                }
            } actions: {
                if screen == .compare, let id = state.attemptID {
                    primary(copy.exported("src.matrix.security-copy.copies.confirm"), id: "security.verify.match") {
                        Task { await driver.compare(id, matches: true) }
                    }
                    quiet(copy.exported("src.matrix.security-copy.copies.mismatch"), id: "security.verify.mismatch") {
                        Task { await driver.compare(id, matches: false) }
                    }
                }
            }
        case let .ended(reason):
            TrustScreen(design: design, glyph: .close,
                        title: copy.text(.notConfirmedTitle), message: endedMessage(reason)) {
                EmptyView()
            } actions: {
                primary(copy.exported("src.matrix.security-copy.copies.retry"), id: "security.verify.retry") {
                    Task { await run { await driver.request() } }
                }
                recoveryKeyAction
            }
        }
    }

    /// Seven emoji in the spec's order, four to a row, each with its name.
    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: kit.space(.s2)), count: 4),
                  spacing: kit.space(.s5)) {
            ForEach(Array(state.emoji.enumerated()), id: \.offset) { _, emoji in
                VStack(spacing: kit.space(.s1)) {
                    Text(verbatim: emoji.symbol)
                        .font(.largeTitle)
                    Text(verbatim: emoji.description)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: emoji.description))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("security.verify.emoji")
    }

    @ViewBuilder private var recoveryKeyAction: some View {
        if screen.offersRecoveryKey, let useRecoveryKey {
            quiet(copy.text(.useKeyInstead), id: "security.verify.useKey", action: useRecoveryKey)
        }
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .accessibilityIdentifier(id)
    }

    private func quiet(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func endedMessage(_ reason: PhoneTrustEndReason) -> String {
        switch reason {
        case .mismatch: copy.text(.mismatchBody)
        case .peerCancelled: copy.text(.peerCancelledBody)
        case .timedOut: copy.text(.timedOutBody)
        case .unavailable: copy.text(.unavailableBody)
        }
    }

    private func begin() async {
        guard !started else { return }
        started = true
        switch entry {
        case .observe:
            break
        case .request:
            // A finished earlier attempt does not block a fresh, explicit one.
            switch state {
            case .idle, .finished: await run { await driver.request() }
            default: break
            }
        case let .accept(id):
            if case let .incoming(invitation) = state, invitation.id == id {
                await run { await driver.accept(id) }
            }
        }
    }

    /// Runs one explicit action. Afterwards the native state is this
    /// presentation's own, even if it already finished before a redraw.
    private func run(_ action: () async -> Void) async {
        sawLiveAttempt = true
        await action()
        settle(screen)
    }

    private func settle(_ screen: PhoneTrustSASScreen) {
        guard sawLiveAttempt, screen.closes, !settled else { return }
        settled = true
        if screen == .confirmed { onConfirmed() }
        close()
    }
}
