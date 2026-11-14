import AtumNativeAPI
import Foundation
import OSLog
import UIKit

private let phoneApprovalLog = Logger(subsystem: "com.atum.mobile", category: "phone-approvals")

/// Production wiring for phone approvals slice 2b: Secure Enclave keys (no
/// software fallback), the device-service registry through the native
/// client, and app-wide files under Application Support.
@MainActor
enum PhoneApprovalLive {
    /// One registration store and one revocation queue per app, shared by
    /// every lifecycle, so two clients never write the same file at once.
    private static let files: (PhoneApprovalRegistrationStore, PhoneRevocationQueue)? = {
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("PhoneApprovals", isDirectory: true)
            return (try PhoneApprovalRegistrationStore(file: folder.appendingPathComponent("registrations.json")),
                    try PhoneRevocationQueue(file: folder.appendingPathComponent("revocations.json")))
        } catch {
            // Fail closed: no Settings row, nothing enrolled from this run.
            phoneApprovalLog.error("Phone approval state could not be read")
            return nil
        }
    }()

    static func lifecycle(server: PhoneApprovalServer) -> PhoneApprovalLifecycle? {
        guard let (registrations, revocations) = files else { return nil }
        return PhoneApprovalLifecycle(server: server, vault: SecureEnclavePhoneKeyVault(),
                                      registrations: registrations, revocations: revocations)
    }

    static func model(owner: String, server: PhoneApprovalServer,
                      identity: @escaping @MainActor () async -> PhoneApprovalMatrixIdentity?) -> PhoneApprovalSettingsModel? {
        guard let lifecycle = lifecycle(server: server) else { return nil }
        return PhoneApprovalSettingsModel(owner: owner, lifecycle: lifecycle, identity: identity,
                                          device: { deviceFacts() })
    }

    static func deviceFacts() -> PhoneApprovalDeviceFacts {
        PhoneApprovalDeviceFacts(displayName: UIDevice.current.name,
                                 osVersion: UIDevice.current.systemVersion,
                                 authentication: .current())
    }

    /// Sign-out: through the live model while the bearer works, else offline
    /// (the revocation waits for this owner's next sign-in). False only when
    /// the revocation could not be recorded.
    static func signOut(owner: String, model: PhoneApprovalSettingsModel?) async -> Bool {
        if let model, model.owner == owner { return await model.signOut() }
        guard let lifecycle = lifecycle(server: PhoneApprovalUnreachableServer()) else { return true }
        return await lifecycle.signOut(owner: owner)
    }
}

extension LiveMatrixSession {
    /// The signed-in Matrix device an enrolment binds to: user, device and
    /// the device's ed25519 key.
    func phoneApprovalIdentity() async -> PhoneApprovalMatrixIdentity? {
        guard (try? runtime.requireCurrent()) != nil,
              let user = try? runtime.client.userId(),
              let device = try? runtime.client.deviceId(),
              let fingerprint = await runtime.client.encryption().ed25519Key() else { return nil }
        return PhoneApprovalMatrixIdentity(userID: user, deviceID: device, fingerprint: fingerprint)
    }
}
