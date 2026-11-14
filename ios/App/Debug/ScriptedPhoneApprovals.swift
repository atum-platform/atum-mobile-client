#if DEBUG
import AtumNativeAPI
import Foundation

/// Phone approvals for the scripted Settings screens: the DEBUG in-memory
/// registry and software keys (never in a Release build), in a fresh folder
/// per launch.
@MainActor
enum ScriptedPhoneApprovals {
    static let owner = "@an:atum.invalid"

    static func make(_ scenario: S6ScriptedScenario) async -> PhoneApprovalSettingsModel? {
        let server = PhoneApprovalScriptedServer(owner: owner,
                                                 mode: scenario == .approvalsLegacy ? .legacyMacOnly : .phoneRegistry)
        let vault = PhoneApprovalSoftwareKeyVault()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scripted-phone-approvals-\(UUID().uuidString)", isDirectory: true)
        guard let registrations = try? PhoneApprovalRegistrationStore(file: folder.appendingPathComponent("registrations.json")),
              let revocations = try? PhoneRevocationQueue(file: folder.appendingPathComponent("revocations.json"))
        else { return nil }
        let lifecycle = PhoneApprovalLifecycle(server: server, vault: vault, registrations: registrations,
                                               revocations: revocations, retryDelays: [])
        let authentication: PhoneApprovalAuthentication = switch scenario {
        case .approvalsNoPasscode: .noPasscode
        case .approvalsPasscodeOnly: .passcodeOnly
        default: .faceID
        }
        let identity = PhoneApprovalMatrixIdentity(userID: owner, deviceID: "SCRIPTEDPHONE",
                                                   fingerprint: String(repeating: "f", count: 43))
        let facts = PhoneApprovalDeviceFacts(displayName: "iPhone", osVersion: "26.0", authentication: authentication)
        if scenario == .approvalsOn || scenario == .approvalsKeyMissing {
            _ = try? await lifecycle.setUp(owner: owner, identity: identity,
                                           device: PhoneApprovalDeviceFacts(displayName: "iPhone", osVersion: "26.0",
                                                                            authentication: .faceID),
                                           reason: "scripted")
        }
        if scenario == .approvalsKeyMissing { vault.loseAllKeys() }
        if scenario == .approvalsCancel { vault.script([.cancel]) }
        await server.set(enrollDelay: .milliseconds(1_500))
        let model = PhoneApprovalSettingsModel(owner: owner, lifecycle: lifecycle,
                                               identity: { identity }, device: { facts })
        await model.refresh()
        if scenario == .approvalsOffline { await server.set(offline: true) }
        return model
    }
}
#endif
