import Foundation
import Security

public enum LocalSignOutFailure: Error, Equatable {
    case confirmationRequired
    case identityChanged
    case storageUnavailable
    /// Rollback could not restore a coherent active namespace and completing
    /// the already-authorized sign-out forward also failed. Bootstrap keeps
    /// the journal and retries forward; callers must not reopen the session.
    case rollbackIncomplete
}

public struct LocalSignOutReceipt: Equatable, Sendable {
    /// Active identity and store data are already unreachable. A later launch
    /// will retry physical deletion of the inaccessible quarantine.
    public let purgePending: Bool
}

/// S6's local sign-out transaction. It removes one exact active installation,
/// never broad Keychain state, and journals only non-secret identifiers.
@MainActor
public final class LocalSignOutCoordinator {
    private let marker: OIDCInstallationMarker
    private let directories: MatrixStoreDirectory
    private let operations: any LocalSignOutOperations
    private let journalStore: LocalSignOutJournalStore

    public convenience init() throws {
        let marker = OIDCInstallationMarker()
        let directories = try MatrixStoreDirectory()
        self.init(marker: marker, directories: directories,
                  operations: SystemLocalSignOutOperations(marker: marker,
                                                           directories: directories,
                                                           keychain: SystemOIDCKeychain()),
                  journalDirectory: URL.applicationSupportDirectory
                    .appendingPathComponent("AtumSignOut", isDirectory: true))
    }

    init(marker: OIDCInstallationMarker,
         directories: MatrixStoreDirectory,
         operations: any LocalSignOutOperations,
         journalDirectory: URL) {
        self.marker = marker
        self.directories = directories
        self.operations = operations
        journalStore = LocalSignOutJournalStore(directory: journalDirectory)
    }

    /// The caller stops the Matrix runtime before entering this method. A
    /// recovery root is removed only when it was actually readable and the
    /// person explicitly confirmed saving it.
    public func signOut(
        installation: OIDCInstallation,
        session: MatrixCustodyTicket,
        sessionStore: MatrixSessionKeychain,
        domainStore: OIDCDomainKeychain,
        recoveryStore: MatrixRecoveryKeychain,
        confirmedRecoverySaved: Bool
    ) throws -> LocalSignOutReceipt {
        do {
            try sessionStore.recheck(session, marker: marker)
            _ = try directories.requireExisting(generation: installation.generation)
            guard try marker.load() == installation else { throw LocalSignOutFailure.identityChanged }
            let domainPresent = try domainStore.load() != nil
            let recoveryPresent = try recoveryStore.currentInput(
                session: session, sessionStore: sessionStore, marker: marker
            ) != nil
            guard !recoveryPresent || confirmedRecoverySaved else {
                throw LocalSignOutFailure.confirmationRequired
            }

            let value = LocalSignOutJournal(
                transactionID: UUID(), installationID: installation.id,
                generation: installation.generation,
                steps: LocalSignOutStep.plan(domainPresent: domainPresent,
                                             recoveryPresent: recoveryPresent)
            )
            try operations.preflight(value)
            try journalStore.save(value)
            return try advance(value, rollbackOnFailure: true)
        } catch let failure as LocalSignOutFailure {
            throw failure
        } catch {
            throw LocalSignOutFailure.storageUnavailable
        }
    }

    /// Called before bootstrap. An interrupted user-authorized sign-out is
    /// completed; active credentials are never silently reactivated.
    public func resumePending() throws -> LocalSignOutReceipt? {
        guard let value = try journalStore.load() else { return nil }
        return try advance(value, rollbackOnFailure: false)
    }

    func executePrepared(_ value: LocalSignOutJournal,
                         rollbackOnFailure: Bool = true) throws -> LocalSignOutReceipt {
        try operations.preflight(value)
        try journalStore.save(value)
        return try advance(value, rollbackOnFailure: rollbackOnFailure)
    }

