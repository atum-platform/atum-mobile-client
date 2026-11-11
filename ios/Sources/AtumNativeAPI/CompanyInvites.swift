import Foundation

// Wave 3 TS-11: inviting people to a company and joining one with a link.
// Desktop references (atum-desktop `c14d74a1`, `apps/desktop/`):
// `src/matrix/team-space/invite-sheet.tsx`, `invite-links.tsx`, `invite-join.ts`,
// `invite-join-dialog.tsx`, `abilities.ts`, `shared/matrix-invite-link.ts`,
// `electron/matrix/company.ts` (the 1.1 `invite` route) and
// `electron/matrix/company-team-space.ts` (1.2 links, 1.3 invitations). Protocol:
// `atum-platform/packages/protocol/src/company-workspace.ts`.
//
// Everything here is a display-safe value, a request body or a refusal: no
// transport and no persistence. An invite link's token is a bearer secret: it
// is never part of a description, an error or a log line, and the phone holds
// it in memory only (`CompanyInviteLinkToken`).

// MARK: Who may invite (desktop `abilities.ts` `teamSpaceProfile`, `companyAbilities`)

/// The server's team-space profile, from the 1.3 capability answer. Nil
/// capabilities (an older server, a failed read) are the desktop's `legacy`
/// profile: nothing here turns a missing answer into a permission.
public struct CompanyTeamSpaceProfile: Equatable, Sendable {
    /// C1: single owner, roles, invitation attempts, links (wire 1.3 + 1.2).
    public var admin: Bool
    /// C2: public and private channels, browse, admission (wire 1.4).
    public var channels: Bool
    /// The hosted room controller is ready, so a new admission can become a room.
    public var rooms: Bool

    public init(admin: Bool = false, channels: Bool = false, rooms: Bool = false) {
        self.admin = admin
        self.channels = channels
        self.rooms = rooms
    }

    public static let legacy = CompanyTeamSpaceProfile()

    public static func resolve(_ capabilities: CompanyCapabilities?) -> CompanyTeamSpaceProfile {
        guard let capabilities else { return .legacy }
        let speaks = { (wire: String) in capabilities.supportedWireVersions.contains(wire) }
        return CompanyTeamSpaceProfile(
            admin: speaks("1.3") && capabilities.teamAdminActive,
            channels: speaks("1.4") && capabilities.channelAdmissionFeature && capabilities.channelAdmissionActive,
            rooms: capabilities.roomReconciliationReady)
    }
}

/// How an Add is sent. `legacy`: the 1.1 one-press invitation by handle (role
/// member). `admin`: C1's durable invitation by handle (wire 1.3).
public enum CompanyInviteMethod: Equatable, Sendable {
    case legacy
    case admin
}

/// What the invite sheet may do in one company (desktop `companyAbilities`).
/// The phone knows the 1.1 roles only (admin, member). The owner of a C1
/// company is an admin there, so inviting someone as an admin, which is the
/// owner's alone, is never offered: every invitation is as a member.
public struct CompanyInviteAbilities: Equatable, Sendable {
    public var invite: Bool
    public var method: CompanyInviteMethod
    /// Making a share link (C1 only, and the server's link configuration is ready).
    public var inviteLink: Bool
    /// Revoking a link stays with owners and admins.
    public var revokeInviteLink: Bool

    public init(invite: Bool = false, method: CompanyInviteMethod = .legacy, inviteLink: Bool = false,
                revokeInviteLink: Bool = false) {
        self.invite = invite
        self.method = method
        self.inviteLink = inviteLink
        self.revokeInviteLink = revokeInviteLink
    }

    public static let none = CompanyInviteAbilities()

    /// - Parameters:
    ///   - viewerIsAdmin: the snapshot's own row is an admin. Members inviting
    ///     (company policy 1.2 `members`) needs the team-admin read the phone does
    ///     not have yet, so a member is never offered the sheet.
    ///   - readiness: invite readiness profile 1, nil when it was not read.
    public static func resolve(profile: CompanyTeamSpaceProfile, viewerIsAdmin: Bool?,
                               readiness: CompanyInviteReadiness?) -> CompanyInviteAbilities {
        guard viewerIsAdmin == true else { return .none }
        let admin = profile.admin
        let link = readiness.map { admin && $0.inviteLink == .ready } ?? admin
        return CompanyInviteAbilities(invite: true, method: admin ? .admin : .legacy,
                                      inviteLink: link, revokeInviteLink: admin)
    }
}

