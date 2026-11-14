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
    /// every lifecycle, so the sign-out fence covers lifecycles created for
    /// replacement clients and two clients never write the same file at once.
    /// An undecodable file is set aside and salvaged (`recovering`); nil only
    /// when the folder cannot be read or written at all.
    private static let files: (PhoneApprovalRegistrationStore, PhoneRevocationQueue)? = {
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent("PhoneApprovals", isDirectory: true)
            return (try PhoneApprovalRegistrationStore.recovering(file: folder.appendingPathComponent("registrations.json")),
                    try PhoneRevocationQueue.recovering(file: folder.appendingPathComponent("revocations.json")))
        } catch {
            // No row and nothing enrolled from this run; sign-out takes the
            // stateless path below.
            phoneApprovalLog.error("Phone approval state could not be opened")
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

    /// Sign-out: through the live model while the bearer works; else through
    /// a lifecycle on the shared files (offline: revocations wait for this
    /// owner's next sign-in; with no client at all, confirmed key deletion
    /// releases it); else, when the files cannot be opened, the stateless path
    /// (delete every key of the owner, which releases it, and best effort
    /// revoke on the server whatever is bound to this Matrix device).
    /// Credentials may go only when the result allows it.
    static func signOut(owner: String, model: PhoneApprovalSettingsModel?, matrixDeviceID: String?,
                        server: PhoneApprovalServer?) async -> Bool {
        let result: PhoneApprovalSignOutResult
        if let model, model.owner == owner {
            result = await model.signOut(matrixDeviceID: matrixDeviceID)
        } else if let lifecycle = lifecycle(server: server ?? PhoneApprovalUnreachableServer()) {
            // No client: confirmed key deletion is what releases sign-out.
            result = await lifecycle.signOut(owner: owner, matrixDeviceID: matrixDeviceID, hasClient: server != nil)
        } else {
            result = await PhoneApprovalLifecycle.signOutWithoutState(owner: owner, matrixDeviceID: matrixDeviceID,
                                                                       server: server, vault: SecureEnclavePhoneKeyVault())
        }
        if !result.allowsSignOut {
            phoneApprovalLog.error("Sign-out held: phone approval cleanup not settled (keys \(result.keysDeleted), recorded \(result.revocationRecorded), revoked \(result.serverRevoked))")
        }
        return result.allowsSignOut
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