    private func advance(_ input: LocalSignOutJournal,
                         rollbackOnFailure: Bool) throws -> LocalSignOutReceipt {
        var value = input
        if value.phase == .staging {
            var attempted: LocalSignOutStep?
            do {
                // Re-run completed steps too. Staging is idempotent, and this
                // lets resumePending finish forward after a rollback itself
                // was interrupted and reactivated only part of the namespace.
                for step in value.steps {
                    attempted = step
                    try operations.stage(step, value)
                    if !value.completed.contains(step) {
                        value.completed.append(step)
                        try journalStore.save(value)
                    }
                    attempted = nil
                }
                guard try operations.activeNamespaceIsEmpty(value) else {
                    throw LocalSignOutFailure.storageUnavailable
                }
            } catch {
                guard rollbackOnFailure else { throw LocalSignOutFailure.storageUnavailable }
                let rollback = (attempted.map { [$0] } ?? []) + value.completed.reversed()
                var rollbackFailed = false
                for completed in rollback.uniqued() {
                    do { try operations.rollback(completed, value) }
                    catch { rollbackFailed = true }
                }
                if !rollbackFailed {
                    do { try journalStore.clear() }
                    catch {
                        // A journal that cannot be cleared would silently
                        // sign this restored session out on next launch. The
                        // person's authorization still permits finishing the
                        // transaction forward now instead.
                        rollbackFailed = true
                    }
                }
                if !rollbackFailed { throw LocalSignOutFailure.storageUnavailable }
                do { return try advance(value, rollbackOnFailure: false) }
                catch { throw LocalSignOutFailure.rollbackIncomplete }
            }
            // The active namespace is now empty: sign-out has committed. A
            // failure to persist the phase cannot safely reactivate identity;
            // keep the staging journal for bootstrap to replay forward.
            value.phase = .deactivated
            do { try journalStore.save(value) }
            catch { return LocalSignOutReceipt(purgePending: true) }
        }

        var purgePending = false
        for step in value.steps.reversed() {
            do { try operations.purge(step, value) }
            catch { purgePending = true }
        }
        if !purgePending { try journalStore.clear() }
        return LocalSignOutReceipt(purgePending: purgePending)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum LocalSignOutStep: String, Codable, CaseIterable, Hashable, Sendable {
    case matrix
    case domain
    case recovery
    case store
    case marker

    static func plan(domainPresent: Bool, recoveryPresent: Bool) -> [Self] {
        [.matrix] + (domainPresent ? [.domain] : [])
            + (recoveryPresent ? [.recovery] : []) + [.store, .marker]
    }
}

struct LocalSignOutJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case staging, deactivated }

    let version: Int
    let transactionID: UUID
    let installationID: UUID
    let generation: UUID
    let steps: [LocalSignOutStep]
    var completed: [LocalSignOutStep]
    var phase: Phase

    init(transactionID: UUID, installationID: UUID, generation: UUID,
         steps: [LocalSignOutStep]) {
        version = 1
        self.transactionID = transactionID
        self.installationID = installationID
        self.generation = generation
        self.steps = steps
        completed = []
        phase = .staging
    }

    var installation: OIDCInstallation {
        OIDCInstallation(id: installationID, generation: generation)
    }

    func validate() throws {
        guard version == 1,
              steps == LocalSignOutStep.plan(domainPresent: steps.contains(.domain),
                                             recoveryPresent: steps.contains(.recovery)),
              Set(completed).count == completed.count,
              completed.allSatisfy(steps.contains) else {
            throw LocalSignOutFailure.storageUnavailable
        }
    }
}