/// `GET /company-capabilities` with `Atum-Company-Invites: 1` (wire 1.3): which
/// invitation methods this install has ready. Closed; only `inviteLink` is used.
public struct CompanyInviteReadiness: Decodable, Equatable, Sendable {
    public enum LinkState: String, Decodable, Sendable { case ready, inactive, notConfigured = "not_configured" }

    public static let profileHeader = "Atum-Company-Invites"
    public static let profile = "1"

    public let directoryInvite: String
    public let inviteLink: LinkState

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "directoryInvite", "emailInvite", "emailCreation", "emailDelivery",
                      "inviteLink", "emailAutoClaim"])
        guard try c.integer("schemaVersion", minimum: 1) == 1 else { throw ContractViolation.invalidValue }
        directoryInvite = try c.string("directoryInvite", minimum: 1, maximum: 16)
        guard ["ready", "inactive"].contains(directoryInvite) else { throw ContractViolation.invalidValue }
        guard ["delivery_unavailable", "inactive", "not_configured"].contains(try c.value("emailInvite", as: String.self)),
              ["ready", "inactive", "not_configured"].contains(try c.value("emailCreation", as: String.self)),
              try c.value("emailDelivery", as: String.self) == "not_implemented",
              ["active", "verification_required"].contains(try c.value("emailAutoClaim", as: String.self))
        else { throw ContractViolation.invalidValue }
        inviteLink = try c.value("inviteLink")
    }
}

// MARK: The typed person (desktop `inviteHandleOf`, `inviteStanding`)

public enum CompanyInviteQuery {
    /// The handle a query names exactly, lowercased without its @, or nil.
    public static func handle(_ query: String) -> String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^@?[A-Za-z][A-Za-z0-9_]{2,31}$", options: .regularExpression) != nil else {
            return nil
        }
        return String(value.drop(while: { $0 == "@" })).lowercased()
    }

    /// A complete email address (the desktop's email row needs wire 1.9, which
    /// the phone does not send: such a query says email invitations are off).
    public static func isEmail(_ query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count <= 254
            && value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }
}

/// Where one person already stands with this company, by the handles the
/// snapshot knows.
public enum CompanyInviteStanding: Equatable, Sendable {
    case member
    case invited
    case none

    public static func resolve(handle: String?, members: [CompanyMember]) -> CompanyInviteStanding {
        guard let handle else { return .none }
        if members.contains(where: { $0.state == .active && $0.handle == handle }) { return .member }
        if members.contains(where: { $0.state == .invited && $0.handle == handle }) { return .invited }
        return .none
    }
}

/// What became of one Add, for its row and the sheet's one status line.
public enum CompanyInviteOutcome: Equatable, Sendable {
    case invited
    /// The platform refused. `reason` is its typed reason, when it named one.
    case refused(CompanyRefusal, reason: String?)
    /// Transport or an unreadable answer: the same press may be tried again.
    case unavailable
}

/// `POST /companies/{id}/invite` (wire 1.1): one invitation by handle. Its
/// answer is the company's snapshot.
public struct CompanyLegacyInviteRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let memberHandle: String
    public let role: String

    public init(requestId: NativeID, memberHandle: String) {
        self.requestId = requestId
        self.memberHandle = memberHandle
        role = "member"
    }
}

/// `POST /companies/{id}/invitations` (wire 1.3): C1's seven-day invitation.
public struct CompanyInvitationCreateRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let memberHandle: String
    public let role: String

    public init(requestId: NativeID, memberHandle: String) {
        self.requestId = requestId
        self.memberHandle = memberHandle
        role = "member"
    }
}

