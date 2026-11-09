import Foundation

// Pure rules for the phone's Team Space surface (B19 S4): which rooms belong
// to a company, how an accepted invitation converges to a channel room, how a
// leave request is kept until its acknowledgement, and when the non-E2EE line
// shows. No transport and no UI.

public struct CompanyRoomClaim: Equatable, Sendable {
    public let companyID: String
    public let channelID: String
    public let displayName: String
    public let isDefault: Bool
    public let roomID: String
}

/// The platform channel directory's `roomId` is the only authority for "this
/// Matrix room is a company channel": the SDK cannot read a custom room type,
/// and `m.room.create.type` is skipped above two members. Claims survive a
/// directory refresh that omits a room and a room-list reconciliation that
/// rebuilds the rows, and end only when the company leaves the account's list
/// (leave, removal) or the account changes.
public struct CompanyRoomDirectory: Equatable, Sendable {
    private var claimsByRoom = [String: CompanyRoomClaim]()
    private var roomsByCompany = [String: Set<String>]()

    public init() {}

    public var isEmpty: Bool { claimsByRoom.isEmpty }
    public var companyIDs: Set<String> { Set(roomsByCompany.keys) }

    /// Adds every ready room. Missing or not-yet-ready channels never erase a
    /// known claim: reconciliation is not removal.
    public mutating func absorb(_ directory: CompanyChannelDirectory, companyID: NativeID) {
        let company = companyID.rawValue
        for entry in directory.channels {
            guard entry.room.state == "ready", let roomID = entry.room.roomId else { continue }
            let claim = CompanyRoomClaim(companyID: company,
                                         channelID: entry.channel.id.rawValue,
                                         displayName: entry.channel.displayName,
                                         isDefault: entry.channel.isDefault,
                                         roomID: roomID)
            claimsByRoom[roomID] = claim
            roomsByCompany[company, default: []].insert(roomID)
        }
        if roomsByCompany[company] == nil { roomsByCompany[company] = [] }
    }

    /// Applies a successful company list: a company no longer listed (left,
    /// removed, retired) ends its claims with the same reach as the list.
    public mutating func retain(companies: Set<String>) {
        for company in Array(roomsByCompany.keys) where !companies.contains(company) {
            remove(companyID: company)
        }
    }

    public mutating func remove(companyID: String) {
        for roomID in roomsByCompany.removeValue(forKey: companyID) ?? [] {
            claimsByRoom.removeValue(forKey: roomID)
        }
    }

    public mutating func clear() {
        claimsByRoom.removeAll()
        roomsByCompany.removeAll()
    }

    public func claim(roomID: String) -> CompanyRoomClaim? { claimsByRoom[roomID] }

    public func isCompanyChannel(_ roomID: String) -> Bool { claimsByRoom[roomID] != nil }

    public func companyID(roomID: String) -> String? { claimsByRoom[roomID]?.companyID }

    public func roomIDs(companyID: String) -> Set<String> { roomsByCompany[companyID] ?? [] }
}

/// What the SDK currently shows for the target room.
public enum CompanyRoomPresence: Equatable, Sendable {
    case joined
    case invited
    case absent
    /// No live Matrix session to ask.
    case unknown
}

/// Accept → directory ready → invitation synced → join → open, with a bounded
/// retry and no manual refresh (Round 2 item 6). The app performs the step;
/// this decides it.
public enum CompanyConvergence {
    public static let attempts = 8
    public static let delayMilliseconds = 1_500

    public enum Step: Equatable, Sendable {
        case wait
        case join(roomID: String)
        case open(roomID: String)
        case giveUp
    }

    /// The preferred channel once its room is ready, else the seeded default
    /// channel, else nil.
    public static func targetRoomID(in directory: CompanyChannelDirectory,
                                    preferredChannelID: String?) -> String? {
        let ready = directory.channels.filter { $0.room.state == "ready" }
        if let preferredChannelID,
           let preferred = ready.first(where: { $0.channel.id.rawValue == preferredChannelID }) {
            return preferred.room.roomId
        }
        if let seeded = ready.first(where: { $0.channel.isDefault }) { return seeded.room.roomId }
        // A company created before the default channel existed has none.
        return ready.first?.room.roomId
    }

    public static func step(attempt: Int,
                            directory: CompanyChannelDirectory?,
                            preferredChannelID: String?,
                            presence: CompanyRoomPresence) -> Step {
        guard attempt >= 0, attempt < attempts else { return .giveUp }
        guard let directory,
              let roomID = targetRoomID(in: directory, preferredChannelID: preferredChannelID) else {
            return .wait
        }
        switch presence {
        case .joined: return .open(roomID: roomID)
        case .invited: return .join(roomID: roomID)
        case .absent, .unknown: return .wait
        }
    }
}

