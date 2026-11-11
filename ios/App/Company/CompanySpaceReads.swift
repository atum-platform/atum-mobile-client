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
