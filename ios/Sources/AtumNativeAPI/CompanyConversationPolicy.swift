import Foundation

// Pure rules for the phone's "Direct messages" (wire 1.5): which answers are
// believed, how a refusal is worded, the people picker's bound, the identity of
// a retried request, the rows a person sees and how an opened conversation's
// room converges. No transport and no UI.

/// An answer is for the conversation that was asked for. Anything else is a
/// refusal, not data (the digest is already checked when the answer decodes).
public enum CompanyConversationBinding {
    /// Open and expand: the answer is for this company and for exactly the
    /// people asked for (caller included, any order); an expand answer is a
    /// different conversation from its source.
    public static func holds(_ answer: CompanyConversationAnswer, companyID: NativeID,
                             requestedRefs: [String], sourceID: NativeID? = nil) -> Bool {
        let conversation = answer.conversation
        guard conversation.companyId == companyID,
              Set(conversation.participants.map(\.memberRef)) == Set(requestedRefs),
              conversation.participants.count == requestedRefs.count else { return false }
        if let sourceID, conversation.id == sourceID { return false }
        return true
    }

    public static func holds(_ conversation: CompanyConversation, companyID: NativeID,
                             conversationID: NativeID? = nil) -> Bool {
        conversation.companyId == companyID && (conversationID.map { $0 == conversation.id } ?? true)
    }

    public static func holds(_ answer: CompanyConversationHiddenAnswer, conversationID: NativeID,
                             hidden: Bool) -> Bool {
        answer.conversationId == conversationID && answer.hidden == hidden
    }
}

// MARK: Picker

/// The people picker: one other person is a DM, several a group, at most eight
/// others (nine in all). Only active company members are offered, never the
/// caller, and an expansion keeps the people already in the conversation.
public enum ConversationPeople {
    public static let maximumOthers = 8
    public static let maximumParticipants = CompanyConversation.maximumParticipants

    /// Members that can be picked, in the roster's order. The caller's own
    /// ref must be known: without it nothing is offered, because the request
    /// has to include the caller and the picker cannot tell who that is.
    public static func candidates(members: [CompanyMember], selfRef: String?,
                                  excluding kept: Set<String> = []) -> [CompanyMember] {
        guard let selfRef else { return [] }
        return members.filter { $0.state == .active && $0.memberRef != selfRef && !kept.contains($0.memberRef) }
    }

    /// Whether another person can still be added to a selection of `count`
    /// others (people already kept in an expansion count as selected).
    public static func canAddAnother(selectedOthers count: Int) -> Bool { count < maximumOthers }

    /// Start needs at least one other person; an expansion needs at least one
    /// new person on top of the kept ones.
    public static func canStart(selectedOthers: Int, keptOthers: Int = 0) -> Bool {
        guard selectedOthers >= 1 else { return false }
        return selectedOthers + keptOthers <= maximumOthers
    }

    /// `participantMemberRefs` for a request: the caller, then the picked
    /// people. Nil when the set breaks the contract (2…9, no duplicates, the
    /// caller in it, every ref well formed). Order is irrelevant to the
    /// platform; the refs are sorted so a retry sends the same bytes.
    public static func refs(selfRef: String, others: [String]) -> [String]? {
        let all = [selfRef] + others
        guard isWellFormed(all) else { return nil }
        return all.sorted { CompanyConversationDigest.precedes($0, $1) }
    }

    /// 2…9 refs, no duplicates, each an opaque member ref (never a handle, an
    /// address or a Matrix id).
    public static func isWellFormed(_ refs: [String]) -> Bool {
        (2...maximumParticipants).contains(refs.count)
            && Set(refs).count == refs.count
            && refs.allSatisfy { (try? CompanyMemberRef.checked($0)) != nil }
    }
}

// MARK: Refusals

/// What a refused or lost 1.5 call means to the person. The typed reasons are
/// a closed list per status; a reason from another family, at another status,
/// is not understood and the plain status stands.
public enum ConversationRefusal: Equatable, Sendable {
    case conversationUnavailable
    case participantUnavailable
    case participantLimit
    case participantSetConflict
    case admissionEpochConflict
    case readOnly
    /// The plain status, with no usable reason.
    case plain(CompanyRefusal)
    /// The answer never arrived or was not understood. A committed open may
    /// hide behind it, so the same request is offered again.
    case lost

