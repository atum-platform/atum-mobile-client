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

    /// The open's answer: true opened, false failed, nil no answer of its own (another
    /// open replaced it). A stale attempt changes nothing.
    public mutating func finish(_ attempt: UInt64, opened: Bool?) {
        guard attempt == self.attempt, let target = opening else { return }
        opening = nil
        switch opened {
        case true?: failure = nil
        case false?: failure = target
        case nil: break
        }
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
