#if DEBUG
import AtumChat
import AuthenticationServices
import Observation
import SwiftUI

/// `-AtumScriptedSecurity <scenario>`: the real ML5 trust screens on scripted
/// engine states, for simulator screenshots against mockup M4. It signs in to
/// nothing and touches no Matrix SDK, Keychain or pasteboard. The key shown is
/// a fixed fake that is not a valid Matrix recovery key.
enum ScriptedSecurityScenario: String, CaseIterable {
    case waiting, emoji, mismatch, key, keyFallback, sheet, incoming, privateOff, privateOn
}

enum ScriptedSecurityLaunch {
    static let scenario: ScriptedSecurityScenario? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-AtumScriptedSecurity"),
              arguments.indices.contains(flag + 1) else { return nil }
        return ScriptedSecurityScenario(rawValue: arguments[flag + 1])
    }()
}

@MainActor @Observable
private final class ScriptedVerificationDriver: DeviceVerificationDriver {
    var state: MatrixSASVerification.State
    init(_ state: MatrixSASVerification.State) { self.state = state }
    func listen() async {}
    func request() async { state = .requested(UUID()) }
    func accept(_ id: UUID) async { state = .accepted(id) }
    func compare(_ id: UUID, matches: Bool) async {
        state = matches ? .waitingForPeer(id) : .finished(.mismatch)
    }
    func cancel(_ id: UUID) async { state = .finished(.cancelled) }
}

struct ScriptedSecurityHost: View {
    let scenario: ScriptedSecurityScenario
    private let design = try! LiveDesign()
    private static let attempt = UUID()
    private static let emoji: [MatrixSASVerification.Emoji] = [
        .init(symbol: "🐶", description: "Dog"), .init(symbol: "🔑", description: "Key"),
        .init(symbol: "🌵", description: "Cactus"), .init(symbol: "🚀", description: "Rocket"),
        .init(symbol: "🎸", description: "Guitar"), .init(symbol: "🍄", description: "Mushroom"),
        .init(symbol: "🐧", description: "Penguin"),
    ]

    @State private var makePrivate = false
    @State private var privateShown = false
    @State private var groupName = ""

    var body: some View {
        Group {
            switch scenario {
            case .waiting: verification(.requested(Self.attempt), entry: .observe)
            case .emoji: verification(.comparing(Self.attempt, Self.emoji), entry: .observe)
            case .mismatch: verification(.finished(.mismatch), entry: .observe, live: true)
            case .key, .keyFallback:
                NavigationStack {
                    RecoveryKeySaveView(design: design, id: Self.attempt,
                                        actions: actions(platformSave: scenario == .key),
                                        mode: .offer, onSaved: {}, close: {})
                }
            case .sheet:
                Color.clear.sheet(isPresented: .constant(true)) {
                    SecuritySheet(design: design, actions: actions(platformSave: true))
                }
            case .incoming:
                Color.clear
                    .deviceVerificationRequests(
                        design: design,
                        actions: actions(platformSave: true,
                                         driver: ScriptedVerificationDriver(
                                            .incoming(.init(id: Self.attempt, deviceName: "MacBook Pro")))),
                        ready: true)
            case .privateOff, .privateOn:
                NavigationStack {
                    Form {
                        Section { TextField("", text: $groupName) }
                        PrivateChatOptionSection(design: design, shown: privateShown, isOn: $makePrivate)
                    }
                    .privateChatReadiness(privateActions, shown: $privateShown, isOn: $makePrivate)
                    .navigationBarTitleDisplayMode(.inline)
                }
                .onAppear { makePrivate = scenario == .privateOn }
            }
        }
        .atumDesign(design)
        .accessibilityIdentifier("scripted.security.\(scenario.rawValue)")
    }

    private func verification(_ state: MatrixSASVerification.State, entry: DeviceVerificationView.Entry,
                              live: Bool = false) -> some View {
        let driver = ScriptedVerificationDriver(live ? .requested(Self.attempt) : state)
        return NavigationStack {
            DeviceVerificationView(design: design, driver: driver, entry: entry,
                                   useRecoveryKey: {}, onConfirmed: {}, close: {})
        }
        .task {
            // Pass through a live attempt first, as the engine does.
            if live { driver.state = state }
        }
    }

    private var privateActions: PrivateChatActions {
        PrivateChatActions(readiness: { true }, createDirect: { _ in .failed },
                           createGroup: { _, _, _ in .failed })
    }

    private func actions(platformSave: Bool,
                         driver: ScriptedVerificationDriver? = nil) -> SecurityActions {
        let verification = driver ?? ScriptedVerificationDriver(.idle)
        var save: (@MainActor (UUID, ASPresentationAnchor) async -> Result<Void, PhoneTrustFailure>)?
        if platformSave { save = { _, _ in .success(()) } }
        return SecurityActions(
            verification: { verification },
            snapshot: {
                MatrixSecuritySnapshot(sessionVerified: true, recoveryEnabled: true, backupEnabled: true,
                                       recoveryKeyConfirmed: false, pendingSaveID: Self.attempt)
            },
            setup: { .success(Self.attempt) },
            revealKey: { _ in "EsTb7Hq2Kd9PwZx43mRfLp8VnC6yUg1A0000ScRp" },
            saveToPasswords: save,
            confirmSaved: { _ in .success(()) },
            restore: { _ in .failed }
        )
    }
}
#endif
