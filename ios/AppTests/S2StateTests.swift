@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import UIKit
import UserNotifications
import XCTest

final class S2StateTests: XCTestCase {
    private enum CompanyStubFailure: Error { case unavailable }

    @MainActor
    private final class CompanyAPIStub: CompanyWorkspaceAPI, @unchecked Sendable {
        var list: CompanyList
        var directories: [String: CompanyChannelDirectory]
        var snapshots: [String: CompanySnapshot]
        var failedChannels = Set<String>()
        var listFails = false
        var listUsesV1 = false
        var delayedCompanyID: String?
        var channelContinuation: CheckedContinuation<CompanyRead<CompanyChannelDirectory>, Error>?

        init(list: CompanyList,
             directories: [String: CompanyChannelDirectory],
             snapshots: [String: CompanySnapshot]) {
            self.list = list
            self.directories = directories
            self.snapshots = snapshots
        }

        func companyList() async throws -> CompanyRead<CompanyList> {
            if listFails { throw CompanyStubFailure.unavailable }
            if listUsesV1 { return .v1 }
            return .v1_1(list)
        }

        func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot> {
            guard let value = snapshots[companyID.rawValue] else { throw CompanyStubFailure.unavailable }
            return .v1_1(value)
        }

        func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory> {
            let id = companyID.rawValue
            if delayedCompanyID == id {
                return try await withCheckedThrowingContinuation { channelContinuation = $0 }
            }
            if failedChannels.contains(id) { throw CompanyStubFailure.unavailable }
            guard let value = directories[id] else { throw CompanyStubFailure.unavailable }
            return .v1_1(value)
        }

        func resumeDelayedChannel() {
            guard let id = delayedCompanyID, let value = directories[id] else {
                channelContinuation?.resume(throwing: CompanyStubFailure.unavailable)
                channelContinuation = nil
                return
            }
            delayedCompanyID = nil
            channelContinuation?.resume(returning: .v1_1(value))
            channelContinuation = nil
        }

        func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                     invitationID: NativeID) async throws -> CompanySnapshot {
            throw CompanyStubFailure.unavailable
        }

        func leaveCompany(companyID: NativeID,
                          requestID: NativeID) async throws -> CompanyLeaveAcknowledgement {
            throw CompanyStubFailure.unavailable
        }

