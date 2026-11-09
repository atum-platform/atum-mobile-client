@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import XCTest

/// Company DMs and group DMs on the phone (wire 1.5): the section exists only
/// when the server, the feature and the tenant all say so; the platform's
/// directory is the only thing that makes a Matrix room a conversation; New
/// message / Add people / Hide go through the company authority with a retry
/// that replays the same request; and the copy is complete in five locales.
/// Company, ids and names are generic (the frozen pack's own).
final class ConversationTests: XCTestCase {
    private enum StubFailure: Error { case unavailable }

    private let company = "00000000-0000-4000-8000-87c6455cae48"
    private let channel = "00000000-0000-4000-8000-7983649001b9"
    private let dmID = "00000000-0000-4000-8000-f6c6b8bb709f"
    private let groupID = "00000000-0000-4000-8000-8a4e23bab81e"
    private let anh = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
    private let bao = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"
    private let chi = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM"
    private let dmRoom = "!dm:example.invalid"
    private let channelRoom = "!general:example.invalid"

    // MARK: Stub

    /// One stub for both authorities: the company reads and the 1.3 / 1.5 calls.
    @MainActor
    private final class API: CompanyWorkspaceAPI, CompanyConversationsAPI, @unchecked Sendable {
        var list: CompanyList
        var channels: CompanyChannelDirectory
        var snapshot: CompanySnapshot
        var capabilities: Result<CompanyCapabilities, Error>
        var conversations: [Result<CompanyConversationDirectory, Error>] = []
        var opens: [(requestID: String, refs: [String])] = []
        var expands: [(requestID: String, source: String, refs: [String])] = []
        var hides: [(requestID: String, id: String, hidden: Bool)] = []
        var listCalls = 0
        var capabilityCalls = 0
        var openResults: [Result<CompanyConversationAnswer, Error>] = []
        /// Runs inside the open call, before its answer: the person does something meanwhile.
        var onOpen: (() -> Void)?
        /// Overrides the company list answer (a v1 answer is a downgrade).
        var listRead: CompanyRead<CompanyList>?
        var leaveResult: Result<CompanyLeaveAcknowledgement, Error> = .failure(StubFailure.unavailable)
        /// Per-company conversation directories; falls back to `conversations`.
        var directoryFor: ((String) -> Result<CompanyConversationDirectory, Error>)?
        var expandResults: [Result<CompanyConversationAnswer, Error>] = []
        var hideResults: [Result<CompanyConversationHiddenAnswer, Error>] = []

        init(list: CompanyList, channels: CompanyChannelDirectory, snapshot: CompanySnapshot,
             capabilities: Result<CompanyCapabilities, Error>) {
            self.list = list
            self.channels = channels
            self.snapshot = snapshot
            self.capabilities = capabilities
        }

        func companyList() async throws -> CompanyRead<CompanyList> { listRead ?? .v1_1(list) }
        func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot> { .v1_1(snapshot) }
        func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory> { .v1_1(channels) }
        func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                     invitationID: NativeID) async throws -> CompanySnapshot { throw StubFailure.unavailable }
        func leaveCompany(companyID: NativeID, requestID: NativeID) async throws -> CompanyLeaveAcknowledgement {
            try leaveResult.get()
        }
        func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot {
            throw StubFailure.unavailable
        }