/// The 1.3 create answer. Only what the sheet needs is kept; the shape is closed.
public struct CompanyInvitationCreateAnswer: Decodable, Equatable, Sendable {
    public let invitationId: NativeID
    public let companyId: NativeID
    public let targetHandle: String
    public let replayed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "invitation", "authorityGeneration", "replayed"])
        guard try c.integer("schemaVersion", minimum: 1) == 4 else { throw ContractViolation.invalidValue }
        _ = try c.integer("authorityGeneration", minimum: 1)
        replayed = try c.value("replayed")
        let invitation = try c.nestedContainer(keyedBy: Field.self, forKey: Field("invitation"))
        try invitation.closed(["id", "companyId", "targetHandle", "role", "state", "createdAt", "expiresAt",
                               "inviter", "supersededByInvitationId"])
        invitationId = try invitation.value("id")
        companyId = try invitation.value("companyId")
        targetHandle = try CompanyHandle.checked(try invitation.value("targetHandle", as: String.self))
        guard ["admin", "member"].contains(try invitation.value("role", as: String.self)),
              ["pending", "accepted", "declined", "cancelled", "expired", "superseded"]
                .contains(try invitation.value("state", as: String.self)),
              try invitation.integer("createdAt") < invitation.integer("expiresAt")
        else { throw ContractViolation.invalidValue }
        _ = try invitation.value("inviter", as: CompanyInviter.self)
    }
}

// MARK: Invite links (wire 1.2, schema 3)

/// A pasted invite link's bearer token. Its description never shows the token,
/// so it cannot reach a log line through string interpolation.
public struct CompanyInviteLinkToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    public static let maximumPasteCharacters = 4096
    static let pattern = "^[A-Za-z0-9_-]{43,128}$"

    public init?(token: String) {
        guard token.range(of: Self.pattern, options: .regularExpression) != nil else { return nil }
        rawValue = token
    }

    /// The token of a pasted HTTPS invite link: `https://<host>/j#<token>` (the
    /// form new links use) or `https://<host>/j/<token>` (older links). The host is
    /// not pinned, as on the desktop: old, staging and owned origins share `/j`.
    /// No credentials, port or query; nothing else survives.
    public static func parse(paste value: String) -> CompanyInviteLinkToken? {
        guard !value.isEmpty, value.count <= maximumPasteCharacters,
              let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil
        else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let fragment = components.fragment {
            guard parts == ["j"] else { return nil }
            return CompanyInviteLinkToken(token: fragment)
        }
        guard parts.count == 2, parts[0] == "j" else { return nil }
        return CompanyInviteLinkToken(token: parts[1])
    }

    public var description: String { "CompanyInviteLinkToken(redacted)" }
    public var debugDescription: String { description }
}

public enum CompanyInviteLinkState: String, Decodable, Equatable, Sendable {
    case active, exhausted, expired, revoked
}

/// One link's metadata: never its token.
public struct CompanyInviteLinkSummary: Decodable, Equatable, Sendable, Identifiable {
    public let id: NativeID
    public let state: CompanyInviteLinkState
    public let createdAt: Int64
    public let expiresAt: Int64
    public let maxUses: Int
    public let uses: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "role", "state", "createdAt", "expiresAt", "maxUses", "uses"])
        (id, state, createdAt, expiresAt, maxUses, uses) = try Self.fields(c)
    }

    static func fields(_ c: KeyedDecodingContainer<Field>) throws
        -> (NativeID, CompanyInviteLinkState, Int64, Int64, Int, Int) {
        let id: NativeID = try c.value("id")
        guard try c.value("role", as: String.self) == "member" else { throw ContractViolation.invalidValue }
        let state: CompanyInviteLinkState = try c.value("state")
        let createdAt = try c.integer("createdAt")
        let expiresAt = try c.integer("expiresAt")
        let maxUses = try c.integer("maxUses", minimum: 1)
        let uses = try c.integer("uses")
        guard maxUses <= 100, uses <= maxUses, createdAt <= expiresAt else { throw ContractViolation.invariant }
        return (id, state, createdAt, expiresAt, Int(maxUses), Int(uses))
    }
}

/// The first create answer, the only shape that carries the link itself.
public struct CompanyInviteLinkSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let summary: CompanyInviteLinkSummary
    public let companyId: NativeID
    /// The link to copy, verbatim. Never logged.
    public let url: String

    static let urlPattern = "^https://[a-z0-9][a-z0-9.-]{0,252}/j(?:/|#)[A-Za-z0-9_-]{43,128}$"

    public var description: String { "CompanyInviteLinkSecret(\(summary.id.rawValue), redacted)" }
    public var debugDescription: String { description }
}

/// `POST /companies/{id}/invite-links`: a new link (its text, shown once) or a
/// replay (metadata only; the server keeps a hash, never the token).
public enum CompanyInviteLinkCreated: Equatable, Sendable {
    case created(CompanyInviteLinkSecret)
    case replayed(CompanyInviteLinkSummary)
}

public struct CompanyInviteLinkCreateRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let role: String

    public init(requestId: NativeID) {
        self.requestId = requestId
        role = "member"
    }
}

public struct CompanyInviteLinkRevokeRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public init(requestId: NativeID) { self.requestId = requestId }
}

public struct CompanyInviteLinkPreviewRequest: Encodable, Equatable, Sendable {
    let token: String
    public init(token: CompanyInviteLinkToken) { self.token = token.rawValue }
}

public struct CompanyInviteLinkRedeemRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    let token: String
    public init(requestId: NativeID, token: CompanyInviteLinkToken) {
        self.requestId = requestId
        self.token = token.rawValue
    }
}

/// `POST /invite-links/preview`: what the link is for, before joining. No effect.
public struct CompanyInviteLinkPreview: Decodable, Equatable, Sendable {
    public let companyId: NativeID
    public let companyName: String
    public let inviter: CompanyInviter
    public let expiresAt: Int64
    public let maxUses: Int
    public let usesRemaining: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "company", "role", "inviter", "expiresAt", "maxUses", "usesRemaining"])
        guard try c.integer("schemaVersion", minimum: 1) == 3,
              try c.value("role", as: String.self) == "member" else { throw ContractViolation.invalidValue }
        let company = try c.nestedContainer(keyedBy: Field.self, forKey: Field("company"))
        try company.closed(["id", "displayName"])
        companyId = try company.value("id")
        companyName = try company.string("displayName", minimum: 1, maximum: 120)
        inviter = try c.value("inviter")
        expiresAt = try c.integer("expiresAt")
        let maxUses = try c.integer("maxUses", minimum: 1)
        let remaining = try c.integer("usesRemaining")
        guard maxUses <= 100, remaining <= maxUses else { throw ContractViolation.invariant }
        self.maxUses = Int(maxUses)
        usesRemaining = Int(remaining)
    }

    /// The inviter's name, else their @handle (desktop `invite-join-dialog.tsx`).
    public var inviterLabel: String? {
        inviter.displayName ?? inviter.handle.map { "@" + $0 }
    }
}

/// `POST /invite-links/redeem`: the person is now an active member.
public struct CompanyInviteLinkRedeemed: Decodable, Equatable, Sendable {
    public let companyId: NativeID
    public let consumedNow: Bool
    public let replayed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["schemaVersion", "companyId", "memberRef", "role", "state", "link"])
        guard try c.integer("schemaVersion", minimum: 1) == 3,
              try c.value("role", as: String.self) == "member",
              try c.value("state", as: String.self) == "active" else { throw ContractViolation.invalidValue }
        companyId = try c.value("companyId")
        _ = try CompanyMemberRef.checked(try c.value("memberRef", as: String.self))
        let link = try c.nestedContainer(keyedBy: Field.self, forKey: Field("link"))
        try link.closed(["id", "maxUses", "usesRemaining", "consumedNow", "replayed"])
        _ = try link.value("id", as: NativeID.self)
        let maxUses = try link.integer("maxUses", minimum: 1)
        let remaining = try link.integer("usesRemaining")
        consumedNow = try link.value("consumedNow")
        replayed = try link.value("replayed")
        guard maxUses <= 100, remaining <= maxUses, !(replayed && consumedNow) else {
            throw ContractViolation.invariant
        }
    }
}

public enum CompanyInviteWire {
    public static func decodeLinkCreated(_ data: Data) throws -> CompanyInviteLinkCreated {
        let root = try object(data)
        guard root["schemaVersion"] as? Int == 3, let replayed = root["replayed"] as? Bool,
              let link = root["link"] as? [String: Any],
              Set(root.keys) == ["schemaVersion", "replayed", "link"] else { throw ContractViolation.invalidValue }
        if replayed {
            let linkData = try JSONSerialization.data(withJSONObject: link)
            return .replayed(try NativeAPI.decode(CompanyInviteLinkSummary.self, from: linkData))
        }
        guard let url = link["url"] as? String,
              url.range(of: CompanyInviteLinkSecret.urlPattern, options: .regularExpression) != nil,
              Set(link.keys) == ["id", "companyId", "role", "state", "createdAt", "expiresAt", "maxUses", "uses", "url"],
              let companyRaw = link["companyId"] as? String, let companyID = try? NativeID(companyRaw)
        else { throw ContractViolation.invalidValue }
        var summary = link
        summary.removeValue(forKey: "url")
        summary.removeValue(forKey: "companyId")
        let summaryData = try JSONSerialization.data(withJSONObject: summary)
        return .created(CompanyInviteLinkSecret(
            summary: try NativeAPI.decode(CompanyInviteLinkSummary.self, from: summaryData),
            companyId: companyID, url: url))
    }

