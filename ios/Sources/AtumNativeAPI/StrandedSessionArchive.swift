import Foundation
import Security

/// W4 E3, coordinator decision 11 (2026-10-11): the way out of a stranded
/// session. A refresh-token spend that never finished, an unfinished
/// preparation, a record from another installation, or records that survived
/// without their installation marker (a reinstall) leave custody refusing for
/// good, and every sign-in preflight refuses while any of it exists. "Đăng nhập
/// lại" moves those records aside, then signs in as a new installation beside
/// them.
///
/// Nothing is deleted or overwritten:
/// - each Matrix custody and account-service Keychain item keeps its bytes,
///   access group and protection class; only its service and account change,
///   in one `SecItemUpdate` per item, to an archive service no custody read,
///   sign-in preflight or the notification extension ever queries. An archive
///   label is new each time (the archive's own ID), and a label already taken
///   fails with `errSecDuplicateItem`, changing nothing;
/// - the installation marker file is renamed into `archived/` in its own
///   folder (not backed up, same file protection);
/// - the Matrix store folder of the old installation is not touched (a new
///   installation gets a new generation and folder), nor is the recovery-key
///   record, which may be the only copy and never blocks signing in.
///
/// The order is Matrix custody, account service, then the marker, so an
/// archive cut short still reads as stranded at the next launch (the marker
/// is there, custody refuses) and "Đăng nhập lại" finishes it: every step
/// moves whatever is still there. Old encrypted history may stay unreadable
/// on the new installation (placeholders; the recovery row in Account).
@MainActor public final class StrandedSessionArchive {
    static let matrixArchiveService = "com.atum.mobile.matrix.custody.archive.v1"
    static let domainArchiveService = "com.atum.mobile.oidc.domain.archive.v1"

    /// What still blocks a fresh sign-in, counted from attributes only (no
    /// secret is read).
    public struct Survivors: Equatable, Sendable {
        public let matrixRecords: Int
        public let domainRecords: Int
        public var isEmpty: Bool { matrixRecords == 0 && domainRecords == 0 }
        public var logCode: String { "m\(matrixRecords)_d\(domainRecords)" }
    }

    /// What one archive moved.
    public struct Receipt: Equatable, Sendable {
        public let matrixRecords: Int
        public let domainRecords: Int
        public let installationMarkers: Int
        public var logCode: String { "m\(matrixRecords)_d\(domainRecords)_i\(installationMarkers)" }
    }

    /// Moves only account/domain records aside so the current Matrix
    /// installation can run a fresh domain authorization. The installation
    /// marker, Matrix custody and encrypted SDK stores are never addressed.
    /// This is the recovery for an unresolved domain refresh spend.
    public func archiveDomain(id: UUID = UUID()) throws -> Int {
        let domain = try relabel(Self.domain, to: Self.domainArchiveService, id: id)
        guard try inventory(Self.domain).isEmpty else {
            throw OIDCGrantFailure.storageUnavailable
        }
        return domain
    }

    private let marker: OIDCInstallationMarker
    private let operations: any OIDCKeychainOperations

    public convenience init(marker: OIDCInstallationMarker) {
        self.init(marker: marker, operations: SystemOIDCKeychain())
    }
    init(marker: OIDCInstallationMarker, operations: any OIDCKeychainOperations) {
        self.marker = marker; self.operations = operations
    }

    /// The Matrix custody and account-service records a sign-in preflight
    /// would refuse (`MatrixSessionReader.requireAbsent`,
    /// `OIDCDomainKeychain.requireAbsentForExplicitSignIn`). Throws
    /// `storageUnavailable` when the Keychain cannot be read just now.
    public func survivors() throws -> Survivors {
        Survivors(matrixRecords: try inventory(Self.matrix).count,
                  domainRecords: try inventory(Self.domain).count)
    }

    /// Moves every Matrix custody and account-service record and the
    /// installation marker aside (see the type's notes), then checks that
    /// nothing is left to block a fresh sign-in. Throws `storageUnavailable`
    /// on any Keychain or file failure; what already moved stays moved, and
    /// nothing is ever lost.
    public func archive(id: UUID = UUID()) throws -> Receipt {
        let matrix = try relabel(Self.matrix, to: Self.matrixArchiveService, id: id)
        let domain = try relabel(Self.domain, to: Self.domainArchiveService, id: id)
        let markers = try marker.archiveForSignInAgain(id: id) ? 1 : 0
        guard try survivors().isEmpty, try marker.load() == nil else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        return Receipt(matrixRecords: matrix, domainRecords: domain, installationMarkers: markers)
    }

    private struct Location { let service, accessGroup: String }
    private static let matrix = Location(service: MatrixCustodyRecord.service,
                                         accessGroup: MatrixCustodyRecord.accessGroup)
    private static let domain = Location(service: OIDCDomainKeychain.service,
                                         accessGroup: OIDCDomainKeychain.accessGroup)

    /// Every item under the service, whatever its account (legacy UUID
    /// accounts included) and synchronization: the same breadth as the
    /// custody inventories.
    private func inventory(_ location: Location) throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: location.service,
            kSecAttrAccessGroup as String: location.accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        let (status, result) = operations.copy(query)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw MatrixCustodyFailure.storageUnavailable
        }
        return items
    }

    /// One `SecItemUpdate` per item, addressed exactly (its account and
    /// synchronization), changing only its service and account.
    private func relabel(_ location: Location, to archiveService: String, id: UUID) throws -> Int {
        let items = try inventory(location)
        for (index, item) in items.enumerated() {
            let account = item[kSecAttrAccount as String] as? String ?? ""
            let synchronizable = item[kSecAttrSynchronizable as String] as? Bool ?? false
            let exact: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: location.service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: location.accessGroup,
                kSecAttrSynchronizable as String: synchronizable,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let label = "\(id.uuidString).\(index).\(account)"
            let status = operations.update(exact, attributes: [kSecAttrService as String: archiveService,
                                                               kSecAttrAccount as String: label])
            guard status == errSecSuccess else { throw MatrixCustodyFailure.storageUnavailable }
        }
        return items.count
    }
}