        func companyCapabilities() async throws -> CompanyCapabilities {
            capabilityCalls += 1
            return try capabilities.get()
        }
        func companyConversations(companyID: NativeID) async throws -> CompanyConversationDirectory {
            listCalls += 1
            if let directoryFor { return try directoryFor(companyID.rawValue).get() }
            guard !conversations.isEmpty else { throw StubFailure.unavailable }
            return try (conversations.count > 1 ? conversations.removeFirst() : conversations[0]).get()
        }
        func openCompanyConversation(companyID: NativeID, requestID: NativeID,
                                     participantMemberRefs: [String]) async throws -> CompanyConversationAnswer {
            opens.append((requestID.rawValue, participantMemberRefs))
            onOpen?()
            guard !openResults.isEmpty else { throw StubFailure.unavailable }
            return try openResults.removeFirst().get()
        }
        func expandCompanyConversation(companyID: NativeID, sourceConversationID: NativeID, requestID: NativeID,
                                       participantMemberRefs: [String]) async throws -> CompanyConversationAnswer {
            expands.append((requestID.rawValue, sourceConversationID.rawValue, participantMemberRefs))
            guard !expandResults.isEmpty else { throw StubFailure.unavailable }
            return try expandResults.removeFirst().get()
        }
        func setCompanyConversationHidden(companyID: NativeID, conversationID: NativeID, requestID: NativeID,
                                          hidden: Bool) async throws -> CompanyConversationHiddenAnswer {
            hides.append((requestID.rawValue, conversationID.rawValue, hidden))
            guard !hideResults.isEmpty else { throw StubFailure.unavailable }
            return try hideResults.removeFirst().get()
        }
    }

    // MARK: Fixtures

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    private func capabilities(feature: Bool = true, active: Bool = true,
                              wires: [String] = ["1", "1.1", "1.2", "1.3", "1.4", "1.5"]) throws -> CompanyCapabilities {
        try CompanyConversationWire.decodeCapabilities(json([
            "schemaVersion": 4, "wireVersion": "1.3", "supportedWireVersions": wires,
            "features": ["ownership": true, "invitationLifecycle": true, "capabilityDiscovery": true,
                         "channelAdmission": true, "companyConversations": feature],
            "activation": ["teamAdmin": "active", "channelAdmission": "active",
                           "companyConversations": active ? "active" : "inactive"],
            "controller": ["roomReconciliation": "ready"],
        ]))
    }

    private func companyList() throws -> CompanyList {
        try NativeAPI.decode(CompanyList.self, from: json([
            "schemaVersion": 2,
            "companies": [["id": company, "displayName": "Acme", "role": "admin", "authorityGeneration": 1]],
            "invitations": [], "canCreate": false,
        ]))
    }

    private func channelDirectory() throws -> CompanyChannelDirectory {
        try NativeAPI.decode(CompanyChannelDirectory.self, from: json([
            "schemaVersion": 2,
            "channels": [[
                "schemaVersion": 2,
                "channel": ["id": channel, "companyId": company, "displayName": "general",
                            "visibility": "company", "state": "active", "projectId": NSNull(),
                            "authorityGeneration": 1, "channelGeneration": 1, "systemKey": "default"],
                "memberCount": 3, "room": ["state": "ready", "roomId": channelRoom],
            ]],
        ]))
    }

    /// The caller is Anh; Bảo, Chi and a person not yet active are the company's others.
    private func companySnapshot() throws -> CompanySnapshot {
        func member(_ ref: String, _ name: String, state: String = "active", isSelf: Bool = false) -> [String: Any] {
            ["memberRef": ref, "role": "member", "state": state, "self": isSelf,
             "handle": name.lowercased().folding(options: .diacriticInsensitive, locale: nil),
             "displayName": name]
        }
        return try NativeAPI.decode(CompanySnapshot.self, from: json([
            "schemaVersion": 2,
            "company": ["id": company, "displayName": "Acme", "role": "admin", "authorityGeneration": 1],
            "members": [member(anh, "Anh", isSelf: true), member(bao, "Bảo"), member(chi, "Chi"),
                        member("BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ", "Dung", state: "invited")],
            "projects": [], "defaultChannelId": channel,
        ]))
    }

    private func participant(_ ref: String, _ epoch: Int, _ handle: String, _ name: String) -> [String: Any] {
        ["memberRef": ref, "admissionEpoch": epoch, "handle": handle, "displayName": name]
    }

    /// A conversation as the platform would answer it (digest included).
    private func conversation(id: String, kind: CompanyConversationKind, people: [[String: Any]],
                              state: String = "active", roomID: String? = nil, hidden: Bool = false,
                              companyID: String? = nil) -> [String: Any] {
        let owner = companyID ?? company
        let digest = CompanyConversationDigest.digest(
            companyID: owner, kind: kind,
            participants: people.map { (memberRef: $0["memberRef"] as! String,
                                        admissionEpoch: Int64($0["admissionEpoch"] as! Int)) })
        return ["id": id, "companyId": owner, "kind": kind.rawValue, "state": state,
                "participants": people, "participantSetDigest": digest,
                "authorityGeneration": 3, "conversationGeneration": 1,
                "room": roomID.map { ["state": "ready", "roomId": $0] as [String: Any] }
                    ?? ["state": "provisioning", "roomId": NSNull()],
                "hidden": hidden]
    }

    private var dmPeople: [[String: Any]] { [participant(anh, 1, "anh", "Anh"), participant(bao, 1, "bao", "Bảo")] }
    private var groupPeople: [[String: Any]] {
        [participant(anh, 1, "anh", "Anh"), participant(bao, 1, "bao", "Bảo"), participant(chi, 1, "chi", "Chi")]
    }

    private func directory(_ items: [[String: Any]]) throws -> CompanyConversationDirectory {
        try CompanyConversationWire.decodeDirectory(json(["schemaVersion": 6, "conversations": items]))
    }

    private func answer(_ item: [String: Any], replayed: Bool = false) throws -> CompanyConversationAnswer {
        try CompanyConversationWire.decodeAnswer(json(["schemaVersion": 6, "conversation": item,
                                                       "replayed": replayed]))
    }

    private func hiddenAnswer(_ id: String, _ hidden: Bool) throws -> CompanyConversationHiddenAnswer {
        try CompanyConversationWire.decodeHidden(json(["schemaVersion": 6, "conversationId": id,
                                                       "hidden": hidden, "replayed": false]))
    }

    @MainActor
    private func api(on: Bool = true, items: [[String: Any]]? = nil) throws -> API {
        let stub = API(list: try companyList(), channels: try channelDirectory(), snapshot: try companySnapshot(),
                       capabilities: .success(try capabilities(feature: on, active: on)))
        stub.conversations = [.success(try directory(items ?? [
            conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom),
        ]))]
        return stub
    }

    @MainActor
    private func model(_ api: API, account: String = "conv-" + UUID().uuidString) throws -> CompanyWorkspaceModel {
        let model = CompanyWorkspaceModel()
        model.copy = CompanyCopy(design: try LiveDesign())
        model.clientProvider = { api }
        model.conversationsProvider = { api }
        model.presence = { _ in .joined }
        model.conversations.convergence = (attempts: 3, delayMilliseconds: 1)
        model.beginAccountScope(account)
        return model
    }

    // MARK: The probe

    @MainActor
    func testTheSectionAppearsOnlyWhenTheWireTheFeatureAndTheActivationAllSayYes() async throws {
        let on = try api()
        let enabled = try model(on)
        await enabled.refresh()
        let section = try XCTUnwrap(enabled.workspace(companyID: company)?.conversations)
        XCTAssertEqual(section.rows.map(\.row.title), ["Bảo"], "named for the other person")
        XCTAssertEqual(on.capabilityCalls, 1)
        XCTAssertEqual(on.listCalls, 1)

        // Feature on, activation inactive: no section and no 1.5 request.
        let inactive = try api()
        inactive.capabilities = .success(try capabilities(feature: true, active: false))
        let idle = try model(inactive)
        await idle.refresh()
        XCTAssertNil(idle.workspace(companyID: company)?.conversations)
        XCTAssertEqual(inactive.listCalls, 0, "no 1.5 request while the family is off")

        // Activation active, feature off.
        let featureOff = try api()
        featureOff.capabilities = .success(try capabilities(feature: false, active: true))
        let off = try model(featureOff)
        await off.refresh()
        XCTAssertNil(off.workspace(companyID: company)?.conversations)
        XCTAssertEqual(featureOff.listCalls, 0)

        // A 1.4 server: the wire is not named.
        let old = try api()
        old.capabilities = .success(try capabilities(feature: true, active: true,
                                                     wires: ["1", "1.1", "1.2", "1.3", "1.4"]))
        let oldModel = try model(old)
        await oldModel.refresh()
        XCTAssertNil(oldModel.workspace(companyID: company)?.conversations)
        XCTAssertEqual(old.listCalls, 0)

        // A server that predates discovery (a refusal on the probe): hidden, quiet.
        let predates = try api()
        predates.capabilities = .failure(CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil))
        let predatesModel = try model(predates)
        await predatesModel.refresh()
        XCTAssertNil(predatesModel.workspace(companyID: company)?.conversations)
        XCTAssertEqual(predates.listCalls, 0)
        XCTAssertEqual(predatesModel.phase, .ready, "no error: the rest of Workplace works")
    }

    @MainActor
    func testAFamilySwitchedOffDropsTheListAtOnceButATransientFailureKeepsIt() async throws {
        let stub = try api()
        let subject = try model(stub)
        await subject.refresh()
        XCTAssertNotNil(subject.workspace(companyID: company)?.conversations)
        XCTAssertTrue(subject.isConversationRoom(dmRoom))

        // A lost probe changes nothing.
        stub.capabilities = .failure(CompanyAPIError.transport)
        await subject.refresh()
        XCTAssertNotNil(subject.workspace(companyID: company)?.conversations)

        // The server turns the family off: the list and the claims are dropped at once.
        stub.capabilities = .success(try capabilities(feature: true, active: false))
        await subject.refresh()
        XCTAssertNil(subject.workspace(companyID: company)?.conversations)
        XCTAssertFalse(subject.isConversationRoom(dmRoom))
    }

    // MARK: Classification

    @MainActor
    func testOnlyTheDirectoryMakesARoomAConversationAndAClaimedUnlistedOneShowsNowhere() async throws {
        let subject = try model(try api())
        await subject.refresh()
        let strangerClaim = "!stranger:example.invalid"
        let personal = "!friends:example.invalid"
        subject.reconcileMatrixRooms([dmRoom, channelRoom, strangerClaim, personal],
                                     conversationTypeClaims: [dmRoom, strangerClaim])
        XCTAssertEqual(subject.roomClassification(dmRoom), .conversation(try XCTUnwrap(subject.conversationClaim(roomID: dmRoom))))
        XCTAssertEqual(subject.conversationClaim(roomID: dmRoom)?.title, "Bảo")
        XCTAssertEqual(subject.roomClassification(strangerClaim), .quarantined,
                       "a room that claims the type and is not listed is shown nowhere, and never Personal")
        XCTAssertEqual(subject.roomClassification(personal), .personal)
        if case .company = subject.roomClassification(channelRoom) {} else { XCTFail("the channel stays a channel") }
    }

    @MainActor
    func testAFailedConversationReadKeepsTheClassificationIncompleteSoNothingLeaksIntoHome() async throws {
        let stub = try api()
        stub.conversations = []   // the 1.5 list fails
        let subject = try model(stub)
        await subject.refresh()
        XCTAssertFalse(subject.classificationComplete, "unknown rooms stay unknown, never Personal")
        subject.reconcileMatrixRooms(["!some-group:example.invalid"])
        XCTAssertEqual(subject.roomClassification("!some-group:example.invalid"), .unknown)
    }

    @MainActor
    func testLeavingTheCompanyDropsItsConversationRooms() async throws {
        let stub = try api()
        let subject = try model(stub)
        var left = Set<String>()
        subject.onLeft = { left.formUnion($0) }
        await subject.refresh()
        XCTAssertTrue(subject.isConversationRoom(dmRoom))
        stub.list = try NativeAPI.decode(CompanyList.self, from: json([
            "schemaVersion": 2, "companies": [], "invitations": [], "canCreate": false]))
        await subject.refresh()
        XCTAssertFalse(subject.isConversationRoom(dmRoom))
        XCTAssertTrue(left.contains(dmRoom), "the open chat closes")
        XCTAssertTrue(left.contains(channelRoom))
    }

    @MainActor
    func testConversationsCountTowardTheCompanysMarkByTheChannelRule() async throws {
        let subject = try model(try api())
        await subject.refresh()
        let rooms = [
            LiveProductRoom(id: dmRoom, kind: .people, title: "Bảo", unreadCount: 2, notificationCount: 2,
                            highlightCount: 1, isMarkedUnread: false),
            LiveProductRoom(id: "!friends:example.invalid", kind: .people, title: "Friend", unreadCount: 9,
                            notificationCount: 9),
        ]
        let signals = subject.roomSignals(from: rooms)
        XCTAssertEqual(Set(signals.keys), [dmRoom], "only the platform's conversation counts, not a Personal chat")
        XCTAssertEqual(subject.companyBadge(companyID: company, signals: signals), .mention(2))
        let row = try XCTUnwrap(subject.workspace(companyID: company, signals: signals)?.conversations?.rows.first)
        XCTAssertEqual(row.badge, .mention(2))
        XCTAssertTrue(row.isBold)
    }

    // MARK: New message

    @MainActor
    func testOneOtherPersonOpensADMWithTheCallerIncludedAndSortedAndJoinsTheRoom() async throws {
        let stub = try api(items: [])
        stub.openResults = [.success(try answer(conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)))]
        stub.conversations = [.success(try directory([conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)]))]
        let subject = try model(stub)
        await subject.refresh()
        let outcome = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(outcome, .opened(roomID: dmRoom))
        XCTAssertEqual(stub.opens.map(\.refs), [[anh, bao]], "the caller is in the set, refs sorted")
        XCTAssertEqual(stub.opens.count, 1)
    }

    @MainActor
    func testSeveralPeopleOpenAGroupInAnyOrderAndAnInvitationIsJoinedFirst() async throws {
        let stub = try api(items: [])
        let group = conversation(id: groupID, kind: .groupDM, people: groupPeople, roomID: dmRoom)
        stub.openResults = [.success(try answer(group))]
        stub.conversations = [.success(try directory([group]))]
        let subject = try model(stub)
        var joined = [String]()
        var joinedYet = false
        subject.presence = { _ in joinedYet ? .joined : .invited }
        subject.conversationJoin = { room in joined.append(room); joinedYet = true; return true }
        await subject.refresh()
        let outcome = await subject.conversations.start(companyID: company, others: [chi, bao])
        XCTAssertEqual(outcome, .opened(roomID: dmRoom))
        XCTAssertEqual(joined, [dmRoom], "the invitation for the listed room is accepted, no substitute room")
        XCTAssertEqual(stub.opens.first?.refs, [anh, bao, chi])
    }

    @MainActor
    func testARoomThatIsNotReadyIsAQuietSettingUpNeverAnError() async throws {
        let stub = try api(items: [])
        let provisioning = conversation(id: groupID, kind: .groupDM, people: groupPeople)
        stub.openResults = [.success(try answer(provisioning))]
        stub.conversations = [.success(try directory([provisioning]))]
        let subject = try model(stub)
        await subject.refresh()
        let outcome = await subject.conversations.start(companyID: company, others: [bao, chi])
        XCTAssertEqual(outcome, .settingUp)
        let row = try XCTUnwrap(subject.workspace(companyID: company)?.conversations?.rows.first)
        XCTAssertEqual(row.row.state, .settingUp)
        XCTAssertFalse(row.row.canOpen, "not tappable until the room is ready")
    }

    @MainActor
    func testALostAnswerRetriesWithTheSameRequestAndAFinishedOneDoesNot() async throws {
        let stub = try api(items: [])
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.failure(CompanyAPIError.transport), .success(try answer(made)), .success(try answer(made, replayed: true))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        await subject.refresh()
        let first = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(first, .failed(.lost))
        let retry = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(retry, .opened(roomID: dmRoom))
        XCTAssertEqual(stub.opens.count, 2)
        XCTAssertEqual(stub.opens[0].requestID, stub.opens[1].requestID, "Retry is the same request")

        // The attempt finished: choosing the same person again is a new action.
        _ = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertNotEqual(stub.opens[2].requestID, stub.opens[1].requestID)
        XCTAssertEqual(stub.opens[2].refs, stub.opens[1].refs, "same people, same conversation")
    }

    @MainActor
    func testARefusalKeepsThePickerOpenWithItsTypedReasonAndEndsTheAttempt() async throws {
        let stub = try api(items: [])
        stub.openResults = [.failure(CompanyAPIError.refused(.conflict, reason: "participant_limit", retryAfter: nil)),
                            .failure(CompanyAPIError.refused(.missing, reason: "participant_unavailable", retryAfter: nil))]
        let subject = try model(stub)
        await subject.refresh()
        let limit = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(limit, .failed(.participantLimit))
        let unavailable = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(unavailable, .failed(.participantUnavailable))
        XCTAssertNotEqual(stub.opens[0].requestID, stub.opens[1].requestID,
                          "a refusal is terminal: the next try is a new request")
    }

    @MainActor
    func testTheEightOtherPeopleBoundAndNoPersonAreRefusedBeforeAnyRequest() async throws {
        let stub = try api(items: [])
        let subject = try model(stub)
        await subject.refresh()
        let none = await subject.conversations.start(companyID: company, others: [])
        XCTAssertEqual(none, .failed(.plain(.invalid)))
        let nine = (0..<9).map { String(repeating: String(UnicodeScalar(UInt8(65 + $0))), count: 43) }
        let over = await subject.conversations.start(companyID: company, others: nine)
        XCTAssertEqual(over, .failed(.plain(.invalid)))
        XCTAssertTrue(stub.opens.isEmpty)
    }

    @MainActor
    func testTheFamilySwitchedOffUnderAnOpenPickerSendsNothing() async throws {
        let stub = try api(items: [])
        let subject = try model(stub)
        await subject.refresh()
        stub.capabilities = .success(try capabilities(feature: true, active: false))
        await subject.refresh()
        let outcome = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(outcome, .failed(.plain(.unavailable)))
        XCTAssertTrue(stub.opens.isEmpty)
    }

    // MARK: The picker's people

    @MainActor
    func testThePickerOffersActiveOthersAndAnExpansionKeepsThePeopleAlreadyIn() async throws {
        let subject = try model(try api())
        await subject.refresh()
        XCTAssertEqual(subject.conversationPeople(companyID: company).map(\.name), ["Bảo", "Chi"],
                       "not the caller, not someone who has not joined yet")
        XCTAssertEqual(subject.conversationPeople(companyID: company, excluding: [bao]).map(\.name), ["Chi"])
    }

    // MARK: Add people and hide

    @MainActor
    func testAddPeopleExpandsToTheWholeLargerSetAndLeavesTheSourceAlone() async throws {
        let stub = try api()
        let group = conversation(id: groupID, kind: .groupDM, people: groupPeople, roomID: "!group:example.invalid")
        stub.expandResults = [.success(try answer(group))]
        stub.conversations = [.success(try directory([
            conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom), group,
        ]))]
        let subject = try model(stub)
        await subject.refresh()
        let outcome = await subject.conversations.addPeople(companyID: company, sourceConversationID: dmID,
                                                            others: [bao, chi])
        XCTAssertEqual(outcome, .opened(roomID: "!group:example.invalid"))
        XCTAssertEqual(stub.expands.first?.source, dmID)
        XCTAssertEqual(stub.expands.first?.refs, [anh, bao, chi])
        XCTAssertTrue(subject.isConversationRoom(dmRoom), "the source stays as it is")

        // Two people in all is not an expansion.
        let two = await subject.conversations.addPeople(companyID: company, sourceConversationID: dmID, others: [bao])
        XCTAssertEqual(two, .failed(.plain(.invalid)))
        XCTAssertEqual(stub.expands.count, 1)
    }

    @MainActor
    func testHideMovesTheRowUnderHiddenAndOpeningItShowsItAgain() async throws {
        let stub = try api()
        let hiddenDM = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom, hidden: true)
        let shownDM = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.hideResults = [.success(try hiddenAnswer(dmID, true)), .success(try hiddenAnswer(dmID, false))]
        let subject = try model(stub)
        await subject.refresh()

        stub.conversations = [.success(try directory([hiddenDM]))]
        let hidden = await subject.conversations.setHidden(companyID: company, conversationID: dmID, hidden: true)
        XCTAssertTrue(hidden)
        XCTAssertEqual(stub.hides.map(\.hidden), [true])
        var section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
        XCTAssertTrue(section.rows.isEmpty)
        XCTAssertEqual(section.hidden.map(\.row.title), ["Bảo"])

        // Opening a hidden one shows it again first.
        stub.conversations = [.success(try directory([shownDM]))]
        await subject.conversations.prepareToOpen(companyID: company, conversationID: dmID)
        XCTAssertEqual(stub.hides.map(\.hidden), [true, false])
        section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
        XCTAssertEqual(section.rows.map(\.row.title), ["Bảo"])
        XCTAssertTrue(section.hidden.isEmpty)
    }

    @MainActor
    func testAHideTheServerRefusesLeavesTheRowAndSaysSo() async throws {
        let stub = try api()
        stub.hideResults = [.failure(CompanyAPIError.refused(.missing, reason: "conversation_unavailable", retryAfter: nil))]
        let subject = try model(stub)
        await subject.refresh()
        let ok = await subject.conversations.setHidden(companyID: company, conversationID: dmID, hidden: true)
        XCTAssertFalse(ok)
        let section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
        XCTAssertEqual(section.rows.count, 1)
        XCTAssertEqual(section.notice, ConversationCopy(design: try LiveDesign()).text("refusal.conversation_unavailable"))
    }

    // MARK: Read-only

    @MainActor
    func testAReadOnlyConversationIsTheServersWordNotMatrixPowerLevels() async throws {
        let readOnly = conversation(id: dmID, kind: .dm, people: dmPeople, state: "read_only", roomID: dmRoom)
        let subject = try model(try api(items: [readOnly]))
        await subject.refresh()
        let row = try XCTUnwrap(subject.workspace(companyID: company)?.conversations?.rows.first)
        XCTAssertEqual(row.row.state, .readOnly)
        XCTAssertTrue(row.row.canOpen, "it can still be read")
        let record = try XCTUnwrap(subject.conversations.conversation(roomID: dmRoom))
        XCTAssertTrue(record.isReadOnly)
        XCTAssertEqual(subject.conversations.kept(roomID: dmRoom)?.refs, [bao])
    }

    // MARK: Claiming the type is not authority

    private let otherCompany = "00000000-0000-4000-8000-cf2a09fadcde"

    private func twoCompanyList() throws -> CompanyList {
        try NativeAPI.decode(CompanyList.self, from: json([
            "schemaVersion": 2,
            "companies": [
                ["id": company, "displayName": "Acme", "role": "admin", "authorityGeneration": 1],
                ["id": otherCompany, "displayName": "Beta", "role": "admin", "authorityGeneration": 1],
            ],
            "invitations": [], "canCreate": false,
        ]))
    }

    @MainActor
    func testARoomThatOnlyClaimsTheTypeHasNoTranscriptComposerBadgeOrNotificationAndOpensNowhere() async throws {
        let subject = try model(try api())
        await subject.refresh()
        let stranger = "!stranger:example.invalid"
        subject.reconcileMatrixRooms([dmRoom, stranger], conversationTypeClaims: [dmRoom, stranger])

        // Nothing of it is believed: no record, so no title, composer state, or badge.
        XCTAssertNil(subject.conversationClaim(roomID: stranger))
        XCTAssertNil(subject.conversations.conversation(roomID: stranger))
        XCTAssertNil(subject.conversations.kept(roomID: stranger))
        XCTAssertFalse(subject.conversations.isFresh(roomID: stranger))
        XCTAssertTrue(subject.isQuarantinedConversation(stranger))
        let signals = subject.roomSignals(from: [
            LiveProductRoom(id: stranger, kind: .group, title: "x", unreadCount: 5, notificationCount: 5, highlightCount: 5),
        ])
        XCTAssertTrue(signals.isEmpty, "no badge")
        XCTAssertEqual(subject.companyBadge(companyID: company, signals: signals), .none)
        XCTAssertEqual(subject.roomClassification(stranger), .quarantined)
        // The listed one is the contrast.
        XCTAssertFalse(subject.isQuarantinedConversation(dmRoom))
        XCTAssertNotNil(subject.conversations.conversation(roomID: dmRoom))
        XCTAssertTrue(subject.conversations.isFresh(roomID: dmRoom))
    }

    @MainActor
    func testARecordThatNamesAnotherCompanyGivesNoAuthorityToItsRoom() async throws {
        // The platform's answer for Acme lists a conversation that is another company's.
        var foreign = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        let digest = CompanyConversationDigest.digest(
            companyID: otherCompany, kind: .dm,
            participants: [(memberRef: anh, admissionEpoch: 1), (memberRef: bao, admissionEpoch: 1)])
        foreign["companyId"] = otherCompany
        foreign["participantSetDigest"] = digest
        let subject = try model(try api(items: [foreign]))
        await subject.refresh()
        XCTAssertNil(subject.conversationClaim(roomID: dmRoom), "company, conversation and room must all match")
        XCTAssertNil(subject.conversations.conversation(roomID: dmRoom))
        subject.reconcileMatrixRooms([dmRoom], conversationTypeClaims: [dmRoom])
        XCTAssertTrue(subject.isQuarantinedConversation(dmRoom))
    }

    // MARK: Fail closed

    @MainActor
    func testADeniedMissingOrInvalidListClearsAuthorityAndClosesEverything() async throws {
        let answers: [Error] = [
            CompanyAPIError.refused(.denied, reason: nil, retryAfter: nil),
            CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil),
            CompanyAPIError.refused(.invalid, reason: nil, retryAfter: nil),
            CompanyAPIError.invalid,
        ]
        for answer in answers {
            let stub = try api()
            let subject = try model(stub)
            var lost = Set<String>()
            subject.onLeft = { lost.formUnion($0) }
            await subject.refresh()
            XCTAssertTrue(subject.conversations.canMutate(companyID: company))

            stub.conversations = [.failure(answer)]
            await subject.refresh()
            let section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
            XCTAssertTrue(section.rows.isEmpty, "\(answer): no stale rows")
            XCTAssertTrue(section.failed)
            XCTAssertNil(subject.conversationClaim(roomID: dmRoom), "\(answer): the claim is gone")
            XCTAssertTrue(lost.contains(dmRoom), "\(answer): the open chat closes")
            XCTAssertFalse(subject.conversations.canMutate(companyID: company))

            let before = stub.opens.count + stub.hides.count + stub.expands.count
            let started = await subject.conversations.start(companyID: company, others: [bao])
            XCTAssertEqual(started, .failed(.plain(.unavailable)))
            let hidden = await subject.conversations.setHidden(companyID: company, conversationID: dmID, hidden: true)
            XCTAssertFalse(hidden)
            let added = await subject.conversations.addPeople(companyID: company, sourceConversationID: dmID,
                                                              others: [bao, chi])
            XCTAssertEqual(added, .failed(.plain(.unavailable)))
            XCTAssertEqual(stub.opens.count + stub.hides.count + stub.expands.count, before, "nothing is sent")
        }
    }

    @MainActor
    func testATransientFailureKeepsRowsAsStaleWithEveryWriteAndComposerClosedUntilAReadSucceeds() async throws {
        let transient: [Error] = [CompanyAPIError.transport, CompanyAPIError.unavailable,
                                  CompanyAPIError.refused(.limit, reason: nil, retryAfter: 1)]
        for failure in transient {
            let stub = try api()
            let subject = try model(stub)
            await subject.refresh()
            stub.conversations = [.failure(failure)]
            await subject.refresh()

            let section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
            XCTAssertEqual(section.rows.map(\.row.title), ["Bảo"], "\(failure): rows stay visible")
            XCTAssertTrue(section.isStale, "\(failure): shown as stale")
            XCTAssertFalse(section.failed)
            XCTAssertNotNil(subject.conversationClaim(roomID: dmRoom), "the last good record is still a record")
            XCTAssertFalse(subject.conversations.isFresh(roomID: dmRoom), "so the composer is closed")
            XCTAssertFalse(subject.conversations.canMutate(companyID: company))

            let before = stub.opens.count + stub.hides.count + stub.expands.count
            let started = await subject.conversations.start(companyID: company, others: [bao])
            XCTAssertEqual(started, .failed(.plain(.unavailable)))
            let hidden = await subject.conversations.setHidden(companyID: company, conversationID: dmID, hidden: true)
            XCTAssertFalse(hidden)
            XCTAssertEqual(stub.opens.count + stub.hides.count + stub.expands.count, before)

            // A successful refresh reopens everything.
            stub.conversations = [.success(try directory([conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)]))]
            await subject.refresh()
            XCTAssertEqual(subject.workspace(companyID: company)?.conversations?.isStale, false)
            XCTAssertTrue(subject.conversations.isFresh(roomID: dmRoom))
            XCTAssertTrue(subject.conversations.canMutate(companyID: company))
        }
    }

    // MARK: Retry keeps the gate

    @MainActor
    func testRetryPassesTheGateAgainAndTheUnresolvedIdSurvivesTheFeatureGoingOffAndOn() async throws {
        let stub = try api(items: [])
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.failure(CompanyAPIError.transport), .success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        await subject.refresh()
        let lost = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(lost, .failed(.lost))
        let firstID = try XCTUnwrap(stub.opens.first?.requestID)

        // The feature is switched off before the person presses Retry: nothing is sent.
        stub.capabilities = .success(try capabilities(feature: true, active: false))
        await subject.refresh()
        let retryWhileOff = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(retryWhileOff, .failed(.plain(.unavailable)))
        XCTAssertEqual(stub.opens.count, 1, "Retry did not bypass the capability gate")

        // The feature comes back: the unresolved id is reused (an unresolved operation survives the
        // gate being unavailable until a terminal outcome, its company's clearing or the account ending).
        stub.capabilities = .success(try capabilities())
        await subject.refresh()
        let again = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(again, .opened(roomID: dmRoom))
        XCTAssertEqual(stub.opens.count, 2)
        XCTAssertEqual(stub.opens[1].requestID, firstID)
    }

    @MainActor
    func testRetryAfterTheCompanysListWasDeniedDoesNotReuseTheOldRequest() async throws {
        let stub = try api(items: [])
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.failure(CompanyAPIError.transport), .success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        await subject.refresh()
        _ = await subject.conversations.start(companyID: company, others: [bao])
        let firstID = try XCTUnwrap(stub.opens.first?.requestID)

        stub.conversations = [.failure(CompanyAPIError.refused(.denied, reason: nil, retryAfter: nil))]
        await subject.refresh()
        let denied = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(denied, .failed(.plain(.unavailable)))
        XCTAssertEqual(stub.opens.count, 1)

        stub.conversations = [.success(try directory([made]))]
        await subject.refresh()
        _ = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertNotEqual(stub.opens.last?.requestID, firstID)
    }

    // MARK: Company switches are fenced

    @MainActor
    func testSwitchingCompanyWhileAConversationIsBeingMadeListsItButNeverNavigates() async throws {
        let stub = try api(items: [])
        stub.list = try twoCompanyList()
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.success(try answer(made)), .success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        await subject.refresh()
        subject.selectCompany(company)

        // Control: the person stays where they are, so the room opens.
        let stayed = await subject.startConversation(companyID: company, others: [bao])
        XCTAssertEqual(stayed, .opened(roomID: dmRoom))

        // They switch company while the answer is in flight: the conversation is made, nothing opens.
        stub.onOpen = { subject.selectCompany(self.otherCompany) }
        let moved = await subject.startConversation(companyID: company, others: [bao])
        XCTAssertEqual(moved, .settingUp)
        XCTAssertEqual(subject.activeCompanyID, otherCompany, "and they are not pulled back")
    }

    @MainActor
    func testNavigationRevalidatesTheSelectedCompanyAndTheRoomsOwner() async throws {
        let stub = try api()
        stub.list = try twoCompanyList()
        let subject = try model(stub)
        await subject.refresh()
        subject.selectCompany(company)
        subject.reconcileMatrixRooms([dmRoom, "!stranger:example.invalid"],
                                     conversationTypeClaims: [dmRoom, "!stranger:example.invalid"])
        XCTAssertTrue(subject.isSelected(companyID: company, owning: dmRoom))
        XCTAssertFalse(subject.isSelected(companyID: otherCompany, owning: dmRoom), "another company's tap")
        XCTAssertFalse(subject.isSelected(companyID: company, owning: "!stranger:example.invalid"),
                       "a room that only claims the type")
        XCTAssertFalse(subject.isSelected(companyID: company, owning: "!unknown:example.invalid"))
        subject.selectCompany(otherCompany)
        XCTAssertFalse(subject.isSelected(companyID: company, owning: dmRoom), "the person moved on")
    }

    // MARK: Round r1: authority changes close chats

    @MainActor
    func testASuccessfulListThatDropsAConversationClosesItsRoom() async throws {
        let stub = try api(items: [
            conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom),
            conversation(id: groupID, kind: .groupDM, people: groupPeople, roomID: "!group:example.invalid"),
        ])
        let subject = try model(stub)
        var lost = Set<String>()
        subject.onLeft = { lost.formUnion($0) }
        await subject.refresh()
        XCTAssertTrue(lost.isEmpty)
        // The platform no longer lists the DM: its open chat must close, not keep a composer.
        stub.conversations = [.success(try directory([
            conversation(id: groupID, kind: .groupDM, people: groupPeople, roomID: "!group:example.invalid"),
        ]))]
        await subject.refresh()
        XCTAssertEqual(lost, [dmRoom])
        XCTAssertNil(subject.conversationClaim(roomID: dmRoom))
        XCTAssertNotNil(subject.conversationClaim(roomID: "!group:example.invalid"))
    }

    @MainActor
    func testLeavingACompanyClosesItsConversationRoomsAsWellAsItsChannels() async throws {
        let stub = try api()
        stub.leaveResult = .success(try NativeAPI.decode(CompanyLeaveAcknowledgement.self, from: json([
            "schemaVersion": 2, "companyId": company, "state": "removed", "retired": true,
            "authorityGeneration": 2,
        ])))
        let subject = try model(stub)
        var lost = Set<String>()
        subject.onLeft = { lost.formUnion($0) }
        await subject.refresh()
        await subject.leave(companyID: company)
        XCTAssertTrue(lost.contains(dmRoom), "the conversation chat closes")
        XCTAssertTrue(lost.contains(channelRoom))
        XCTAssertNil(subject.conversationClaim(roomID: dmRoom))
    }

    @MainActor
    func testADowngradeClosesConversationRooms() async throws {
        let stub = try api()
        let subject = try model(stub)
        var lost = Set<String>()
        subject.onLeft = { lost.formUnion($0) }
        await subject.refresh()
        stub.listRead = .v1
        await subject.refresh()
        XCTAssertEqual(subject.phase, .hidden)
        XCTAssertTrue(lost.contains(dmRoom))
        XCTAssertNil(subject.conversationClaim(roomID: dmRoom))
    }

    @MainActor
    func testAFinalAuthenticationRefusalEndsAuthority() async throws {
        let stub = try api()
        let subject = try model(stub)
        var lost = Set<String>()
        subject.onLeft = { lost.formUnion($0) }
        await subject.refresh()
        stub.conversations = [.failure(CompanyAPIError.refused(.authentication, reason: nil, retryAfter: nil))]
        await subject.refresh()
        XCTAssertTrue(lost.contains(dmRoom))
        XCTAssertNil(subject.conversationClaim(roomID: dmRoom))
        XCTAssertFalse(subject.conversations.canMutate(companyID: company))
        XCTAssertTrue(try XCTUnwrap(subject.workspace(companyID: company)?.conversations).rows.isEmpty)
    }

    // MARK: Round r1: a failed probe closes writes, keeps lost ids

    @MainActor
    func testAFailedProbeClosesWritesAndRequestsButKeepsLostIdsForTheNextSuccessfulProbe() async throws {
        let stub = try api(items: [])
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.failure(CompanyAPIError.transport), .success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        await subject.refresh()
        let lost = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(lost, .failed(.lost))
        let firstID = try XCTUnwrap(stub.opens.first?.requestID)

        // The next probe fails: rows stay visible but stale, and nothing 1.5 is sent.
        stub.capabilities = .failure(CompanyAPIError.transport)
        let listCallsBefore = stub.listCalls
        await subject.refresh()
        let section = try XCTUnwrap(subject.workspace(companyID: company)?.conversations)
        XCTAssertEqual(section.rows.count, 1)
        XCTAssertTrue(section.isStale)
        XCTAssertFalse(subject.conversations.canMutate(companyID: company), "discovery no longer authorizes writes")
        XCTAssertFalse(subject.conversations.isFresh(roomID: dmRoom))
        XCTAssertEqual(stub.listCalls, listCallsBefore, "no 1.5 request while the probe is failing")
        let retry = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(retry, .failed(.plain(.unavailable)))
        XCTAssertEqual(stub.opens.count, 1, "Retry cannot bypass the failed probe")

        // The probe succeeds again: the same request id is replayed.
        stub.capabilities = .success(try capabilities())
        await subject.refresh()
        XCTAssertTrue(subject.conversations.canMutate(companyID: company))
        let again = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(again, .opened(roomID: dmRoom))
        XCTAssertEqual(stub.opens.last?.requestID, firstID)
    }

    // MARK: Round r1: the selection check runs around joins and opens

    @MainActor
    func testAJoinNeverRunsAfterTheCompanyOrRoomIsNoLongerCurrent() async throws {
        let stub = try api(items: [])
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.success(try answer(made)), .success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        let subject = try model(stub)
        var joined = [String]()
        subject.presence = { _ in .invited }
        subject.conversationJoin = { room in joined.append(room); return true }
        await subject.refresh()

        // Current is lost while the answer is in flight: nothing is joined or opened.
        var current = true
        stub.onOpen = { current = false }
        let moved = await subject.conversations.start(companyID: company, others: [bao], isCurrent: { current })
        XCTAssertEqual(moved, .settingUp)
        XCTAssertTrue(joined.isEmpty, "no join once the person has moved on")

        // Current until the join returns, then lost: the room is not opened.
        stub.onOpen = nil
        current = true
        var joinedYet = false
        subject.presence = { _ in joinedYet ? .joined : .invited }
        subject.conversationJoin = { room in joined.append(room); joinedYet = true; current = false; return true }
        let late = await subject.conversations.start(companyID: company, others: [bao], isCurrent: { current })
        XCTAssertEqual(late, .settingUp, "the check runs again after the join, before opening")
        XCTAssertEqual(joined, [dmRoom])
    }

    @MainActor
    func testSwitchingCompanyDuringTheOpenNeverJoinsEither() async throws {
        let stub = try api(items: [])
        stub.list = try twoCompanyList()
        let made = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        stub.openResults = [.success(try answer(made))]
        stub.conversations = [.success(try directory([made]))]
        stub.directoryFor = { [self] id in
            id == company ? .success((try? directory([made]))!)
                : .success((try? directory([]))!)
        }
        let subject = try model(stub)
        var joined = [String]()
        subject.presence = { _ in .invited }
        subject.conversationJoin = { room in joined.append(room); return true }
        await subject.refresh()
        subject.selectCompany(company)
        stub.onOpen = { subject.selectCompany(self.otherCompany) }
        let outcome = await subject.startConversation(companyID: company, others: [bao])
        XCTAssertEqual(outcome, .settingUp)
        XCTAssertTrue(joined.isEmpty)
        XCTAssertEqual(subject.activeCompanyID, otherCompany)
    }

    // MARK: Round r1: request identity is company-scoped

    @MainActor
    func testTheSamePeopleInTwoCompaniesAreTwoRequests() async throws {
        let stub = try api(items: [])
        stub.list = try twoCompanyList()
        let inA = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: dmRoom)
        let inB = conversation(id: dmID, kind: .dm, people: dmPeople, roomID: "!dm-b:example.invalid",
                               companyID: otherCompany)
        stub.directoryFor = { [self] id in .success((try? directory(id == company ? [inA] : [inB]))!) }
        stub.openResults = [.failure(CompanyAPIError.transport), .failure(CompanyAPIError.transport),
                            .failure(CompanyAPIError.transport)]
        let subject = try model(stub)
        await subject.refresh()
        _ = await subject.conversations.start(companyID: company, others: [bao])
        _ = await subject.conversations.start(companyID: otherCompany, others: [bao])
        XCTAssertEqual(stub.opens.count, 2)
        XCTAssertNotEqual(stub.opens[0].requestID, stub.opens[1].requestID,
                          "an unresolved id in one company is never replayed in another")
        // Each company's retry replays its own id.
        _ = await subject.conversations.start(companyID: company, others: [bao])
        XCTAssertEqual(stub.opens[2].requestID, stub.opens[0].requestID)
    }

    // MARK: Copy

    @MainActor
    func testTheCopyIsCompleteInFiveLocalesAndEveryRefusalIsWorded() throws {
        let english = try XCTUnwrap(ConversationPendingCopy.tables["en"])
        let locales = ["en", "vi", "ja", "zh", "zh-Hant"]
        for locale in locales {
            let table = try XCTUnwrap(ConversationPendingCopy.tables[locale], locale)
            XCTAssertEqual(Set(table.keys), Set(english.keys), "\(locale) has every key")
            for (key, value) in table {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(locale).\(key)")
            }
            XCTAssertTrue(ConversationPendingCopy.peopleSelected(3, locale: locale).contains("3"))
            XCTAssertTrue(ConversationPendingCopy.conversationGroup(4, locale: locale).contains("4"))
            XCTAssertTrue(ConversationPendingCopy.openConversation("Bảo", locale: locale).contains("Bảo"))
        }
        // The six typed reasons the closed list defines, and the keys the phone reads, are all present.
        for key in ["refusal.conversation_unavailable", "refusal.participant_unavailable", "refusal.participant_limit",
                    "refusal.participant_set_conflict", "refusal.admission_epoch_conflict",
                    "refusal.conversation_read_only", "directMessages", "newMessage", "newMessageStart",
                    "conversationNote", "conversationReadOnlyBanner", "conversationAddNote", "addPeopleTitle",
                    "conversationAttachments", "hiddenConversations"] {
            XCTAssertNotNil(english[key], key)
        }
        let copy = ConversationCopy(design: try LiveDesign())
        for refusal in [ConversationRefusal.conversationUnavailable, .participantUnavailable, .participantLimit,
                        .participantSetConflict, .admissionEpochConflict, .readOnly, .lost,
                        .plain(.denied), .plain(.conflict), .plain(.missing)] {
            XCTAssertFalse(copy.refusal(refusal).isEmpty, "\(refusal)")
        }
    }
}

// MARK: Routing (needs AppRoot.swift; the Xcode test target runs it)

extension ConversationTests {
    @MainActor
    func testAConversationRoutesToWorkplaceWhateverItsSizeAndAClaimedUnlistedRoomOpensNowhere() async throws {
        let claim = ConversationRoomClaim(companyID: "00000000-0000-4000-8000-87c6455cae48",
                                          conversationID: "00000000-0000-4000-8000-f6c6b8bb709f",
                                          kind: .dm, state: .active, roomID: "!dm:example.invalid", title: "Bảo")
        // A two-person company DM is `.people` to the room list; the directory decides before the kind does.
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: .people, classification: .conversation(claim)),
                       .teamSpace)
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: .group, classification: .conversation(claim)),
                       .teamSpace)
        XCTAssertNil(RoomRootDestination.authoritative(roomKind: .group, classification: .quarantined))
        XCTAssertNil(RoomRootDestination.authoritative(roomKind: .people, classification: .quarantined))
        // The rules for everything else are unchanged.
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: .people, classification: .unknown), .personal)
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: .group, classification: .personal), .personal)
        XCTAssertNil(RoomRootDestination.authoritative(roomKind: .group, classification: .unknown))
    }
}
