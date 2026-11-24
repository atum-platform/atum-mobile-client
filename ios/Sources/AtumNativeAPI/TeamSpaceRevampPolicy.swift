import Foundation

// Team Space revamp pass 1 (atum-desktop #114, `fef8286c`), the state rules the
// phone shares with the desktop. Layout stays the phone's own; see
// docs/ports/w4-e7-team-space.md.

// MARK: Header search

/// The box at the top of the workspace filters the list as you type. Enter, or
/// the "Search “…”" row under the box, runs company message search
/// (desktop `company-workspace.tsx`, `[...sidebarQuery.trim()].length >= 2`).
public enum TeamSpaceHeaderSearch {
    /// The trimmed query once it is long enough for company message search, else nil.
    /// Desktop counts code points (`[...string]`), not UTF-16 units or grapheme clusters.
    public static func messageQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.unicodeScalars.count >= 2 ? trimmed : nil
    }
}

/// The submitted query and its pages. Replacing or clearing the query
/// invalidates the old request, even when an async response arrives late.
public struct TeamSpaceMessageSearchState: Equatable, Sendable {
    public struct Request: Equatable, Sendable {
        public let term: String
        public let nextBatch: String?
        fileprivate let serial: UInt64
    }

    public private(set) var request: Request?
    public private(set) var page: CompanySearchPage?
    public private(set) var failed = false
    private var term: String?
    private var serial: UInt64 = 0

    public init() {}

    public mutating func submit(_ raw: String) {
        term = TeamSpaceHeaderSearch.messageQuery(raw)
        page = nil
        failed = false
        request = nil
        if let term { begin(term: term, nextBatch: nil) }
    }

    public mutating func loadMore() {
        guard request == nil, let term, let nextBatch = page?.nextBatch else { return }
        begin(term: term, nextBatch: nextBatch)
    }

    public mutating func finish(_ request: Request, answer: CompanySearchPage?) {
        guard request == self.request else { return }
        self.request = nil
        failed = answer == nil
        guard let answer else { return }
        let previous = page?.results ?? []
        var seen = Set(previous.map(\.id))
        page = CompanySearchPage(results: previous + answer.results.filter { seen.insert($0.id).inserted },
                                 nextBatch: answer.nextBatch)
    }

    private mutating func begin(term: String, nextBatch: String?) {
        serial &+= 1
        failed = false
        request = Request(term: term, nextBatch: nextBatch, serial: serial)
    }
}

/// The one line the Channels section says when it lists nothing (desktop
/// `team-space/channel-sections.tsx:152–156`): "No matches" while a query hides live
/// channels, else "No channels". An Archived list still on screen keeps it quiet.
public enum CompanyChannelListNote: Equatable, Sendable {
    case noChannels, noMatches

    /// - Parameters:
    ///   - query: the header box's text.
    ///   - shown: live channels left after filtering (Favorites and Channels).
    ///   - live: live channels before filtering.
    ///   - archived: archived channels still listed (desktop's list is unfiltered; the
    ///     phone's box filters Archived, so the caller passes what it still shows).
    public static func note(query: String, shown: Int, live: Int, archived: Int) -> CompanyChannelListNote? {
        guard shown == 0, archived == 0 else { return nil }
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return searching && live > 0 ? .noMatches : .noChannels
    }
}

// MARK: Settings sections

/// Company settings show one section at a time (desktop `CompanySettingsSection`).
public enum CompanySettingsSection: String, CaseIterable, Sendable {
    case people, workspace, ai, billing
}

public enum CompanySettingsSections {
    /// The sections the viewer can use, in desktop order. AI is always there.
    /// - Parameters:
    ///   - people: the member snapshot is read (desktop `snapshot11`).
    ///   - workspace: the viewer can edit policy or projects are on.
    ///   - billing: the company wallet (owners and admins) or project funding.
    public static func available(people: Bool, workspace: Bool, billing: Bool) -> [CompanySettingsSection] {
        [(CompanySettingsSection.people, people), (.workspace, workspace), (.ai, true), (.billing, billing)]
            .filter(\.1).map(\.0)
    }

