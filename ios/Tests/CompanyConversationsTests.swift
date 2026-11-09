import CryptoKit
import Foundation
import XCTest
@testable import AtumNativeAPI

/// Company DMs and group DMs (`atum.company-workspace/1.5`), against the frozen
/// pack copied verbatim from atum-platform@bee273b7422b:spec/company-workspace/v1.5
/// (vendored by atum-app, mirrored here). The company, people and names are the
/// pack's own generic ones: nothing here is a real company.
final class CompanyConversationsTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-87c6455cae48"
    private let conversation = "00000000-0000-4000-8000-f6c6b8bb709f"
    private let anh = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
    private let bao = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"
    private let chi = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM"

    // MARK: Fixtures

    private func packURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.5", withExtension: nil))
    }

    private func pack(_ file: String) throws -> Data {
        try Data(contentsOf: packURL().appendingPathComponent(file))
    }

    private func object(_ file: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: pack(file)) as? [String: Any])
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func directory() throws -> CompanyConversationDirectory {
        try CompanyConversationWire.decodeDirectory(pack("fixtures/conversation-directory.response.json"))
    }

    private func groupAnswer() throws -> CompanyConversationAnswer {
        try CompanyConversationWire.decodeAnswer(pack("fixtures/conversation-group.response.json"))
    }

    // MARK: The pack

    func testTheVendoredPackIsTheExactFrozenOne() throws {
        let vendored = try XCTUnwrap(object("VENDORED.json")["sha256"] as? String)
        let pinned = try String(decoding: pack("PINNED-SHA256"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(pinned, vendored)
        let contract = try object("contract.json")
        XCTAssertEqual(contract["version"] as? String, "1.5")
        var hash = SHA256()
        for file in try XCTUnwrap(contract["pack_files"] as? [String]) {
            let name = Data(file.utf8)
            let body = try pack(file)
            hash.update(data: lengthPrefix(UInt32(name.count), bytes: 4))
            hash.update(data: name)
            hash.update(data: lengthPrefix(UInt64(body.count), bytes: 8))
            hash.update(data: body)
        }
        XCTAssertEqual(hash.finalize().map { String(format: "%02x", $0) }.joined(), vendored)
        XCTAssertEqual(try XCTUnwrap(object("VENDORED.json")["path"] as? String), "spec/company-workspace/v1.5")
    }

    private func lengthPrefix<T: FixedWidthInteger>(_ value: T, bytes: Int) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0.suffix(bytes)) }
    }

    /// Every message family in the pack goes through the strict Swift parser it
    /// was written for, and accept/reject agree with the pack.
    func testEveryConsumedFixtureAgreesWithItsExpectation() throws {
        let contract = try object("contract.json")
        let fixtures = try XCTUnwrap(contract["fixtures"] as? [[String: Any]])
        // Producer-side relation fixtures; the vectors are run separately.
        let notConsumed: Set<String> = ["conversation-open.trace", "participant-digest.vector"]
        var consumed = 0
        for fixture in fixtures {
            guard let message = fixture["message"] as? String, !notConsumed.contains(message) else { continue }
            let file = try XCTUnwrap(fixture["file"] as? String)
            let expected = fixture["expect"] as? String
            let accepted = try accepts(message: message, data: pack(file))
            XCTAssertEqual(accepted, expected == "accept", "\(file) must be \(expected ?? "?")ed")
            consumed += 1
        }
        XCTAssertGreaterThanOrEqual(consumed, 15, "no fixture family is silently skipped")
    }

    private func accepts(message: String, data: Data) throws -> Bool {
        switch message {
        case "conversation-directory.response":
            return (try? CompanyConversationWire.decodeDirectory(data)) != nil
        case "conversation-open.response":
            return (try? CompanyConversationWire.decodeAnswer(data)) != nil
        case "conversation-hidden.response":
            return (try? CompanyConversationWire.decodeHidden(data)) != nil
        case "conversation-open.request":
            return openRequestIsValid(data)
        case "conversation-expand.request":
            return expandRequestIsValid(data)
        case "conversation-hidden.request":
            return hiddenRequestIsValid(data)
        case "conversation.error.response":
            return errorIsUnderstood(data, requiresReason: true)
        case "legacy-conversation.error.response":
            return errorIsUnderstood(data, requiresReason: false)
        default:
            XCTFail("a fixture family without a parser: \(message)")
            return false
        }
    }

    /// The request shapes the encoders send, checked the way a server would.
    private func openRequestIsValid(_ data: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(body.keys) == ["requestId", "participantMemberRefs"],
              let id = body["requestId"] as? String, (try? NativeID(id)) != nil,
              let refs = body["participantMemberRefs"] as? [String] else { return false }
        return ConversationPeople.isWellFormed(refs)
    }

    private func expandRequestIsValid(_ data: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(body.keys) == ["requestId", "sourceConversationId", "participantMemberRefs"],
              let id = body["requestId"] as? String, (try? NativeID(id)) != nil,
              let source = body["sourceConversationId"] as? String, (try? NativeID(source)) != nil,
              let refs = body["participantMemberRefs"] as? [String] else { return false }
        return ConversationPeople.isWellFormed(refs) && refs.count >= 3
    }

    private func hiddenRequestIsValid(_ data: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(body.keys) == ["requestId", "hidden"],
              let id = body["requestId"] as? String, (try? NativeID(id)) != nil,
              body["hidden"] is Bool else { return false }
        return true
    }

    /// A refusal is understood when its body is the closed error shape, and a
    /// reason (if any) is one of the conversation family's for that status.
    private func errorIsUnderstood(_ data: Data, requiresReason: Bool) -> Bool {
        guard let response = try? NativeAPI.decode(NativeErrorResponse.self, from: data) else { return false }
        let error = CompanyAPIError(.http(NativeHTTPFailureStub.make(response)))
        let refusal = ConversationRefusal(error)
        if case .plain = refusal { return !requiresReason && response.details == nil }
        return true
    }

    // MARK: Digest

    func testTheDigestMatchesTheNormativeVectors() throws {
        for name in ["participant-digest-dm", "participant-digest-group"] {
            let vector = try object("fixtures/\(name).vector.json")
            let kind = try XCTUnwrap(CompanyConversationKind(rawValue: try XCTUnwrap(vector["kind"] as? String)))
            let people = try XCTUnwrap(vector["participants"] as? [[String: Any]]).map {
                (memberRef: $0["memberRef"] as! String, admissionEpoch: ($0["admissionEpoch"] as! NSNumber).int64Value)
            }
            let companyID = try XCTUnwrap(vector["companyId"] as? String)
            let expected = try XCTUnwrap(vector["participantSetDigest"] as? String)
            XCTAssertEqual(CompanyConversationDigest.digest(companyID: companyID, kind: kind, participants: people),
                           expected, name)
            // Request order is irrelevant: the preimage sorts by the ref's bytes.
            XCTAssertEqual(CompanyConversationDigest.digest(companyID: companyID, kind: kind,
                                                            participants: people.reversed()), expected, name)
        }
    }

    func testTheDigestChangesWithTheCompanyTheKindAndEveryAdmissionEpoch() throws {
        let people = [(memberRef: anh, admissionEpoch: Int64(2)), (memberRef: bao, admissionEpoch: Int64(1))]
        let base = CompanyConversationDigest.digest(companyID: company, kind: .dm, participants: people)
        XCTAssertEqual(base, "049af09dc4dc0ef5cc4c7fa27f5c732cd077270b40fd8a5b3ed24adda9d55a76")
        XCTAssertNotEqual(CompanyConversationDigest.digest(
            companyID: "00000000-0000-4000-8000-c70f27930704", kind: .dm, participants: people), base)
        XCTAssertNotEqual(CompanyConversationDigest.digest(companyID: company, kind: .groupDM,
                                                           participants: people), base)
        // A readmission is another membership epoch, so another conversation.
        XCTAssertNotEqual(CompanyConversationDigest.digest(
            companyID: company, kind: .dm,
            participants: [(memberRef: anh, admissionEpoch: 3), people[1]]), base)
    }

    // MARK: Capability probe

    private func capabilities(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var base = try capabilityFixture("capabilities-active.response.json")
        var activation = base["activation"] as! [String: Any]
        activation["companyConversations"] = "active"
        base["activation"] = activation
        edit(&base)
        return try json(base)
    }

    private func capabilityFixture(_ name: String) throws -> [String: Any] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.3-capabilities",
                                                  withExtension: nil))
        return try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
    }

    func testTheSectionIsOfferedOnlyWhenTheWireTheFeatureAndTheActivationAllSayYes() throws {
        XCTAssertTrue(try CompanyConversationWire.decodeCapabilities(capabilities()).offersConversations)

        // Activation off (the pack's own capabilities-active fixture).
        let activeFixture = try CompanyConversationWire.decodeCapabilities(
            Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.3-capabilities",
                                                         withExtension: nil))
                .appendingPathComponent("capabilities-active.response.json")))
        XCTAssertFalse(activeFixture.offersConversations)

        // The feature off, the wire named.
        XCTAssertFalse(try CompanyConversationWire.decodeCapabilities(capabilities {
            var features = $0["features"] as! [String: Any]
            features["companyConversations"] = false
            $0["features"] = features
        }).offersConversations)

        // The wire not named (a 1.4 server), feature and activation on.
        XCTAssertFalse(try CompanyConversationWire.decodeCapabilities(capabilities {
            $0["supportedWireVersions"] = ["1", "1.1", "1.2", "1.3", "1.4"]
        }).offersConversations)
    }

    func testTheProbeIsStrict() throws {
        // A key this build does not know is not an answer (the pack's extra fixture).
        let extra = try json(capabilityFixture("capabilities-extra.response.json"))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(extra))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities { $0["schemaVersion"] = 3 }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities { $0["wireVersion"] = "1.5" }))
        // The wires are one ordered prefix.
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities {
            $0["supportedWireVersions"] = ["1", "1.1", "1.2", "1.3", "1.5"]
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities {
            $0["supportedWireVersions"] = ["1", "1.1", "1.2"]
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities {
            var activation = $0["activation"] as! [String: Any]
            activation["companyConversations"] = "on"
            $0["activation"] = activation
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(capabilities {
            $0["unexpected"] = true
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeCapabilities(Data("[]".utf8)))
    }

    // MARK: Answers

    func testTheDirectoryDecodesThePacksDmAndTheGroupAnswerItsGroup() throws {
        let dm = try XCTUnwrap(directory().conversations.first)
        XCTAssertEqual(dm.kind, .dm)
        XCTAssertEqual(dm.state, .active)
        XCTAssertEqual(dm.participants.map(\.memberRef), [anh, bao])
        XCTAssertEqual(dm.room.roomId, "!dm:example.invalid")
        XCTAssertFalse(dm.hidden)
        let group = try groupAnswer().conversation
        XCTAssertEqual(group.kind, .groupDM)
        XCTAssertEqual(group.participants.count, 3)
        XCTAssertEqual(group.room.state, "provisioning")
        XCTAssertNil(group.room.roomId)
    }

    func testAnAnswerWithAForgedDigestIsNotAnAnswer() throws {
        var answer = try object("fixtures/conversation-open.response.json")
        var conversation = answer["conversation"] as! [String: Any]
        conversation["participantSetDigest"] = String(repeating: "0", count: 64)
        answer["conversation"] = conversation
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(json(answer)))
    }

    func testAnAnswerBreakingTheClosedShapeIsRefused() throws {
        func edit(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var answer = try object("fixtures/conversation-open.response.json")
            var conversation = answer["conversation"] as! [String: Any]
            change(&conversation)
            answer["conversation"] = conversation
            return try json(answer)
        }
        // A key outside the shape (a private address, say) is not tolerated.
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit { $0["email"] = "x@example.test" }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit {
            var people = $0["participants"] as! [[String: Any]]
            people[0]["principal"] = "x"
            $0["participants"] = people
        }))
        // A DM has two; a group three to nine.
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit { $0["kind"] = "group_dm" }))
        // A room that is not ready cannot carry an id, and a ready one must.
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit {
            $0["room"] = ["state": "provisioning", "roomId": "!dm:example.invalid"]
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit {
            $0["room"] = ["state": "ready", "roomId": NSNull()]
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit { $0["state"] = "archived" }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit { $0["authorityGeneration"] = 0 }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit {
            var people = $0["participants"] as! [[String: Any]]
            people[1]["memberRef"] = people[0]["memberRef"]
            $0["participants"] = people
        }))
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(edit {
            var people = $0["participants"] as! [[String: Any]]
            people[1]["handle"] = "Bao"
            $0["participants"] = people
        }))
        // The answer for a schema other than 6.
        var wrongSchema = try object("fixtures/conversation-open.response.json")
        wrongSchema["schemaVersion"] = 2
        XCTAssertThrowsError(try CompanyConversationWire.decodeAnswer(json(wrongSchema)))
    }

    func testTheDirectoryRefusesDuplicatesAndTooMany() throws {
        var listing = try object("fixtures/conversation-directory.response.json")
        let first = (listing["conversations"] as! [[String: Any]])[0]
        listing["conversations"] = [first, first]
        XCTAssertThrowsError(try CompanyConversationWire.decodeDirectory(json(listing)))
        listing["schemaVersion"] = 5
        listing["conversations"] = [first]
        XCTAssertThrowsError(try CompanyConversationWire.decodeDirectory(json(listing)))
    }

    // MARK: Binding

    func testAnOpenAnswerMustBeForExactlyTheSetAskedFor() throws {
        let answer = try groupAnswer()
        let id = try NativeID(company)
        XCTAssertTrue(CompanyConversationBinding.holds(answer, companyID: id, requestedRefs: [chi, anh, bao]))
        XCTAssertFalse(CompanyConversationBinding.holds(answer, companyID: id, requestedRefs: [anh, bao]))
        XCTAssertFalse(CompanyConversationBinding.holds(answer, companyID: id,
                                                        requestedRefs: [anh, bao, "BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ"]))
        XCTAssertFalse(CompanyConversationBinding.holds(
            answer, companyID: try NativeID("00000000-0000-4000-8000-c70f27930704"), requestedRefs: [anh, bao, chi]))
        // An expand answer is another conversation than its source.
        XCTAssertFalse(CompanyConversationBinding.holds(answer, companyID: id, requestedRefs: [anh, bao, chi],
                                                        sourceID: answer.conversation.id))
        XCTAssertTrue(CompanyConversationBinding.holds(answer, companyID: id, requestedRefs: [anh, bao, chi],
                                                       sourceID: try NativeID(conversation)))
    }

    func testAHideAnswerNamesTheConversationAndTheStateAskedFor() throws {
        let answer = try CompanyConversationWire.decodeHidden(pack("fixtures/conversation-hidden.response.json"))
        let id = try NativeID(conversation)
        XCTAssertTrue(CompanyConversationBinding.holds(answer, conversationID: id, hidden: true))
        XCTAssertFalse(CompanyConversationBinding.holds(answer, conversationID: id, hidden: false))
        XCTAssertFalse(CompanyConversationBinding.holds(
            answer, conversationID: try NativeID("00000000-0000-4000-8000-fe2f28c879ce"), hidden: true))
    }

    // MARK: Picker

    private func member(_ ref: String, state: CompanyMemberState = .active, name: String) throws -> CompanyMember {
        let body = """
        {"memberRef":"\(ref)","role":"member","state":"\(state.rawValue)","self":false,
         "handle":null,"displayName":"\(name)"}
        """
        return try NativeAPI.decode(CompanyMember.self, from: Data(body.utf8))
    }

    func testThePickerOffersActiveOthersAndNothingWhenSelfIsUnknown() throws {
        let people = try [member(anh, name: "Anh"), member(bao, name: "Bảo"),
                          member(chi, state: .invited, name: "Chi")]
        XCTAssertEqual(ConversationPeople.candidates(members: people, selfRef: anh).map(\.memberRef), [bao])
        XCTAssertEqual(ConversationPeople.candidates(members: people, selfRef: nil).count, 0)
        XCTAssertEqual(ConversationPeople.candidates(members: people, selfRef: nil, excluding: [bao]).count, 0)
        XCTAssertEqual(ConversationPeople.candidates(members: people, selfRef: anh, excluding: [bao]).count, 0,
                       "an expansion does not offer the people already in the conversation")
    }

    func testThePickerBoundIsEightOthers() {
        XCTAssertFalse(ConversationPeople.canStart(selectedOthers: 0))
        XCTAssertTrue(ConversationPeople.canStart(selectedOthers: 1))
        XCTAssertTrue(ConversationPeople.canStart(selectedOthers: 8))
        XCTAssertFalse(ConversationPeople.canStart(selectedOthers: 9))
        XCTAssertTrue(ConversationPeople.canAddAnother(selectedOthers: 7))
        XCTAssertFalse(ConversationPeople.canAddAnother(selectedOthers: 8))
        // Kept people count toward the bound of an expansion.
        XCTAssertTrue(ConversationPeople.canStart(selectedOthers: 1, keptOthers: 7))
        XCTAssertFalse(ConversationPeople.canStart(selectedOthers: 2, keptOthers: 7))
        XCTAssertFalse(ConversationPeople.canStart(selectedOthers: 0, keptOthers: 2))
    }

    func testRequestRefsIncludeTheCallerAreOpaqueAndSortedForAStableRetry() throws {
        let refs = [anh, bao, chi]
        XCTAssertEqual(ConversationPeople.refs(selfRef: chi, others: [bao, anh]), refs)
        XCTAssertEqual(ConversationPeople.refs(selfRef: chi, others: [anh, bao]), refs, "pick order is irrelevant")
        XCTAssertNil(ConversationPeople.refs(selfRef: anh, others: []), "one person alone is not a conversation")
        XCTAssertNil(ConversationPeople.refs(selfRef: anh, others: [anh]), "no duplicates")
        XCTAssertNil(ConversationPeople.refs(selfRef: anh, others: ["@bao:example.invalid"]), "never a Matrix id")
        XCTAssertNil(ConversationPeople.refs(selfRef: anh, others: ["bao"]), "never a handle")
        let nine = (0..<8).map { index in
            String(repeating: String(UnicodeScalar(UInt8(65 + index))), count: 43)
        }
        XCTAssertEqual(ConversationPeople.refs(selfRef: anh, others: nine)?.count, 9)
        XCTAssertNil(ConversationPeople.refs(selfRef: anh, others: nine + [chi]), "ten is over the limit")
    }

    // MARK: Request identity

    func testALostAnswerRetriesWithTheSameRequestAndANewActionGetsANewOne() {
        var tracker = ConversationRequestTracker()
        var counter = 0
        let make = { counter += 1; return "request-\(counter)" }
        let open = ConversationRequestTracker.Operation.open(company: company, people: [bao, anh])
        let first = tracker.requestID(for: open, make: make)
        // Retry after a lost answer: same id, and the same people in another order are the same action.
        tracker.failed(open, .lost)
        XCTAssertEqual(tracker.requestID(for: .open(company: company, people: [anh, bao]), make: make), first)
        // The attempt finished: choosing the same people again is a new action.
        tracker.succeeded(open)
        XCTAssertNotEqual(tracker.requestID(for: open, make: make), first)
    }

    func testATerminalRefusalEndsTheAttemptButALostAnswerKeepsIt() {
        var tracker = ConversationRequestTracker()
        var counter = 0
        let make = { counter += 1; return "request-\(counter)" }
        let hide = ConversationRequestTracker.Operation.hidden(company: company, conversation: conversation, hidden: true)
        let first = tracker.requestID(for: hide, make: make)
        tracker.failed(hide, .lost)
        XCTAssertEqual(tracker.requestID(for: hide, make: make), first)
        tracker.failed(hide, .conversationUnavailable)
        XCTAssertNotEqual(tracker.requestID(for: hide, make: make), first)
        // Different actions never share an id.
        let expand = ConversationRequestTracker.Operation.expand(company: company, source: conversation, people: [anh, bao, chi])
        XCTAssertNotEqual(tracker.requestID(for: expand, make: make), tracker.requestID(for: hide, make: make))
        tracker.clear()
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    func testRequestIdentityIsScopedToTheCompany() {
        var tracker = ConversationRequestTracker()
        var counter = 0
        let make = { counter += 1; return "request-\(counter)" }
        let other = "00000000-0000-4000-8000-cf2a09fadcde"
        // The same people in two companies are two actions, with two ids.
        let inCompany = tracker.requestID(for: .open(company: company, people: [anh, bao]), make: make)
        let inOther = tracker.requestID(for: .open(company: other, people: [anh, bao]), make: make)
        XCTAssertNotEqual(inCompany, inOther)
        // The same hide of the same conversation id in two companies likewise.
        XCTAssertNotEqual(tracker.requestID(for: .hidden(company: company, conversation: conversation, hidden: true), make: make),
                          tracker.requestID(for: .hidden(company: other, conversation: conversation, hidden: true), make: make))
        // Clearing one company leaves the other's unresolved ids alone.
        tracker.clear(company: company)
        XCTAssertEqual(tracker.requestID(for: .open(company: other, people: [anh, bao]), make: make), inOther)
        XCTAssertNotEqual(tracker.requestID(for: .open(company: company, people: [anh, bao]), make: make), inCompany)
        // An unresolved id survives anything but a terminal outcome, a company clear or the account ending.
        tracker.failed(.open(company: other, people: [anh, bao]), .lost)
        XCTAssertEqual(tracker.requestID(for: .open(company: other, people: [anh, bao]), make: make), inOther)
        tracker.clear()
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    // MARK: A room that claims the conversation type

    private let agentUser = "@agent-1:example.invalid"

    func testAConversationTypeRoomIsNeverABotOrAgentRoomAndNeverAutoJoined() {
        let type = ConversationRoomType.value
        XCTAssertTrue(ConversationTypeGuard.excludedFromBotAndAgent(roomType: type))
        XCTAssertFalse(ConversationTypeGuard.excludedFromBotAndAgent(roomType: nil))
        XCTAssertFalse(ConversationTypeGuard.excludedFromBotAndAgent(roomType: "io.atum.agent_task.v1"))
        // A known agent or bot inviting you to such a room is not auto-accepted.
        let known: Set<String> = [agentUser]
        XCTAssertTrue(MobileInvitePolicy.shouldAutoAccept(inviterID: agentUser, knownAgentAndBotUserIDs: known))
        XCTAssertFalse(MobileInvitePolicy.shouldAutoAccept(inviterID: agentUser, knownAgentAndBotUserIDs: known,
                                                           roomType: type))
    }

    func testOnlyADirectoryConfirmedConversationMayJoinAClaimedRoom() {
        let type = ConversationRoomType.value
        XCTAssertFalse(ConversationTypeGuard.mayJoin(roomType: type, directoryConfirmed: false))
        XCTAssertTrue(ConversationTypeGuard.mayJoin(roomType: type, directoryConfirmed: true))
        XCTAssertTrue(ConversationTypeGuard.mayJoin(roomType: nil, directoryConfirmed: false))
        XCTAssertTrue(ConversationTypeGuard.mayJoin(roomType: "io.atum.agent_task.v1", directoryConfirmed: false))
    }

    // MARK: A chat that was a conversation never becomes an ordinary one

    func testAChatThatWasAConversationNeverFallsThroughToTheOrdinaryComposer() {
        typealias Gate = ConversationChatGate
        // Never a conversation, no claim: an ordinary chat.
        XCTAssertEqual(Gate.state(wasConversation: false, hasAuthority: false, isFresh: false, claimsType: false), .ordinary)
        // Authority and fresh: the conversation chat.
        XCTAssertEqual(Gate.state(wasConversation: true, hasAuthority: true, isFresh: true, claimsType: true), .active)
        // Authority from a stale read: shown, composer closed.
        XCTAssertEqual(Gate.state(wasConversation: true, hasAuthority: true, isFresh: false, claimsType: true), .closed)
        // It was a conversation and the record is gone: closed, never ordinary.
        XCTAssertEqual(Gate.state(wasConversation: true, hasAuthority: false, isFresh: false, claimsType: true), .closed)
        XCTAssertEqual(Gate.state(wasConversation: true, hasAuthority: false, isFresh: true, claimsType: false), .closed)
        // A room that only claims the type: closed.
        XCTAssertEqual(Gate.state(wasConversation: false, hasAuthority: false, isFresh: false, claimsType: true), .closed)
    }

    // MARK: Refusals

    private func refusal(_ status: NativeErrorResponse.Code, _ reason: String?) -> ConversationRefusal {
        let kind: CompanyRefusal = switch status {
        case .badRequest: .invalid
        case .unauthenticated: .authentication
        case .denied: .denied
        case .notFound: .missing
        case .conflict: .conflict
        case .rateLimited: .limit
        case .unavailable: .unavailable
        }
        return ConversationRefusal(.refused(kind, reason: reason, retryAfter: nil))
    }

    func testTheConversationFamilyReasonsAreClosedPerStatus() {
        XCTAssertEqual(refusal(.notFound, "conversation_unavailable"), .conversationUnavailable)
        XCTAssertEqual(refusal(.notFound, "participant_unavailable"), .participantUnavailable)
        XCTAssertEqual(refusal(.conflict, "participant_limit"), .participantLimit)
        XCTAssertEqual(refusal(.conflict, "participant_set_conflict"), .participantSetConflict)
        XCTAssertEqual(refusal(.conflict, "admission_epoch_conflict"), .admissionEpochConflict)
        XCTAssertEqual(refusal(.conflict, "conversation_read_only"), .readOnly)
        // Another family's reason, or a conversation reason at another status: the plain status stands.
        XCTAssertEqual(refusal(.conflict, "channel_archived"), .plain(.conflict))
        XCTAssertEqual(refusal(.conflict, "last_admin"), .plain(.conflict))
        XCTAssertEqual(refusal(.notFound, "participant_limit"), .plain(.missing))
        XCTAssertEqual(refusal(.conflict, "conversation_unavailable"), .plain(.conflict))
        XCTAssertEqual(refusal(.notFound, nil), .plain(.missing))
    }

    func testALostOrUnreadableAnswerIsTheOnlyOneThatMayHaveCommitted() {
        XCTAssertEqual(ConversationRefusal(.transport), .lost)
        XCTAssertEqual(ConversationRefusal(.unavailable), .lost)
        XCTAssertEqual(ConversationRefusal(.invalid), .lost)
        XCTAssertTrue(ConversationRefusal.lost.mayHaveCommitted)
        XCTAssertFalse(ConversationRefusal.participantLimit.mayHaveCommitted)
        XCTAssertFalse(ConversationRefusal.plain(.denied).mayHaveCommitted)
    }

    // MARK: Rows

    func testRowsAreNamedForTheOtherPeopleAndCarryThePlatformsState() throws {
        let rows = ConversationRows.rows(try directory(), selfRef: anh, fallbackName: "Someone",
                                         locale: Locale(identifier: "vi"))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.title, "Bảo")
        XCTAssertEqual(row.kind, .dm)
        XCTAssertEqual(row.state, .ready)
        XCTAssertTrue(row.canOpen)
        XCTAssertEqual(row.roomID, "!dm:example.invalid")
        let group = try groupAnswer().conversation
        XCTAssertEqual(ConversationRows.title(of: group, selfRef: bao, fallbackName: "Someone"), "Anh, Chi")
        // The caller unknown: everyone is named rather than guessing who to leave out.
        XCTAssertEqual(ConversationRows.title(of: group, selfRef: nil, fallbackName: "Someone"), "Anh, Bảo, Chi")
        // A group still being set up is not tappable.
        XCTAssertEqual(ConversationRows.state(of: group), .settingUp)
    }

    func testANameIsTheDisplayNameElseTheHandleElseAFallback() throws {
        var answer = try object("fixtures/conversation-group.response.json")
        var conversation = answer["conversation"] as! [String: Any]
        var people = conversation["participants"] as! [[String: Any]]
        people[0]["displayName"] = NSNull()
        people[1]["displayName"] = NSNull()
        people[1]["handle"] = NSNull()
        conversation["participants"] = people
        answer["conversation"] = conversation
        let decoded = try CompanyConversationWire.decodeAnswer(json(answer)).conversation
        XCTAssertEqual(ConversationRows.title(of: decoded, selfRef: nil, fallbackName: "Someone"),
                       "@anh, Someone, Chi")
    }

    func testReadOnlyIsTerminalAndNeverReadyWhateverTheRoomSays() throws {
        var answer = try object("fixtures/conversation-open.response.json")
        var conversation = answer["conversation"] as! [String: Any]
        conversation["state"] = "read_only"
        answer["conversation"] = conversation
        let decoded = try CompanyConversationWire.decodeAnswer(json(answer)).conversation
        XCTAssertEqual(ConversationRows.state(of: decoded), .readOnly)
        XCTAssertTrue(decoded.isReadOnly)
    }

    func testRowsSortByRoomActivityThenTitleAndHiddenOnesStayListed() throws {
        let dm = try directory().conversations[0]
        var second = try object("fixtures/conversation-directory.response.json")
        var items = second["conversations"] as! [[String: Any]]
        var other = items[0]
        other["id"] = "00000000-0000-4000-8000-84529e4e0710"
        other["hidden"] = true
        other["room"] = ["state": "ready", "roomId": "!other:example.invalid"]
        items.append(other)
        second["conversations"] = items
        let listing = try CompanyConversationWire.decodeDirectory(json(second))
        XCTAssertEqual(listing.conversations.count, 2)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let rows = ConversationRows.rows(listing, selfRef: anh, fallbackName: "Someone",
                                         activity: [dm.room.roomId!: older, "!other:example.invalid": newer],
                                         locale: Locale(identifier: "en"))
        XCTAssertEqual(rows.map(\.id), ["00000000-0000-4000-8000-84529e4e0710", conversation])
        XCTAssertEqual(rows.map(\.isHidden), [true, false])
        // Without activity the title decides and the id breaks a tie.
        let quiet = ConversationRows.rows(listing, selfRef: anh, fallbackName: "Someone", locale: Locale(identifier: "en"))
        XCTAssertEqual(quiet.map(\.id), [conversation, "00000000-0000-4000-8000-84529e4e0710"].sorted())
    }

    // MARK: Room classification

    func testOnlyTheDirectorysRoomIdsAreConversationRooms() throws {
        var rooms = ConversationRoomDirectory()
        rooms.replace(try directory(), companyID: company, selfRef: anh, fallbackName: "Someone")
        let claim = try XCTUnwrap(rooms.claim(roomID: "!dm:example.invalid"))
        XCTAssertEqual(claim.conversationID, conversation)
        XCTAssertEqual(claim.title, "Bảo")
        XCTAssertEqual(claim.kind, .dm)
        // A room that merely claims the type is not a conversation.
        XCTAssertNil(rooms.claim(roomID: "!stranger:example.invalid"))
        // A conversation whose room is not ready has no claim yet.
        var pending = ConversationRoomDirectory()
        let provisioning = try CompanyConversationDirectory.decodeSingle(groupAnswer().conversation, via: self)
        pending.replace(provisioning, companyID: company, selfRef: anh, fallbackName: "Someone")
        XCTAssertTrue(pending.isEmpty)
    }

    func testClaimsFollowTheDirectoryAndEndWithTheCompany() throws {
        var rooms = ConversationRoomDirectory()
        rooms.replace(try directory(), companyID: company, selfRef: anh, fallbackName: "Someone")
        XCTAssertEqual(rooms.roomIDs(companyID: company), ["!dm:example.invalid"])
        // The person's own list is the whole truth: a conversation the platform stops listing loses its claim.
        let empty = try CompanyConversationWire.decodeDirectory(Data(#"{"schemaVersion":6,"conversations":[]}"#.utf8))
        rooms.replace(empty, companyID: company, selfRef: anh, fallbackName: "Someone")
        XCTAssertNil(rooms.claim(roomID: "!dm:example.invalid"))
        rooms.replace(try directory(), companyID: company, selfRef: anh, fallbackName: "Someone")
        rooms.retain(companies: ["00000000-0000-4000-8000-c70f27930704"])
        XCTAssertTrue(rooms.isEmpty)
    }

    func testTheConversationRoomTypeIsOnlyAHint() {
        XCTAssertTrue(ConversationRoomType.isClaimed("io.atum.company_conversation.v1"))
        XCTAssertFalse(ConversationRoomType.isClaimed(nil))
        XCTAssertFalse(ConversationRoomType.isClaimed("io.atum.agent_task.v1"))
    }

    // MARK: Convergence

    func testAnOpenedConversationConvergesToItsRoomWithoutASubstitute() throws {
        let ready = try XCTUnwrap(directory().conversations.first)
        let provisioning = try groupAnswer().conversation
        XCTAssertEqual(ConversationConvergence.step(attempt: 0, conversation: nil, presence: .joined), .wait)
        XCTAssertEqual(ConversationConvergence.step(attempt: 0, conversation: provisioning, presence: .joined), .wait)
        XCTAssertEqual(ConversationConvergence.step(attempt: 0, conversation: ready, presence: .absent), .wait)
        XCTAssertEqual(ConversationConvergence.step(attempt: 0, conversation: ready, presence: .invited),
                       .join(roomID: "!dm:example.invalid"))
        XCTAssertEqual(ConversationConvergence.step(attempt: 3, conversation: ready, presence: .joined),
                       .open(roomID: "!dm:example.invalid"))
        XCTAssertEqual(ConversationConvergence.step(attempt: CompanyConvergence.attempts, conversation: ready,
                                                    presence: .joined), .giveUp)
    }
}

/// A one-conversation directory for a test, built from the pack's own answer.
private extension CompanyConversationDirectory {
    static func decodeSingle(_ conversation: CompanyConversation, via test: CompanyConversationsTests) throws
        -> CompanyConversationDirectory {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.5", withExtension: nil))
        let answer = try JSONSerialization.jsonObject(
            with: Data(contentsOf: source.appendingPathComponent("fixtures/conversation-group.response.json"))
        ) as! [String: Any]
        let body: [String: Any] = ["schemaVersion": 6, "conversations": [answer["conversation"]!]]
        return try CompanyConversationWire.decodeDirectory(JSONSerialization.data(withJSONObject: body))
    }
}

enum NativeHTTPFailureStub {
    /// A transport-free `NativeHTTPFailure` for an already-decoded error body.
    static func make(_ response: NativeErrorResponse) -> NativeHTTPFailure {
        var details = ""
        if let reason = response.details?.reason { details = #","details":{"reason":"\#(reason)"}"# }
        let retry: [String: String] = response.error == .rateLimited ? ["Retry-After": "1"] : [:]
        return try! NativeHTTPFailure(status: response.error.status, headers: retry,
                                      body: Data(#"{"error":"\#(response.error.rawValue)"\#(details)}"#.utf8))
    }
}