    public static func decodeLinkList(_ data: Data) throws -> [CompanyInviteLinkSummary] {
        let list = try NativeAPI.decode(LinkList.self, from: data)
        guard Set(list.links.map(\.id)).count == list.links.count else { throw ContractViolation.invariant }
        return list.links
    }

    public static func decodeRevoked(_ data: Data, linkID: NativeID) throws {
        let ack = try NativeAPI.decode(Revoked.self, from: data)
        guard ack.linkId == linkID else { throw ContractViolation.invariant }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= CompanyWorkspaceWire.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractViolation.invalidValue
        }
        return root
    }

    private struct LinkList: Decodable {
        let links: [CompanyInviteLinkSummary]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["schemaVersion", "links"])
            guard try c.integer("schemaVersion", minimum: 1) == 3 else { throw ContractViolation.invalidValue }
            links = try c.value("links")
            guard links.count <= 100 else { throw ContractViolation.invalidValue }
        }
    }

    private struct Revoked: Decodable {
        let linkId: NativeID
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["schemaVersion", "linkId", "state", "revokedAt", "replayed"])
            guard try c.integer("schemaVersion", minimum: 1) == 3,
                  try c.value("state", as: String.self) == "revoked" else { throw ContractViolation.invalidValue }
            linkId = try c.value("linkId")
            _ = try c.integer("revokedAt")
            _ = try c.value("replayed", as: Bool.self)
        }
    }
}

/// Whole days until `expiresAt`, at least 0 (desktop `invitationDaysLeft`).
public enum CompanyInviteDays {
    public static func left(expiresAt: Int64, now: Int64) -> Int {
        guard expiresAt > now else { return 0 }
        return Int((expiresAt - now + 86_399) / 86_400)
    }
}

// MARK: Join with an invite link (desktop `invite-join.ts` `inviteJoinReducer`)

public enum CompanyInviteJoinFailure: Equatable, Sendable {
    case invalid, expired, revoked, exhausted, unavailable
}

public enum CompanyInviteJoinCompletion: Equatable, Sendable {
    case joined, alreadyMember, replayed
}

/// One join flow: paste, preview, join. The token lives only in the flow's
/// memory and is dropped with it.
public enum CompanyInviteJoinState: Equatable, Sendable {
    case paste
    case previewing
    case preview(CompanyInviteLinkPreview)
    case redeeming(CompanyInviteLinkPreview)
    case complete(CompanyInviteLinkPreview, CompanyInviteJoinCompletion, companyID: String)
    case failure(CompanyInviteJoinFailure, preview: CompanyInviteLinkPreview?)

    public var previewValue: CompanyInviteLinkPreview? {
        switch self {
        case .paste, .previewing: nil
        case let .preview(value), let .redeeming(value), let .complete(value, _, _): value
        case let .failure(_, preview): preview
        }
    }
}

public enum CompanyInviteJoin {
    /// The preview answered: an expired or used-up link says so before Join.
    public static func previewed(_ preview: CompanyInviteLinkPreview, now: Int64) -> CompanyInviteJoinState {
        if preview.expiresAt <= now { return .failure(.expired, preview: preview) }
        if preview.usesRemaining == 0 { return .failure(.exhausted, preview: preview) }
        return .preview(preview)
    }

    /// A refused preview: an unknown or withdrawn link is "not valid"; anything
    /// else is "could not be checked" (the same words for every reason, so a link
    /// never tells a stranger which it was).
    public static func previewFailed(_ error: Error) -> CompanyInviteJoinState {
        .failure(isUnavailableLink(error) ? .invalid : .unavailable, preview: nil)
    }

    public static func redeemed(_ value: CompanyInviteLinkRedeemed,
                                preview: CompanyInviteLinkPreview) -> CompanyInviteJoinState {
        let completion: CompanyInviteJoinCompletion = value.replayed ? .replayed
            : value.consumedNow ? .joined : .alreadyMember
        return .complete(preview, completion, companyID: value.companyId.rawValue)
    }

