import Foundation
import XCTest
@testable import AtumNativeAPI

/// Slice 2b: registration storage, lifecycle (set up, remove, sign-out,
/// offline revoke, key loss, removed elsewhere, two devices, rotation) and
/// retry, against the DEBUG in-memory registry that checks signatures the
/// way the platform route does.
final class PhoneApprovalLifecycleTests: XCTestCase {
    private let owner = "@owner:atum.invalid"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct Phone {
        let lifecycle: PhoneApprovalLifecycle
        let vault: PhoneApprovalSoftwareKeyVault
        let store: PhoneApprovalRegistrationStore
        let queue: PhoneRevocationQueue
    }

    private func phone(_ name: String = "a", server: PhoneApprovalScriptedServer,
                       vault: PhoneApprovalSoftwareKeyVault = PhoneApprovalSoftwareKeyVault(),
                       queueFile: URL? = nil, writer: PhoneApprovalFileWriter = .atomic,
                       sharing: Phone? = nil) throws -> Phone {
        let store = try sharing?.store
            ?? PhoneApprovalRegistrationStore(file: folder.appendingPathComponent("\(name)/registrations.json"), writer: writer)
        let queue = try sharing?.queue
            ?? PhoneRevocationQueue(file: queueFile ?? folder.appendingPathComponent("\(name)/revocations.json"), writer: writer)
        let lifecycle = PhoneApprovalLifecycle(server: server, vault: vault, registrations: store,
                                               revocations: queue, retryDelays: [.zero, .zero])
        return Phone(lifecycle: lifecycle, vault: vault, store: store, queue: queue)
    }

    private func identity(_ device: String = "PHONEA") -> PhoneApprovalMatrixIdentity {
        PhoneApprovalMatrixIdentity(userID: owner, deviceID: device, fingerprint: String(repeating: "f", count: 43))
    }

    private let facts = PhoneApprovalDeviceFacts(displayName: "Minh’s iPhone", osVersion: "26.1", authentication: .faceID)

    private func setUp(_ phone: Phone, device: String = "PHONEA",
                       facts: PhoneApprovalDeviceFacts? = nil) async throws(PhoneApprovalSetupFailure) -> PhoneApprovalStatus {
        try await phone.lifecycle.setUp(owner: owner, identity: identity(device), device: facts ?? self.facts,
                                        reason: "Set up approvals on this iPhone")
    }

    private func expectFailure(_ expected: PhoneApprovalSetupFailure, _ phone: Phone,
                               facts: PhoneApprovalDeviceFacts? = nil, line: UInt = #line) async {
        do {
            _ = try await setUp(phone, facts: facts)
            XCTFail("set up succeeded", line: line)
        } catch {
            XCTAssertEqual(error, expected, line: line)
        }
    }