    public init(_ error: CompanyAPIError) {
        switch error {
        case let .refused(refusal, reason, _):
            switch (refusal, reason) {
            case (.missing, "conversation_unavailable"?): self = .conversationUnavailable
            case (.missing, "participant_unavailable"?): self = .participantUnavailable
            case (.conflict, "participant_limit"?): self = .participantLimit
            case (.conflict, "participant_set_conflict"?): self = .participantSetConflict
            case (.conflict, "admission_epoch_conflict"?): self = .admissionEpochConflict
            case (.conflict, "conversation_read_only"?): self = .readOnly
            default: self = .plain(refusal)
            }
        case .unavailable, .transport, .invalid:
            self = .lost
        }
    }

    /// Only a lost answer can hide a conversation that was already made.
    public var mayHaveCommitted: Bool { self == .lost }
}

// MARK: Request identity

/// Keeps one request id per user action until its outcome is known, the way
/// `CompanyCreateTracker` keeps a create's: a Retry after a lost answer sends
/// the same id, so the platform answers the same receipt; choosing the same
/// people again after the action finished is a new action with a new id.
public struct ConversationRequestTracker: Equatable, Sendable {
    /// Every operation is scoped to its company: the same people, or the same conversation id, in
    /// two companies are two actions with two request ids.
    public enum Operation: Hashable, Sendable {
        case open(company: String, refs: [String])
        case expand(company: String, source: String, refs: [String])
        case hidden(company: String, conversation: String, hidden: Bool)

        public var company: String {
            switch self {
            case let .open(company, _), let .expand(company, _, _), let .hidden(company, _, _): company
            }
        }

        /// The same people in any order are one operation.
        public static func open(company: String, people: [String]) -> Operation {
            .open(company: company, refs: people.sorted { CompanyConversationDigest.precedes($0, $1) })
        }

        public static func expand(company: String, source: String, people: [String]) -> Operation {
            .expand(company: company, source: source,
                    refs: people.sorted { CompanyConversationDigest.precedes($0, $1) })
        }
    }

    public private(set) var pending = [Operation: String]()

    public init() {}

    /// The request id for this operation: the pending one if the last try was
    /// lost, else a new one (kept until `succeeded` or a terminal `failed`).
    public mutating func requestID(for operation: Operation, make: () -> String) -> String {
        if let existing = pending[operation] { return existing }
        let id = make()
        pending[operation] = id
        return id
    }

    public mutating func succeeded(_ operation: Operation) { pending[operation] = nil }

    public mutating func failed(_ operation: Operation, _ refusal: ConversationRefusal) {
        if !refusal.mayHaveCommitted { pending[operation] = nil }
    }

    /// A company's unresolved ids end with its authority (denied, left, removed).
    public mutating func clear(company: String) {
        for operation in pending.keys where operation.company == company { pending[operation] = nil }
    }

    /// The account scope ended.
    public mutating func clear() { pending.removeAll() }
}

// MARK: Rows

public enum ConversationRowState: Equatable, Sendable {
    case ready
    /// Being set up: not tappable.
    case settingUp
    /// Terminal: readable, no composer, no Add people.
    case readOnly
}

public struct ConversationRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: CompanyConversationKind
    public let title: String
    public let participantCount: Int
    public let state: ConversationRowState
    public let roomID: String?
    public let isHidden: Bool

    public init(id: String, kind: CompanyConversationKind, title: String, participantCount: Int,
                state: ConversationRowState, roomID: String?, isHidden: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.participantCount = participantCount
        self.state = state
        self.roomID = roomID
        self.isHidden = isHidden
    }

    public var canOpen: Bool { state != .settingUp && roomID != nil }
    public var isReadOnly: Bool { state == .readOnly }
}

