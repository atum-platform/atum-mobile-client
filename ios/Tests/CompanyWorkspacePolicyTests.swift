import Foundation
import XCTest
@testable import AtumNativeAPI

final class CompanyWorkspacePolicyTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-2a39c7cf131c"
    private let defaultChannel = "00000000-0000-4000-8000-c52538d87a60"
    private let readyChannel = "00000000-0000-4000-8000-08deeedbba36"
    private let readyRoom = "!AbCdEf123:example.invalid"

    private func fixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.1", withExtension: nil))
        return try Data(contentsOf: base.appendingPathComponent(name))
    }

    private func directory() throws -> CompanyChannelDirectory {
        let read = try CompanyWorkspaceWire.decodeChannelDirectory(
            try fixture("channel-directory.response.json"))
        return try XCTUnwrap(read.value)
    }

    private func emptyDirectory() throws -> CompanyChannelDirectory {
        let read = try CompanyWorkspaceWire.decodeChannelDirectory(
            try fixture("channel-directory-empty.response.json"))
        return try XCTUnwrap(read.value)
    }

    private func acknowledgement(state: String, retired: Bool = false) throws -> CompanyLeaveAcknowledgement {
        let body = Data("""
        {"schemaVersion":2,"companyId":"\(company)","state":"\(state)",
         "retired":\(retired),"authorityGeneration":9}
        """.utf8)
        return try CompanyWorkspaceWire.decodeLeave(body)
    }

    // MARK: Classification

    func testCompanyChannelsAreClassifiedOnlyByTheDirectoryRoomID() throws {
        var rooms = CompanyRoomDirectory()
        rooms.absorb(try directory(), companyID: try NativeID(company))
        let claim = try XCTUnwrap(rooms.claim(roomID: readyRoom))
        XCTAssertEqual(claim.companyID, company)
        XCTAssertEqual(claim.channelID, readyChannel)
        XCTAssertEqual(claim.displayName, "Thiết kế")
        XCTAssertFalse(claim.isDefault)
        XCTAssertTrue(rooms.isCompanyChannel(readyRoom))
        // A room the directory does not name is an ordinary group, even when
        // it has many members.
        XCTAssertNil(rooms.claim(roomID: "!not-a-company-room:example.invalid"))
    }

    func testClassificationSurvivesReconciliationAndDirectoryRefresh() throws {
        var rooms = CompanyRoomDirectory()
        rooms.absorb(try directory(), companyID: try NativeID(company))
        // A refresh that omits the room (manager reconciling) and a rebuilt
        // room list must not demote the room to an ordinary group.
        rooms.absorb(try emptyDirectory(), companyID: try NativeID(company))
        XCTAssertEqual(rooms.claim(roomID: readyRoom)?.companyID, company)
        // Leaving/removal ends the claims with the company.
        rooms.retain(companies: [company])
        XCTAssertNotNil(rooms.claim(roomID: readyRoom))
        rooms.retain(companies: [])
        XCTAssertNil(rooms.claim(roomID: readyRoom))
        XCTAssertTrue(rooms.isEmpty)
    }

    func testRemovingOneCompanyKeepsAnother() throws {
        var rooms = CompanyRoomDirectory()
        rooms.absorb(try directory(), companyID: try NativeID(company))
        let other = try NativeID("00000000-0000-4000-8000-48f58564068b")
        rooms.absorb(try directory(), companyID: other)
        rooms.remove(companyID: company)
        XCTAssertNil(rooms.claim(roomID: readyRoom))
        rooms.clear()
        XCTAssertTrue(rooms.isEmpty)
    }

    // MARK: Leave

    func testLeaveIsKeptUntilRemoved() throws {
        var tracker = CompanyLeaveTracker()
        tracker.begin(companyID: company, requestID: "00000000-0000-4000-8000-175097128f22")
        XCTAssertTrue(tracker.isPending)
        XCTAssertFalse(tracker.apply(try acknowledgement(state: "revoking")))
        XCTAssertTrue(tracker.isPending, "revoking is not the acknowledgement: the ban is not witnessed yet")
        XCTAssertTrue(tracker.apply(try acknowledgement(state: "removed")))
        XCTAssertFalse(tracker.isPending)
    }

    func testRetiredCompanyFinishesAPendingLeave() throws {
        var tracker = CompanyLeaveTracker()
        tracker.begin(companyID: company, requestID: "00000000-0000-4000-8000-175097128f22")
        XCTAssertTrue(tracker.apply(try acknowledgement(state: "revoking", retired: true)))
        XCTAssertFalse(tracker.isPending)
    }

    func testLeaveStopsOnRefusalsButSurvivesTransportFailures() {
        var tracker = CompanyLeaveTracker()
        tracker.begin(companyID: company, requestID: "00000000-0000-4000-8000-175097128f22")
        tracker.apply(.unavailable)
        tracker.apply(.transport)
        tracker.apply(.refused(.limit, reason: "invite_lookup_limited", retryAfter: 60))
        XCTAssertTrue(tracker.isPending)
        tracker.apply(.refused(.conflict, reason: "last_admin", retryAfter: nil))
        XCTAssertFalse(tracker.isPending)
    }

    func testLeaveJournalRoundTrips() throws {
        let suite = "company-leave-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = CompanyLeaveJournal(defaults: defaults)
        var tracker = journal.load()
        XCTAssertFalse(tracker.isPending)
        tracker.begin(companyID: company, requestID: "00000000-0000-4000-8000-175097128f22")
        journal.save(tracker)
        XCTAssertEqual(journal.load(), tracker)
        tracker = CompanyLeaveTracker()
        journal.save(tracker)
        XCTAssertFalse(journal.load().isPending)
    }

    // MARK: Notice

    func testCompanyChannelsShowTheNonE2EELineUntilTheFirstMessage() {
        XCTAssertTrue(CompanyChannelNotice.isRequired(isCompanyChannel: true, roomEncrypted: false))
        XCTAssertTrue(CompanyChannelNotice.isRequired(isCompanyChannel: true, roomEncrypted: nil))
        XCTAssertFalse(CompanyChannelNotice.isRequired(isCompanyChannel: true, roomEncrypted: true))
        XCTAssertFalse(CompanyChannelNotice.isRequired(isCompanyChannel: false, roomEncrypted: false))
        XCTAssertTrue(CompanyChannelNotice.showsAboveComposer(required: true, hasOwnMessage: false))
        XCTAssertFalse(CompanyChannelNotice.showsAboveComposer(required: true, hasOwnMessage: true))
        XCTAssertFalse(CompanyChannelNotice.showsAboveComposer(required: false, hasOwnMessage: false))
    }

    // MARK: Degrade

    func testV1AndOneOneWriteRefusalsDegradeButTransportDoesNot() {
        XCTAssertTrue(CompanyWireDegrade.shouldDegrade(CompanyWireRefusal.v1Answer))
        XCTAssertTrue(CompanyWireDegrade.shouldDegrade(
            CompanyAPIError.refused(.invalid, reason: nil, retryAfter: nil)))
        XCTAssertTrue(CompanyWireDegrade.shouldDegrade(
            CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil)))
        XCTAssertFalse(CompanyWireDegrade.shouldDegrade(
            CompanyAPIError.refused(.denied, reason: nil, retryAfter: nil)))
        XCTAssertFalse(CompanyWireDegrade.shouldDegrade(CompanyAPIError.transport))
        XCTAssertFalse(CompanyWireDegrade.shouldDegrade(CompanyAPIError.unavailable))
        XCTAssertFalse(CompanyWireDegrade.shouldDegrade(
            CompanyAPIError.refused(.limit, reason: nil, retryAfter: 10)))
    }

    // MARK: Convergence

    func testConvergenceJoinsAnInvitationThenOpensTheJoinedRoom() throws {
        let directory = try directory()
        let room = try XCTUnwrap(CompanyConvergence.targetRoomID(in: directory,
                                                                 preferredChannelID: nil))
        XCTAssertEqual(room, readyRoom, "the seeded default is not provisioned yet; the ready channel wins")
        XCTAssertEqual(CompanyConvergence.step(attempt: 0, directory: directory,
                                               preferredChannelID: nil, presence: .invited),
                       .join(roomID: readyRoom))
        XCTAssertEqual(CompanyConvergence.step(attempt: 1, directory: directory,
                                               preferredChannelID: nil, presence: .joined),
                       .open(roomID: readyRoom))
        XCTAssertEqual(CompanyConvergence.step(attempt: 1, directory: directory,
                                               preferredChannelID: nil, presence: .absent),
                       .wait)
        XCTAssertEqual(CompanyConvergence.step(attempt: 1, directory: directory,
                                               preferredChannelID: nil, presence: .unknown),
                       .wait)
    }

    func testConvergencePrefersTheAcceptedChannelsDefaultAndGivesUpBounded() throws {
        let both = try CompanyWorkspaceWire.decodeChannelDirectory(Data("""
        {"schemaVersion":2,"channels":[
          {"schemaVersion":2,"channel":{"id":"\(defaultChannel)","companyId":"\(company)",
           "displayName":"general","visibility":"company","state":"active","projectId":null,
           "authorityGeneration":7,"channelGeneration":1,"systemKey":"default"},
           "memberCount":3,"room":{"state":"ready","roomId":"!general:example.invalid"}},
          {"schemaVersion":2,"channel":{"id":"\(readyChannel)","companyId":"\(company)",
           "displayName":"Thiết kế","visibility":"company","state":"active","projectId":null,
           "authorityGeneration":7,"channelGeneration":1},
           "memberCount":2,"room":{"state":"ready","roomId":"\(readyRoom)"}}
        ]}
        """.utf8)).value!
        XCTAssertEqual(CompanyConvergence.targetRoomID(in: both, preferredChannelID: defaultChannel),
                       "!general:example.invalid")
        XCTAssertEqual(CompanyConvergence.targetRoomID(in: both, preferredChannelID: nil),
                       "!general:example.invalid")
        XCTAssertEqual(CompanyConvergence.step(attempt: CompanyConvergence.attempts,
                                               directory: both, preferredChannelID: nil,
                                               presence: .joined), .giveUp)
        XCTAssertEqual(CompanyConvergence.step(attempt: -1, directory: both,
                                               preferredChannelID: nil, presence: .joined), .giveUp)
    }

    func testConvergenceWaitsWithoutADirectory() {
        XCTAssertEqual(CompanyConvergence.step(attempt: 0, directory: nil,
                                               preferredChannelID: nil, presence: .joined), .wait)
    }

    // MARK: Create

    func testACompanyNameIsShapedTheWayThePlatformRequiresBeforeItIsSent() {
        XCTAssertEqual(CompanyName.normalized("  Công ty Atum \n"), "Công ty Atum")
        // A paste can carry control characters; they become spaces, not a refusal.
        XCTAssertEqual(CompanyName.normalized("Anka\tLabs"), "Anka Labs")
        XCTAssertEqual(CompanyName.normalized("\u{FEFF}Anka\u{FEFF}"), "Anka")
        XCTAssertNil(CompanyName.normalized(""))
        XCTAssertNil(CompanyName.normalized("   \n\t "))
        // The platform counts UTF-16 units, so an astral character costs two.
        XCTAssertNotNil(CompanyName.normalized(String(repeating: "a", count: 120)))
        XCTAssertNil(CompanyName.normalized(String(repeating: "a", count: 121)))
        XCTAssertNotNil(CompanyName.normalized(String(repeating: "😀", count: 60)))
        XCTAssertNil(CompanyName.normalized(String(repeating: "😀", count: 61)))
        XCTAssertTrue(CompanyName.isAtLimit(String(repeating: "a", count: 120)))
        XCTAssertFalse(CompanyName.isAtLimit(String(repeating: "a", count: 119)))
    }

    func testEveryShapedNameIsExactlyWhatThePlatformAccepts() throws {
        let samples = ["Anka", "  Anka  ", "Công ty\nAtum", "😀 Studio", "a\u{0007}b", "\u{00A0}Anka\u{00A0}"]
        for sample in samples {
            let name = try XCTUnwrap(CompanyName.normalized(sample), sample.debugDescription)
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(name.unicodeScalars.contains { $0.value <= 31 || $0.value == 127 })
            XCTAssertTrue((1...120).contains(name.utf16.count))
            XCTAssertEqual(CompanyName.normalized(name), name, "shaping is idempotent")
        }
    }

    func testCreateFailuresAreTheRefusalTheyAreAndOnlyALostAnswerMayHaveCommitted() {
        XCTAssertEqual(CompanyCreateFailure(.refused(.denied, reason: "company_creation_closed", retryAfter: nil)),
                       .closed)
        XCTAssertEqual(CompanyCreateFailure(.refused(.denied, reason: nil, retryAfter: nil)), .denied)
        XCTAssertEqual(CompanyCreateFailure(.refused(.invalid, reason: nil, retryAfter: nil)), .invalidName)
        XCTAssertEqual(CompanyCreateFailure(.refused(.conflict, reason: nil, retryAfter: nil)), .conflict)
        XCTAssertEqual(CompanyCreateFailure(.refused(.limit, reason: nil, retryAfter: 30)), .limit)
        XCTAssertEqual(CompanyCreateFailure(.refused(.authentication, reason: nil, retryAfter: nil)),
                       .authentication)
        for lost in [CompanyAPIError.transport, .unavailable, .invalid] {
            let failure = CompanyCreateFailure(lost)
            XCTAssertEqual(failure, .unavailable)
            XCTAssertTrue(failure.mayHaveCommitted, "a lost answer can hide a company that exists")
        }
        for refused in [CompanyCreateFailure.closed, .invalidName, .denied, .conflict, .limit, .authentication] {
            XCTAssertFalse(refused.mayHaveCommitted)
        }
    }

    func testARetryOfTheSameNameAfterALostAnswerReplaysTheSameRequest() {
        var ids = ["id-1", "id-2", "id-3"]
        let make = { ids.removeFirst() }
        var tracker = CompanyCreateTracker()
        let first = tracker.attempt(for: "Anka", makeRequestID: make)
        XCTAssertEqual(first.requestID, "id-1")
        tracker.failed(.unavailable)
        XCTAssertEqual(tracker.attempt(for: "Anka", makeRequestID: make).requestID, "id-1",
                       "the platform answers the same company instead of creating a second one")
        // Another name is another company.
        XCTAssertEqual(tracker.attempt(for: "Studio", makeRequestID: make).requestID, "id-2")
        // A refusal ends the attempt; the next try is new.
        tracker.failed(.invalidName)
        XCTAssertNil(tracker.pending)
        XCTAssertEqual(tracker.attempt(for: "Studio", makeRequestID: make).requestID, "id-3")
        tracker.succeeded()
        XCTAssertNil(tracker.pending)

        // Editing the name abandons the attempt even when it may have committed.
        ids = ["id-4"]
        _ = tracker.attempt(for: "Anka", makeRequestID: make)
        tracker.failed(.unavailable)
        XCTAssertNotNil(tracker.pending)
        tracker.abandoned()
        XCTAssertNil(tracker.pending)
    }

    // MARK: Switcher foot

    func testTheClosedNoteIsOnlyForAnAccountWithNoCompany() {
        XCTAssertEqual(CompanySwitcherFooter.resolve(canCreate: false, companyCount: 0), .closedNote,
                       "empty state: say creating is not open")
        XCTAssertEqual(CompanySwitcherFooter.resolve(canCreate: false, companyCount: 1), .nothing,
                       "one company: no dead-end line")
        XCTAssertEqual(CompanySwitcherFooter.resolve(canCreate: false, companyCount: 3), .nothing)
    }

    func testAnAccountThatCanCreateIsOfferedCreateWithOrWithoutCompanies() {
        XCTAssertEqual(CompanySwitcherFooter.resolve(canCreate: true, companyCount: 0), .create)
        XCTAssertEqual(CompanySwitcherFooter.resolve(canCreate: true, companyCount: 2), .create)
    }
}