    public static func redeemFailed(_ error: Error, preview: CompanyInviteLinkPreview,
                                    now: Int64) -> CompanyInviteJoinState {
        let failure: CompanyInviteJoinFailure = preview.expiresAt <= now ? .expired
            : preview.usesRemaining == 0 ? .exhausted
            : isUnavailableLink(error) ? .revoked : .unavailable
        return .failure(failure, preview: preview)
    }

    static func isUnavailableLink(_ error: Error) -> Bool {
        guard case let .refused(refusal, reason, _) = error as? CompanyAPIError else { return false }
        return refusal == .missing || reason == "invite_link_unavailable"
    }
}

// MARK: Channels (TS-13)

/// `POST /companies/{id}/channels` (wire 1.1, the desktop's flat-mode create):
/// one company-wide channel. The answer is the channel's snapshot.
public struct CompanyChannelCreateRequest: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let displayName: String

    public init(requestId: NativeID, displayName: String) {
        self.requestId = requestId
        self.displayName = displayName
    }
}

/// The platform's channel name (1…80 characters, trimmed, printable).
public enum CompanyChannelName {
    public static let maximumLength = 80

    public enum Problem: Equatable, Sendable { case required, tooLong }

    public static func normalized(_ typed: String) -> String? {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= maximumLength,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    public static func problem(_ typed: String) -> Problem? {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .required }
        if value.unicodeScalars.count > maximumLength { return .tooLong }
        return nil
    }
}

/// Who may create a channel (desktop `companyAbilities.createChannel`): before
/// C2, admins; with C2 the company's policy decides, which needs the team-admin
/// read the phone does not have, so it stays admins once the room controller
/// is ready.
public enum CompanyChannelCreation {
    public static func allowed(profile: CompanyTeamSpaceProfile, viewerIsAdmin: Bool?) -> Bool {
        guard viewerIsAdmin == true else { return false }
        return !profile.channels || profile.rooms
    }
}

/// The channel list's sections (desktop `channel-sections.tsx`): Favorites (the
/// person's own Matrix `m.favourite` tags), Channels, and Archived (collapsed).
/// Pending channel invitations need the C2 admitted directory.
public struct CompanyChannelSectionPlan<Row: Equatable>: Equatable {
    public var favorites: [Row]
    public var channels: [Row]
    public var archived: [Row]

    /// `sectioned` is the desktop's C2 channels mode (the directory read on
    /// 1.4 with channel admission on). Before it the desktop draws one flat
    /// Channels list with archived channels inline, so the phone does too.
    public static func split(_ rows: [Row], isFavourite: (Row) -> Bool, isArchived: (Row) -> Bool,
                             matches: (Row) -> Bool, sectioned: Bool = true) -> CompanyChannelSectionPlan<Row> {
        guard sectioned else {
            return CompanyChannelSectionPlan(favorites: [], channels: rows.filter(matches), archived: [])
        }
        let archived = rows.filter(isArchived)
        let live = rows.filter { !isArchived($0) && matches($0) }
        return CompanyChannelSectionPlan(favorites: live.filter(isFavourite),
                                         channels: live.filter { !isFavourite($0) },
                                         archived: archived.filter(matches))
    }
}

// MARK: Transport seam

/// The invite, link and channel-create calls, on the same account client as
/// the company reads. Every call names its company; none carries a principal.
public protocol CompanyInvitesAPI: AnyObject, Sendable {
    func companyInviteReadiness() async throws -> CompanyInviteReadiness
    func inviteToCompany(companyID: NativeID, requestID: NativeID, handle: String,
                         method: CompanyInviteMethod) async throws
    func companyInviteLinks(companyID: NativeID) async throws -> [CompanyInviteLinkSummary]
    func createCompanyInviteLink(companyID: NativeID, requestID: NativeID) async throws -> CompanyInviteLinkCreated
    func revokeCompanyInviteLink(companyID: NativeID, linkID: NativeID, requestID: NativeID) async throws
    func previewCompanyInviteLink(token: CompanyInviteLinkToken) async throws -> CompanyInviteLinkPreview
    func redeemCompanyInviteLink(requestID: NativeID, token: CompanyInviteLinkToken) async throws
        -> CompanyInviteLinkRedeemed
    func createCompanyChannel(companyID: NativeID, requestID: NativeID,
                              displayName: String) async throws -> CompanyChannelEntry
}