/// The leave request is kept until its acknowledgement is `removed` (or the
/// company retired): authority ended at `revoking`, but the same requestId is
/// replayed quietly so a lost answer can still reach `removed`.
public struct CompanyLeaveTracker: Equatable, Sendable {
    public struct Pending: Codable, Equatable, Sendable {
        public let companyID: String
        public let requestID: String
        public init(companyID: String, requestID: String) {
            self.companyID = companyID
            self.requestID = requestID
        }
    }

    public private(set) var pending: Pending?

    public init(pending: Pending? = nil) { self.pending = pending }

    public var isPending: Bool { pending != nil }

    public mutating func begin(companyID: String, requestID: String) {
        pending = Pending(companyID: companyID, requestID: requestID)
    }

    /// Returns true when the acknowledgement finishes the departure.
    @discardableResult
    public mutating func apply(_ acknowledgement: CompanyLeaveAcknowledgement) -> Bool {
        if acknowledgement.isFinished {
            pending = nil
            return true
        }
        return false
    }

    /// A refusal that means there is nothing left to retry: no longer a
    /// member, a v1 server, or the last-admin blocker. Transport failures and
    /// 503 keep the request.
    public mutating func apply(_ error: CompanyAPIError) {
        switch error {
        case let .refused(refusal, _, _):
            if [.invalid, .denied, .missing, .conflict, .authentication].contains(refusal) {
                pending = nil
            }
        case .invalid, .unavailable, .transport:
            break
        }
    }
}

