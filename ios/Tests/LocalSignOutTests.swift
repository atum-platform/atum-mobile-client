import XCTest
@testable import AtumNativeAPI

final class LocalSignOutTests: XCTestCase {
    @MainActor
    func testSuccessfulTransactionDeactivatesBeforePurgingAndClearsJournal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = fixture.value(domain: true, recovery: true)

        let receipt = try fixture.coordinator.executePrepared(value)

        XCTAssertEqual(receipt, LocalSignOutReceipt(purgePending: false))
        XCTAssertEqual(fixture.operations.staged, value.steps)
        XCTAssertEqual(fixture.operations.purged, value.steps.reversed())
        XCTAssertTrue(fixture.operations.active.isEmpty)
        XCTAssertTrue(fixture.operations.quarantine.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }

    @MainActor
    func testEveryStagingFailureRollsBackCompletedStepsAndLeavesNoJournal() throws {
        for failed in LocalSignOutStep.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let value = fixture.value(domain: true, recovery: true)
            fixture.operations.failStageOnce = failed

            XCTAssertThrowsError(try fixture.coordinator.executePrepared(value)) {
                XCTAssertEqual($0 as? LocalSignOutFailure, .storageUnavailable)
            }
            XCTAssertEqual(fixture.operations.active, Set(value.steps))
            XCTAssertTrue(fixture.operations.quarantine.isEmpty)
            XCTAssertNil(try fixture.journal.load())
        }
    }

    @MainActor
    func testInterruptedStagingResumesForwardWithoutReactivatingIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var value = fixture.value(domain: true, recovery: false)
        let completed = Array(value.steps.prefix(2))
        for step in completed { try fixture.operations.stage(step, value) }
        value.completed = completed
        try fixture.journal.save(value)

        let receipt = try XCTUnwrap(fixture.coordinator.resumePending())

        XCTAssertFalse(receipt.purgePending)
        XCTAssertTrue(fixture.operations.active.isEmpty)
        XCTAssertTrue(fixture.operations.quarantine.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }

    @MainActor
    func testFinalNamespaceCheckFailureRollsBackEveryStep() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = fixture.value(domain: true, recovery: true)
        fixture.operations.failActiveNamespaceCheckOnce = true

        XCTAssertThrowsError(try fixture.coordinator.executePrepared(value)) {
            XCTAssertEqual($0 as? LocalSignOutFailure, .storageUnavailable)
        }
        XCTAssertEqual(fixture.operations.active, Set(value.steps))
        XCTAssertTrue(fixture.operations.quarantine.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }

    @MainActor
    func testInterruptedRollbackFinishesTheAuthorizedSignOutForward() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = fixture.value(domain: true, recovery: true)
        fixture.operations.failStageOnce = .store
        fixture.operations.failRollbackOnce = .domain

        let receipt = try fixture.coordinator.executePrepared(value)

        XCTAssertFalse(receipt.purgePending)
        XCTAssertTrue(fixture.operations.active.isEmpty)
        XCTAssertTrue(fixture.operations.quarantine.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }

    @MainActor
    func testPurgeFailureReturnsSignedOutAndNextLaunchFinishesIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let value = fixture.value(domain: false, recovery: true)
        fixture.operations.failPurgeOnce = .store

        let first = try fixture.coordinator.executePrepared(value)
        XCTAssertTrue(first.purgePending)
        XCTAssertTrue(fixture.operations.active.isEmpty)
        XCTAssertNotNil(try fixture.journal.load())

        let second = try XCTUnwrap(fixture.coordinator.resumePending())
        XCTAssertFalse(second.purgePending)
        XCTAssertTrue(fixture.operations.quarantine.isEmpty)
        XCTAssertNil(try fixture.journal.load())
    }
}

private extension LocalSignOutTests {
    @MainActor
    final class Fixture {
        let directory: URL
        let marker: OIDCInstallationMarker
        let stores: MatrixStoreDirectory
        let operations: Operations
        let coordinator: LocalSignOutCoordinator
        let journal: LocalSignOutJournalStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("local-sign-out-tests-" + UUID().uuidString,
                                        isDirectory: true)
            let markerDirectory = directory.appendingPathComponent("marker", isDirectory: true)
            marker = OIDCInstallationMarker(directory: markerDirectory)
            let storeRoot = directory.appendingPathComponent("store", isDirectory: true)
            stores = MatrixStoreDirectory(root: storeRoot)
            operations = Operations()
            let journalDirectory = directory.appendingPathComponent("journal", isDirectory: true)
            journal = LocalSignOutJournalStore(directory: journalDirectory)
            coordinator = LocalSignOutCoordinator(marker: marker, directories: stores,
                                                   operations: operations,
                                                   journalDirectory: journalDirectory)
        }

        func value(domain: Bool, recovery: Bool) -> LocalSignOutJournal {
            let value = LocalSignOutJournal(transactionID: UUID(), installationID: UUID(),
                                            generation: UUID(),
                                            steps: LocalSignOutStep.plan(domainPresent: domain,
                                                                         recoveryPresent: recovery))
            operations.reset(value.steps)
            return value
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    final class Operations: LocalSignOutOperations {
        var active = Set<LocalSignOutStep>()
        var quarantine = Set<LocalSignOutStep>()
        var staged = [LocalSignOutStep]()
        var purged = [LocalSignOutStep]()
        var failStageOnce: LocalSignOutStep?
        var failPurgeOnce: LocalSignOutStep?
        var failRollbackOnce: LocalSignOutStep?
        var failActiveNamespaceCheckOnce = false

        func reset(_ steps: [LocalSignOutStep]) {
            active = Set(steps); quarantine = []; staged = []; purged = []
        }

        func preflight(_ value: LocalSignOutJournal) throws {
            try value.validate()
            guard active == Set(value.steps), quarantine.isEmpty else {
                throw LocalSignOutFailure.storageUnavailable
            }
        }

        func stage(_ step: LocalSignOutStep, _: LocalSignOutJournal) throws {
            if failStageOnce == step {
                failStageOnce = nil
                throw LocalSignOutFailure.storageUnavailable
            }
            if !active.contains(step), quarantine.contains(step) { return }
            guard active.remove(step) != nil, quarantine.insert(step).inserted else {
                throw LocalSignOutFailure.storageUnavailable
            }
            staged.append(step)
        }

        func rollback(_ step: LocalSignOutStep, _: LocalSignOutJournal) throws {
            if failRollbackOnce == step {
                failRollbackOnce = nil
                throw LocalSignOutFailure.storageUnavailable
            }
            if active.contains(step), !quarantine.contains(step) { return }
            guard quarantine.remove(step) != nil else { return }
            active.insert(step)
        }

        func purge(_ step: LocalSignOutStep, _: LocalSignOutJournal) throws {
            if failPurgeOnce == step {
                failPurgeOnce = nil
                throw LocalSignOutFailure.storageUnavailable
            }
            quarantine.remove(step)
            purged.append(step)
        }

        func activeNamespaceIsEmpty(_: LocalSignOutJournal) throws -> Bool {
            if failActiveNamespaceCheckOnce {
                failActiveNamespaceCheckOnce = false
                throw LocalSignOutFailure.storageUnavailable
            }
            return active.isEmpty
        }
    }
}