public enum ConversationRows {
    /// "Bảo, Lan Nguyễn": the other people, each as display name, else
    /// "@handle", else a neutral word. If the caller is not known every
    /// participant is named rather than guessing who to leave out.
    public static func title(of conversation: CompanyConversation, selfRef: String?,
                             fallbackName: String) -> String {
        let others = conversation.participants.filter { $0.memberRef != selfRef }
        let named = (others.isEmpty ? conversation.participants : others).map { person in
            person.displayName ?? person.handle.map { "@" + $0 } ?? fallbackName
        }
        return named.joined(separator: ", ")
    }

    public static func state(of conversation: CompanyConversation) -> ConversationRowState {
        switch conversation.state {
        case .readOnly:
            return .readOnly
        case .provisioning:
            return .settingUp
        case .active:
            return conversation.room.state == "ready" && conversation.room.roomId != nil ? .ready : .settingUp
        }
    }

    /// Newest room activity first, then by title (locale-aware); a row with no
    /// known activity sorts after those with some.
    public static func rows(_ directory: CompanyConversationDirectory, selfRef: String?,
                            fallbackName: String, activity: [String: Date] = [:],
                            locale: Locale) -> [ConversationRow] {
        let rows = directory.conversations.map { conversation in
            ConversationRow(id: conversation.id.rawValue, kind: conversation.kind,
                            title: title(of: conversation, selfRef: selfRef, fallbackName: fallbackName),
                            participantCount: conversation.participants.count,
                            state: state(of: conversation), roomID: conversation.room.roomId,
                            isHidden: conversation.hidden)
        }
        return rows.sorted { left, right in
            let leftDate = left.roomID.flatMap { activity[$0] }
            let rightDate = right.roomID.flatMap { activity[$0] }
            if leftDate != rightDate {
                guard let leftDate else { return false }
                guard let rightDate else { return true }
                return leftDate > rightDate
            }
            let order = left.title.compare(right.title, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: nil, locale: locale)
            if order != .orderedSame { return order == .orderedAscending }
            return left.id < right.id
        }
    }
}

// MARK: Room claims

/// A conversation room, believed only because the platform's conversation
/// directory lists that conversation with that room id.
public struct ConversationRoomClaim: Equatable, Sendable {
    public let companyID: String
    public let conversationID: String
    public let kind: CompanyConversationKind
    public let state: CompanyConversationState
    public let roomID: String
    public let title: String

    public init(companyID: String, conversationID: String, kind: CompanyConversationKind,
                state: CompanyConversationState, roomID: String, title: String) {
        self.companyID = companyID
        self.conversationID = conversationID
        self.kind = kind
        self.state = state
        self.roomID = roomID
        self.title = title
    }
}

/// The directory's room ids, per company. A listed conversation whose room is
/// not ready yet has no claim; a claim ends with its company or the family.
public struct ConversationRoomDirectory: Equatable, Sendable {
    private var claimsByRoom = [String: ConversationRoomClaim]()
    private var roomsByCompany = [String: Set<String>]()

    public init() {}

    public var isEmpty: Bool { claimsByRoom.isEmpty }
    public var companyIDs: Set<String> { Set(roomsByCompany.keys) }

    /// Replaces a company's claims with its current directory. A conversation
    /// the directory no longer lists loses its claim (unlike channels, a
    /// conversation is the person's own list: the platform answer is the whole
    /// truth, and it never lists a room the person may not read).
    public mutating func replace(_ directory: CompanyConversationDirectory, companyID: String,
                                 selfRef: String?, fallbackName: String) {
        remove(companyID: companyID)
        var rooms = Set<String>()
        for conversation in directory.conversations {
            guard let roomID = conversation.room.roomId, conversation.room.state == "ready" else { continue }
            claimsByRoom[roomID] = ConversationRoomClaim(
                companyID: companyID, conversationID: conversation.id.rawValue,
                kind: conversation.kind, state: conversation.state, roomID: roomID,
                title: ConversationRows.title(of: conversation, selfRef: selfRef, fallbackName: fallbackName))
            rooms.insert(roomID)
        }
        roomsByCompany[companyID] = rooms
    }

    public mutating func remove(companyID: String) {
        for roomID in roomsByCompany.removeValue(forKey: companyID) ?? [] {
            claimsByRoom.removeValue(forKey: roomID)
        }
    }