public struct CompanyLeaveJournal {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "atum.company-leave.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CompanyLeaveTracker {
        guard let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(CompanyLeaveTracker.Pending.self, from: data)
        else { return CompanyLeaveTracker() }
        return CompanyLeaveTracker(pending: pending)
    }

    public func save(_ tracker: CompanyLeaveTracker) {
        guard let pending = tracker.pending else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Company channels are plain rooms. The line shows in the channel details
/// always and above the composer until the person's first message.
public enum CompanyChannelNotice {
    public static func isRequired(isCompanyChannel: Bool, roomEncrypted: Bool?) -> Bool {
        isCompanyChannel && roomEncrypted != true
    }

    public static func showsAboveComposer(required: Bool, hasOwnMessage: Bool) -> Bool {
        required && !hasOwnMessage
    }
}

/// A 1.1 client that meets a v1 server (or a rolled-back Shell) hides the
/// feature instead of presenting the refusal as the person's mistake.
public enum CompanyWireDegrade {
    public static func shouldDegrade(_ error: Error) -> Bool {
        if error is CompanyWireRefusal { return true }
        guard let error = error as? CompanyAPIError else { return false }
        switch error {
        case .refused(.invalid, _, _), .refused(.missing, _, _):
            // A 400 on a 1.1 write or a 404 on `leave` is the pack's
            // "this server is v1" path. `denied` is a real refusal.
            return true
        case .refused, .invalid, .unavailable, .transport:
            return false
        }
    }
}

public enum CompanyRefusal: String, Equatable, Sendable {
    case invalid, authentication, denied, missing, conflict, limit, unavailable
}

/// Classified failures only: no server body, reason beyond the pack's fixed
/// vocabulary, or credential ever reaches the UI.
public enum CompanyAPIError: Error, Equatable, Sendable {
    case refused(CompanyRefusal, reason: String?, retryAfter: Int64?)
    case unavailable
    case transport
    case invalid

    public init(_ failure: NativeDomainClientFailure) {
        switch failure {
        case .transportUnavailable, .cancelled:
            self = .transport
        case let .http(http):
            let reason = http.response.details?.reason
            switch http.response.error {
            case .badRequest: self = .refused(.invalid, reason: reason, retryAfter: nil)
            case .unauthenticated: self = .refused(.authentication, reason: reason, retryAfter: nil)
            case .denied: self = .refused(.denied, reason: reason, retryAfter: nil)
            case .notFound: self = .refused(.missing, reason: reason, retryAfter: nil)
            case .conflict: self = .refused(.conflict, reason: reason, retryAfter: nil)
            case .rateLimited: self = .refused(.limit, reason: reason, retryAfter: http.retryAfterSeconds)
            case .unavailable: self = .unavailable
            }
        default:
            self = .invalid
        }
    }

    public var isLastAdmin: Bool {
        if case let .refused(.conflict, reason, _) = self { return reason == "last_admin" }
        return false
    }
}

/// The one company-name rule. The platform (Shell `printableTrimmed`) and the
/// desktop both require 1…120 UTF-16 units, already trimmed, with no control
/// characters; anything else is a 400 with no effect. The phone normalises what
/// was typed to that shape instead of sending a request it knows is refused.
public enum CompanyName {
    public static let maximumLength = 120

    private static let trimmed = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// The name to send for what a person typed, or nil when nothing usable
    /// is left (empty, or longer than the platform allows). Control characters
    /// a paste can carry become spaces; the ends are trimmed.
    public static func normalized(_ typed: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        for scalar in typed.unicodeScalars {
            let isControl = scalar.value <= 31 || scalar.value == 127
            cleaned.append(isControl ? " " : scalar)
        }
        let name = String(cleaned).trimmingCharacters(in: trimmed)
        guard !name.isEmpty, name.utf16.count <= maximumLength else { return nil }
        return name
    }

    /// True when a name is already at the limit, so a field can stop growing
    /// instead of silently refusing the Create button.
    public static func isAtLimit(_ typed: String) -> Bool {
        typed.utf16.count >= maximumLength
    }
}

/// Why a create did not produce a company. The first four are the platform's
/// answer and end the attempt; `unavailable` is a lost or unreadable answer,
/// which may hide a committed create, so the same request ID is replayed.
public enum CompanyCreateFailure: Equatable, Sendable {
    /// `403 company_creation_closed`: the pilot admission does not allow this person.
    case closed
    /// `400`: the name was refused.
    case invalidName
    case denied
    case conflict
    case limit
    case authentication
    case unavailable

    public init(_ error: CompanyAPIError) {
        switch error {
        case let .refused(refusal, reason, _):
            switch refusal {
            case .denied: self = reason == "company_creation_closed" ? .closed : .denied
            case .invalid: self = .invalidName
            case .conflict: self = .conflict
            case .limit: self = .limit
            case .authentication: self = .authentication
            case .missing, .unavailable: self = .unavailable
            }
        case .unavailable, .transport, .invalid:
            self = .unavailable
        }
    }

    /// Only a lost answer can hide a company that was already created.
    public var mayHaveCommitted: Bool { self == .unavailable }
}

/// Keeps one create's request ID until its outcome is known, the way
/// `CompanyLeaveTracker` keeps a leave. A retry of the same name after a lost
/// answer replays the same request, so the platform answers the same company;
/// a different name is a different request. The pending attempt is persisted
/// per account (`CompanyLocalPrefs.pendingCreate`), so a retry after the app
/// was relaunched still replays the same request.
public struct CompanyCreateTracker: Equatable, Sendable {
    public struct Attempt: Codable, Equatable, Sendable {
        public let displayName: String
        public let requestID: String

        public init(displayName: String, requestID: String) {
            self.displayName = displayName
            self.requestID = requestID
        }
    }

    public private(set) var pending: Attempt?

    public init(pending: Attempt? = nil) { self.pending = pending }

    public mutating func attempt(for name: String, makeRequestID: () -> String) -> Attempt {
        if let pending, pending.displayName == name { return pending }
        let attempt = Attempt(displayName: name, requestID: makeRequestID())
        pending = attempt
        return attempt
    }

    public mutating func succeeded() { pending = nil }

    /// The person changed the name: the old attempt is no longer the one they
    /// mean to retry.
    public mutating func abandoned() { pending = nil }

    public mutating func failed(_ failure: CompanyCreateFailure) {
        if !failure.mayHaveCommitted { pending = nil }
    }
}

/// The company authority's client. `NativeDomainClient` is the production
/// implementation; tests supply the same shapes without a network.
@MainActor
public protocol CompanyWorkspaceAPI: AnyObject, Sendable {
    func companyList() async throws -> CompanyRead<CompanyList>
    func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot>
    func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory>
    func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                 invitationID: NativeID) async throws -> CompanySnapshot
    func leaveCompany(companyID: NativeID, requestID: NativeID) async throws -> CompanyLeaveAcknowledgement
    /// Creates one company and answers its first snapshot (with the seeded
    /// default channel's ID). The platform decides who may create; a person it
    /// does not admit gets `.refused(.denied, reason: "company_creation_closed")`.
    func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot
}

/// What the foot of the company switcher offers. A person who can create sees
/// "Create company". "Creating companies is not open yet" is the empty state's
/// line only: once someone belongs to a company it is a dead end beside the
/// list, so the sheet says nothing (Create is hidden, never disabled).
public enum CompanySwitcherFooter: Equatable, Sendable {
    case create
    case closedNote
    case nothing

    public static func resolve(canCreate: Bool, companyCount: Int) -> CompanySwitcherFooter {
        if canCreate { return .create }
        return companyCount > 0 ? .nothing : .closedNote
    }
}
