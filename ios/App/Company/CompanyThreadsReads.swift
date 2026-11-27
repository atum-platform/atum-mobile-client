import AtumChat
import AtumNativeAPI
import Foundation

/// The room-list membership change signal. Admission itself uses the
/// synchronized joined members, since the room list contains only heroes.
struct CompanyTurnMembershipKey: Equatable {
    let session: ObjectIdentifier
    let memberCount: UInt64
    let heroes: Set<String>
}

/// The joined-member proof has its own clock. Neither a blocked refresh nor
/// a blocked timeline attach can postpone withdrawal.
@MainActor
final class CompanyTurnProofLease {
    static let refreshInterval: Duration = .seconds(30)

    private let lifetime: Duration
    private var generation: UInt64 = 0
    private var deadline: ContinuousClock.Instant?
    private var expiryTask: Task<Void, Never>?

    init(lifetime: Duration = .seconds(60)) {
        self.lifetime = lifetime
    }

    var isLive: Bool { deadline.map { ContinuousClock.now < $0 } ?? false }

    @discardableResult
    func reset() -> UInt64 {
        generation &+= 1
        clearDeadline()
        return generation
    }

    func isCurrent(_ generation: UInt64) -> Bool { self.generation == generation }

    func clearDeadline() {
        expiryTask?.cancel()
        expiryTask = nil
        deadline = nil
    }

    func arm(from readStarted: ContinuousClock.Instant, onExpiry: @escaping @MainActor () -> Void) -> Bool {
        clearDeadline()
        let deadline = readStarted.advanced(by: lifetime)
        guard ContinuousClock.now < deadline else { return false }
        self.deadline = deadline
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.clearDeadline()
            onExpiry()
        }
        return true
    }
}

// TS-6b: the thread rows Team Space and a channel's thread panel show, read
// through the live Matrix session and fenced to the platform's company
// directory, plus the follow / read writes and the thread's own chat store.
// `LiveAppModel` itself only had `conversationInfo` opened up for this.

extension LiveAppModel {
    func companyTurnMembershipKey(roomID: String) -> CompanyTurnMembershipKey? {
        guard let liveMatrix, liveMatrix.isReady,
              let room = liveMatrix.rooms.first(where: { $0.roomID == roomID }) else { return nil }
        return CompanyTurnMembershipKey(session: ObjectIdentifier(liveMatrix), memberCount: room.memberCount,
                                        heroes: Set(room.memberUserIDs))
    }

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

    /// Whether one thread is followed (explicit choice, then the automatic
    /// rule), for a thread opened without its list. Nil when unreadable.
    func companyThreadFollowed(roomID: String, rootID: String) async -> Bool? {
        guard offersCompanyThreads(roomID: roomID), let liveMatrix else { return nil }
        if let thread = await roomThreads(roomID: roomID)?.first(where: { $0.root.eventID == rootID }) {
            return thread.followed
        }
        // Older than the newest page: only an explicit choice is known.
        return await liveMatrix.companyThreadAttention(roomID: roomID).isFollowed(rootID, automatic: false)
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

    private static let concurrentRoomReads = 4

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
        // At most `concurrentRoomReads` rooms at once, in batches, so a large
        // workspace doesn't fire one `/threads` request per room together.
        let ordered = roomIDs.sorted()
        var read = [(String, [CompanyThreadRoot]?)]()
        for start in stride(from: 0, to: ordered.count, by: Self.concurrentRoomReads) {
            let batch = ordered[start..<min(start + Self.concurrentRoomReads, ordered.count)]
            let reads = batch.map { roomID in
                Task { @MainActor in
                    (roomID, await session.companyThreadRoots(roomID: roomID, ownUserID: own))
                }
            }
            for task in reads { read.append(await task.value) }
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