    private func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else {
            XCTFail("nil", line: line)
            throw CancellationError()
        }
        return value
    }

    // MARK: Set up

    func testSetUpRegistersOnePhoneWithOnePromptAndStoresOnlyMetadata() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        let unknown = await phone.lifecycle.status(owner: owner)
        XCTAssertEqual(unknown, .unavailable, "nothing shows before the server answers")
        let off = await phone.lifecycle.refresh(owner: owner)
        XCTAssertEqual(off, .off)
        let status = try await setUp(phone)
        guard case .on = status else { return XCTFail("not on: \(status)") }
        XCTAssertEqual(phone.vault.promptCount, 1, "enrolment signs with the approval key once")
        let stored = try unwrap(await phone.store.registration(owner: owner))
        XCTAssertEqual(stored.enrollmentEpoch, 1)
        XCTAssertTrue(phone.vault.keysExist(for: stored.namespace))
        let record = try unwrap(await server.record(stored.deviceServiceId))
        XCTAssertEqual(record.state, .active)
        XCTAssertEqual(record.platform, .ios)
        XCTAssertEqual(record.approvalKeyId, stored.approvalKeyId)
        XCTAssertEqual(record.displayName, "Minh’s iPhone")
        // The file holds IDs and key IDs only: no key bytes, no signatures.
        let file = try String(contentsOf: folder.appendingPathComponent("a/registrations.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("approvalKey\""))
        XCTAssertFalse(file.contains("sigs"))
        let reopened = try PhoneApprovalRegistrationStore(file: folder.appendingPathComponent("a/registrations.json"))
        let again = await reopened.registration(owner: owner)
        XCTAssertEqual(again, stored)
    }

    func testCancellingTheSystemPromptOnlyMeansNotSetUp() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        phone.vault.script([.cancel])
        await expectFailure(.cancelled, phone)
        XCTAssertEqual(phone.vault.keyCount, 0, "keys made for the attempt are deleted")
        let calls = await server.enrollCalls
        XCTAssertEqual(calls, 0, "nothing is sent")
        let registration = await phone.store.registration(owner: owner)
        XCTAssertNil(registration)
        let status = await phone.lifecycle.status(owner: owner)
        XCTAssertEqual(status, .off)
        // A failed prompt (not a cancel) is the generic line.
        phone.vault.script([.fail])
        await expectFailure(.generic, phone)
        XCTAssertEqual(phone.vault.keyCount, 0)
    }

    func testNoPasscodeNeverCreatesAKey() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        await expectFailure(.noPasscode, phone,
                            facts: PhoneApprovalDeviceFacts(displayName: "iPhone", osVersion: "26.1", authentication: .noPasscode))
        XCTAssertEqual(phone.vault.keyCount, 0)
        XCTAssertEqual(phone.vault.promptCount, 0)
        // Passcode without Face ID is enough (biometrics preferred, not required).
        let status = try await setUp(phone, facts: PhoneApprovalDeviceFacts(displayName: "iPhone", osVersion: "26.1",
                                                                           authentication: .passcodeOnly))
        guard case .on = status else { return XCTFail("passcode-only phone was not set up") }
    }

    func testFailsClosedWhenTheServerDoesNotAdvertisePhoneRegistry() async throws {
        let legacy = PhoneApprovalScriptedServer(owner: owner, mode: .legacyMacOnly)
        let phone = try phone(server: legacy)
        let status = await phone.lifecycle.refresh(owner: owner)
        XCTAssertEqual(status, .unavailable)
        await expectFailure(.unavailable, phone)
        XCTAssertEqual(phone.vault.keyCount, 0)

        let closed = PhoneApprovalScriptedServer(owner: owner, mode: .closed)
        let gated = try self.phone("b", server: closed)
        let gatedStatus = await gated.lifecycle.refresh(owner: owner)
        XCTAssertEqual(gatedStatus, .unavailable, "a 503 cloud gate is not an advertisement")
        await expectFailure(.offline, gated)

        let offline = PhoneApprovalScriptedServer(owner: owner)
        await offline.set(offline: true)
        let away = try self.phone("c", server: offline)
        let awayStatus = await away.lifecycle.refresh(owner: owner)
        XCTAssertEqual(awayStatus, .unavailable)
        await expectFailure(.offline, away)
        XCTAssertEqual(away.vault.keyCount, 0)
    }

    func testWrongOwnerIdentityIsRefusedLocally() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        do {
            _ = try await phone.lifecycle.setUp(owner: owner, identity: PhoneApprovalMatrixIdentity(
                userID: "@someone:atum.invalid", deviceID: "X", fingerprint: String(repeating: "f", count: 43)),
                device: facts, reason: "r")
            XCTFail("set up for another owner")
        } catch {
            XCTAssertEqual(error, .generic)
        }
        XCTAssertEqual(phone.vault.keyCount, 0)
    }

    // MARK: Retry

    func testTransientFailuresResendTheIdenticalSignedRequestWithoutANewPrompt() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        await server.failNextEnrolls([NativeDomainClientFailure.transportUnavailable,
                                      PhoneApprovalScriptedServer.error(503, nil)])
        let status = try await setUp(phone)
        guard case .on = status else { return XCTFail("not on") }
        let calls = await server.enrollCalls
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(phone.vault.promptCount, 1, "a resend needs no new Face ID")
    }

    func testALostAnswerRevokesTheIDSoNoRegistrationOutlivesItsKey() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        // The registry admits the POST, the answer is lost, and there is no
        // retry left: the phone cannot know, so it revokes that ID.
        await server.loseNextEnrollAnswer()
        let retryless = PhoneApprovalLifecycle(server: server, vault: phone.vault, registrations: phone.store,
                                               revocations: phone.queue, retryDelays: [])
        do {
            _ = try await retryless.setUp(owner: owner, identity: identity(), device: facts, reason: "r")
            XCTFail("set up succeeded")
        } catch {
            XCTAssertEqual(error, .offline)
        }
        XCTAssertEqual(phone.vault.keyCount, 0)
        let active = await server.activePhones()
        XCTAssertTrue(active.isEmpty, "the admitted registration was revoked")
        let pending = await retryless.pendingRevocations(owner: owner)
        XCTAssertTrue(pending.isEmpty)
    }

    func testALostAnswerIsRecoveredByTheIdenticalRetry() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        await server.loseNextEnrollAnswer()
        let status = try await setUp(phone)
        guard case .on = status else { return XCTFail("not on") }
        let active = await server.activePhones()
        XCTAssertEqual(active.count, 1, "the retry was idempotent: one registration")
    }

    func testRefusalsAreNotRetriedAndLeaveNothingBehind() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        await server.failNextEnrolls([PhoneApprovalScriptedServer.error(409, "enrollment_conflict")])
        await expectFailure(.refused, phone)
        let calls = await server.enrollCalls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(phone.vault.keyCount, 0)
        let pending = await phone.lifecycle.pendingRevocations(owner: owner)
        XCTAssertTrue(pending.isEmpty, "a refused enrolment created nothing to revoke")
        await server.failNextEnrolls([PhoneApprovalScriptedServer.error(401, nil)])
        await expectFailure(.generic, phone)
    }

    // MARK: Remove and sign out

    func testRemoveRevokesOnlineAndDeletesBothKeys() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let stored = try unwrap(await phone.store.registration(owner: owner))
        let status = try await phone.lifecycle.remove(owner: owner)
        XCTAssertEqual(status, .off)
        XCTAssertEqual(phone.vault.keyCount, 0)
        let record = await server.record(stored.deviceServiceId)
        XCTAssertEqual(record?.state, .revoked)
        XCTAssertEqual(record?.revokeSeq, 1)
        let pending = await phone.lifecycle.pendingRevocations(owner: owner)
        XCTAssertTrue(pending.isEmpty)
    }

    func testOfflineRemoveDiscardsLocalAuthorityAndRetriesTheRevocationLater() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let stored = try unwrap(await phone.store.registration(owner: owner))
        await server.set(offline: true)
        let status = try await phone.lifecycle.remove(owner: owner)
        XCTAssertEqual(status, .off)
        XCTAssertEqual(phone.vault.keyCount, 0, "local authority goes even offline")
        let pending = await phone.lifecycle.pendingRevocations(owner: owner)
        XCTAssertEqual(pending, [stored.deviceServiceId])
        let stillActive = await server.record(stored.deviceServiceId)?.state
        XCTAssertEqual(stillActive, .active)
        // A restart keeps the owed revocation.
        let restarted = try self.phone(server: server)
        await server.set(offline: false)
        let refreshed = await restarted.lifecycle.refresh(owner: owner)
        XCTAssertEqual(refreshed, .off)
        let revoked = await server.record(stored.deviceServiceId)?.state
        XCTAssertEqual(revoked, .revoked)
        let after = await restarted.lifecycle.pendingRevocations(owner: owner)
        XCTAssertTrue(after.isEmpty)
    }

    func testSignOutOfflineLetsCredentialsGoButAnUnwritableQueueDoesNot() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        await server.set(offline: true)
        let result = await phone.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertTrue(result.allowsSignOut, "keys gone and the revocation recorded")
        XCTAssertTrue(result.keysDeleted)
        XCTAssertFalse(result.serverRevoked)
        XCTAssertEqual(phone.vault.keyCount, 0)
        let pending = await phone.lifecycle.pendingRevocations(owner: owner)
        XCTAssertEqual(pending.count, 1)

        // A queue that cannot be written: its folder is a regular file.
        await server.set(offline: false)
        let blocker = folder.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocker)
        let stuck = try self.phone("b", server: server, queueFile: blocker.appendingPathComponent("revocations.json"))
        _ = try await setUp(stuck, device: "PHONEB")
        let stuckID = try unwrap(await stuck.store.registration(owner: owner)).deviceServiceId
        await server.set(offline: true)
        let kept = await stuck.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEB")
        XCTAssertFalse(kept.allowsSignOut, "credentials must stay when the revocation cannot be recorded")
        XCTAssertFalse(kept.revocationRecorded)
        let registration = await stuck.store.registration(owner: owner)
        XCTAssertNotNil(registration, "the registration is kept to record its revocation later")
        // Online, the server confirms the revocation itself: sign-out may go.
        await server.set(offline: false)
        let online = await stuck.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEB")
        XCTAssertTrue(online.serverRevoked)
        XCTAssertTrue(online.allowsSignOut)
        let state = await server.record(stuckID)?.state
        XCTAssertEqual(state, .revoked, "the sweep revoked this iPhone's registration")
    }

    func testSignOutWithoutARegistrationIsAllowed() async throws {
        let phone = try phone(server: PhoneApprovalScriptedServer(owner: owner))
        let result = await phone.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertTrue(result.allowsSignOut)
    }

    // MARK: Key loss, removal elsewhere, two devices

    func testKeyLossRevokesTheStaleRegistrationAndAsksToSetUpAgain() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let old = try unwrap(await phone.store.registration(owner: owner))
        phone.vault.loseAllKeys()
        let status = await phone.lifecycle.refresh(owner: owner)
        XCTAssertEqual(status, .needsSetUpAgain)
        let local = await phone.lifecycle.status(owner: owner)
        XCTAssertEqual(local, .needsSetUpAgain, "the notice survives until set up again")
        let revoked = await server.record(old.deviceServiceId)?.state
        XCTAssertEqual(revoked, .revoked)
        // Set up again: a new identity at epoch 1, never the old registration.
        let again = try await setUp(phone)
        guard case .on = again else { return XCTFail("not on") }
        let fresh = try unwrap(await phone.store.registration(owner: owner))
        XCTAssertNotEqual(fresh.deviceServiceId, old.deviceServiceId)
        XCTAssertEqual(fresh.enrollmentEpoch, 1)
        let needs = await phone.store.needsSetUpAgain(owner: owner)
        XCTAssertFalse(needs)
    }

    func testARestoredRegistrationFileWithoutKeysIsDetected() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let original = try phone(server: server)
        _ = try await setUp(original)
        let old = try unwrap(await original.store.registration(owner: owner))
        // A new iPhone restored from backup: the file comes, the keys do not.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("restored"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("a/registrations.json"),
                                         to: folder.appendingPathComponent("restored/registrations.json"))
        let restored = try phone("restored", server: server)
        let status = await restored.lifecycle.refresh(owner: owner)
        XCTAssertEqual(status, .needsSetUpAgain)
        let state = await server.record(old.deviceServiceId)?.state
        XCTAssertEqual(state, .revoked)
    }

    func testRemovedElsewhereTurnsThisIPhoneOff() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let stored = try unwrap(await phone.store.registration(owner: owner))
        await server.revokeElsewhere(stored.deviceServiceId)
        let status = await phone.lifecycle.refresh(owner: owner)
        XCTAssertEqual(status, .off)
        XCTAssertEqual(phone.vault.keyCount, 0)
        let registration = await phone.store.registration(owner: owner)
        XCTAssertNil(registration)
    }

    func testOfflineRefreshKeepsAnExistingRegistration() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        await server.set(offline: true)
        let status = await phone.lifecycle.refresh(owner: owner)
        guard case .on = status else { return XCTFail("offline turned approvals off") }
    }

    func testTwoIPhonesAreIndependent() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let first = try phone("a", server: server)
        let second = try phone("b", server: server)
        _ = try await setUp(first, device: "PHONEA")
        _ = try await setUp(second, device: "PHONEB")
        let a = try unwrap(await first.store.registration(owner: owner))
        let b = try unwrap(await second.store.registration(owner: owner))
        XCTAssertNotEqual(a.deviceServiceId, b.deviceServiceId)
        XCTAssertNotEqual(a.approvalKeyId, b.approvalKeyId)
        let active = await server.activePhones()
        XCTAssertEqual(active.count, 2)
        _ = try await first.lifecycle.remove(owner: owner)
        let firstStatus = await first.lifecycle.refresh(owner: owner)
        let secondStatus = await second.lifecycle.refresh(owner: owner)
        XCTAssertEqual(firstStatus, .off)
        guard case .on = secondStatus else { return XCTFail("removing one iPhone removed the other") }
    }

    func testAnotherAccountNeverSeesThisRegistration() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let other = await phone.lifecycle.status(owner: "@other:atum.invalid")
        XCTAssertEqual(other, .off)
    }

    // MARK: Rotation

    func testRotationUsesThePreviousKeyAndTheNextEpoch() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let old = try unwrap(await phone.store.registration(owner: owner))
        let status = try await phone.lifecycle.rotate(owner: owner, identity: identity(), device: facts, reason: "r")
        guard case .on = status else { return XCTFail("not on") }
        let rotated = try unwrap(await phone.store.registration(owner: owner))
        XCTAssertEqual(rotated.deviceServiceId, old.deviceServiceId)
        XCTAssertEqual(rotated.enrollmentEpoch, 2)
        XCTAssertNotEqual(rotated.approvalKeyId, old.approvalKeyId)
        XCTAssertEqual(phone.vault.promptCount, 3, "new approval key and previous approval key")
        XCTAssertFalse(phone.vault.keysExist(for: old.namespace), "the previous generation is deleted")
        let record = await server.record(old.deviceServiceId)
        XCTAssertEqual(record?.enrollmentEpoch, 2)
        XCTAssertEqual(record?.approvalKeyId, rotated.approvalKeyId)
    }

    func testARotationWhoseAnswerWasLostIsSettledByTheNextRefresh() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let old = try unwrap(await phone.store.registration(owner: owner))
        let retryless = PhoneApprovalLifecycle(server: server, vault: phone.vault, registrations: phone.store,
                                               revocations: phone.queue, retryDelays: [])
        await server.loseNextEnrollAnswer()
        do {
            _ = try await retryless.rotate(owner: owner, identity: identity(), device: facts, reason: "r")
            XCTFail("rotation reported success")
        } catch {
            XCTAssertEqual(error, .offline)
        }
        let pending = try unwrap(await phone.store.registration(owner: owner))
        XCTAssertNotNil(pending.pendingGeneration)
        let status = await retryless.refresh(owner: owner)
        guard case .on = status else { return XCTFail("not on") }
        let settled = try unwrap(await phone.store.registration(owner: owner))
        XCTAssertNil(settled.pendingGeneration)
        XCTAssertEqual(settled.enrollmentEpoch, 2)
        XCTAssertFalse(phone.vault.keysExist(for: old.namespace))
    }

    func testRotationWithoutThePreviousKeyRecoversInstead() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        phone.vault.loseAllKeys()
        do {
            _ = try await phone.lifecycle.rotate(owner: owner, identity: identity(), device: facts, reason: "r")
            XCTFail("rotated without the previous key")
        } catch {
            XCTAssertEqual(error, .generic)
        }
        let status = await phone.lifecycle.status(owner: owner)
        XCTAssertEqual(status, .needsSetUpAgain)
    }

    // MARK: Storage

    func testAnUnreadableRegistrationFileFailsClosed() throws {
        let file = folder.appendingPathComponent("corrupt.json")
        try Data("{not json".utf8).write(to: file)
        XCTAssertThrowsError(try PhoneApprovalRegistrationStore(file: file))
    }

    func testRegistryDisplayNameRule() {
        XCTAssertEqual(PhoneApprovalDeviceFacts.registryName("  Lan\u{0007}’s iPhone "), "Lan’s iPhone")
        XCTAssertEqual(PhoneApprovalDeviceFacts.registryName(String(repeating: "😀", count: 40)).utf16.count, 64)
        XCTAssertEqual(PhoneApprovalDeviceFacts.registryName("\u{0001}"), "iPhone")
    }
}