@MainActor
protocol LocalSignOutOperations: AnyObject {
    func preflight(_ value: LocalSignOutJournal) throws
    func stage(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws
    func rollback(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws
    func purge(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws
    func activeNamespaceIsEmpty(_ value: LocalSignOutJournal) throws -> Bool
}

@MainActor
private final class SystemLocalSignOutOperations: LocalSignOutOperations {
    private static let quarantineService = "com.atum.mobile.signout.quarantine.v1"

    private let marker: OIDCInstallationMarker
    private let directories: MatrixStoreDirectory
    private let keychain: any OIDCKeychainOperations

    init(marker: OIDCInstallationMarker, directories: MatrixStoreDirectory,
         keychain: any OIDCKeychainOperations) {
        self.marker = marker
        self.directories = directories
        self.keychain = keychain
    }

    func preflight(_ value: LocalSignOutJournal) throws {
        try value.validate()
        guard try marker.load() == value.installation,
              (try? directories.requireExisting(generation: value.generation)) != nil,
              try inventoryCount(service: MatrixCustodyRecord.service,
                                 accessGroup: MatrixCustodyRecord.accessGroup) == 1,
              try inventoryCount(service: OIDCDomainKeychain.service,
                                 accessGroup: OIDCDomainKeychain.accessGroup)
                == (value.steps.contains(.domain) ? 1 : 0),
              try inventoryCount(service: MatrixRecoveryKeychain.service,
                                 accessGroup: MatrixRecoveryKeychain.accessGroup)
                == (value.steps.contains(.recovery) ? 1 : 0) else {
            throw LocalSignOutFailure.identityChanged
        }
        for step in value.steps where step.isKeychain {
            guard try exists(step.originalRecord(value)) else {
                throw LocalSignOutFailure.identityChanged
            }
            guard try !exists(step.quarantineRecord(value)) else {
                throw LocalSignOutFailure.storageUnavailable
            }
        }
    }

    func stage(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws {
        switch step {
        case .matrix, .domain, .recovery:
            try move(from: step.originalRecord(value), to: step.quarantineRecord(value))
        case .store:
            try directories.quarantineForSignOut(generation: value.generation,
                                                 transactionID: value.transactionID)
        case .marker:
            try marker.quarantineForSignOut(value.installation,
                                            transactionID: value.transactionID)
        }
    }

    func rollback(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws {
        switch step {
        case .matrix, .domain, .recovery:
            try move(from: step.quarantineRecord(value), to: step.originalRecord(value))
        case .store:
            try directories.restoreAfterFailedSignOut(generation: value.generation,
                                                      transactionID: value.transactionID)
        case .marker:
            try marker.restoreAfterFailedSignOut(value.installation,
                                                 transactionID: value.transactionID)
        }
    }

    func purge(_ step: LocalSignOutStep, _ value: LocalSignOutJournal) throws {
        switch step {
        case .matrix, .domain, .recovery:
            let status = keychain.delete(step.quarantineRecord(value).query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LocalSignOutFailure.storageUnavailable
            }
        case .store:
            try directories.purgeSignOutQuarantine(transactionID: value.transactionID)
        case .marker:
            try marker.purgeSignOutQuarantine(transactionID: value.transactionID)
        }
    }

    func activeNamespaceIsEmpty(_ value: LocalSignOutJournal) throws -> Bool {
        guard !marker.hasActiveInstallationFile(),
              !directories.hasActiveStore(generation: value.generation) else { return false }
        for step in value.steps where step.isKeychain {
            if try exists(step.originalRecord(value)) { return false }
            if try !exists(step.quarantineRecord(value)) { return false }
        }
        return true
    }

    private func move(from: Record, to: Record) throws {
        let source = try exists(from)
        let target = try exists(to)
        if !source && target { return }
        guard source && !target else { throw LocalSignOutFailure.storageUnavailable }
        let status = keychain.update(from.query, attributes: [
            kSecAttrService as String: to.service,
            kSecAttrAccount as String: to.account,
        ])
        guard status == errSecSuccess, try !exists(from), try exists(to) else {
            throw LocalSignOutFailure.storageUnavailable
        }
    }

    private func exists(_ record: Record) throws -> Bool {
        var query = record.query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        let (status, _) = keychain.copy(query)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LocalSignOutFailure.storageUnavailable }
        return true
    }

    private func inventoryCount(service: String, accessGroup: String) throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]
        let (status, result) = keychain.copy(query)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else { throw LocalSignOutFailure.storageUnavailable }
        if let values = result as? [[String: Any]] { return values.count }
        if result is [String: Any] { return 1 }
        throw LocalSignOutFailure.storageUnavailable
    }

    fileprivate struct Record {
        let service: String
        let account: String
        let accessGroup: String
        let synchronizable: Bool

        var query: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: synchronizable,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
    }
}

@MainActor private extension LocalSignOutStep {
    var isKeychain: Bool {
        self == .matrix || self == .domain || self == .recovery
    }

    func originalRecord(_ value: LocalSignOutJournal) -> SystemLocalSignOutOperations.Record {
        switch self {
        case .matrix:
            .init(service: MatrixCustodyRecord.service, account: MatrixCustodyRecord.account,
                  accessGroup: MatrixCustodyRecord.accessGroup, synchronizable: false)
        case .domain:
            .init(service: OIDCDomainKeychain.service, account: value.generation.uuidString,
                  accessGroup: OIDCDomainKeychain.accessGroup, synchronizable: false)
        case .recovery:
            .init(service: MatrixRecoveryKeychain.service, account: MatrixRecoveryKeychain.account,
                  accessGroup: MatrixRecoveryKeychain.accessGroup, synchronizable: false)
        case .store, .marker:
            preconditionFailure("not a Keychain step")
        }
    }

    func quarantineRecord(_ value: LocalSignOutJournal) -> SystemLocalSignOutOperations.Record {
        let original = originalRecord(value)
        return .init(service: "com.atum.mobile.signout.quarantine.v1",
                     account: value.transactionID.uuidString + "." + rawValue,
                     accessGroup: original.accessGroup, synchronizable: original.synchronizable)
    }
}

struct LocalSignOutJournalStore {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("transaction-v1.json") }

    func load() throws -> LocalSignOutJournal? {
        do {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            guard data.count <= 16_384 else { throw LocalSignOutFailure.storageUnavailable }
            let value = try JSONDecoder().decode(LocalSignOutJournal.self, from: data)
            try value.validate()
            return value
        } catch let failure as LocalSignOutFailure { throw failure }
        catch { throw LocalSignOutFailure.storageUnavailable }
    }

    func save(_ value: LocalSignOutJournal) throws {
        do {
            try value.validate()
            let data = try JSONEncoder().encode(value)
            guard data.count <= 16_384 else { throw LocalSignOutFailure.storageUnavailable }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                var location = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try location.setResourceValues(values)
            }
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard try load() == value else { throw LocalSignOutFailure.storageUnavailable }
        } catch let failure as LocalSignOutFailure { throw failure }
        catch { throw LocalSignOutFailure.storageUnavailable }
    }

    func clear() throws {
        do {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            try FileManager.default.removeItem(at: file)
        } catch { throw LocalSignOutFailure.storageUnavailable }
    }
}