        func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot {
            throw CompanyStubFailure.unavailable
        }
    }

    private func companyList(_ ids: [String]) throws -> CompanyList {
        try NativeAPI.decode(CompanyList.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "companies": ids.enumerated().map { index, id in [
                "id": id, "displayName": "Company \(index + 1)",
                "role": "member", "authorityGeneration": 1,
            ] },
            "invitations": [], "canCreate": false,
        ]))
    }

    private func companyDirectory(companyID: String, channelID: String,
                                  roomID: String) throws -> CompanyChannelDirectory {
        try NativeAPI.decode(CompanyChannelDirectory.self,
                             from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "channels": [[
                "schemaVersion": 2,
                "channel": [
                    "id": channelID, "companyId": companyID,
                    "displayName": "general", "visibility": "company",
                    "state": "active", "projectId": NSNull(),
                    "authorityGeneration": 1, "channelGeneration": 1,
                    "systemKey": "default",
                ],
                "memberCount": 1,
                "room": ["state": "ready", "roomId": roomID],
            ]],
        ]))
    }

    private func companySnapshot(companyID: String, channelID: String) throws -> CompanySnapshot {
        try NativeAPI.decode(CompanySnapshot.self,
                             from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "company": [
                "id": companyID, "displayName": "Company",
                "role": "member", "authorityGeneration": 1,
            ],
            "members": [[
                "memberRef": String(repeating: "a", count: 43),
                "role": "member", "state": "active", "self": true,
                "handle": "owner", "displayName": "Owner",
            ]],
            "projects": [], "defaultChannelId": channelID,
        ]))
    }
    @MainActor
    func testHomeAvatarNeverExceedsTheS6DynamicTypeCap() {
        XCTAssertEqual(AtumAvatar.cappedPointSize(base: 52, scaled: 160), 70.2, accuracy: 0.001)
        XCTAssertEqual(AtumAvatar.cappedPointSize(base: 52, scaled: 60), 60, accuracy: 0.001)
    }

    @MainActor
    func testAssistantAvatarPhotoIsSquareMetadataFreeAndProviderBounded() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 800)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1_600, height: 800))
        }
        let input = try XCTUnwrap(source.jpegData(compressionQuality: 0.95))
        let prepared = try AssistantAvatarPhoto.prepare(input)
        XCTAssertEqual(prepared.type, .jpeg)
        let bytes = try XCTUnwrap(Data(base64Encoded: prepared.base64))
        XCTAssertLessThanOrEqual(bytes.count, 2 * 1_024 * 1_024)
        let image = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertLessThanOrEqual(image.size.width, 1_024)
    }

    func testHomeSearchFoldsVietnameseDStrokeAndAccents() {
        let locale = Locale(identifier: "vi")
        XCTAssertEqual(HomeSearch.normalize("  Đặng  ", locale: locale), "dang")
        XCTAssertEqual(HomeSearch.normalize("LAN", locale: locale), "lan")
    }

    func testAddFriendAcceptsOnlyCanonicalHandlesAndReusesNewestDirectRoom() {
        XCTAssertEqual(HomeAddFriendPolicy.handle("  @Lan_Anh  ")?.rawValue, "lan_anh")
        for invalid in ["", "@ab", "a space", "1person", "lan-anh"] {
            XCTAssertNil(HomeAddFriendPolicy.handle(invalid), invalid)
        }

        func room(_ id: String, direct: Bool = true, members: [String], count: UInt64 = 2,
                  at: UInt64?) -> LiveMatrixRoomRow {
            LiveMatrixRoomRow(
                roomID: id, displayName: id, avatarURL: nil, latestText: nil,
                latestPreviewContent: .none, latestSenderID: nil, latestSenderName: nil,
                latestIsOwn: false, latestIsNotice: false, latestSendState: .sent,
                latestTimestamp: at, unreadCount: 0, notificationCount: 0,
                highlightCount: 0, isMarkedUnread: false, isFavourite: false,
                isMuted: false, isDirect: direct, memberUserIDs: members,
                memberCount: count, roomType: nil, isEncrypted: false
            )
        }
        let target = "@user:atum.test"
        let rooms = [
            room("group", direct: false, members: [target], count: 3, at: 5_000),
            room("old", members: [target], at: 1_000),
            room("new", members: [target], at: 2_000),
            room("other", members: ["@other:atum.test"], at: 3_000),
        ]
        XCTAssertEqual(HomeAddFriendPolicy.existingRoomID(in: rooms, matrixUserID: target), "new")
        XCTAssertNil(HomeAddFriendPolicy.existingRoomID(in: rooms, matrixUserID: "@missing:atum.test"))
    }

    func testNewGroupDerivesANameAndEnforcesMemberLimits() {
        let people = (0..<20).map {
            HomeGroupCandidate(id: "@person\($0):atum.test", name: "Person \($0)", kind: .person)
        }
        XCTAssertEqual(HomeGroupPolicy.name(typed: "  Design  ", selected: []), "Design")
        XCTAssertEqual(HomeGroupPolicy.name(typed: "", selected: Array(people.prefix(2))),
                       "Person 0, Person 1")
        XCTAssertNil(HomeGroupPolicy.name(typed: "", selected: []))
        XCTAssertFalse(HomeGroupPolicy.canSelect(
            HomeGroupCandidate(id: "@extra:atum.test", name: "Extra", kind: .person),
            selected: people
        ))
        let assistants = (0..<5).map {
            HomeGroupCandidate(id: "@agent\($0):atum.test", name: "Agent \($0)", kind: .assistant)
        }
        XCTAssertFalse(HomeGroupPolicy.canSelect(
            HomeGroupCandidate(id: "@agent5:atum.test", name: "Agent 5", kind: .assistant),
            selected: assistants
        ))
        XCTAssertTrue(HomeGroupPolicy.canSelect(assistants[0], selected: assistants))
    }

    func testAssistantLifecycleStorePersistsOnlyOneOpaqueRequestPerAccount() throws {
        let suite = "assistant-lifecycle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alice = LiveAssistantLifecycleStore(matrixUserID: "@alice:atum.test", defaults: defaults)
        let bob = LiveAssistantLifecycleStore(matrixUserID: "@bob:atum.test", defaults: defaults)
        let request = try NativeID("00000000-0000-4000-8000-f2e3447907ab")
        XCTAssertNil(alice.pending())
        alice.save(request)
        XCTAssertEqual(alice.pending(), request)
        XCTAssertNil(bob.pending())
        let newer = try NativeID("00000000-0000-4000-8000-13d272dc0ada")
        alice.save(newer)
        alice.clear(request)
        XCTAssertEqual(alice.pending(), newer)
        alice.clear(newer)
        XCTAssertNil(alice.pending())
    }

    func testAssistantLifecycleOpensOnlyThePublishedExactJoinedRoom() throws {
        let assistantID = "00000000-0000-4000-8000-b0e149e7f3ad"
        let principal = "00000000-0000-4000-8000-5a158f7e24f0"
        let matrixUser = "@agent-alfred:atum.test"
        let roomID = "!assistant:atum.test"
        let agent: [String: Any] = [
            "id": assistantID,
            "identity_id": "00000000-0000-4000-8000-ff5a7ca461b8",
            "display_name": "Alfred",
            "slug": NSNull(),
            "avatar": "",
            "avatar_url": NSNull(),
            "is_default": false,
            "lifecycle_revision": 1,
            "identity_revision": 1,
            "definition_revision": 1,
            "status": "active",
            "answering": "cloud",
            "principal": principal,
            "matrixUser": matrixUser,
        ]
        let roster = try NativeAPI.decode(
            AgentsResponse.self,
            from: JSONSerialization.data(withJSONObject: [agent])
        )
        let snapshot = try NativeAPI.decode(
            AgentLifecycleSnapshot.self,
            from: JSONSerialization.data(withJSONObject: [
                "profile": "atum.agent-lifecycle/1",
                "requestId": "00000000-0000-4000-8000-f2e3447907ab",
                "state": "ready",
                "assistant": agent,
                "enrollment": [
                    "enrollmentId": "00000000-0000-4000-8000-aa401efe326a",
                    "kind": "cloud",
                    "agentPrincipal": principal,
                    "executorId": "00000000-0000-4000-8000-4ec6fd83c508",
                    "state": "active",
                    "trust": "trusted",
                    "conversationReady": true,
                ],
                "roomId": roomID,
            ])
        )
        let authoritative = HomeAssistantLifecyclePolicy.authoritativeAgent(
            for: snapshot, in: roster.agents
        )

        func room(_ id: String, members: [String]) -> LiveMatrixRoomRow {
            LiveMatrixRoomRow(
                roomID: id, displayName: "Alfred", avatarURL: nil, latestText: nil,
                latestPreviewContent: .none, latestSenderID: nil, latestSenderName: nil,
                latestIsOwn: false, latestIsNotice: false, latestSendState: .sent,
                latestTimestamp: nil, unreadCount: 0, notificationCount: 0,
                highlightCount: 0, isMarkedUnread: false, isFavourite: false,
                isMuted: false, isDirect: true, memberUserIDs: members,
                memberCount: 2, roomType: nil, isEncrypted: false
            )
        }

        XCTAssertEqual(HomeAssistantLifecyclePolicy.joinedRoomID(
            for: snapshot, authoritativeAgent: authoritative,
            rooms: [room(roomID, members: [matrixUser])]
        ), roomID)
        XCTAssertNil(HomeAssistantLifecyclePolicy.joinedRoomID(
            for: snapshot, authoritativeAgent: authoritative,
            rooms: [room(roomID, members: ["@someone-else:atum.test"])]
        ))
        XCTAssertNil(HomeAssistantLifecyclePolicy.joinedRoomID(
            for: snapshot, authoritativeAgent: authoritative,
            rooms: [room("!other:atum.test", members: [matrixUser])]
        ))
    }

    func testPushRoutingAcceptsOnlyBoundedMatrixRoomIDs() {
        XCTAssertEqual(LivePushRouting.roomID(from: ["room_id": "!room:atum.test"]),
                       "!room:atum.test")
        for value in ["", "room:atum.test", "!room", "!room :atum.test",
                      "!" + String(repeating: "x", count: 260) + ":atum.test"] {
            XCTAssertNil(LivePushRouting.roomID(from: ["room_id": value]), value)
        }
        XCTAssertNil(LivePushRouting.roomID(from: ["room_id": 4]))
        XCTAssertTrue(LivePushRouting.belongs(["room_id": "!room:atum.test"],
                                              to: "!room:atum.test"))
        XCTAssertFalse(LivePushRouting.belongs(["room_id": "!other:atum.test"],
                                               to: "!room:atum.test"))
    }

    func testPushPresentationMapsThePureDecisionWithoutExtraOptions() {
        XCTAssertEqual(LivePushRouting.options(for: .suppress), [])
        XCTAssertEqual(LivePushRouting.options(for: .present([.banner, .list, .sound])),
                       [.banner, .list, .sound])
    }

    @MainActor
    func testPushRelayKeepsOneColdIntentAndUsesTheCurrentSurface() {
        let relay = LiveRemoteNotificationRelay()
        relay.deliver(roomID: "!first:atum.test")
        relay.deliver(roomID: "!latest:atum.test")
        var delivered = [String]()
        var screen = PushPresentation.Screen.homeRoot
        relay.update(screen: screen)
        relay.attach(onToken: { _ in }, onFailure: { _ in },
                     onRoomIntent: { delivered.append($0) })
        XCTAssertEqual(delivered, ["!latest:atum.test"])
        XCTAssertEqual(relay.foregroundOptions(roomID: "!latest:atum.test"), [])
        screen = .other
        relay.update(screen: screen)
        XCTAssertEqual(relay.foregroundOptions(roomID: "!latest:atum.test"),
                       [.banner, .list, .sound])
    }

    @MainActor
    func testRouterPushScreenReadsLivePresentationState() {
        let router = Router()
        XCTAssertEqual(router.pushScreen, .homeRoot)
        router.open(roomId: "!room:atum.test")
        XCTAssertEqual(router.pushScreen, .chat(roomID: "!room:atum.test"))
        router.presentationChanged(true)
        XCTAssertEqual(router.pushScreen, .other)
        router.presentationChanged(false)
        router.select(tab: .drive)
        XCTAssertEqual(router.pushScreen, .other)
        router.select(tab: .store)
        XCTAssertEqual(router.pushScreen, .other)
    }

    @MainActor
    func testAuthoritativeCompanyRoomUsesTeamSpaceStack() throws {
        let companyID = "00000000-0000-4000-8000-95eb2692c90e"
        let channelID = "00000000-0000-4000-8000-b4b6412c243e"
        var directory = CompanyRoomDirectory()
        directory.absorb(
            try companyDirectory(companyID: companyID, channelID: channelID,
                                 roomID: "!company:atum.test"),
            companyID: try NativeID(companyID)
        )
        let claim = try XCTUnwrap(directory.claim(roomID: "!company:atum.test"))
        XCTAssertEqual(RoomRootDestination.authoritative(
            roomKind: .people, classification: .unknown
        ), .personal)
        XCTAssertNil(RoomRootDestination.authoritative(
            roomKind: .group, classification: .unknown
        ))
        XCTAssertEqual(RoomRootDestination.authoritative(
            roomKind: .group,
            classification: .company(claim)
        ), .teamSpace)

        let router = Router()
        router.openTeamSpace(roomId: "!company:atum.test")
        XCTAssertEqual(router.selectedTab, .teamSpace)
        XCTAssertEqual(router.teamSpaceRoomID, "!company:atum.test")
        XCTAssertNil(router.homeRoomID)
        XCTAssertEqual(router.pushScreen, .chat(roomID: "!company:atum.test"))
    }

    @MainActor
    func testPersonalAndTeamSpaceKeepIndependentBackstacks() {
        let router = Router()
        router.open(roomId: "!person:atum.test")
        router.openTeamSpace(roomId: "!company:atum.test")
        XCTAssertEqual(router.homePath.count, 1)
        XCTAssertEqual(router.teamSpacePath.count, 1)

        router.popTeamSpaceToRoot()
        XCTAssertTrue(router.teamSpacePath.isEmpty)
        XCTAssertNil(router.teamSpaceRoomID)
        XCTAssertEqual(router.homePath.count, 1)
        XCTAssertEqual(router.homeRoomID, "!person:atum.test")
    }

    @MainActor
    func testTeamSpaceChatNotificationAndTabTransitionUseActiveMode() {
        let router = Router()
        router.openTeamSpace(roomId: "!company:atum.test")
        XCTAssertEqual(router.pushScreen, .chat(roomID: "!company:atum.test"))
        router.presentationChanged(true)
        XCTAssertEqual(router.pushScreen, .other)
        router.presentationChanged(false)
        XCTAssertEqual(router.pushScreen, .chat(roomID: "!company:atum.test"))

        var callback: (Router.Tab, Router.Tab)?
        router.onUserSelectedTab = { callback = ($0, router.selectedTab) }
        router.select(tab: .store)
        XCTAssertEqual(callback?.0, .store)
        XCTAssertEqual(callback?.1, .store,
                       "AppRoot can dismiss the Team sheet after the selected tab is current")
        XCTAssertEqual(router.teamSpacePath.count, 1,
                       "tab changes do not destroy the independent Workplace stack")
        XCTAssertNil(router.activeRoomID)
    }

    func testLeavingOneCompanyClosesOnlyItsOpenRoom() {
        let removedA: Set<String> = ["!company-a:atum.test"]
        XCTAssertTrue(CompanyRoomRemovalFence.closes(
            openRoomID: "!company-a:atum.test", removedRoomIDs: removedA
        ))
        XCTAssertFalse(CompanyRoomRemovalFence.closes(
            openRoomID: "!company-b:atum.test", removedRoomIDs: removedA
        ))
        XCTAssertFalse(CompanyRoomRemovalFence.closes(openRoomID: nil, removedRoomIDs: removedA))
    }

    @MainActor
    func testCompanyClassificationWaitsForDelayedFirstDirectory() async throws {
        let company = "00000000-0000-4000-8000-eb0c07319adc"
        let channel = "00000000-0000-4000-8000-7cf9de70f536"
        let room = "!company-a:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([company]),
            directories: [company: try companyDirectory(
                companyID: company, channelID: channel, roomID: room
            )],
            snapshots: [company: try companySnapshot(companyID: company, channelID: channel)]
        )
        api.delayedCompanyID = company
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        let router = Router()
        router.holdDeepLink(roomID: room, cold: true)

        let refresh = Task { await model.refresh() }
        while api.channelContinuation == nil { await Task.yield() }
        XCTAssertEqual(model.phase, .probing)
        XCTAssertFalse(model.classificationComplete)
        XCTAssertEqual(model.roomClassification(room), .unknown)
        XCTAssertFalse(router.validatePendingDeepLink(
            sessionAndRosterAreReady: true
        ) { roomID in
            RoomPushDecision.decide(
                canOpen: true,
                destination: RoomRootDestination.authoritative(
                    roomKind: .group, classification: model.roomClassification(roomID)
                )
            )
        })
        XCTAssertEqual(router.pendingDeepLinkRoomID, room)

        api.resumeDelayedChannel()
        await refresh.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.classificationComplete)
        guard case .company = model.roomClassification(room) else {
            return XCTFail("ready company directory did not own its room")
        }
        router.onValidatedColdRoom = { roomID in
            if RoomRootDestination.authoritative(
                roomKind: .group, classification: model.roomClassification(roomID)
            ) == .teamSpace {
                router.stageColdTeamSpaceRoom(roomID: roomID)
            }
        }
        XCTAssertTrue(router.validatePendingDeepLink(
            sessionAndRosterAreReady: true
        ) { roomID in
            RoomPushDecision.decide(
                canOpen: true,
                destination: RoomRootDestination.authoritative(
                    roomKind: .group, classification: model.roomClassification(roomID)
                )
            )
        })
        XCTAssertNil(router.pendingDeepLinkRoomID)
        XCTAssertEqual(router.selectedTab, .teamSpace)
        XCTAssertEqual(router.teamSpaceRoomID, room)

        let foregroundRoom = "!personal:atum.test"
        var foregroundRouted: String?
        router.onValidatedRoom = { foregroundRouted = $0 }
        router.holdDeepLink(roomID: foregroundRoom)
        XCTAssertFalse(router.validatePendingDeepLink(sessionAndRosterAreReady: true) { roomID in
            RoomPushDecision.decide(
                canOpen: true,
                destination: RoomRootDestination.authoritative(
                    roomKind: .group, classification: model.roomClassification(roomID)
                )
            )
        })
        XCTAssertEqual(router.pendingDeepLinkRoomID, foregroundRoom)
        model.reconcileMatrixRooms([room, foregroundRoom])
        XCTAssertTrue(router.validatePendingDeepLink(sessionAndRosterAreReady: true) { roomID in
            RoomPushDecision.decide(
                canOpen: true,
                destination: RoomRootDestination.authoritative(
                    roomKind: .group, classification: model.roomClassification(roomID)
                )
            )
        })
        XCTAssertEqual(foregroundRouted, foregroundRoom)
    }

    @MainActor
    func testPartialRefreshKeepsKnownRoomsAndLeavesNewRoomUnknown() async throws {
        let companyA = "00000000-0000-4000-8000-dd28ba2fee70"
        let companyB = "00000000-0000-4000-8000-bfe45f77dee7"
        let channelA = "00000000-0000-4000-8000-3333d17baab2"
        let channelB = "00000000-0000-4000-8000-b94b782aef88"
        let roomA = "!company-a:atum.test"
        let roomB = "!company-b:atum.test"
        let personal = "!family:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([companyA, companyB]),
            directories: [
                companyA: try companyDirectory(companyID: companyA, channelID: channelA, roomID: roomA),
                companyB: try companyDirectory(companyID: companyB, channelID: channelB, roomID: roomB),
            ],
            snapshots: [
                companyA: try companySnapshot(companyID: companyA, channelID: channelA),
                companyB: try companySnapshot(companyID: companyB, channelID: channelB),
            ]
        )
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        await model.refresh()
        model.reconcileMatrixRooms([roomA, roomB, personal])
        XCTAssertEqual(model.roomClassification(personal), .personal)

        api.failedChannels = [companyB]
        await model.refresh()
        model.reconcileMatrixRooms([roomA, roomB, personal, "!new:atum.test"])
        XCTAssertFalse(model.classificationComplete)
        guard case .company = model.roomClassification(roomA) else { return XCTFail("A lost") }
        guard case .company = model.roomClassification(roomB) else { return XCTFail("B cache lost") }
        XCTAssertEqual(model.roomClassification(personal), .personal)
        XCTAssertEqual(model.roomClassification("!new:atum.test"), .unknown)
    }

    @MainActor
    func testCompanyListOutageKeepsValidatedPersonalGroupButNotNewGroup() async throws {
        let company = "00000000-0000-4000-8000-bc8bb9605315"
        let channel = "00000000-0000-4000-8000-8c97d79389b6"
        let companyRoom = "!company:atum.test"
        let personal = "!family:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([company]),
            directories: [company: try companyDirectory(
                companyID: company, channelID: channel, roomID: companyRoom
            )],
            snapshots: [company: try companySnapshot(companyID: company, channelID: channel)]
        )
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        await model.refresh()
        model.reconcileMatrixRooms([companyRoom, personal])

        api.listFails = true
        await model.refresh()
        model.reconcileMatrixRooms([companyRoom, personal, "!new:atum.test"])
        XCTAssertEqual(model.roomClassification(personal), .personal)
        guard case .company = model.roomClassification(companyRoom) else {
            return XCTFail("known company identity was not cached")
        }
        XCTAssertEqual(model.roomClassification("!new:atum.test"), .unknown)
    }

    @MainActor
    func testRemoteCompanyRemovalEvictsOnlyItsRooms() async throws {
        let companyA = "00000000-0000-4000-8000-24c3daf60bf4"
        let companyB = "00000000-0000-4000-8000-1a8879849e5a"
        let channelA = "00000000-0000-4000-8000-e531400cafeb"
        let channelB = "00000000-0000-4000-8000-40fd71b1efb8"
        let roomA = "!company-a:atum.test"
        let roomB = "!company-b:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([companyA, companyB]),
            directories: [
                companyA: try companyDirectory(companyID: companyA, channelID: channelA, roomID: roomA),
                companyB: try companyDirectory(companyID: companyB, channelID: channelB, roomID: roomB),
            ],
            snapshots: [
                companyA: try companySnapshot(companyID: companyA, channelID: channelA),
                companyB: try companySnapshot(companyID: companyB, channelID: channelB),
            ]
        )
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        var evicted = Set<String>()
        model.onLeft = { evicted = $0 }
        await model.refresh()

        api.list = try companyList([companyB])
        await model.refresh()
        XCTAssertEqual(evicted, [roomA])
        XCTAssertEqual(model.roomClassification(roomA), .unknown)
        guard case .company = model.roomClassification(roomB) else {
            return XCTFail("retained company B lost its route")
        }
        XCTAssertFalse(CompanyRoomRemovalFence.closes(
            openRoomID: roomB, removedRoomIDs: evicted
        ))
    }

    @MainActor
    func testAccountScopeClearsCompanyAndPersonalRoomIdentityWithoutBreakingReconnect() async throws {
        let company = "00000000-0000-4000-8000-157a30343cf3"
        let channel = "00000000-0000-4000-8000-35600c849c7c"
        let companyRoom = "!company:atum.test"
        let personalRoom = "!family:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([company]),
            directories: [company: try companyDirectory(
                companyID: company, channelID: channel, roomID: companyRoom
            )],
            snapshots: [company: try companySnapshot(companyID: company, channelID: channel)]
        )
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        model.beginAccountScope("@alice:atum.test")
        await model.refresh()
        model.reconcileMatrixRooms([companyRoom, personalRoom])

        model.beginAccountScope("@alice:atum.test")
        XCTAssertEqual(model.roomClassification(personalRoom), .personal,
                       "same-account reconnect preserves classification")
        model.beginAccountScope("@bob:atum.test")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.roomClassification(companyRoom), .unknown)
        XCTAssertEqual(model.roomClassification(personalRoom), .unknown)

        let router = Router()
        router.open(roomId: personalRoom)
        router.openTeamSpace(roomId: companyRoom)
        router.holdDeepLink(roomID: "!pending:atum.test", cold: true)
        router.presentationChanged(true)
        router.presentAccount()
        router.resetAccountScope()
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.homePath.isEmpty && router.teamSpacePath.isEmpty)
        XCTAssertNil(router.homeRoomID)
        XCTAssertNil(router.teamSpaceRoomID)
        XCTAssertNil(router.pendingDeepLinkRoomID)
        XCTAssertFalse(router.hasActivePresentation)
        XCTAssertFalse(router.isAccountPresented)
    }

    @MainActor
    func testPermanentV1DowngradePreservesValidatedRoomClassification() async throws {
        let company = "00000000-0000-4000-8000-91320823a72f"
        let channel = "00000000-0000-4000-8000-13746fa86639"
        let companyRoom = "!company:atum.test"
        let personalRoom = "!family:atum.test"
        let api = CompanyAPIStub(
            list: try companyList([company]),
            directories: [company: try companyDirectory(
                companyID: company, channelID: channel, roomID: companyRoom
            )],
            snapshots: [company: try companySnapshot(companyID: company, channelID: channel)]
        )
        let model = CompanyWorkspaceModel()
        model.clientProvider = { api }
        await model.refresh()
        model.reconcileMatrixRooms([companyRoom, personalRoom])

        api.listUsesV1 = true
        await model.refresh()
        model.reconcileMatrixRooms([companyRoom, personalRoom, "!new:atum.test"])
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertFalse(model.classificationComplete)
        guard case .company = model.roomClassification(companyRoom) else {
            return XCTFail("downgrade forgot a validated company room")
        }
        XCTAssertEqual(model.roomClassification(personalRoom), .personal)
        XCTAssertEqual(model.roomClassification("!new:atum.test"), .unknown)
    }

    @MainActor
    func testColdValidatedLinkUsesColdCallbackAndStagesWithoutAnimation() {
        let router = Router()
        var coldRoom: String?
        router.onValidatedColdRoom = { coldRoom = $0 }
        router.holdDeepLink(roomID: "!cold:atum.test", cold: true)
        XCTAssertTrue(router.validatePendingDeepLink(sessionAndRosterAreReady: true) { _ in .allow })
        XCTAssertEqual(coldRoom, "!cold:atum.test")
        XCTAssertNil(router.homeRoomID)
        router.stageColdRoom(roomID: "!cold:atum.test")
        XCTAssertEqual(router.homeRoomID, "!cold:atum.test")

        router.stageColdTeamSpaceRoom(roomID: "!cold-company:atum.test")
        XCTAssertEqual(router.selectedTab, .teamSpace)
        XCTAssertEqual(router.teamSpaceRoomID, "!cold-company:atum.test")
        XCTAssertEqual(router.teamSpacePath.count, 1)
        XCTAssertEqual(router.homePath.count, 1)
    }

    @MainActor
    func testRoomMutationQueueSerializesRapidSameFieldToggles() async {
        let queue = RoomMutationQueue<String>()
        var order = [String]()
        var releaseFirst: CheckedContinuation<Void, Never>?
        queue.enqueue(for: "pin") {
            order.append("first-start")
            await withCheckedContinuation { releaseFirst = $0 }
            order.append("first-end")
        }
        while releaseFirst == nil { await Task.yield() }
        queue.enqueue(for: "pin") { order.append("second") }
        await Task.yield()
        XCTAssertEqual(order, ["first-start"])
        releaseFirst?.resume()
        await queue.waitForIdle("pin")
        XCTAssertEqual(order, ["first-start", "first-end", "second"])
    }

    func testCompletedOptimisticMutationYieldsToNextAuthoritativePublication() {
        let inFlight = PendingRoomMutation(desired: false, generation: 1,
                                           settleAfterRoomRevision: nil)
        XCTAssertFalse(inFlight.shouldRetire(actualMatches: false, publicationRevision: 9))
        let completed = PendingRoomMutation(desired: false, generation: 1,
                                            settleAfterRoomRevision: 10)
        XCTAssertFalse(completed.shouldRetire(actualMatches: false, publicationRevision: 10),
                       "a concurrent in-flight publication cannot retire the optimistic value")
        XCTAssertTrue(completed.shouldRetire(actualMatches: false, publicationRevision: 11),
                      "new activity after mark-read must replace the optimistic zero badge")
        XCTAssertTrue(inFlight.shouldRetire(actualMatches: true, publicationRevision: 9))
    }

    func testChatInfoMembersPutMeFirstThenUseTheAppLocale() {
        let info = ChatInfoPresentation(
            roomID: "room", title: "Group", kind: .group(memberCount: 3),
            members: [
                .init(userID: "z", name: "Zoe", matrixAvatarURI: nil,
                      isAssistant: false, isCurrentUser: false),
                .init(userID: "me", name: "Minh", matrixAvatarURI: nil,
                      isAssistant: false, isCurrentUser: true),
                .init(userID: "a", name: "Ánh", matrixAvatarURI: nil,
                      isAssistant: true, isCurrentUser: false),
            ]
        )
        XCTAssertEqual(info.sortedMembers(locale: Locale(identifier: "vi")).map(\.userID),
                       ["me", "a", "z"])
    }

    func testChatInfoNeverPromotesUnknownAppVerificationToOfficial() {
        XCTAssertNil(ChatInfoAppTier.presentation(nil))
        XCTAssertEqual(ChatInfoAppTier.presentation(.official), .official)
        XCTAssertEqual(ChatInfoAppTier.presentation(.verified), .verified)
    }

    func testChatInfoUsesMessageDisclosureOnlyForConfirmedPlainRooms() {
        let plain = ChatInfoPresentation(roomID: "plain", title: "Family", kind: .group(memberCount: 3),
                                         roomIsEncrypted: false)
        let encrypted = ChatInfoPresentation(roomID: "encrypted", title: "Family",
                                             kind: .group(memberCount: 3), roomIsEncrypted: true)

        XCTAssertEqual(plain.assistantAccessCopyKey, .infoAssistantAccessPlain)
        XCTAssertEqual(encrypted.assistantAccessCopyKey, .infoAssistantAccessEncrypted)
    }

    func testOptimisticReadProjectionClearsEveryBadgeCounter() {
        let room = LiveProductRoom(id: "room", kind: .people, title: "Lan",
                                   unreadCount: 8, notificationCount: 5, highlightCount: 2,
                                   isMarkedUnread: true, isPinned: false, isMuted: false)
        let read = room.withRosterState(unreadOverride: false,
                                        pinnedOverride: true, mutedOverride: true)
        XCTAssertEqual(read.unreadCount, 0)
        XCTAssertEqual(read.notificationCount, 0)
        XCTAssertEqual(read.highlightCount, 0)
        XCTAssertFalse(read.isMarkedUnread)
        XCTAssertTrue(read.isPinned)
        XCTAssertTrue(read.isMuted)
    }

    /// Every live room passes through this projection; a field it drops is lost
    /// app-wide. A company channel's `m.room.avatar` is the company logo.
    func testRosterProjectionKeepsEveryFieldItDoesNotOverride() {
        let room = LiveProductRoom(id: "!channel:atum.test", kind: .group, title: "general",
                                   detail: "Acme", latestEventAt: Date(timeIntervalSince1970: 1_000),
                                   latestSenderName: "Lan", matrixAvatarURL: "mxc://atum.test/hero",
                                   avatarSHA256: "abc", appAccent: "#123456",
                                   unreadCount: 3, notificationCount: 2, highlightCount: 1,
                                   isMarkedUnread: true, isPinned: true, isMuted: true,
                                   isLowPriority: true, canOpen: false, isAwaitingRoom: true,
                                   isComingSoon: true, awaitsStart: true, isFounder: true,
                                   claimsConversationType: true,
                                   roomAvatarURL: "mxc://atum.test/acme-logo")
        XCTAssertEqual(room.withRosterState(), room)
        XCTAssertEqual(room.withRosterState(pinnedOverride: false).roomAvatarURL,
                       "mxc://atum.test/acme-logo")
    }

    func testAuthoritativeReadProjectionRestoresEveryBadgeCounter() {
        let room = LiveProductRoom(id: "room", kind: .people, title: "Lan",
                                   unreadCount: 0, notificationCount: 0, highlightCount: 0,
                                   isMarkedUnread: false)
        let restored = room.withRosterState(
            unreadOverride: false,
            unreadCountOverride: 8,
            notificationCountOverride: 5,
            highlightCountOverride: 2
        )
        XCTAssertEqual(restored.unreadCount, 8)
        XCTAssertEqual(restored.notificationCount, 5)
        XCTAssertEqual(restored.highlightCount, 2)
        XCTAssertFalse(restored.isMarkedUnread)
    }

    func testSyntheticAppRowCannotBeDeletedAgain() {
        let synthetic = HomeRow(id: "app", roomID: "app:moon", kind: .app, name: "Moon")
        let room = HomeRow(id: "room", roomID: "!moon:atum.test", kind: .app, name: "Moon")
        XCTAssertFalse(synthetic.canDeleteAppRoom)
        XCTAssertTrue(room.canDeleteAppRoom)
    }

    func testPinLimitStillOffersAppDeleteForVoiceOverParity() {
        let appRoom = HomeRow(id: "room", roomID: "!moon:atum.test", kind: .app, name: "Moon")
        XCTAssertFalse(HomeRowActionPolicy.canOfferPin(
            row: appRoom, pinnedCount: RosterProjection.pinLimit
        ))
        XCTAssertTrue(HomeRowActionPolicy.offersDelete(row: appRoom, hasDeleteAction: true))
    }

    @MainActor
    func testRouterReplacesChatAndTreatsSameRoomAsLatestRequest() {
        let router = Router()
        var latestRoomIDs = [String]()
        router.onOpenCurrentRoom = { latestRoomIDs.append($0) }

        router.open(roomId: "!first:atum.test")
        router.open(roomId: "!second:atum.test")

        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertEqual(router.homeRoomID, "!second:atum.test")
        XCTAssertEqual(router.homePath.count, 1)

        router.open(roomId: "!second:atum.test")
        XCTAssertEqual(router.homePath.count, 1)
        XCTAssertEqual(latestRoomIDs, ["!second:atum.test"])
    }

    @MainActor
    func testRouterRetapAndHeldLinkValidation() {
        let router = Router()
        var rootRetaps = 0
        router.onHomeRootRetap = { rootRetaps += 1 }

        router.select(tab: .home)
        XCTAssertEqual(rootRetaps, 1)

        router.holdDeepLink(roomID: "!known:atum.test")
        XCTAssertFalse(router.validatePendingDeepLink(sessionAndRosterAreReady: false) { _ in .allow })
        XCTAssertEqual(router.pendingDeepLinkRoomID, "!known:atum.test")
        XCTAssertTrue(router.validatePendingDeepLink(sessionAndRosterAreReady: true) {
            $0 == "!known:atum.test" ? .allow : .deny
        })
        XCTAssertNil(router.pendingDeepLinkRoomID)
        XCTAssertEqual(router.homeRoomID, "!known:atum.test")

        router.select(tab: .home)
        XCTAssertNil(router.homeRoomID)
        XCTAssertTrue(router.homePath.isEmpty)

        router.holdDeepLink(roomID: "!unknown:atum.test")
        XCTAssertFalse(router.validatePendingDeepLink(sessionAndRosterAreReady: true) { _ in .deny })
        XCTAssertNil(router.pendingDeepLinkRoomID)
        XCTAssertTrue(router.homePath.isEmpty)
    }

    @MainActor
    func testRouterNotificationFallbackDismissesAndReturnsHomeToRoot() {
        let router = Router()
        var dismissals = 0
        router.dismissPresentation = { dismissals += 1 }
        router.open(roomId: "!open:atum.test")
        router.select(tab: .drive)
        router.showHomeRoot()
        XCTAssertEqual(dismissals, 2)
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertNil(router.homeRoomID)
        XCTAssertTrue(router.homePath.isEmpty)
    }

    @MainActor
    func testRouterPopClearsPresentationBeforeReturningToHomeRoot() {
        let router = Router()
        router.open(roomId: "!open:atum.test")
        router.presentationChanged(true)
        XCTAssertEqual(router.pushScreen, .other)

        router.popHomeToRoot()

        XCTAssertFalse(router.hasActivePresentation)
        XCTAssertEqual(router.pushScreen, .homeRoot)
    }

    @MainActor
    func testRouterHandsValidatedLiveLinkToModelBeforeMutatingPath() {
        let router = Router()
        var handedOff: String?
        router.onValidatedRoom = { handedOff = $0 }
        router.holdDeepLink(roomID: "!known:atum.test")

        XCTAssertTrue(router.validatePendingDeepLink(sessionAndRosterAreReady: true) { _ in .allow })
        XCTAssertEqual(handedOff, "!known:atum.test")
        XCTAssertTrue(router.homePath.isEmpty)
        XCTAssertNil(router.homeRoomID)
    }

    func testRoomListControllerReadsOnlyTouchedRooms() async throws {
        let recorder = RoomReadRecorder()
        let controller = RoomListController<String> { roomID in
            await recorder.read(roomID)
            return roomID.uppercased()
        }

        let initial = try await controller.apply([.reset(["a", "b"])])
        XCTAssertEqual(initial?.entries.map(\.roomID), ["a", "b"])
        XCTAssertEqual(initial?.entries.map(\.value), ["A", "B"])
        let initialReads = await recorder.values()
        XCTAssertEqual(initialReads, ["a", "b"])

        let changed = try await controller.apply([.set(index: 1, roomID: "c")])
        XCTAssertEqual(changed?.entries.map(\.roomID), ["a", "c"])
        let changedReads = await recorder.values()
        XCTAssertEqual(changedReads, ["a", "b", "c"])

        let removed = try await controller.apply([.remove(index: 0)])
        XCTAssertEqual(removed?.entries.map(\.roomID), ["c"])
        let removedReads = await recorder.values()
        XCTAssertEqual(removedReads, ["a", "b", "c"])
    }

    func testRoomListControllerDropsAStaleSuspendedRead() async throws {
        let reader = SuspendedRoomReader()
        let controller = RoomListController<String> { roomID in
            await reader.read(roomID)
        }
        let staleTask = Task { try await controller.apply([.reset(["slow"])]) }
        await reader.waitUntilSlowReadStarts()

        let current = try await controller.apply([.reset(["current"])])
        XCTAssertEqual(current?.entries.map(\.roomID), ["current"])

        await reader.releaseSlowRead()
        let stale = try await staleTask.value
        XCTAssertNil(stale)
    }

    func testRemovalOvertakingFirstReadStillPublishesRemainingRoom() async throws {
        let reader = SuspendedRoomReader()
        let controller = RoomListController<String> { roomID in
            await reader.read(roomID)
        }
        let staleTask = Task { try await controller.apply([.reset(["slow", "removed"])]) }
        await reader.waitUntilSlowReadStarts()

        let current = try await controller.apply([.remove(index: 1)])
        XCTAssertEqual(current?.entries.map(\.roomID), ["slow"])
        XCTAssertEqual(current?.entries.map(\.value), ["slow"])

        await reader.releaseSlowRead()
        let stale = try await staleTask.value
        XCTAssertNil(stale)
    }

    func testRoomListControllerRejectsMalformedDiffWithoutPublishing() async throws {
        let controller = RoomListController<String> { $0 }
        do {
            _ = try await controller.apply([.remove(index: 0)])
            XCTFail("Expected invalidDiff")
        } catch let error as RoomListControllerError {
            XCTAssertEqual(error, .invalidDiff)
        }
    }

    func testRoomListControllerRejectsEmptyAndDuplicateRoomIDs() async throws {
        let controller = RoomListController<String> { $0 }
        for updates: [RoomListDiff] in [
            [.reset(["valid", ""])],
            [.reset(["duplicate", "duplicate"])],
        ] {
            do {
                _ = try await controller.apply(updates)
                XCTFail("Expected invalidDiff for \(updates)")
            } catch let error as RoomListControllerError {
                XCTAssertEqual(error, .invalidDiff)
            }
        }
    }

    @MainActor
    func testRosterStoreKeepsClassificationAcrossRoomOnlyUpdates() {
        let assistant = RosterProjection.Assistant(id: "assistant", conversationRoomID: "a", agentOrder: 0)
        let app = RosterProjection.App(id: "app", rosterOrder: 0, conversationRoomID: "app-room")
        let initial = RosterSnapshot(
            rooms: [
                .init(id: "a", kind: .assistant(agentID: "assistant")),
                .init(id: "person", kind: .person),
                .init(id: "app-room", kind: .app(appID: "app")),
            ],
            assistants: [assistant], apps: [app]
        )
        let store = RosterStore(snapshot: initial)
        XCTAssertEqual(store.assistantRows.map(\.roomID), ["a"])
        XCTAssertEqual(store.chatRows.map(\.roomID), ["person", "app-room"])

        store.applyRooms([
            .init(id: "a", kind: .assistant(agentID: "assistant")),
            .init(id: "new-person", kind: .person),
            .init(id: "app-room", kind: .app(appID: "app")),
        ])
        XCTAssertEqual(store.snapshot.assistants, [assistant])
        XCTAssertEqual(store.snapshot.apps, [app])
        XCTAssertEqual(store.chatRows.map(\.roomID), ["new-person", "app-room"])
    }

    @MainActor
    func testRosterStoreIndexesFirstDuplicateRoomOnly() {
        let first = RosterProjection.Room(id: "same", kind: .person, isFavourite: true)
        let second = RosterProjection.Room(id: "same", kind: .group, isFavourite: false)
        let store = RosterStore(snapshot: RosterSnapshot(rooms: [first, second]))
        XCTAssertEqual(store.roomsByID["same"], first)
        XCTAssertEqual(store.chatRows.map(\.roomID), ["same"])
    }

    @MainActor
    func testLiveRosterRowPreservesHomeSignals() {
        let room = LiveMatrixRoomRow(
            roomID: "room", displayName: "Room", avatarURL: nil,
            latestText: "line one\nline two",
            latestPreviewContent: .text("line one\nline two"), latestSenderID: "sender",
            latestSenderName: "Sender", latestIsOwn: false, latestIsNotice: true,
            latestSendState: .cannotBeSent, latestTimestamp: 1_000,
            unreadCount: 7, notificationCount: 5, highlightCount: 3,
            isMarkedUnread: true, isFavourite: true, isMuted: true,
            isDirect: true, memberUserIDs: ["sender"], memberCount: 2,
            roomType: nil, isEncrypted: false
        )
        let product = LiveRosterRows.agentRow(room, title: "Moon", avatar: .monogram("M"),
                                              app: nil, isBotRoom: true)
        XCTAssertEqual(product.latestSenderName, "Sender")
        XCTAssertEqual(product.latestSendState, .cannotBeSent)
        XCTAssertEqual(product.notificationCount, 5)
        XCTAssertEqual(product.highlightCount, 3)
        XCTAssertTrue(product.isMarkedUnread)
        XCTAssertTrue(product.isPinned)
        XCTAssertTrue(product.isMuted)
        XCTAssertEqual(product.previewContent, .appNotice([
            .init(localeIdentifier: "vi", text: "line one"),
            .init(localeIdentifier: "en", text: "line two"),
        ]))
        let home = HomeRow(product: product, locale: Locale(identifier: "vi"))
        XCTAssertEqual(home.badge, .mention(5))
        XCTAssertEqual(home.preview.value, .appNotice("line one"))
        XCTAssertEqual(home.preview.sendState, .cannotBeSent)
        XCTAssertTrue(home.isPinned)
        XCTAssertTrue(home.isMuted)
    }

    @MainActor
    func testAnAgentWithoutItsRoomShowsGettingReadyAndStaysClosed() throws {
        let rows = ScriptedHomeHost.rows(ScriptedRoster(rooms: []), locale: "vi")
        let atum = try XCTUnwrap(
            rows.first(where: { $0.id == "agent:00000000-0000-4000-8000-89c0dd5b3309" })
        )
        XCTAssertFalse(atum.canOpen)
        XCTAssertTrue(atum.isAwaitingRoom)
        XCTAssertEqual(atum.detail, "Đang chuẩn bị")
        XCTAssertEqual(atum.previewContent, .text("Đang chuẩn bị"))
        let home = HomeRow(product: atum, locale: Locale(identifier: "vi"))
        XCTAssertFalse(home.canOpen)
        XCTAssertTrue(home.isWaitingForRoom)
    }

    @MainActor
    func testDuplicatePlainAgentRoomsKeepTheirDisabledRowWithoutTheWaitingLine() throws {
        let rows = ScriptedHomeHost.rows(ScriptedRoster(rooms: [
            ScriptedRosterRoom(roomID: "!atum-a:atum.test", name: "Atum",
                               members: [ScriptedCast.atum]),
            ScriptedRosterRoom(roomID: "!atum-b:atum.test", name: "Atum",
                               members: [ScriptedCast.atum])
        ]), locale: "vi")
        let atum = try XCTUnwrap(
            rows.first(where: { $0.id == "agent:00000000-0000-4000-8000-89c0dd5b3309" })
        )
        XCTAssertFalse(atum.canOpen)
        XCTAssertFalse(atum.isAwaitingRoom)
        XCTAssertNil(atum.detail)
        XCTAssertEqual(atum.previewContent, .none)
    }

    @MainActor
    func testScriptedHumanInvitationUsesTheLiveRosterAdapter() throws {
        let invitation = ScriptedRosterRoom(
            roomID: "!invite:atum.test", name: "Đặng", members: ["@dang:atum.test"],
            membership: .invited(by: "@dang:atum.test"), latestTimestamp: Date()
        )
        let product = try XCTUnwrap(
            ScriptedHomeHost.rows(ScriptedRoster(rooms: [invitation]), locale: "vi")
                .first(where: { $0.id == invitation.roomID })
        )
        XCTAssertTrue(product.isInvitation)
        let home = HomeRow(product: product, locale: Locale(identifier: "vi"))
        XCTAssertEqual(home.kind, .invitation)
        XCTAssertEqual(home.preview.value, .invitation)
        XCTAssertEqual(home.badge, .none)
    }

    @MainActor
    func testLiveRosterKeepsDefaultAndServerOrderAcrossPhotoRoomOrderAndRecency() throws {
        let secondary = "00000000-0000-4000-8000-a28c50c0e7e8"
        let primary = "00000000-0000-4000-8000-c9a6a6942b3d"
        let third = "00000000-0000-4000-8000-04e2e3dee61c"
        let agents = try decodeAgents([
            agentJSON(id: secondary, name: "Second", matrixUser: "@second:atum.test"),
            agentJSON(id: primary, name: "Primary", matrixUser: "@primary:atum.test",
                      isDefault: true, avatarURL: "https://images.atum.test/primary.jpg"),
            agentJSON(id: third, name: "Third", matrixUser: "@third:atum.test"),
        ])
        let rooms = [
            rosterRoom("!third:atum.test", userID: "@third:atum.test", latest: 9_000),
            rosterRoom("!second:atum.test", userID: "@second:atum.test", latest: 5_000),
            rosterRoom("!primary:atum.test", userID: "@primary:atum.test", latest: 1_000),
        ]

        func projected(_ value: [LiveMatrixRoomRow]) -> [String] {
            let product = LiveRosterRows.rows(.init(
                agents: agents, apps: [], rooms: value, invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
            )).rows
            let snapshot = AppRoot.rosterSnapshot(from: product)
            return RosterProjection.project(snapshot.projectionInput).assistants.map(\.roomID)
        }

        XCTAssertEqual(projected(rooms),
                       ["!primary:atum.test", "!second:atum.test", "!third:atum.test"])
        XCTAssertEqual(projected(Array(rooms.reversed())),
                       ["!primary:atum.test", "!second:atum.test", "!third:atum.test"])
        let product = LiveRosterRows.rows(.init(
            agents: agents, apps: [], rooms: rooms, invites: [], pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        )).rows
        let primaryRow = try XCTUnwrap(product.first { $0.id == "!primary:atum.test" })
        XCTAssertEqual(primaryRow.assistant,
                       LiveProductAssistantMetadata(id: primary, isDefault: true, order: 1))
        guard case .photo? = primaryRow.avatar else {
            return XCTFail("the default keeps its photo without losing its semantic role")
        }
    }

    func testLiveRosterKeepsAssistantsAndPortraitsWhenACompanionUsesFutureValues() throws {
        let primary = "00000000-0000-4000-8000-eaed3477e8b6"
        let alfred = "00000000-0000-4000-8000-b0c5ad35009f"
        var raymond = agentJSON(id: primary, name: "Raymond", matrixUser: "@raymond:atum.test",
                                isDefault: true,
                                avatarURL: "https://images.atum.test/raymond.jpg")
        raymond["mark_shape"] = "circle"
        raymond["mark_color"] = "blue"
        var assistant = agentJSON(id: alfred, name: "Alfred", matrixUser: "@alfred:atum.test",
                                  avatarURL: "https://images.atum.test/alfred.jpg")
        assistant["mark_shape"] = "diamond"
        assistant["mark_color"] = "coral"
        var companion = agentJSON(
            id: "00000000-0000-4000-8000-0a57e3c82f8b",
            name: "Gigi", matrixUser: "@gigi:atum.test", status: "companion"
        )
        companion["kind"] = "pet"
        companion["answering"] = "managed_companion"
        companion["mark_shape"] = "future_pet_shape"
        companion["mark_color"] = "future_pet_color"

        let agents = try decodeAgents([raymond, assistant, companion])
        let rows = LiveRosterRows.rows(.init(
            agents: agents,
            apps: [],
            rooms: [rosterRoom("!alfred:atum.test", userID: "@alfred:atum.test", latest: 1_000)],
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        )).rows
        let home = rows.map { HomeRow(product: $0, locale: Locale(identifier: "vi")) }

        let waitingPrimary = try XCTUnwrap(home.first { $0.name == "Raymond" })
        XCTAssertEqual(waitingPrimary.kind, .atum)
        XCTAssertTrue(waitingPrimary.isWaitingForRoom)
        XCTAssertEqual(waitingPrimary.avatarURL?.absoluteString,
                       "https://images.atum.test/raymond.jpg")
        let alfredRow = try XCTUnwrap(home.first { $0.name == "Alfred" })
        XCTAssertEqual(alfredRow.kind, .assistant)
        XCTAssertEqual(alfredRow.avatarURL?.absoluteString,
                       "https://images.atum.test/alfred.jpg")
        XCTAssertNil(home.first { $0.name == "Gigi" },
                     "the phone has no pet roster design, so a companion is not an assistant")
    }

    func testAssistantRoomWithoutServerMetadataStillReachesTheRoster() {
        let known = LiveProductRoom(
            id: "!known:atum.test", kind: .agent, title: "Known",
            assistant: LiveProductAssistantMetadata(id: "agent-known",
                                                    isDefault: false, order: 0))
        let orphan = LiveProductRoom(id: "!orphan:atum.test", kind: .agent, title: "Orphan")

        let output = RosterProjection.project(
            AppRoot.rosterSnapshot(from: [orphan, known]).projectionInput)

        XCTAssertEqual(output.assistants.map(\.roomID),
                       ["!known:atum.test", "!orphan:atum.test"],
                       "an assistant room without /agents metadata is never dropped")
        XCTAssertEqual(output.assistants.last?.kind,
                       .assistant(agentID: "!orphan:atum.test"),
                       "the fallback keeps the room under its own ID and after the server's agents")
    }

    func testNamelessDirectAndGroupInvitesRemainActionableWithSDKAvatars() throws {
        let invites = [
            LiveMatrixInvite(roomID: "!dm:example.test", inviterID: nil, displayName: " ",
                             avatarURL: "mxc://example.test/person", isDirect: true),
            LiveMatrixInvite(roomID: "!group:example.test", inviterID: "@member:example.test",
                             displayName: "Friends", avatarURL: "mxc://example.test/group", isDirect: false)
        ]
        let rows = LiveRosterRows.rows(.init(
            agents: [], apps: [], rooms: [], invites: invites, pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(), locale: "en"
        )).rows
        XCTAssertEqual(rows.map(\.id), invites.map(\.roomID))
        XCTAssertTrue(rows.allSatisfy { $0.isInvitation && $0.canOpen && !$0.title.isEmpty })
        XCTAssertEqual(rows.map(\.kind), [.people, .group])
        XCTAssertEqual(rows.map(\.matrixAvatarURL), invites.map(\.avatarURL))
        for row in rows {
            let home = HomeRow(product: row, locale: Locale(identifier: "en"))
            XCTAssertEqual(home.kind, .invitation)
            XCTAssertEqual(home.preview.value, .invitation)
        }
    }

    func testUnknownTypeInviteFromAnAgentOrBotNeverBecomesAPersonInvitation() throws {
        let agentID = "00000000-0000-4000-8000-38e60b5c1238"
        let appID = "00000000-0000-4000-8000-f726a5bca776"
        let botID = "@app-moon:atumplatform.com"
        let agents = try decodeAgents([agentJSON(id: agentID, name: "Assistant",
                                                  matrixUser: "@assistant:atum.test",
                                                  status: "retired")])
        let moon = try decodeMoon(appID: appID, botID: botID)
        let invites = [
            // The stripped create state is unreadable for an invite, so the
            // room type is nil; the sender still proves this is an agent's room.
            LiveMatrixInvite(roomID: "!task:atum.test", inviterID: "@assistant:atum.test",
                             displayName: "Assistant", roomType: nil),
            LiveMatrixInvite(roomID: "!bot:atum.test", inviterID: botID,
                             displayName: "Moon", isEncrypted: false, roomType: nil),
            LiveMatrixInvite(roomID: "!person:atum.test", inviterID: "@dang:atum.test",
                             displayName: "Đặng", roomType: nil),
        ]

        let rows = LiveRosterRows.rows(.init(
            agents: agents, apps: [moon], rooms: [], invites: invites, pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(),
            appShortcuts: [moon.appID: .absent], locale: "vi"
        )).rows

        XCTAssertEqual(rows.filter(\.isInvitation).map(\.id), ["!person:atum.test"],
                       "only the person's invite becomes a person invitation row")
        XCTAssertEqual(rows.map(\.id), ["!person:atum.test", "app:" + appID],
                       "the bot's invite stays a re-openable app row")
    }

    func testAgentTaskRoomNeverBecomesARosterRowOrDuplicate() throws {
        let agentID = "00000000-0000-4000-8000-eaed3477e8b6"
        let userID = "@assistant:atum.test"
        let agents = try decodeAgents([agentJSON(id: agentID, name: "Assistant",
                                                  matrixUser: userID, isDefault: true)])
        let output = LiveRosterRows.rows(.init(
            agents: agents,
            apps: [],
            rooms: [
                rosterRoom("!task:atum.test", userID: userID, latest: 9_000,
                           roomType: MobileRoomTypePolicy.agentTask),
                rosterRoom("!main:atum.test", userID: userID, latest: 1_000),
            ],
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        ))
        XCTAssertEqual(output.rows.map(\.id), ["!main:atum.test"])
        XCTAssertEqual(output.agentDuplicatePlainRoomCounts, [:])
    }

    /// The owner's report (2026-11-04): an "Empty Room" row under Chats. It is the desktop's
    /// notes-to-self room (the owner alone); like the desktop's roster, Chats never lists it,
    /// while an ordinary chat with the same members still shows.
    func testNotesSelfRoomNeverBecomesAChatsRow() {
        let owner = "@owner:atum.test"
        let output = LiveRosterRows.rows(.init(
            agents: [],
            apps: [],
            rooms: [
                rosterRoom("!notes:atum.test", userID: owner, latest: 9_000,
                           roomType: MobileRoomTypePolicy.notesSelf),
                rosterRoom("!friend:atum.test", userID: "@friend:atum.test", latest: 1_000, text: "Chào"),
            ],
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        ))
        XCTAssertEqual(output.rows.map(\.id), ["!friend:atum.test"])
    }

    func testTwoPlainMoonRoomsEmitOnlyThePolicyChoice() throws {
        let appID = "00000000-0000-4000-8000-7d3f4165565b"
        let botID = "@app-moon:atumplatform.com"
        let app = try decodeMoon(appID: appID, botID: botID)
        let rooms = [
            rosterRoom("!other:atum.test", userID: botID, latest: 9_000, text: "newer"),
            rosterRoom("!pointer:atum.test", userID: botID, latest: 1_000, text: "pointer"),
        ]

        func ids(_ value: [LiveMatrixRoomRow]) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: value, invites: [],
                pointers: [appID: "!pointer:atum.test"],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: .absent], locale: "vi"
            )).rows.map(\.id)
        }

        XCTAssertEqual(ids(rooms), ["!pointer:atum.test"])
        XCTAssertEqual(ids(Array(rooms.reversed())), ["!pointer:atum.test"])
    }

    func testDesktopDeletedMoonChatGivesTheAppRowBackUntilANewerMessage() throws {
        let appID = "00000000-0000-4000-8000-d09f929fabe6"
        let botID = "@app-moon:atumplatform.com"
        let app = try decodeMoon(appID: appID, botID: botID)

        func ids(_ room: LiveMatrixRoomRow) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: [room], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: .absent], locale: "vi"
            )).rows.map(\.id)
        }

        // Deleted on the desktop after the last message: the chat row is gone,
        // and the app row stays so tapping Moon reopens this same room.
        XCTAssertEqual(ids(rosterRoom("!moon:atum.test", userID: botID, latest: 1_000,
                                      text: "hi", appBotHiddenAt: 2_000)),
                       ["app:" + appID])
        XCTAssertEqual(ids(rosterRoom("!moon:atum.test", userID: botID, latest: 2_000,
                                      text: "hi", appBotHiddenAt: 2_000)),
                       ["app:" + appID])
        // A message after the deletion brings the chat back as the room's row.
        XCTAssertEqual(ids(rosterRoom("!moon:atum.test", userID: botID, latest: 2_001,
                                      text: "hi again", appBotHiddenAt: 2_000)),
                       ["!moon:atum.test"])
        // A cleared or absent note never hides anything.
        XCTAssertEqual(ids(rosterRoom("!moon:atum.test", userID: botID, latest: 1_000,
                                      text: "hi", appBotHiddenAt: nil)),
                       ["!moon:atum.test"])
    }

    func testDesktopHiddenNoteDoesNotHideAnAssistantOrPersonChat() throws {
        let agentID = "00000000-0000-4000-8000-064e196185a1"
        let userID = "@assistant:atum.test"
        let agents = try decodeAgents([agentJSON(id: agentID, name: "Assistant",
                                                  matrixUser: userID, isDefault: true)])
        let rows = LiveRosterRows.rows(.init(
            agents: agents, apps: [],
            rooms: [rosterRoom("!main:atum.test", userID: userID, latest: 1_000, text: "x",
                               appBotHiddenAt: 5_000)],
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        )).rows
        XCTAssertEqual(rows.map(\.id), ["!main:atum.test"],
                       "only official bot chats read the desktop's Delete chat note")
    }

    func testRetiredMovedMoonChatIsNeverTheBotsChat() throws {
        let appID = "00000000-0000-4000-8000-2b418dd90794"
        let otherApp = "00000000-0000-4000-8000-3762abd3a19a"
        let botID = "@app-moon:atumplatform.com"
        let app = try decodeMoon(appID: appID, botID: botID)
        func moved(_ app: String, bot: String? = nil) -> MobileLegacyAppBotMove {
            MobileLegacyAppBotMove(appID: app, botUserID: bot ?? botID, movedAt: 9_000)
        }
        func ids(_ rooms: [LiveMatrixRoomRow], pointers: [String: String] = [:]) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: rooms, invites: [], pointers: pointers,
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: .absent], locale: "vi"
            )).rows.map(\.id)
        }

        let retired = rosterRoom("!retired:atum.test", userID: botID, latest: 9_000,
                                 text: "newest", legacyMove: moved(appID))
        let working = rosterRoom("!working:atum.test", userID: botID, latest: 1_000, text: "older")

        // The retired room is newest and would win by history; the note removes it.
        XCTAssertEqual(ids([retired, working]), ["!working:atum.test"])
        XCTAssertEqual(ids([working, retired]), ["!working:atum.test"])
        // The desktop pointer naming the retired room does not resurrect it.
        XCTAssertEqual(ids([retired, working], pointers: [appID: "!retired:atum.test"]),
                       ["!working:atum.test"])
        // Retired and alone: no chat and no row (nothing on the phone can set it up).
        XCTAssertEqual(ids([retired]), [])
        // A note for another app or bot proves nothing about this one.
        let foreignApp = rosterRoom("!f1:atum.test", userID: botID, latest: 9_000, text: "n",
                                    legacyMove: moved(otherApp))
        let foreignBot = rosterRoom("!f2:atum.test", userID: botID, latest: 8_000, text: "n",
                                    legacyMove: moved(appID, bot: "@app-andy:atumplatform.com"))
        XCTAssertEqual(ids([foreignApp, foreignBot, working]), ["!f1:atum.test"])
    }

    func testServerRosterDefaultKeepsTheExistingChatAndHonoursAFavourite() throws {
        let appID = "00000000-0000-4000-8000-38e60b5c1238"
        let botID = "@app-moon:atumplatform.com"
        let defaultApp = try decodeMoon(appID: appID, botID: botID)
        let nonDefaultApp = try decodeMoon(appID: appID, botID: botID, rosterDefault: false)

        func ids(_ app: AppDescriptor, _ room: LiveMatrixRoomRow) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: [room], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: .absent], locale: "vi"
            )).rows.map(\.id)
        }

        let visible = rosterRoom("!moon:atum.test", userID: botID, latest: 1_000, text: "hi")
        XCTAssertEqual(ids(nonDefaultApp, visible), ["!moon:atum.test"],
                       "a server default change never removes the existing conversation")

        let hidden = rosterRoom("!moon:atum.test", userID: botID, latest: 1_000,
                                text: "hi", appBotHiddenAt: 2_000)
        XCTAssertEqual(ids(nonDefaultApp, hidden), [],
                       "no default shortcut for a non-default app")
        XCTAssertEqual(ids(defaultApp, hidden), ["app:" + appID],
                       "the server default still gives the hidden chat its row back")

        let pinnedHidden = rosterRoom("!moon:atum.test", userID: botID, latest: 1_000,
                                      text: "hi", favourite: true, appBotHiddenAt: 2_000)
        XCTAssertEqual(ids(nonDefaultApp, pinnedHidden), ["app:" + appID],
                       "m.favourite is an explicit person choice and wins")
    }

    func testExplicitAppShortcutBeatsServerDefaultForLiveAndComingSoon() throws {
        let appID = "00000000-0000-4000-8000-8bf0ba5bdf79"
        let botID = "@app-moon:atumplatform.com"
        let nonDefault = try decodeMoon(appID: appID, botID: botID, rosterDefault: false)
        let defaultApp = try decodeMoon(appID: appID, botID: botID)
        let hidden = rosterRoom("!moon:atum.test", userID: botID, latest: 1_000,
                                text: "hi", appBotHiddenAt: 2_000)
        let visible = rosterRoom("!moon:atum.test", userID: botID, latest: 1_000, text: "hi")

        func ids(_ app: AppDescriptor, _ room: LiveMatrixRoomRow,
                 _ state: MobileAppShortcutState) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: [room], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: state], locale: "vi"
            )).rows.map(\.id)
        }

        XCTAssertEqual(ids(nonDefault, hidden, .shown), ["app:" + appID],
                       "explicit shown beats a false server default")
        XCTAssertEqual(ids(defaultApp, hidden, .hidden), [],
                       "explicit hidden beats a true server default")
        XCTAssertEqual(ids(defaultApp, hidden, .unknown), [],
                       "loading or a failed read never guesses a default")
        XCTAssertEqual(ids(nonDefault, hidden, .absent), [],
                       "a successful no-event read follows the server default")
        XCTAssertEqual(ids(nonDefault, visible, .hidden), ["!moon:atum.test"],
                       "an explicit app shortcut hide never removes the joined chat")

        let comingID = "00000000-0000-4000-8000-6223be27f200"
        let coming = try decodeComingSoon(appID: comingID, rosterDefault: false)
        func comingIDs(_ state: MobileAppShortcutState) -> [String] {
            LiveRosterRows.rows(.init(
                agents: [], apps: [coming], rooms: [], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [coming.appID: state], locale: "vi",
                comingSoonDetail: "Sắp ra mắt"
            )).rows.map(\.id)
        }
        XCTAssertEqual(comingIDs(.shown), ["app:" + comingID],
                       "explicit shown exposes an eligible coming-soon row")
        XCTAssertEqual(comingIDs(.hidden), [])
        XCTAssertEqual(comingIDs(.unknown), [])
        XCTAssertEqual(comingIDs(.absent), [], "the server default is false")
    }

    @MainActor
    func testConfirmedShortcutWriteSurvivesOlderBlockedRefreshAndOverlappingRefreshes() async throws {
        let appA = try decodeComingSoon(
            appID: "00000000-0000-4000-8000-7e1ae7ae63e3"
        )
        let appB = try decodeComingSoon(
            appID: "00000000-0000-4000-8000-141ebcee2e7f"
        )
        let gate = ShortcutStateReadGate()
        let blockedOnB = expectation(description: "old refresh waits on B")

        let oldRefresh = Task { @MainActor in
            await MobileAppShortcutRefreshPolicy.states(
                existing: [appA.appID: .hidden, appB.appID: .unknown],
                candidates: [appA.appID, appB.appID],
                canReadCachedAccountData: true,
                read: { appID in
                    if appID == appA.appID { return .shown }
                    blockedOnB.fulfill()
                    return await gate.wait()
                },
                isCurrent: { true }
            )
        }

        await fulfillment(of: [blockedOnB], timeout: 2)
        // A's write is still pending: it has advanced to revision 1 and the
        // server/cache already reads shown, but the UI must remain hidden.
        let publishedWhilePending: [AppCatalogID: MobileAppShortcutState] = [
            appA.appID: .hidden,
            appB.appID: .unknown,
        ]
        await gate.release(.absent)
        let oldRefreshValue = await oldRefresh.value
        let oldResult = try XCTUnwrap(oldRefreshValue)
        let whilePending = LiveAppModel.mergeAppShortcutRefresh(
            existing: publishedWhilePending,
            refreshed: oldResult,
            candidates: [appA.appID, appB.appID],
            capturedMutationRevisions: [appA.appID: 1, appB.appID: 0],
            currentMutationRevisions: [appA.appID: 1, appB.appID: 0],
            activeWriteAppIDs: [appA.appID]
        )
        XCTAssertEqual(whilePending[appA.appID], .hidden,
                       "matching revisions do not admit a pending app write")
        XCTAssertEqual(whilePending[appB.appID], .absent,
                       "an unrelated result from the same refresh still lands")

        // Failed/unconfirmed completion advances A to revision 2. The same
        // old refresh remains fenced after the active-write token is removed.
        let afterUnconfirmed = LiveAppModel.mergeAppShortcutRefresh(
            existing: whilePending,
            refreshed: oldResult,
            candidates: [appA.appID, appB.appID],
            capturedMutationRevisions: [appA.appID: 1, appB.appID: 0],
            currentMutationRevisions: [appA.appID: 2, appB.appID: 0],
            activeWriteAppIDs: []
        )
        XCTAssertEqual(afterUnconfirmed[appA.appID], .hidden)

        // A later clean refresh captures revision 2 and may publish shown.
        // This also proves the active-write guard does not block confirmed
        // success after its operation token has been removed.
        let cleanLater = LiveAppModel.mergeAppShortcutRefresh(
            existing: afterUnconfirmed,
            refreshed: [appA.appID: .shown, appB.appID: .absent],
            candidates: [appA.appID, appB.appID],
            capturedMutationRevisions: [appA.appID: 2, appB.appID: 0],
            currentMutationRevisions: [appA.appID: 2, appB.appID: 0],
            activeWriteAppIDs: []
        )
        XCTAssertEqual(cleanLater[appA.appID], .shown)

        // Starting a newer refresh retires the older pass before it can
        // publish, independently of per-app mutation revisions.
        let overlapGate = ShortcutStateReadGate()
        let overlapBlocked = expectation(description: "older overlapping refresh waits")
        let latestRefresh = ShortcutRefreshEpoch()
        let overlappingOld = Task { @MainActor in
            await MobileAppShortcutRefreshPolicy.states(
                existing: [appA.appID: .hidden],
                candidates: [appA.appID],
                canReadCachedAccountData: true,
                read: { _ in
                    overlapBlocked.fulfill()
                    return await overlapGate.wait()
                },
                isCurrent: { latestRefresh.value == 1 }
            )
        }
        await fulfillment(of: [overlapBlocked], timeout: 2)
        latestRefresh.value = 2
        await overlapGate.release(.shown)
        let overlappingOldValue = await overlappingOld.value
        XCTAssertNil(overlappingOldValue)
    }

    func testFounderRoomIsAnOrdinaryMarkedHumanChatNotALookalike() {
        let founder = "@synthetic-user-0017:example.invalid"
        let own = "@alice:atum.test"
        func room(_ id: String, title: String, members: [String],
                  avatarURL: String? = nil, latestText: String? = "hello",
                  preview: RowPreview.Content = .text("hello")) -> LiveMatrixRoomRow {
            LiveMatrixRoomRow(
                roomID: id, displayName: title, avatarURL: avatarURL, latestText: latestText,
                latestPreviewContent: preview, latestSenderID: founder,
                latestSenderName: nil, latestIsOwn: false, latestIsNotice: false,
                latestSendState: .sent, latestTimestamp: 2_000, unreadCount: 0,
                notificationCount: 0, highlightCount: 0, isMarkedUnread: false,
                isFavourite: false, isMuted: false, isDirect: true,
                memberUserIDs: members, memberCount: 2, roomType: nil, isEncrypted: false
            )
        }
        let founderRoom = room("!founder:atum.test", title: founder, members: [own, founder],
                               latestText: nil, preview: .none)
        let lookalike = room("!lookalike:atum.test", title: "Founder",
                             members: [own, "@user-fake:example.invalid"],
                             avatarURL: "mxc://atum.test/copied-raven")
        let avatarLookalike = room("!avatar-lookalike:atum.test", title: "Raven fan",
                                   members: [own, "@user-other:example.invalid"],
                                   avatarURL: "mxc://atum.test/founder")
        let output = LiveRosterRows.rows(.init(
            agents: [], apps: [], rooms: [lookalike, avatarLookalike, founderRoom], invites: [],
            pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), appShortcuts: [:],
            locale: "vi", founderRoomID: founderRoom.roomID, founderUserID: founder,
            founderName: "Founder", founderSubtitle: "Nhà sáng lập Atum",
            founderAvatarURL: "mxc://atum.test/founder"
        ))
        let founderRow = output.rows.first { $0.id == founderRoom.roomID }
        XCTAssertEqual(founderRow?.kind, .people)
        XCTAssertEqual(founderRow?.title, "Founder")
        XCTAssertTrue(founderRow?.isFounder == true)
        XCTAssertEqual(founderRow?.appVerification, LiveProductAppVerification.official)
        XCTAssertEqual(founderRow?.matrixAvatarURL, "mxc://atum.test/founder")
        XCTAssertEqual(founderRow?.previewContent, .text("Nhà sáng lập Atum"))

        let founderHome = founderRow.map { HomeRow(product: $0, locale: Locale(identifier: "vi")) }
        XCTAssertTrue(founderHome?.isFounder == true)
        XCTAssertEqual(founderHome?.preview.value, .text("Nhà sáng lập Atum"))
        let lookalikeRow = output.rows.first { $0.id == lookalike.roomID }
        XCTAssertFalse(lookalikeRow?.isFounder == true)
        XCTAssertNil(lookalikeRow?.appVerification)
        XCTAssertNil(lookalikeRow?.matrixAvatarURL,
                     "a copied Founder name/avatar stays an initials-only ordinary person")
        XCTAssertEqual(lookalikeRow?.title, "Founder",
                       "the room's own name is never rewritten into a trust claim")
        let lookalikeHome = lookalikeRow.map { HomeRow(product: $0, locale: Locale(identifier: "vi")) }
        XCTAssertFalse(lookalikeHome?.isFounder == true)
        let avatarLookalikeRow = output.rows.first { $0.id == avatarLookalike.roomID }
        XCTAssertNil(avatarLookalikeRow?.matrixAvatarURL,
                     "copying only the configured Founder's Matrix avatar still gets initials")
        XCTAssertNil(avatarLookalikeRow?.appVerification)

        let snapshot = AppRoot.rosterSnapshot(from: output.rows,
                                              founderRoomID: founderRoom.roomID)
        let projection = RosterProjection.project(snapshot.projectionInput)
        XCTAssertEqual(projection.chats.first?.roomID, founderRoom.roomID)

        let intro = FounderIntroPresentation.exactRoom(
            roomID: founderRoom.roomID, founderRoomID: founderRoom.roomID,
            isFounderAccount: false, name: "Founder", subtitle: "Nhà sáng lập Atum",
            intro: "Có câu hỏi, ý tưởng hay gặp sự cố?"
        )
        XCTAssertEqual(intro?.name, "Founder")
        XCTAssertNil(FounderIntroPresentation.exactRoom(
            roomID: lookalike.roomID, founderRoomID: founderRoom.roomID,
            isFounderAccount: false, name: "Founder", subtitle: "Nhà sáng lập Atum",
            intro: "Có câu hỏi, ý tưởng hay gặp sự cố?"
        ))
        XCTAssertNil(FounderIntroPresentation.exactRoom(
            roomID: founderRoom.roomID, founderRoomID: founderRoom.roomID,
            isFounderAccount: true, name: "Founder", subtitle: "Nhà sáng lập Atum",
            intro: "Có câu hỏi, ý tưởng hay gặp sự cố?"
        ))
    }

    func testComingSoonCatalogRowIsInertAndReachesHome() throws {
        let appID = "00000000-0000-4000-8000-5fb4179b493c"
        let app = try decodeComingSoon(appID: appID,
                                       description: ["vi": "Mô tả ứng dụng"])
        let output = LiveRosterRows.rows(.init(
            agents: [], apps: [app], rooms: [], invites: [], pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(),
            appShortcuts: [app.appID: .absent], locale: "vi",
            comingSoonDetail: "Sắp ra mắt"
        ))
        XCTAssertEqual(output.rows.map(\.id), ["app:" + appID])
        let row = try XCTUnwrap(output.rows.first)
        XCTAssertEqual(row.title, "VNeID")
        XCTAssertEqual(row.detail, "Sắp ra mắt")
        XCTAssertEqual(row.previewContent, .text("Sắp ra mắt"))
        XCTAssertFalse(row.canOpen)
        XCTAssertTrue(row.isComingSoon)
        XCTAssertTrue(output.agentChoices.isEmpty)

        let snapshot = AppRoot.rosterSnapshot(from: output.rows)
        XCTAssertEqual(RosterProjection.project(snapshot.projectionInput).chats.map(\.roomID),
                       ["app:" + appID],
                       "the inert row survives the roster projection exactly once")

        let home = HomeRow(product: row, locale: Locale(identifier: "vi"))
        XCTAssertEqual(home.kind, .app)
        XCTAssertFalse(home.canOpen)
        XCTAssertTrue(home.isComingSoon)
        XCTAssertFalse(HomeRowActionPolicy.canOfferPin(row: home, pinnedCount: 0))
        XCTAssertFalse(HomeRowActionPolicy.offersDelete(row: home, hasDeleteAction: true))
        XCTAssertTrue(HomeRowActionPolicy.offersShortcutHide(row: home, hasAction: true))
        XCTAssertFalse(HomeRowActionPolicy.offersShortcutHide(row: home, hasAction: false))

        XCTAssertEqual(LiveAppModel.storeShortcutVisibility(for: app, state: .shown), true)
        XCTAssertEqual(LiveAppModel.storeShortcutVisibility(for: app, state: .hidden), false)
        XCTAssertEqual(LiveAppModel.storeShortcutVisibility(for: app, state: .absent), true)
        XCTAssertNil(LiveAppModel.storeShortcutVisibility(for: app, state: .unknown))

        let nonDefault = try decodeComingSoon(appID: appID, rosterDefault: false)
        XCTAssertEqual(LiveAppModel.storeShortcutVisibility(for: nonDefault, state: .absent), false)
    }

    func testAppRosterMetadataFallbackAndActualRoomPreviewPrecedence() throws {
        let botID = "@app-moon:atumplatform.com"
        let description = try decodeMoon(
            appID: "00000000-0000-4000-8000-81f131e9deac", botID: botID,
            description: ["vi": "Mô tả tiếng Việt", "en": "English description"],
            subtitle: ["vi": "Phụ đề"]
        )
        let subtitleOnly = try decodeMoon(
            appID: "00000000-0000-4000-8000-24379d58ee1b", botID: botID,
            subtitle: ["vi": "Chỉ có phụ đề"]
        )
        let missing = try decodeMoon(
            appID: "00000000-0000-4000-8000-723dae84f96e", botID: botID
        )

        func hiddenShortcut(_ app: AppDescriptor) throws -> LiveProductRoom {
            let hiddenRoom = rosterRoom("!hidden-\(app.appID.rawValue):atum.test",
                                       userID: botID, latest: 1_000,
                                       appBotHiddenAt: 2_000)
            let output = LiveRosterRows.rows(.init(
                agents: [], apps: [app], rooms: [hiddenRoom], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [app.appID: .absent], locale: "vi"
            ))
            return try XCTUnwrap(output.rows.first { $0.id == "app:" + app.appID.rawValue })
        }

        let describedRow = try hiddenShortcut(description)
        XCTAssertEqual(describedRow.detail, "Mô tả tiếng Việt")
        XCTAssertEqual(describedRow.previewContent, .text("Mô tả tiếng Việt"))

        let subtitleRow = try hiddenShortcut(subtitleOnly)
        XCTAssertEqual(subtitleRow.detail, "Chỉ có phụ đề")
        XCTAssertEqual(subtitleRow.previewContent, .text("Chỉ có phụ đề"))

        let missingRow = try hiddenShortcut(missing)
        XCTAssertNil(missingRow.detail)
        XCTAssertEqual(missingRow.previewContent, .none)

        let noPreviewRoom = rosterRoom("!no-preview:atum.test", userID: botID, latest: 900)
        let noPreviewOutput = LiveRosterRows.rows(.init(
            agents: [], apps: [description], rooms: [noPreviewRoom], invites: [], pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(),
            appShortcuts: [description.appID: .absent], locale: "vi"
        ))
        let noPreviewBotRow = try XCTUnwrap(
            noPreviewOutput.rows.first { $0.id == noPreviewRoom.roomID }
        )
        XCTAssertEqual(noPreviewBotRow.detail, "Mô tả tiếng Việt")
        XCTAssertEqual(noPreviewBotRow.previewContent, .text("Mô tả tiếng Việt"))

        let actualPreviews: [RowPreview.Content] = [
            .text("Actual chat message"),
            .image,
            .appNotice([
                .init(localeIdentifier: "vi", text: "Thông báo tiếng Việt"),
                .init(localeIdentifier: "en", text: "English notice"),
            ]),
        ]
        for (index, preview) in actualPreviews.enumerated() {
            let room = rosterRoom("!preview-\(index):atum.test", userID: botID,
                                  latest: UInt64(1_000 + index),
                                  text: index == 0 ? "Actual chat message" : nil,
                                  previewContent: preview,
                                  isNotice: index == 2)
            let output = LiveRosterRows.rows(.init(
                agents: [], apps: [description], rooms: [room], invites: [], pointers: [:],
                hiddenRooms: MobileHiddenRoomLedger(),
                appShortcuts: [description.appID: .absent], locale: "vi"
            ))
            let botRoomRow = try XCTUnwrap(output.rows.first { $0.id == room.roomID })
            XCTAssertEqual(botRoomRow.previewContent, preview,
                           "catalog copy must not replace semantic room preview \(index)")
        }
    }

    // MARK: Conversation-type rooms are never a bot's or an agent's

    func testAConversationTypeRoomWithAnAgentInItIsNotTheAgentsChatAndKeepsItsClaim() throws {
        let agentID = "00000000-0000-4000-8000-d09f929fabe6"
        let userID = "@assistant:atum.test"
        let agents = try decodeAgents([agentJSON(id: agentID, name: "Assistant", matrixUser: userID, isDefault: true)])
        let claimed = rosterRoom("!conv:atum.test", userID: userID, latest: 9_000,
                                 roomType: ConversationRoomType.value, text: "newest")
        let output = LiveRosterRows.rows(.init(
            agents: agents, apps: [],
            rooms: [claimed, rosterRoom("!main:atum.test", userID: userID, latest: 1_000, text: "hi")],
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "vi"
        ))
        let conversation = try XCTUnwrap(output.rows.first { $0.id == "!conv:atum.test" })
        XCTAssertNotEqual(conversation.kind, .agent, "an agent in the room does not make it the agent's chat")
        XCTAssertTrue(conversation.claimsConversationType, "the claim rides on the row so Home can leave it out")
        let agentRow = try XCTUnwrap(output.rows.first { $0.id == "!main:atum.test" })
        XCTAssertEqual(agentRow.kind, .agent)
        XCTAssertFalse(agentRow.claimsConversationType)
        XCTAssertEqual(output.agentChoices.values.map(\.chatRoomID), ["!main:atum.test"])
    }

    func testABotsConversationTypeRoomAndInvitationAreNeverItsChat() throws {
        let appID = "00000000-0000-4000-8000-064e196185a1"
        let botID = "@app-moon:atumplatform.com"
        let moon = try decodeMoon(appID: appID, botID: botID)
        let claimedRoom = rosterRoom("!conv-bot:atum.test", userID: botID, latest: 9_000,
                                     roomType: ConversationRoomType.value, text: "x")
        let claimedInvite = LiveMatrixInvite(roomID: "!conv-invite:atum.test", inviterID: botID,
                                             displayName: "Moon", isEncrypted: false,
                                             roomType: ConversationRoomType.value)
        // The one chooser every caller goes through never picks either.
        XCTAssertNil(LiveRosterRows.botChatChoice(
            forBot: botID, appID: appID, rooms: [claimedRoom], invites: [claimedInvite],
            pointers: [appID: "!conv-bot:atum.test"], catalogBotUserIDs: [botID]))
        let output = LiveRosterRows.rows(.init(
            agents: [], apps: [moon], rooms: [claimedRoom], invites: [claimedInvite], pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(), appShortcuts: [moon.appID: .absent], locale: "vi"
        ))
        XCTAssertFalse(output.rows.contains { $0.isAppBotRoom }, "no bot room")
        let invitation = try XCTUnwrap(output.rows.first { $0.id == "!conv-invite:atum.test" })
        XCTAssertTrue(invitation.isInvitation)
        XCTAssertTrue(invitation.claimsConversationType, "not hidden as a bot's invite: flagged so Home drops it")
        // A bot's ordinary invitation is still the bot's.
        let plain = LiveMatrixInvite(roomID: "!plain:atum.test", inviterID: botID, displayName: "Moon",
                                     isEncrypted: false, roomType: nil)
        XCTAssertEqual(LiveRosterRows.botChatChoice(forBot: botID, appID: appID, rooms: [], invites: [plain],
                                                    pointers: [:], catalogBotUserIDs: [botID])?.roomID,
                       "!plain:atum.test")
    }

    func testAnAgentRowCarriesTheClaimWhateverBuildsIt() {
        let room = rosterRoom("!conv:atum.test", userID: "@assistant:atum.test", latest: 1,
                              roomType: ConversationRoomType.value, text: "x")
        let row = LiveRosterRows.agentRow(room, title: "A", avatar: .monogram("A"), app: nil, isBotRoom: false)
        XCTAssertTrue(row.claimsConversationType)
    }

    private func rosterRoom(_ id: String, userID: String, latest: UInt64,
                            roomType: String? = nil, text: String? = nil,
                            previewContent: RowPreview.Content? = nil,
                            isNotice: Bool = false,
                            favourite: Bool = false,
                            appBotHiddenAt: UInt64? = nil,
                            legacyMove: MobileLegacyAppBotMove? = nil) -> LiveMatrixRoomRow {
        LiveMatrixRoomRow(
            roomID: id, displayName: id, avatarURL: nil, latestText: text,
            latestPreviewContent: previewContent ?? text.map(RowPreview.Content.text) ?? .none,
            latestSenderID: userID, latestSenderName: nil, latestIsOwn: false,
            latestIsNotice: isNotice, latestSendState: .sent, latestTimestamp: latest,
            unreadCount: 0, notificationCount: 0, highlightCount: 0,
            isMarkedUnread: false, isFavourite: favourite, isMuted: false,
            isDirect: true, memberUserIDs: [userID], memberCount: 2,
            roomType: roomType, isEncrypted: false,
            appBotHiddenAt: appBotHiddenAt, legacyAppBotMove: legacyMove
        )
    }

    private func agentJSON(id: String, name: String, matrixUser: String,
                           isDefault: Bool = false, avatarURL: String? = nil,
                           status: String = "active") -> [String: Any] {
        [
            "id": id, "identity_id": NSNull(), "display_name": name,
            "slug": NSNull(), "avatar": "", "avatar_url": (avatarURL as Any?) ?? NSNull(),
            "is_default": isDefault, "lifecycle_revision": 1,
            "identity_revision": 1, "definition_revision": 1,
            "status": status, "principal": id, "matrixUser": matrixUser,
        ]
    }

    private func decodeAgents(_ agents: [[String: Any]]) throws -> [AgentsResponse.Agent] {
        let data = try JSONSerialization.data(withJSONObject: agents)
        return try NativeAPI.decode(AgentsResponse.self, from: data).agents
    }

    private func decodeMoon(appID: String, botID: String,
                            rosterDefault: Bool = true,
                            description: [String: String]? = nil,
                            subtitle: [String: String]? = nil) throws -> AppDescriptor {
        let key = String(repeating: "A", count: 43)
        let hash = String(repeating: "a", count: 64)
        let body: [String: Any] = [
            "profile": AppCatalogResponse.profile,
            "apps": [[
                "app": "moon", "app_id": appID,
                "app_version_id": "00000000-0000-4000-8000-d005dc4bc41d",
                "name": ["vi": "Moon", "en": "Moon"],
                "subtitle": subtitle.map { $0 as Any } ?? NSNull(),
                "description": description.map { $0 as Any } ?? NSNull(),
                "icon": NSNull(), "accent": "#2c8078",
                "affiliation": "first_party", "verified": true,
                "verification": "official", "availability": "available",
                "roster_default": rosterDefault, "roster_order": 0,
                "supported_modes": ["direct"], "matrix_room_context": "addressed_only",
                "has_surface": true, "link": ["mode": "external_account", "state": "linked"],
                "bot": [
                    "v": 1, "user_id": botID, "handle": "moon_bot", "display_name": "Moon",
                    "avatar": ["url": "https://images.atum.test/moon.png", "sha256": hash],
                    "device_generation": 1,
                    "device": ["device_id": "MOON", "ed25519": key, "curve25519": key],
                    "state": "active", "groups": true, "consent": "accepted",
                    "disclosure_version": 1, "open_route_id": "open",
                    "open_shared_memory": false, "purchase_route_id": "purchase",
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(NativeAPI.decode(AppCatalogResponse.self, from: data).apps.first)
    }

    private func decodeComingSoon(appID: String, rosterDefault: Bool = true,
                                 description: [String: String]? = nil) throws -> AppDescriptor {
        let body: [String: Any] = [
            "profile": AppCatalogResponse.profile,
            "apps": [[
                "app": "vneid", "app_id": appID,
                "app_version_id": "00000000-0000-4000-8000-9e03e03cec45",
                "name": ["vi": "VNeID", "en": "VNeID"], "subtitle": NSNull(),
                "description": description.map { $0 as Any } ?? NSNull(),
                "icon": NSNull(), "accent": "#1a2b3c",
                "affiliation": NSNull(), "verified": false, "verification": NSNull(),
                "availability": "unavailable", "roster_default": rosterDefault,
                "roster_order": 6, "roster_state": "coming_soon",
                "supported_modes": [], "matrix_room_context": NSNull(),
                "has_surface": false,
                "link": ["mode": "none", "state": "never_linked"], "bot": NSNull(),
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try XCTUnwrap(NativeAPI.decode(AppCatalogResponse.self, from: data).apps.first)
    }
}

private actor RoomReadRecorder {
    private var roomIDs = [String]()

    func read(_ roomID: String) { roomIDs.append(roomID) }
    func values() -> [String] { roomIDs }
}

private actor SuspendedRoomReader {
    private var slowStarted = false
    private var slowReadCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func read(_ roomID: String) async -> String? {
        guard roomID == "slow" else { return roomID }
        slowReadCount += 1
        guard slowReadCount == 1 else { return roomID }
        slowStarted = true
        await withCheckedContinuation { continuation = $0 }
        return roomID
    }

    func waitUntilSlowReadStarts() async {
        while !slowStarted { await Task.yield() }
    }

    func releaseSlowRead() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ShortcutStateReadGate {
    private var continuation: CheckedContinuation<MobileAppShortcutState, Never>?
    private var pending: MobileAppShortcutState?

    func wait() async -> MobileAppShortcutState {
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ state: MobileAppShortcutState) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: state)
        } else {
            pending = state
        }
    }
}

@MainActor
private final class ShortcutRefreshEpoch {
    var value: UInt64 = 1
}

extension S2StateTests {
    private func privateCosFixture(_ name: String) throws -> Data {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: ios.appendingPathComponent("Tests/Fixtures/company-private-cos/" + name))
    }

    @MainActor
    private final class PrivateCosAPIStub: CompanyPrivateCosAPI {
        var capability: CompanyPrivateCosCapability
        var view: CompanyPrivateCosView
        var failure: Error?
        var capabilityOff = false
        var reads = 0
        var hold = false
        var continuation: CheckedContinuation<CompanyPrivateCosView, Error>?
        var ensureRequests = [CompanyPrivateCosEnsureRequest]()
        var ensureView: CompanyPrivateCosView?
        var ensureFailure: Error?
        init(capability: CompanyPrivateCosCapability, view: CompanyPrivateCosView) {
            self.capability = capability; self.view = view
        }
        func ensureCompanyPrivateCos(companyID: NativeID,
                                     request: CompanyPrivateCosEnsureRequest) async throws -> CompanyPrivateCosView {
            ensureRequests.append(request)
            if let ensureFailure { throw ensureFailure }
            guard let ensureView else { throw CompanyAPIError.unavailable }
            view = ensureView
            return ensureView
        }
        func companyPrivateCosCapability() async throws -> CompanyPrivateCosCapability {
            if capabilityOff { throw CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil) }
            return capability
        }
        func companyPrivateCosView(companyID: NativeID) async throws -> CompanyPrivateCosView {
            reads += 1
            if hold { return try await withCheckedThrowingContinuation { continuation = $0 } }
            if let failure { throw failure }
            return view
        }
    }

    @MainActor
    private func privateCosModel() throws -> (CompanyWorkspaceModel, CompanyAPIStub, PrivateCosAPIStub) {
        let view = try NativeAPI.decode(CompanyPrivateCosView.self, from:
            privateCosFixture("v1-lazy-first-open.preparing.response.json"))
        let capability = try NativeAPI.decode(CompanyPrivateCosCapability.self, from:
            privateCosFixture("v1.3-capability.response.json"))
        let company = view.pair.companyPrincipal.rawValue
        let channel = "a7000000-0000-4000-8000-000000000001"
        let api = CompanyAPIStub(list: try companyList([company]), directories: [
            company: try companyDirectory(companyID: company, channelID: channel, roomID: "!general:atum.example")
        ], snapshots: [company: try companySnapshot(companyID: company, channelID: channel)])
        let cos = PrivateCosAPIStub(capability: capability, view: view)
        let model = CompanyWorkspaceModel()
        model.copy = CompanyCopy(design: try LiveDesign())
        model.clientProvider = { api }
        model.privateCosProvider = { cos }
        model.privateCosRoomTitle = { _ in "Synthetic private conversation" }
        model.beginAccountScope("synthetic-private-cos-" + UUID().uuidString)
        return (model, api, cos)
    }

    @MainActor
    func testPrivateCosBoundJoinedRoomIsCompanyReachableBeforePersonalAgentSelection() async throws {
        let (model, _, cos) = try privateCosModel()
        await model.refresh()
        let binding = try XCTUnwrap(cos.view.binding)
        let company = cos.view.pair.companyPrincipal.rawValue
        let privateAgentID = "a8000000-0000-4000-8000-000000000001"
        let personalAgentID = "a8000000-0000-4000-8000-000000000002"
        let agents = try decodeAgents([
            agentJSON(id: privateAgentID, name: "Synthetic private assistant", matrixUser: binding.agentUserId),
            agentJSON(id: personalAgentID, name: "Chief of Staff", matrixUser: "@personal:atum.example")
        ])
        let app = try decodeMoon(appID: "a9000000-0000-4000-8000-000000000001", botID: "@app-moon:atumplatform.com")
        let rooms = [
            rosterRoom(binding.roomId, userID: binding.agentUserId, latest: 1),
            rosterRoom("!personal:atum.example", userID: "@personal:atum.example", latest: 2),
            rosterRoom("!founder:atum.example", userID: "@founder:atum.example", latest: 3),
            rosterRoom("!app:atum.example", userID: "@app-moon:atumplatform.com", latest: 4)
        ]
        let baseline = LiveRosterRows.rows(.init(agents: agents, apps: [app], rooms: rooms,
            invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en",
            founderRoomID: "!founder:atum.example", founderUserID: "@founder:atum.example", founderName: "Founder")).rows
        let output = LiveRosterRows.rows(.init(agents: agents, privateCosBindings: model.privateCosBindings,
            apps: [app], rooms: rooms, invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en",
            founderRoomID: "!founder:atum.example", founderUserID: "@founder:atum.example", founderName: "Founder"))
        let home = output.rows.filter {
            !LiveRosterRows.isPrivateCosHomeRow(HomeRow(product: $0, locale: Locale(identifier: "en")).snapshotRow,
                                               agents: agents, bindings: model.privateCosBindings)
        }
        XCTAssertFalse(home.contains { $0.id == binding.roomId || $0.id == "agent:" + privateAgentID })
        XCTAssertEqual(home.first { $0.id == "!personal:atum.example" }?.title, "Chief of Staff")
        for id in ["!founder:atum.example", "!app:atum.example"] {
            XCTAssertEqual(output.rows.first { $0.id == id }, baseline.first { $0.id == id })
        }
        XCTAssertNil(output.agentChoices["agent:" + privateAgentID])
        let privateRow = try XCTUnwrap(output.rows.first { $0.id == binding.roomId })
        XCTAssertTrue(privateRow.canOpen)
        XCTAssertNil(privateRow.assistant)
        XCTAssertEqual(model.roomClassification(binding.roomId), .privateCos(companyID: company))
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: privateRow.kind,
                                                        classification: model.roomClassification(binding.roomId)), .teamSpace)
        let workspace = try XCTUnwrap(model.workspace(companyID: company))
        // TS-4: the Chief of Staff is a Direct messages row, never a "#" channel.
        XCTAssertFalse(workspace.channels.contains { $0.roomID == binding.roomId })
        XCTAssertEqual(workspace.directMessages.chief?.roomID, binding.roomId)
        XCTAssertTrue(model.isSelected(companyID: company, owning: binding.roomId))
        let signals: CompanyRoomSignals = [binding.roomId: .init(highlights: 1, notifications: 1,
            hasUnreadActivity: true, isMarkedUnread: false, isMuted: false)]
        XCTAssertNotEqual(model.companyBadge(companyID: company, signals: signals), .none)
    }

    @MainActor
    func testPrivateCosInvitesCachedRowsAndAwaitingAgentStayOffHome() async throws {
        let (model, _, cos) = try privateCosModel()
        await model.refresh()
        let binding = try XCTUnwrap(cos.view.binding)
        let agentID = "a8000000-0000-4000-8000-000000000001"
        let agents = try decodeAgents([agentJSON(id: agentID, name: "Chief of Staff", matrixUser: binding.agentUserId)])
        let invite = LiveMatrixInvite(roomID: binding.roomId, inviterID: binding.agentUserId,
                                      displayName: "Synthetic private conversation", isEncrypted: false, isDirect: true)
        let output = LiveRosterRows.rows(.init(agents: agents, privateCosBindings: model.privateCosBindings,
            apps: [], rooms: [], invites: [invite], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en"))
        XCTAssertEqual(output.rows.map(\.id), [binding.roomId])
        XCTAssertTrue(output.rows[0].isInvitation, "company entry must still be able to accept the invitation")
        let cached = [
            HomeRow(product: output.rows[0], locale: Locale(identifier: "en")).snapshotRow,
            ChatListSnapshot.Room(id: binding.roomId, roomID: binding.roomId, kind: .person, name: "cached"),
            ChatListSnapshot.Room(id: "agent:" + agentID, roomID: "agent:" + agentID, kind: .assistant, name: "cached waiting"),
            ChatListSnapshot.Room(id: "!personal:atum.example", roomID: "!personal:atum.example", kind: .assistant, name: "Chief of Staff")
        ]
        let offlineWaiting = ChatListSnapshot.Room(id: "agent:" + agentID, roomID: "agent:" + agentID,
            kind: .assistant, name: "cached waiting", assistantPrincipal: binding.agentPrincipal.rawValue,
            assistantMatrixUserID: binding.agentUserId)
        XCTAssertTrue(LiveRosterRows.isPrivateCosHomeRow(offlineWaiting, agents: [],
                                                        bindings: model.privateCosBindings))
        let merged = ChatListSnapshot.merged(cached: cached, live: [], liveIsAuthoritative: false)
        XCTAssertEqual(merged.filter { !LiveRosterRows.isPrivateCosHomeRow($0, agents: agents,
            bindings: model.privateCosBindings) }.map(\.roomID), ["!personal:atum.example"])
        let waiting = LiveRosterRows.rows(.init(agents: agents, privateCosBindings: model.privateCosBindings,
            apps: [], rooms: [], invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en"))
        XCTAssertTrue(waiting.rows.isEmpty)
        var noMatrixIdentity = agentJSON(id: agentID, name: "Synthetic private assistant", matrixUser: binding.agentUserId)
        noMatrixIdentity["matrixUser"] = NSNull()
        noMatrixIdentity["principal"] = binding.agentPrincipal.rawValue
        let principalOnly = try decodeAgents([noMatrixIdentity])
        XCTAssertTrue(LiveRosterRows.rows(.init(agents: principalOnly,
            privateCosBindings: model.privateCosBindings, apps: [], rooms: [], invites: [],
            pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en")).rows.isEmpty)
        XCTAssertEqual(model.workspace(companyID: cos.view.pair.companyPrincipal.rawValue)?
            .directMessages.chief?.roomID, binding.roomId)
    }

    @MainActor
    func testPrivateCosUnavailableForbiddenAndCapabilityOffLeaveUnclassifiedHomeUnchangedAndRetry() async throws {
        for failure in [CompanyAPIError.refused(.denied, reason: nil, retryAfter: nil), CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil), CompanyAPIError.refused(.unavailable, reason: nil, retryAfter: nil)] {
            let (model, _, cos) = try privateCosModel()
            cos.failure = failure
            await model.refresh()
            XCTAssertTrue(model.privateCosBindings.roomIDs.isEmpty)
            let room = rosterRoom(cos.view.binding!.roomId, userID: cos.view.binding!.agentUserId, latest: 1)
            let input = LiveRosterRows.Input(agents: [], privateCosBindings: model.privateCosBindings,
                apps: [], rooms: [room], invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(), locale: "en")
            let rows = LiveRosterRows.rows(input).rows
            XCTAssertEqual(rows.map(\.id), [room.roomID])
            XCTAssertFalse(LiveRosterRows.isPrivateCosHomeRow(HomeRow(product: rows[0], locale: Locale(identifier: "en")).snapshotRow,
                agents: [], bindings: model.privateCosBindings))
            cos.failure = nil
            await model.refresh()
            XCTAssertEqual(cos.reads, 2)
            XCTAssertEqual(model.privateCosBindings.roomIDs, [room.roomID])
            cos.failure = failure
            await model.refresh()
            XCTAssertEqual(model.privateCosBindings.roomIDs, [room.roomID], "failed reads don't demote positive bindings")
        }
        let (off, _, cos) = try privateCosModel()
        cos.capabilityOff = true
        await off.refresh()
        XCTAssertTrue(off.privateCosBindings.roomIDs.isEmpty)
        XCTAssertEqual(cos.reads, 0)
        cos.capabilityOff = false
        await off.refresh()
        XCTAssertFalse(off.privateCosBindings.roomIDs.isEmpty)
    }

    @MainActor
    func testPrivateCosCompanyReplacementAccountSwitchAndLateReadClearScope() async throws {
        let (model, api, cos) = try privateCosModel()
        await model.refresh()
        let room = cos.view.binding!.roomId
        let other = "a1000000-0000-4000-8000-000000000002"
        let original = cos.view.pair.companyPrincipal.rawValue
        api.list = try companyList([original, other])
        await model.refresh()
        model.selectCompany(other)
        XCTAssertFalse(model.isSelected(companyID: original, owning: room))
        XCTAssertNotEqual(model.workspace(companyID: other)?.directMessages.chief?.roomID, room)
        model.selectCompany(original)
        XCTAssertTrue(model.isSelected(companyID: original, owning: room))
        api.list = try companyList([other])
        await model.refresh()
        XCTAssertNil(model.privateCosBindings.companyID(owning: room))
        XCTAssertNotEqual(model.roomClassification(room), .privateCos(companyID: other))
        api.list = try companyList([cos.view.pair.companyPrincipal.rawValue])
        await model.refresh()
        XCTAssertTrue(model.privateCosBindings.roomIDs.contains(room))
        model.beginAccountScope("synthetic-next-account")
        XCTAssertTrue(model.privateCosBindings.views.isEmpty)
        cos.hold = true
        let task = Task { await model.refresh() }
        while cos.continuation == nil { await Task.yield() }
        model.beginAccountScope("synthetic-third-account")
        cos.continuation?.resume(returning: cos.view)
        await task.value
        XCTAssertTrue(model.privateCosBindings.views.isEmpty)
    }

    // MARK: TS-2…TS-4 Direct messages

    @MainActor
    private func privateCosView(_ file: String,
                                _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> CompanyPrivateCosView {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: privateCosFixture(file)) as? [String: Any])
        edit(&value)
        return try NativeAPI.decode(CompanyPrivateCosView.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor
    func testDirectMessagesSectionIsPresentWhileConversationsAreOff() async throws {
        let (model, _, cos) = try privateCosModel()
        await model.refresh()
        let company = cos.view.pair.companyPrincipal.rawValue
        let workspace = try XCTUnwrap(model.workspace(companyID: company))
        // No conversations client: the family is off, so no DM rows and no "+", but the section stays.
        XCTAssertNil(workspace.conversations)
        XCTAssertEqual(workspace.directMessages.order, [.notes, .chiefOfStaff])
        XCTAssertEqual(workspace.directMessages.selfName, "Owner")
        XCTAssertFalse(workspace.channels.contains { $0.id.hasPrefix("private-cos:") })
    }

    @MainActor
    func testDirectMessagesOrderIsYouThenChiefThenConversationsNewestFirst() {
        let rows = ["c1", "c2"].map { id in
            ConversationListRow(row: ConversationRow(id: id, kind: .dm, title: id, participantCount: 2,
                                                     state: .ready, roomID: "!" + id + ":hs", isHidden: false))
        }
        let section = ConversationSectionPresentation(rows: rows, hidden: [], isLoading: false, failed: false,
                                                      isStale: false, notice: nil)
        let chief = ChiefOfStaffRowPresentation(status: .ready, roomID: "!cos:hs", platformName: nil)
        XCTAssertEqual(DirectMessagesPresentation(chief: chief, conversations: section).order,
                       [.notes, .chiefOfStaff, .conversation("c1"), .conversation("c2")])
        XCTAssertEqual(DirectMessagesPresentation(chief: nil, conversations: section).order,
                       [.notes, .conversation("c1"), .conversation("c2")])
        XCTAssertEqual(DirectMessagesPresentation().order, [.notes])
    }

    @MainActor
    func testChiefOfStaffRowProjectsUncreatedPreparingFailedAndRetryEnsures() async throws {
        let (model, _, cos) = try privateCosModel()
        let company = cos.view.pair.companyPrincipal.rawValue
        // Capability off: asked, nothing usable came back → "Not available yet" with Retry.
        cos.capabilityOff = true
        await model.refresh()
        var chief = try XCTUnwrap(model.chiefOfStaffRow(companyID: company))
        XCTAssertEqual(chief.status, .notAvailable)
        XCTAssertTrue(chief.status.offersRetry)
        XCTAssertNil(chief.roomID)

        // Retry reads again; an uncreated pair is then asked for, as a first visit is (desktop
        // recheck), and shows as setting up.
        cos.capabilityOff = false
        cos.view = try privateCosView("v1-lazy-first-open.uncreated.response.json")
        cos.ensureView = try privateCosView("v1-lazy-first-open.preparing.response.json")
        await model.retryPrivateCos(companyID: company)
        XCTAssertEqual(cos.ensureRequests.map(\.trigger), [.firstCompanyVisit])
        chief = try XCTUnwrap(model.chiefOfStaffRow(companyID: company))
        XCTAssertEqual(chief.status, .settingUp)
        XCTAssertEqual(chief.roomID, cos.ensureView?.binding?.roomId)

        // A paused platform answer keeps the served view and says paused.
        cos.ensureFailure = CompanyAPIError.refused(.conflict, reason: "budget_exhausted", retryAfter: nil)
        await model.ensurePrivateCos(companyID: company)
        XCTAssertEqual(model.chiefOfStaffRow(companyID: company)?.status, .paused)
        XCTAssertEqual(model.chiefOfStaffRow(companyID: company)?.status.offersRetry, true)
        // Asking again with the same trigger replays the same request ID.
        await model.ensurePrivateCos(companyID: company)
        XCTAssertEqual(cos.ensureRequests.map(\.trigger), [.firstCompanyVisit, .dmOpen, .dmOpen])
        XCTAssertEqual(cos.ensureRequests[1].requestId, cos.ensureRequests[2].requestId)

        // Ready: the row opens the bound room; a ready pair is never ensured again.
        cos.ensureFailure = nil
        cos.view = try privateCosView("v1-lazy-first-open.preparing.response.json") {
            $0["state"] = "ready"; $0["greetingState"] = "published"
        }
        await model.refresh()
        XCTAssertEqual(model.chiefOfStaffRow(companyID: company)?.status, .ready)
        let room = await model.privateCosRoomToOpen(companyID: company)
        XCTAssertEqual(room, cos.view.binding?.roomId)
        XCTAssertEqual(cos.ensureRequests.count, 3)
    }

    @MainActor
    func testFirstVisitEnsuresAnUncreatedPairOnce() async throws {
        let (model, _, cos) = try privateCosModel()
        cos.view = try privateCosView("v1-lazy-first-open.uncreated.response.json")
        cos.ensureView = try privateCosView("v1-lazy-first-open.preparing.response.json")
        await model.refresh()
        XCTAssertEqual(cos.ensureRequests.map(\.trigger), [.firstCompanyVisit])
        cos.view = try privateCosView("v1-lazy-first-open.uncreated.response.json")
        await model.refresh()
        XCTAssertEqual(cos.ensureRequests.count, 1, "the first visit asks once per account scope")
    }

    @MainActor
    func testNotesSelfRoomIsTeamSpaceOnlyAndTitledYou() async throws {
        let (model, _, cos) = try privateCosModel()
        await model.refresh()
        let company = cos.view.pair.companyPrincipal.rawValue
        let notes = "!notes:atum.example"
        model.reconcileNotesSelf([company: notes, "a1000000-0000-4000-8000-00000000dead": "!gone:atum.example"])
        XCTAssertEqual(model.notesSelfRooms, [company: notes], "only listed companies keep a notes room")
        XCTAssertEqual(model.roomClassification(notes), .notesSelf(companyID: company))
        XCTAssertTrue(model.isSelected(companyID: company, owning: notes))
        XCTAssertEqual(model.workspace(companyID: company)?.directMessages.notesRoomID, notes)
        XCTAssertEqual(RoomRootDestination.authoritative(roomKind: .group, classification: .notesSelf(companyID: company)),
                       .teamSpace)

        var room = rosterRoom(notes, userID: "@me:atum.example", latest: 1, roomType: CompanyNotesSelf.roomType)
        room = LiveMatrixRoomRow(roomID: room.roomID, displayName: "Empty Room", avatarURL: nil, latestText: nil,
                                 latestPreviewContent: .none, latestSenderID: nil, latestSenderName: nil,
                                 latestIsOwn: true, latestIsNotice: false, latestSendState: .sent,
                                 latestTimestamp: 1, unreadCount: 0, notificationCount: 0, highlightCount: 0,
                                 isMarkedUnread: false, isFavourite: false, isMuted: false, isDirect: false,
                                 memberUserIDs: [], memberCount: 1, roomType: CompanyNotesSelf.roomType,
                                 isEncrypted: false)
        let hidden = LiveRosterRows.rows(.init(agents: [], apps: [], rooms: [room], invites: [], pointers: [:],
            hiddenRooms: MobileHiddenRoomLedger(), locale: "en")).rows
        XCTAssertTrue(hidden.isEmpty, "an unproven notes room is never a row")
        let shown = LiveRosterRows.rows(.init(agents: [], notesSelfRoomIDs: [notes], notesSelfTitle: "You",
            apps: [], rooms: [room], invites: [], pointers: [:], hiddenRooms: MobileHiddenRoomLedger(),
            locale: "en")).rows
        XCTAssertEqual(shown.map(\.id), [notes])
        XCTAssertEqual(shown.first?.title, "You")
    }
}
