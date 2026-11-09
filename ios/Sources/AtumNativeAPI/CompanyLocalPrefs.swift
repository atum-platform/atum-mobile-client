import CryptoKit
import Foundation

/// One company as the fallback order sees it.
public struct CompanyCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    /// The company's default channel is active and its room is ready.
    public let hasReachableDefaultChannel: Bool

    public init(id: String, name: String, hasReachableDefaultChannel: Bool) {
        self.id = id
        self.name = name
        self.hasReachableDefaultChannel = hasReachableDefaultChannel
    }

    /// Reachable means the platform's directory lists the default channel as
    /// active with a ready room; a missing directory (not read yet, or the read
    /// failed) is not reachable.
    public static func reachable(_ directory: CompanyChannelDirectory?) -> Bool {
        directory?.channels.contains {
            $0.channel.isDefault && $0.channel.state == .active
                && $0.room.state == "ready" && $0.room.roomId != nil
        } ?? false
    }
}

/// What the phone remembers about Workplace between launches, per account:
/// the invitations the person chose "Not now" for, the company last shown, and
/// the create whose answer has not been seen yet (so a retry after a relaunch
/// replays the same request ID). It holds no authority. An invitation that is
/// no longer in the platform's list drops out on the next read, and a company
/// that is gone falls back to the one used most recently before it, and only
/// then to the first by name whose default channel can be opened.
public struct CompanyLocalPrefs: Codable, Equatable, Sendable {
    public static let maximumRemembered = 200
    public static let maximumRecentCompanies = 20

    public private(set) var laterInvitationIDs: [String]
    public var activeCompanyID: String?
    /// Company ids the person has been in, newest first, by id and never by
    /// list position. The head is `activeCompanyID`.
    public private(set) var recentCompanyIDs: [String]
    /// A create sent but not yet answered or refused: kept until it succeeds,
    /// the platform refuses it, or the person edits the name.
    public var pendingCreate: CompanyCreateTracker.Attempt?

    public init(laterInvitationIDs: [String] = [], activeCompanyID: String? = nil,
                recentCompanyIDs: [String] = [], pendingCreate: CompanyCreateTracker.Attempt? = nil) {
        self.laterInvitationIDs = laterInvitationIDs
        self.activeCompanyID = activeCompanyID
        self.recentCompanyIDs = recentCompanyIDs
        self.pendingCreate = pendingCreate
    }

    // Prefs saved before the recents list or the pending create existed decode
    // with them empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        laterInvitationIDs = try c.decodeIfPresent([String].self, forKey: .laterInvitationIDs) ?? []
        activeCompanyID = try c.decodeIfPresent(String.self, forKey: .activeCompanyID)
        recentCompanyIDs = try c.decodeIfPresent([String].self, forKey: .recentCompanyIDs) ?? []
        pendingCreate = try c.decodeIfPresent(CompanyCreateTracker.Attempt.self, forKey: .pendingCreate)
    }

    /// Makes `companyID` the company in use and the newest of the recents.
    public mutating func use(company companyID: String) {
        activeCompanyID = companyID
        recentCompanyIDs.removeAll { $0 == companyID }
        recentCompanyIDs.insert(companyID, at: 0)
        if recentCompanyIDs.count > Self.maximumRecentCompanies {
            recentCompanyIDs.removeLast(recentCompanyIDs.count - Self.maximumRecentCompanies)
        }
    }

    /// The company Workplace opens to, in this order:
    /// 1. the one in use (`activeCompanyID`), while the person still belongs to it;
    /// 2. else the most recently used one they still belong to;
    /// 3. else the first company by name (locale-aware) whose default channel
    ///    can be opened (a company still being provisioned, or whose channel
    ///    cannot be reached, is skipped);
    /// 4. else the first company by name.
    /// Never the platform list's own first element: its order says nothing
    /// about the person.
    public func resolvedCompanyID(candidates: [CompanyCandidate], locale: Locale) -> String? {
        guard !candidates.isEmpty else { return nil }
        let present = Set(candidates.map(\.id))
        let history = (activeCompanyID.map { [$0] } ?? []) + recentCompanyIDs
        if let remembered = history.first(where: present.contains) { return remembered }
        let byName = candidates.sorted { left, right in
            let order = left.name.compare(right.name, options: [.caseInsensitive, .diacriticInsensitive],
                                          range: nil, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
        return (byName.first(where: \.hasReachableDefaultChannel) ?? byName[0]).id
    }

    public func isLater(_ invitationID: String) -> Bool {
        laterInvitationIDs.contains(invitationID)
    }

    public mutating func later(_ invitationID: String) {
        guard !isLater(invitationID) else { return }
        laterInvitationIDs.append(invitationID)
        if laterInvitationIDs.count > Self.maximumRemembered {
            laterInvitationIDs.removeFirst(laterInvitationIDs.count - Self.maximumRemembered)
        }
    }

    /// Keeps only invitations the platform still lists.
    public mutating func prune(keeping invitationIDs: Set<String>) {
        laterInvitationIDs.removeAll { !invitationIDs.contains($0) }
    }
}

public struct CompanyLocalPrefsJournal {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "atum.company-prefs.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// The defaults key for one account: the full SHA-256 of its identity, so
    /// two accounts cannot share a key (the 32-bit log fingerprint could).
    /// The first version used that short fingerprint; those keys are not read
    /// (prefs are cosmetic and start fresh).
    public static func key(forAccount accountID: String) -> String {
        "atum.company-prefs.v2." + SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func load() -> CompanyLocalPrefs {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(CompanyLocalPrefs.self, from: data)
        else { return CompanyLocalPrefs() }
        return prefs
    }

    public func save(_ prefs: CompanyLocalPrefs) {
        guard prefs != CompanyLocalPrefs() else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key)
    }
}