/// A disk that can fill up on demand, for the store and the queue.
private final class DiskSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var isFull = false
    var full: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isFull }
        set { lock.lock(); isFull = newValue; lock.unlock() }
    }
    var writer: PhoneApprovalFileWriter {
        PhoneApprovalFileWriter { [self] data, url in
            if full { throw CocoaError(.fileWriteOutOfSpace) }
            try PhoneApprovalFileWriter.atomic.write(data, url)
        }
    }
}

/// Review findings on slice 2b (cross-family review, 14 Nov): each is an
/// interleaving or failure the lifecycle must survive.
extension PhoneApprovalLifecycleTests {
    private func waitUntil(_ condition: () async -> Bool, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out", line: line)
    }

    // Finding 1: sign-out while the enrolment POST is in flight, from a
    // lifecycle made for a replacement client (sharing the app's store).
    func testSignOutDuringAnInFlightEnrolmentRevokesTheLateSuccess() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let first = try phone(server: server)
        let replacement = try phone(server: server, vault: first.vault, sharing: first)
        _ = await first.lifecycle.refresh(owner: owner)
        await server.holdNextEnroll()
        let setUpTask = Task { () -> PhoneApprovalSetupFailure? in
            do { _ = try await self.setUp(first); return nil } catch { return error as? PhoneApprovalSetupFailure }
        }
        await waitUntil { await server.enrollIsHeld }
        let journalled = await first.store.pending(owner: owner)
        XCTAssertEqual(journalled.count, 1, "the attempt is journalled before the POST")
        let result = await replacement.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertTrue(result.allowsSignOut)
        XCTAssertEqual(first.vault.keyCount(owner: owner), 0, "sign-out deleted the attempt's keys")
        await server.releaseEnroll()
        let failure = await setUpTask.value
        XCTAssertEqual(failure, .generic, "a completion after sign-out is never reported as set up")
        let registration = await first.store.registration(owner: owner)
        XCTAssertNil(registration, "the late success was not saved")
        XCTAssertEqual(first.vault.keyCount(owner: owner), 0)
        let active = await server.activePhones()
        XCTAssertTrue(active.isEmpty, "the late registration was revoked")
        let pending = await first.store.pending(owner: owner)
        XCTAssertTrue(pending.isEmpty)
    }

    // Finding 1, the other window: sign-out during the prompt sends nothing.
    func testSignOutBeforeThePostSendsNothing() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let first = try phone(server: server)
        _ = await first.lifecycle.refresh(owner: owner)
        let epoch = await first.store.epoch(owner: owner)
        await first.store.fence(owner: owner)   // as if sign-out ran during Face ID
        let moved = await first.store.epoch(owner: owner)
        XCTAssertNotEqual(epoch, moved)
        // A set-up that began before the fence cannot even journal.
        let attempt = PhoneApprovalPendingAttempt(owner: owner, deviceServiceId: UUID(), installation: UUID(),
                                                  generation: UUID(), kind: .enroll)
        do { try await first.store.begin(attempt, epoch: epoch); XCTFail("began after a fence") }
        catch { XCTAssertEqual(error as? PhoneApprovalStoreFailure, .fenced) }
    }

    // Finding 2: the first POST lands but its answer is lost; the retry is
    // refused. The registration that exists must still be revoked.
    func testARefusalAfterALostAnswerStillRevokes() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        await server.script([.lose, .fail(PhoneApprovalScriptedServer.error(403, "rotation_unauthorized"))])
        await expectFailure(.refused, phone)
        let active = await server.activePhones()
        XCTAssertTrue(active.isEmpty, "the first, admitted attempt was revoked")
        let revokes = await server.revokeCalls
        XCTAssertEqual(revokes.count, 1)
        XCTAssertEqual(phone.vault.keyCount, 0)
        let pending = await phone.store.pending(owner: owner)
        XCTAssertTrue(pending.isEmpty)
    }

    // Finding 3: the POST succeeds, then the disk is full: neither the
    // registration nor the revocation can be written. The journalled ID
    // survives on disk and a later refresh revokes it.
    func testAFullDiskAfterThePostKeepsTheIDUntilItIsRevoked() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let disk = DiskSwitch()
        let phone = try phone(server: server, writer: disk.writer)
        _ = await phone.lifecycle.refresh(owner: owner)
        await server.holdNextEnroll()
        let setUpTask = Task { () -> PhoneApprovalSetupFailure? in
            do { _ = try await self.setUp(phone); return nil } catch { return error as? PhoneApprovalSetupFailure }
        }
        await waitUntil { await server.enrollIsHeld }
        disk.full = true
        await server.releaseEnroll()
        let failure = await setUpTask.value
        XCTAssertEqual(failure, .generic)
        let admitted = await server.activePhones()
        XCTAssertEqual(admitted.count, 1, "the server registered it")
        // Restart: the file still names the attempt.
        let reopened = try PhoneApprovalRegistrationStore(file: folder.appendingPathComponent("a/registrations.json"))
        let journal = await reopened.pending(owner: owner)
        XCTAssertEqual(journal.map(\.deviceServiceId), admitted.map(\.deviceServiceId))
        disk.full = false
        let queue = try PhoneRevocationQueue(file: folder.appendingPathComponent("a/revocations.json"))
        let restarted = PhoneApprovalLifecycle(server: server, vault: phone.vault, registrations: reopened,
                                               revocations: queue, retryDelays: [])
        _ = await restarted.refresh(owner: owner)
        let active = await server.activePhones()
        XCTAssertTrue(active.isEmpty, "the journalled ID was revoked")
        let after = await reopened.pending(owner: owner)
        XCTAssertTrue(after.isEmpty)
    }

    // Finding 4: an undecodable state file is set aside and salvaged, so a
    // registration in it is still revoked and its keys deleted.
    func testAnUndecodableStateFileIsSalvagedAndStillRevoked() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let id = try unwrap(await phone.store.registration(owner: owner)).deviceServiceId
        let file = folder.appendingPathComponent("a/registrations.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        root["installation"] = 42   // no longer decodes
        try JSONSerialization.data(withJSONObject: root).write(to: file)
        XCTAssertThrowsError(try PhoneApprovalRegistrationStore(file: file))
        let recovered = try PhoneApprovalRegistrationStore.recovering(file: file)
        let salvaged = await recovered.pending(owner: owner)
        XCTAssertEqual(salvaged.map(\.deviceServiceId), [id])
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("a").path)
        XCTAssertTrue(kept.contains { $0.contains("corrupt-") }, "the damaged file is kept, not deleted")
        let lifecycle = PhoneApprovalLifecycle(server: server, vault: phone.vault, registrations: recovered,
                                               revocations: phone.queue, retryDelays: [])
        let result = await lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertTrue(result.allowsSignOut)
        XCTAssertEqual(phone.vault.keyCount(owner: owner), 0)
        let state = await server.record(id)?.state
        XCTAssertEqual(state, .revoked)
    }

    func testAnUndecodableQueueIsSalvaged() async throws {
        let file = folder.appendingPathComponent("q/revocations.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        try Data("{\"entries\":[{\"owner\":\"\(owner)\",\"id\":\"\(id.uuidString)\"}]}".utf8).write(to: file)
        XCTAssertThrowsError(try PhoneRevocationQueue(file: file))
        let queue = try PhoneRevocationQueue.recovering(file: file)
        let pending = await queue.pending(owner: owner)
        XCTAssertEqual(pending.map(\.id), [id])
    }

    // Finding 4: no state files at all. Sign-out deletes every key of the
    // owner and revokes by Matrix device; offline it is held; with no client
    // the deleted keys are enough.
    func testSignOutWithoutStateDeletesKeysAndRevokesByDevice() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        await server.set(offline: true)
        let offline = await PhoneApprovalLifecycle.signOutWithoutState(owner: owner, matrixDeviceID: "PHONEA",
                                                                        server: server, vault: phone.vault)
        XCTAssertTrue(offline.keysDeleted)
        XCTAssertFalse(offline.allowsSignOut, "nothing recorded and nothing revoked: held until online")
        await server.set(offline: false)
        let online = await PhoneApprovalLifecycle.signOutWithoutState(owner: owner, matrixDeviceID: "PHONEA",
                                                                       server: server, vault: phone.vault)
        XCTAssertTrue(online.allowsSignOut)
        let active = await server.activePhones()
        XCTAssertTrue(active.isEmpty)
        let noClient = await PhoneApprovalLifecycle.signOutWithoutState(owner: owner, matrixDeviceID: "PHONEA",
                                                                         server: nil, vault: phone.vault)
        XCTAssertTrue(noClient.allowsSignOut)
        phone.vault.failDeletes = true
        let other = try self.phone("b", server: server, vault: phone.vault)
        _ = try? await setUp(other, device: "PHONEB")
        let stuck = await PhoneApprovalLifecycle.signOutWithoutState(owner: owner, matrixDeviceID: "PHONEB",
                                                                      server: nil, vault: phone.vault)
        XCTAssertFalse(stuck.allowsSignOut, "a key that cannot be deleted holds sign-out")
    }

    // Finding 5: a refresh whose list answer arrives after the person
    // removed A and set up B must not drop B.
    func testAStaleRefreshNeverDropsTheReplacement() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        await server.holdNextList()
        let refreshTask = Task { await phone.lifecycle.refresh(owner: owner) }
        await waitUntil { await server.listIsHeld }
        _ = try await phone.lifecycle.remove(owner: owner)
        _ = try await setUp(phone)
        let replacement = try unwrap(await phone.store.registration(owner: owner))
        await server.releaseList()   // answers with A revoked, B active
        _ = await refreshTask.value
        let after = await phone.store.registration(owner: owner)
        XCTAssertEqual(after, replacement, "the stale answer was not applied to B")
        XCTAssertTrue(phone.vault.keysExist(for: replacement.namespace))
        let record = await server.record(replacement.deviceServiceId)
        XCTAssertEqual(record?.state, .active)
    }

    // Finding 6: offline removal with a Keychain that refuses to delete.
    func testAKeychainFailureKeepsTheNamespaceAndIsRetried() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        let registration = try unwrap(await phone.store.registration(owner: owner))
        await server.set(offline: true)
        phone.vault.failDeletes = true
        do { _ = try await phone.lifecycle.remove(owner: owner); XCTFail("removal hid a key it could not delete") }
        catch { XCTAssertEqual(error, .keysRemain) }
        let orphans = await phone.store.orphans()
        XCTAssertEqual(orphans.map(\.generation), [registration.generation])
        XCTAssertTrue(phone.vault.keysExist(for: registration.namespace))
        let pending = await phone.lifecycle.pendingRevocations(owner: owner)
        XCTAssertEqual(pending, [registration.deviceServiceId], "the revocation is still recorded")
        phone.vault.failDeletes = false
        await server.set(offline: false)
        _ = await phone.lifecycle.refresh(owner: owner)
        XCTAssertFalse(phone.vault.keysExist(for: registration.namespace), "deletion was retried")
        let cleared = await phone.store.orphans()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testSignOutIsHeldWhileAKeyCannotBeDeletedAndTheServerIsUnreachable() async throws {
        let server = PhoneApprovalScriptedServer(owner: owner)
        let phone = try phone(server: server)
        _ = try await setUp(phone)
        phone.vault.failDeletes = true
        await server.set(offline: true)
        let held = await phone.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertFalse(held.keysDeleted)
        XCTAssertFalse(held.allowsSignOut, "a usable key would survive sign-out")
        await server.set(offline: false)
        let revoked = await phone.lifecycle.signOut(owner: owner, matrixDeviceID: "PHONEA")
        XCTAssertTrue(revoked.serverRevoked)
        XCTAssertTrue(revoked.allowsSignOut, "the server revoked the key that is still here")
    }
}