    public mutating func retain(companies: Set<String>) {
        for company in Array(roomsByCompany.keys) where !companies.contains(company) { remove(companyID: company) }
    }

    public mutating func clear() {
        claimsByRoom.removeAll()
        roomsByCompany.removeAll()
    }

    public func claim(roomID: String) -> ConversationRoomClaim? { claimsByRoom[roomID] }
    public func roomIDs(companyID: String) -> Set<String> { roomsByCompany[companyID] ?? [] }
}

/// The create-event `type` a company conversation room is made with. The
/// binding in the room is a display hint (anyone can write those keys into a
/// room): a room that claims the type and is not listed shows nowhere.
public enum ConversationRoomType {
    public static let value = "io.atum.company_conversation.v1"

    public static func isClaimed(_ roomType: String?) -> Bool { roomType == value }
}

/// The one rule in front of everything that could treat a conversation-type room as something else:
/// the bot and agent choosers, the generic invite handling and every join. A room that claims the
/// type is a company conversation or nothing; only the directory-confirmed conversation
/// convergence may join one.
public enum ConversationTypeGuard {
    /// The bot and agent selection, and the automatic invite acceptance, never see such a room.
    public static func excludedFromBotAndAgent(roomType: String?) -> Bool {
        ConversationRoomType.isClaimed(roomType)
    }

    public static func mayJoin(roomType: String?, directoryConfirmed: Bool) -> Bool {
        !ConversationRoomType.isClaimed(roomType) || directoryConfirmed
    }
}

/// What the open chat may be. A chat that was a conversation, or a room that claims the type, never
/// becomes an ordinary chat with an ordinary composer: without current authority it is `closed`.
public enum ConversationChatGate {
    public enum State: Equatable, Sendable {
        /// Not a conversation at all.
        case ordinary
        /// A conversation with a current directory record: composer and menu available.
        case active
        /// Shown if it can be, composer and every write closed.
        case closed
    }

    public static func state(wasConversation: Bool, hasAuthority: Bool, isFresh: Bool,
                             claimsType: Bool) -> State {
        guard wasConversation || claimsType || hasAuthority else { return .ordinary }
        return hasAuthority && isFresh ? .active : .closed
    }
}

// MARK: Convergence

/// Open → the conversation's room ready → invitation synced → join → select,
/// bounded like a company channel's convergence, with no substitute room.
public enum ConversationConvergence {
    public enum Step: Equatable, Sendable {
        case wait
        case join(roomID: String)
        case open(roomID: String)
        case giveUp
    }

    public static func step(attempt: Int, conversation: CompanyConversation?,
                            presence: CompanyRoomPresence) -> Step {
        guard attempt >= 0, attempt < CompanyConvergence.attempts else { return .giveUp }
        guard let conversation, conversation.room.state == "ready",
              conversation.state != .provisioning, conversation.room.roomId != nil else { return .wait }
        let roomID = conversation.room.roomId!
        switch presence {
        case .joined: return .open(roomID: roomID)
        case .invited: return .join(roomID: roomID)
        case .absent, .unknown: return .wait
        }
    }
}

// MARK: Client

/// The company authority's 1.3 discovery and 1.5 conversation calls.
/// `NativeDomainClient` is the production implementation; tests supply the same
/// shapes without a network.
@MainActor
public protocol CompanyConversationsAPI: AnyObject, Sendable {
    func companyCapabilities() async throws -> CompanyCapabilities
    func companyConversations(companyID: NativeID) async throws -> CompanyConversationDirectory
    func openCompanyConversation(companyID: NativeID, requestID: NativeID,
                                 participantMemberRefs: [String]) async throws -> CompanyConversationAnswer
    func expandCompanyConversation(companyID: NativeID, sourceConversationID: NativeID, requestID: NativeID,
                                   participantMemberRefs: [String]) async throws -> CompanyConversationAnswer
    func setCompanyConversationHidden(companyID: NativeID, conversationID: NativeID, requestID: NativeID,
                                      hidden: Bool) async throws -> CompanyConversationHiddenAnswer
}
