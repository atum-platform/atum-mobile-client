import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

extension LiveAppModel {
    /// Uses the open chat's existing assistant/app classification and the
    /// roster's direct-chat distinction. Typed personal rooms, Notes and
    /// unverified company rooms never fall through into the group surface.
    func sharedChatActions(roomID: String) -> MessageMenuRules.SharedChatActions {
        guard let liveMatrix, liveMatrix.isReady,
              let row = liveMatrix.rooms.first(where: { $0.roomID == roomID }) else { return .unavailable }
        if offersCompanyThreads(roomID: roomID) { return .teamSpace }
        guard let own = try? liveMatrix.companyOwnUserID(),
              let info = conversationInfo(roomID: roomID, title: row.displayName, ownUserID: own)
        else { return .unavailable }
        return peopleChatActions(in: row, kind: info.context.kind)
    }

    /// Shared by the live main transcript and the group thread/pin host.
    func peopleChatActions(in row: LiveMatrixRoomRow, kind: RoomKind) -> MessageMenuRules.SharedChatActions {
        guard row.legacyAppBotMove == nil else { return .unavailable }
        switch companyWorkspace.roomClassification(row.roomID) {
        case .personal, .unknown: break
        case .company, .conversation, .privateCos, .notesSelf, .quarantined: return .unavailable
        }
        return .init(kind: kind, isDirect: row.isDirect, activeMemberCount: row.memberCount,
                     isOrdinaryRoom: row.hasCreateState && row.roomType == nil)
    }

    func openGroupThreadList(roomID: String) -> RoomThreadList? {
        guard let session = liveMatrix, let room = try? session.room(id: roomID),
              isCurrentGroupThreadRoom(room, roomID: roomID, session: session) else { return nil }
        return RoomThreadList(room: room, roomID: roomID, session: session) { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.isCurrentGroupThreadRoom(room, roomID: roomID, session: session)
        }
    }

    /// A new group thread uses the same conversation store and SDK send path
    /// as Team Space. The owner of the pushed screen closes this store.
    func openGroupThread(roomID: String, rootID: String, draft: String,
                         focusEventID: String? = nil) async throws -> LiveConversationStore {
        let (session, room) = try await groupThreadRoom(roomID: roomID, rootID: rootID)
        guard let title = session.rooms.first(where: { $0.roomID == roomID })?.displayName,
              let store = makeThreadStore(session: session, roomID: roomID, title: title,
                                          rootID: rootID, draft: draft, isPeopleGroup: true) else {
            throw RoomThreadsFailure.unavailable
        }
        store.searchTargetEventID = focusEventID
        await store.attach(room: room)
        guard isCurrentGroupThreadRoom(room, roomID: roomID, session: session) else {
            store.close()
            throw RoomThreadsFailure.unavailable
        }
        return store
    }

    /// Portable Atum follow, matching desktop; this stays independent of
    /// the homeserver's optional Matrix push subscription.
    func setGroupThreadFollow(roomID: String, rootID: String, followed: Bool) async throws {
        let (session, room) = try await groupThreadRoom(roomID: roomID, rootID: rootID)
        try await session.companySetThreadFollow(roomID: roomID, rootID: rootID, followed: followed) {
            self.isCurrentGroupThreadRoom(room, roomID: roomID, session: session)
        }
    }

    /// MSC4306, for callers explicitly managing a homeserver subscription.
    func setGroupThreadSubscription(roomID: String, rootID: String, subscribed: Bool) async throws {
        let (session, room) = try await groupThreadRoom(roomID: roomID, rootID: rootID)
        try await room.setThreadSubscription(threadRootEventId: rootID, subscribed: subscribed)
        guard isCurrentGroupThreadRoom(room, roomID: roomID, session: session) else {
            throw RoomThreadsFailure.unavailable
        }
    }

    /// For a read action in the list. The focused store sends its own
    /// private threaded receipts when it is read normally.
    func readGroupThread(_ thread: CompanyThread) async throws {
        guard let latestID = thread.latest?.eventID, latestID != thread.root.eventID else { return }
        let (session, room) = try await groupThreadRoom(roomID: thread.roomID, rootID: thread.root.eventID)
        let latest = try await room.loadOrFetchEvent(eventId: latestID)
        guard latest.threadRootEventId() == thread.root.eventID else { throw RoomThreadsFailure.invalidTarget }
        guard isCurrentGroupThreadRoom(room, roomID: thread.roomID, session: session) else {
            throw RoomThreadsFailure.unavailable
        }
        try await session.companyReadThread(roomID: thread.roomID, rootID: thread.root.eventID,
                                            latestEventID: latestID)
    }

    private func groupThreadRoom(roomID: String, rootID: String) async throws -> (LiveMatrixSession, Room) {
        guard CompanyThreadAttention.isRootID(rootID) else { throw RoomThreadsFailure.invalidTarget }
        guard let session = liveMatrix, let room = try? session.room(id: roomID),
              isCurrentGroupThreadRoom(room, roomID: roomID, session: session) else {
            throw RoomThreadsFailure.unavailable
        }
        let root = try await room.loadOrFetchEvent(eventId: rootID)
        guard root.eventId() == rootID, root.threadRootEventId() == nil,
              case .messageLike(.roomMessage) = try root.content() else {
            throw RoomThreadsFailure.invalidTarget
        }
        guard isCurrentGroupThreadRoom(room, roomID: roomID, session: session) else {
            throw RoomThreadsFailure.unavailable
        }
        return (session, room)
    }

    private func isCurrentGroupThreadRoom(_ room: Room, roomID: String, session: LiveMatrixSession) -> Bool {
        !Task.isCancelled && liveMatrix === session && room.membership() == .joined
            && sharedChatActions(roomID: roomID) == .peopleGroup
    }

    /// A chat store on the thread's own timeline (root, then replies), whose
    /// composer replies in the thread. The caller attaches and closes it.
    func companyThreadStore(roomID: String, rootID: String, draft: String) -> LiveConversationStore? {
        guard offersCompanyThreads(roomID: roomID), let liveMatrix else { return nil }
        return makeThreadStore(session: liveMatrix, roomID: roomID, title: companyThreadPlace(roomID: roomID) ?? "",
                               rootID: rootID, draft: draft, isPeopleGroup: false)
    }

    private func makeThreadStore(session: LiveMatrixSession, roomID: String, title: String, rootID: String,
                                 draft: String, isPeopleGroup: Bool) -> LiveConversationStore? {
        guard let own = try? session.companyOwnUserID(),
              var info = conversationInfo(roomID: roomID, title: title, ownUserID: own) else { return nil }
        info.threadRootID = rootID
        info.context.showsGroupThreads = false
        if isPeopleGroup { info.context.kind = .group }
        if case .channel = info.context.companyTurnScope {
            info.context.companyTurnScope = .channel(threadRoot: rootID, binding: nil)
        }
        let store = LiveConversationStore(info: info, draft: draft, history: .onScroll)
        store.onMessageSent = { LiveReporting.shared.messageSent() }
        let roster = companyWorkspace.mentionRoster(roomID: roomID)
        Task { @MainActor [weak store, weak session] in
            guard let session, let members = await session.members(roomID: roomID), let store else { return }
            store.setMentionCandidates(MentionRules.candidates(
                members: members.map { (userID: $0.userID, displayName: $0.displayName) },
                roster: roster, ownUserID: own))
        }
        return store
    }
}