    /// The section to show: the chosen one while the viewer still has it, else the
    /// first one they have (a role change while settings are open falls back).
    public static func current(_ chosen: CompanySettingsSection,
                               in available: [CompanySettingsSection]) -> CompanySettingsSection {
        available.contains(chosen) ? chosen : (available.first ?? .ai)
    }

    /// Where the sheet opens: Company settings asks for Workspace, the overview for People.
    public static func initial(fromSettings: Bool) -> CompanySettingsSection {
        fromSettings ? .workspace : .people
    }

    /// The section picker is drawn only when there is a choice.
    public static func showsPicker(_ available: [CompanySettingsSection]) -> Bool {
        available.count > 1
    }
}

// MARK: Board views and Mine

/// Two views of the one board (desktop `CompanyBoardViewMode` minus the old `my_tasks`).
public enum CompanyBoardView: String, CaseIterable, Sendable {
    case board, list
}

/// The board's view and owner filter (desktop `CompanySpacePreferences` `boardView` /
/// `ownerMemberRef`). The phone never had the old third view ("My tasks") or a remembered
/// view, so desktop's one-time `my_tasks` migration has nothing to act on here.
public struct CompanyBoardPreference: Equatable, Sendable {
    public var view: CompanyBoardView
    public var ownerMemberRef: String?

    public init(view: CompanyBoardView = .board, ownerMemberRef: String? = nil) {
        self.view = view
        self.ownerMemberRef = ownerMemberRef
    }

    /// Mine is the owner filter set to the viewer's own member.
    public func mineOn(viewer: String?) -> Bool {
        guard let viewer else { return false }
        return ownerMemberRef == viewer
    }

    public func selecting(_ view: CompanyBoardView) -> CompanyBoardPreference {
        CompanyBoardPreference(view: view, ownerMemberRef: ownerMemberRef)
    }

    /// Mine on sets the owner filter to the viewer; off clears it. The view stays.
    public func togglingMine(viewer: String?) -> CompanyBoardPreference {
        guard let viewer else { return self }
        return CompanyBoardPreference(view: view, ownerMemberRef: mineOn(viewer: viewer) ? nil : viewer)
    }
}

// MARK: Channel opening

public enum RoomOpenResult: Equatable, Sendable {
    case opened, failed, superseded
}

/// Opening a channel, and a failed open held with its company and room (desktop
/// `channelOpenFailure`). It shows only while that company is on screen, Try again asks
/// for exactly that room, and any successful navigation clears it. Only the latest
/// open may land.
public struct CompanyChannelOpenState: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        public let companyID: String
        public let roomID: String

        public init(companyID: String, roomID: String) {
            self.companyID = companyID
            self.roomID = roomID
        }
    }

    public private(set) var opening: Target?
    public private(set) var failure: Target?
    private var attempt: UInt64 = 0

    public init() {}

    /// A tap (or Try again) on a channel. Returns the attempt to hand back to `finish`.
    public mutating func begin(_ target: Target) -> UInt64 {
        attempt &+= 1
        opening = target
        // Desktop `openRoom` clears the held failure as it starts.
        failure = nil
        return attempt
    }

    /// A stale attempt changes nothing. Only a current failure is shown.
    public mutating func finish(_ attempt: UInt64, result: RoomOpenResult) {
        guard attempt == self.attempt, let target = opening else { return }
        opening = nil
        failure = result == .failed ? target : nil
    }

    /// Another room or company came on screen: the failure it replaced is gone, and an
    /// open still running for another company cannot land.
    public mutating func navigated(toCompany companyID: String?) {
        failure = nil
        if opening?.companyID != companyID {
            opening = nil
            attempt &+= 1
        }
    }

    /// The room whose open failed in this company, if any.
    public func failedRoom(companyID: String?) -> String? {
        guard let failure, failure.companyID == companyID else { return nil }
        return failure.roomID
    }

    public func isOpening(roomID: String, companyID: String?) -> Bool {
        opening == Target(companyID: companyID ?? "", roomID: roomID)
    }
}
