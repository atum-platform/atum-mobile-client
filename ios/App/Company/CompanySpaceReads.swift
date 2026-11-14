import AtumNativeAPI
import Foundation

// The rows wave 2's Team Space views show, read through the live Matrix
// session and fenced to the platform's company directory. The extension adds
// reads only; `LiveAppModel` itself is not changed.

struct CompanyActivityRow: Identifiable, Equatable {
    let item: CompanyActivityItem
    let roomName: String
    let senderName: String?
    var id: String { item.id }
}

struct CompanySavedRow: Identifiable, Equatable {
    let pointer: CompanySavedMessagePointer
    /// Nil when the message is gone, out of reach, or not in a company room.
    let summary: CompanyEventSummary?
    let roomName: String?
    let companyName: String?
    let isOwn: Bool
    var id: String { pointer.id }
}

struct CompanyPinnedRow: Identifiable, Equatable {
    let eventID: String
    let summary: CompanyEventSummary?
    let isOwn: Bool
    var id: String { eventID }
}

/// The intro and details facts of one company channel.
struct CompanyChannelFacts: Equatable {
    /// The room's `m.room.create` time.
    let createdAt: Date?
    let pinnedCount: Int?
}

extension LiveAppModel {
    /// The open company's Activity inbox, newest first. Nil when it cannot be read.
    func companyActivity(companyID: String) async -> [CompanyActivityRow]? {
        guard let liveMatrix, companyWorkspace.activeCompanyID == companyID,
              let own = try? liveMatrix.companyOwnUserID(),
              let data = try? await liveMatrix.companyNotificationsJSON() else { return nil }
        let rooms = companyWorkspace.teamSpaceRoomIDs(companyID: companyID)
        guard let items = CompanyActivityFeed.parse(notificationsJSON: data, ownUserID: own, roomIDs: rooms)
        else { return nil }
        var names = [String: String]()
        var rows = [CompanyActivityRow]()
        for item in items {
            guard let label = companyWorkspace.teamSpaceRoomLabel(roomID: item.roomID),
                  label.companyID == companyID else { continue }
            let key = item.roomID + "\u{0}" + item.senderID
            if names[key] == nil {
                names[key] = await liveMatrix.companyMemberName(roomID: item.roomID, userID: item.senderID)
            }
            rows.append(CompanyActivityRow(item: item, roomName: label.name, senderName: names[key]))
        }
        return rows
    }

    /// The account's Saved pointers (shared with the desktop). Nil when unreadable.
    func companySavedPointers() async -> [CompanySavedMessagePointer]? {
        guard let liveMatrix else { return nil }
        let json: String?
        do {
            json = try await liveMatrix.freshGlobalAccountData(eventType: CompanySavedMessages.accountDataType)
        } catch {
            return nil
        }
        // Never written is an empty list; a record the phone cannot read is nil.
        return CompanySavedMessages.parse(json)
    }

    /// Saved rows with their message text; a message outside the company directory stays unavailable.
    func companySavedRows(_ pointers: [CompanySavedMessagePointer]) async -> [CompanySavedRow] {
        let own = try? liveMatrix?.companyOwnUserID()
        var rows = [CompanySavedRow]()
        for pointer in pointers {
            let label = companyWorkspace.teamSpaceRoomLabel(roomID: pointer.roomID)
            var summary: CompanyEventSummary?
            if label != nil {
                summary = await liveMatrix?.companyEventSummary(roomID: pointer.roomID, eventID: pointer.eventID)
            }
            rows.append(CompanySavedRow(
                pointer: pointer, summary: summary, roomName: label?.name,
                companyName: label.flatMap { companyWorkspace.companyName($0.companyID) },
                isOwn: summary.map { $0.senderID == own } ?? false))
        }
        return rows
    }

    /// A company channel's pinned messages, in the room's order.
    func companyPinnedRows(roomID: String) async -> [CompanyPinnedRow]? {
        guard companyWorkspace.teamSpaceRoomLabel(roomID: roomID) != nil, let liveMatrix,
              let ids = await liveMatrix.companyPinnedEventIDs(roomID: roomID) else { return nil }
        let own = try? liveMatrix.companyOwnUserID()
        var rows = [CompanyPinnedRow]()
        for eventID in ids {
            let summary = await liveMatrix.companyEventSummary(roomID: roomID, eventID: eventID)
            rows.append(CompanyPinnedRow(eventID: eventID, summary: summary,
                                         isOwn: summary.map { $0.senderID == own } ?? false))
        }
        return rows
    }

    /// When a channel's room was made, and how many messages are pinned in it.
    func companyChannelFacts(roomID: String) async -> CompanyChannelFacts? {
        guard companyWorkspace.claim(roomID: roomID) != nil, let liveMatrix else { return nil }
        let create = await liveMatrix.notesSelfCreateFacts(roomID: roomID)
        let pinned = await liveMatrix.companyPinnedEventIDs(roomID: roomID)
        return CompanyChannelFacts(
            createdAt: create?.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
            pinnedCount: pinned?.count)
    }
}

