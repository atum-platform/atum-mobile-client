import AtumChat
import AtumNativeAPI
import Foundation

// TS-6b: the thread rows Team Space and a channel's thread panel show, read
// through the live Matrix session and fenced to the platform's company
// directory, plus the follow / read writes and the thread's own chat store.
// `LiveAppModel` itself only had `conversationInfo` opened up for this.

extension LiveAppModel {
    /// The rooms whose threads Team Space lists: the company's channels and
    /// conversations (desktop `companyChannel ?? companyConversation`), joined
    /// on this session. Never "You", the Chief of Staff or a personal room.
    func companyThreadRoomIDs(companyID: String) -> Set<String> {
        guard let liveMatrix else { return [] }
        let joined = Set(liveMatrix.rooms.map(\.roomID))
        return companyWorkspace.roomDirectory.roomIDs(companyID: companyID)
            .union(companyWorkspace.conversations.roomDirectory.roomIDs(companyID: companyID))
            .intersection(joined)
    }

    /// Whether a room is a Team Space channel or conversation (where threads live).
    func offersCompanyThreads(roomID: String) -> Bool {
        guard let companyID = companyWorkspace.teamSpaceRoomLabel(roomID: roomID)?.companyID else { return false }
        return companyThreadRoomIDs(companyID: companyID).contains(roomID)
    }

    /// The company's threads, newest first (desktop `matrixCompanyThreads`). Nil when unreadable.
    func companyThreads(companyID: String) async -> [CompanyThread]? {
        guard companyWorkspace.activeCompanyID == companyID else { return nil }
        let roomIDs = companyThreadRoomIDs(companyID: companyID)
        guard let threads = await threads(in: roomIDs) else { return nil }
        // Recheck the directory after the reads: a room that left it meanwhile is not shown.
        return CompanyThreads.company(threads, allowedRoomIDs: companyThreadRoomIDs(companyID: companyID))
    }

    /// The company list's rows: each thread with its room's name as Team Space shows it.
    func companyThreadRows(companyID: String) async -> [CompanyThreadListRow]? {
        guard let threads = await companyThreads(companyID: companyID) else { return nil }
        return threads.compactMap { thread in
            guard let label = companyWorkspace.teamSpaceRoomLabel(roomID: thread.roomID),
                  label.companyID == companyID else { return nil }
            return CompanyThreadListRow(thread: thread, roomName: label.name,
                                        isChannel: companyWorkspace.isCompanyChannel(thread.roomID))
        }
    }

    /// One room's threads, for its panel. Nil when unreadable.
    func roomThreads(roomID: String) async -> [CompanyThread]? {
        guard offersCompanyThreads(roomID: roomID) else { return nil }
        return await threads(in: [roomID]).map { CompanyThreads.sorted($0) }
    }

    /// Where a thread lives, as its header says it ("# general", or the conversation's name).
    func companyThreadPlace(roomID: String) -> String? {
        companyWorkspace.teamSpaceRoomLabel(roomID: roomID)?.name
    }

    /// Follow or unfollow a thread (desktop `setMatrixThreadFollow`).
    func setCompanyThreadFollow(roomID: String, rootID: String, followed: Bool) async -> Bool {
        guard offersCompanyThreads(roomID: roomID), let liveMatrix else { return false }
        do {
            try await liveMatrix.companySetThreadFollow(roomID: roomID, rootID: rootID, followed: followed)
            return true
        } catch {
            return false
        }
    }

    /// Mark read (desktop `readMatrixThread`).
    func readCompanyThread(_ thread: CompanyThread) async -> Bool {
        guard offersCompanyThreads(roomID: thread.roomID), let liveMatrix,
              let latest = thread.latest?.eventID else { return false }
        do {
            try await liveMatrix.companyReadThread(roomID: thread.roomID, rootID: thread.root.eventID,
                                                   latestEventID: latest)
            return true
        } catch {
            return false
        }
    }

    /// Whether the thread's root can still be read (desktop `threadUnavailable` otherwise).
    func companyThreadRootAvailable(roomID: String, rootID: String) async -> Bool {
        guard offersCompanyThreads(roomID: roomID), let liveMatrix else { return false }
        return await liveMatrix.companyEventSummary(roomID: roomID, eventID: rootID) != nil
    }

    /// A chat store on the thread's own timeline (root, then replies), whose
    /// composer replies in the thread. The caller attaches and closes it.
    func companyThreadStore(roomID: String, rootID: String, draft: String) -> LiveConversationStore? {
        guard offersCompanyThreads(roomID: roomID), let liveMatrix,
              let own = try? liveMatrix.companyOwnUserID(),
              var info = conversationInfo(roomID: roomID, title: companyThreadPlace(roomID: roomID) ?? "",
                                          ownUserID: own) else { return nil }
        info.threadRootID = rootID
        let store = LiveConversationStore(info: info, draft: draft, history: .onScroll)
        store.onMessageSent = { LiveReporting.shared.messageSent() }
        let roster = companyWorkspace.mentionRoster(roomID: roomID)
        Task { @MainActor [weak store, weak liveMatrix] in
            guard let liveMatrix, let members = await liveMatrix.members(roomID: roomID), let store else { return }
            store.setMentionCandidates(MentionRules.candidates(
                members: members.map { (userID: $0.userID, displayName: $0.displayName) },
                roster: roster, ownUserID: own))
        }
        return store
    }

    private func threads(in roomIDs: Set<String>) async -> [CompanyThread]? {
        guard let liveMatrix, let own = try? liveMatrix.companyOwnUserID() else { return nil }
        if roomIDs.isEmpty { return [] }
        // Unread and mentions: the homeserver's own notification list, as the
        // Activity inbox reads it (the pinned SDK has no per-thread counts).
        var activity = [CompanyActivityItem]()
        if let data = try? await liveMatrix.companyNotificationsJSON() {
            activity = CompanyActivityFeed.parse(notificationsJSON: data, ownUserID: own, roomIDs: roomIDs) ?? []
        }
        let session = liveMatrix
        let read = await withTaskGroup(of: (String, [CompanyThreadRoot]?).self) { group in
            for roomID in roomIDs {
                group.addTask { @MainActor in
                    (roomID, await session.companyThreadRoots(roomID: roomID, ownUserID: own))
                }
            }
            var collected = [(String, [CompanyThreadRoot]?)]()
            for await result in group { collected.append(result) }
            return collected
        }
        guard liveMatrix === self.liveMatrix else { return nil }
        // Every room failing is a failed read; one room failing hides only its threads.
        guard read.contains(where: { $0.1 != nil }) else { return nil }
        var threads = [CompanyThread]()
        for (roomID, roots) in read {
            guard let roots else { continue }
            let attention = await liveMatrix.companyThreadAttention(roomID: roomID)
            threads += CompanyThreads.project(
                roomID: roomID,
                roots: roots.map { (root: $0.root, latest: $0.latest, replyCount: $0.replyCount) },
                attention: attention,
                activity: activity.filter { $0.roomID == roomID })
        }
        return threads
    }
}