// MARK: Home search: Channels, Messages and Files (desktop roster global search)

extension LiveAppModel {
    /// Desktop `globalChannels`' source: the joined Team Space rooms, channels
    /// and conversations, named as the room list names them (`room.name`), in
    /// the room list's order. "You" and the Chief of Staff are left out, as
    /// desktop leaves out `isCompanyPrivateCosClaim` rooms.
    func homeSearchChannels() -> [HomeSearchChannel] {
        guard let liveMatrix else { return [] }
        return liveMatrix.rooms.compactMap { row in
            guard companyWorkspace.isCompanyChannel(row.roomID)
                || companyWorkspace.conversations.claim(roomID: row.roomID) != nil else { return nil }
            return HomeSearchChannel(roomID: row.roomID, name: row.displayName)
        }
    }

    /// Each company Home search may ask, with the rooms its directory lists.
    /// A company is asked once one of its rooms is joined (desktop
    /// `globalCompanyIds`: companies of the rooms in the roster's snapshot).
    func homeSearchTargets() -> [String: [CompanySearchTarget]] {
        guard let liveMatrix else { return [:] }
        let joined = Set(liveMatrix.rooms.map(\.roomID))
        let companies = Set(companyWorkspace.channelsByCompany.keys)
            .union(companyWorkspace.conversations.directories.keys)
        var result = [String: [CompanySearchTarget]]()
        for company in companies {
            let targets = CompanySearchTarget.targets(
                channels: companyWorkspace.channelsByCompany[company],
                conversations: companyWorkspace.conversations.directories[company])
            if targets.contains(where: { joined.contains($0.roomID) }) { result[company] = targets }
        }
        return result
    }

    /// Desktop `searchCompanies`: every company asked at once for ten of one
    /// tab, companies in id order. A company that fails answers nothing; there
    /// is no error row and no retry.
    func homeCompanySearch(_ term: String, tab: CompanySearchTab) async -> [CompanySearchResult] {
        guard let liveMatrix, let query = CompanyMessageSearch.query(term) else { return [] }
        let rows = Dictionary(liveMatrix.rooms.map { ($0.roomID, $0) }, uniquingKeysWith: { first, _ in first })
        let companies = homeSearchTargets()
        // Every company is asked at once (desktop `Promise.all`); each page is
        // a main-actor task because the session is main-actor state.
        let tasks: [(String, Task<[CompanySearchResult], Never>)] = companies.map { entry in
            let company = entry.key
            let admitted = CompanyMessageSearch.admitted(
                entry.value, query: query, isJoined: { rows[$0] != nil },
                isEncrypted: { rows[$0]?.isEncrypted == true })
            return (company, Task { @MainActor in
                await Self.companySearchPage(liveMatrix: liveMatrix, companyID: company,
                                             admitted: admitted, query: query, tab: tab)
            })
        }
        var pages = [String: [CompanySearchResult]]()
        await withTaskCancellationHandler {
            for entry in tasks { pages[entry.0] = await entry.1.value }
        } onCancel: {
            for entry in tasks { entry.1.cancel() }
        }
        return CompanyMessageSearch.merged(pages)
    }

    private static func companySearchPage(liveMatrix: LiveMatrixSession, companyID: String,
                                          admitted: [CompanySearchTarget], query: CompanySearchQuery,
                                          tab: CompanySearchTab) async -> [CompanySearchResult] {
        // An operator-only query (`from:me`) is answered from the loaded
        // timeline on desktop; the phone has no such read yet.
        guard !admitted.isEmpty, !query.needsLoadedHistory else { return [] }
        var senders: [String]?
        if let from = query.from {
            if from == "me" {
                senders = (try? liveMatrix.companyOwnUserID()).map { [$0] } ?? []
            } else {
                var matches = Set<String>()
                for target in admitted {
                    for member in await liveMatrix.companySearchMembers(roomID: target.roomID)
                    where CompanyMessageSearch.memberMatches(userID: member.userID, names: member.names, from: from) {
                        matches.insert(member.userID)
                    }
                }
                senders = matches.sorted()
            }
        }
        if senders?.isEmpty == true { return [] }
        guard let body = try? CompanyMessageSearch.requestBody(query: query, tab: tab,
                                                                roomIDs: admitted.map(\.roomID), senders: senders),
              let data = try? await liveMatrix.companySearchJSON(body: body) else { return [] }
        return CompanyMessageSearch.results(responseJSON: data, companyID: companyID, tab: tab,
                                            query: query, targets: admitted) ?? []
    }

    /// Desktop `openGlobalEvent` → `openCompanyMessage`: the room is still one
    /// the company lists, and the message is still there, the same message
    /// in the same thread. Then Home opens its room.
    func openHomeSearchResult(_ result: CompanySearchResult) async -> Bool {
        guard companyWorkspace.teamSpaceRoomLabel(roomID: result.roomID)?.companyID == result.companyID,
              let summary = await liveMatrix?.companyEventSummary(roomID: result.roomID, eventID: result.eventID)
        else { return false }
        return summary.senderID == result.sender && summary.threadRootID == result.threadRootID
    }
}
