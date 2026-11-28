import Foundation

/// Owner decision 7 (2026-11-28): the whole-room mention follows desktop
/// `matrix-mentions.ts` and `team-space/use-channel-facts.ts` exactly. It is
/// `@channel`, offered only in a Team Space company channel, only to someone
/// whose Matrix power reaches `notifications.room` and who has the platform
/// authority desktop asks for (channel owner or company owner/admin). Never in
/// a DM, a company conversation or a people group. A whole `@channel` token in
/// such a channel is room intent whether picked or typed, as on desktop.
///
/// Desktop asks for confirmation at 20 or more people. The pinned phone export
/// does not carry desktop's confirmation words yet (`mentionChannelConfirm*`),
/// so the phone withholds room intent at that size instead of sending without
/// the speed bump: the row is not offered and a typed token stays plain text.
public enum RoomMentionRules {
    public static let token = "@channel"
    /// The legacy body push rule's token. A message that contains it carries an
    /// empty `m.mentions`, which switches the legacy rule off.
    public static let legacyToken = "@room"
    /// Desktop `MATRIX_ROOM_MENTION_CONFIRM_AT`.
    public static let confirmAt = 20

    /// The facts desktop's `mentionRoom` reads, as the phone knows them.
    public struct Scope: Equatable, Sendable {
        public var isCompanyChannel: Bool
        /// Platform authority: the viewer may notify the whole channel.
        public var hasAuthority: Bool
        /// Matrix power: `canUserTriggerRoomNotification` and may send.
        public var canNotifyRoom: Bool
        /// The people `@channel` reaches (joined humans other than the
        /// sender). Nil while the member list is unknown.
        public var audience: Int?

        public init(isCompanyChannel: Bool = false, hasAuthority: Bool = false,
                    canNotifyRoom: Bool = false, audience: Int? = nil) {
            self.isCompanyChannel = isCompanyChannel
            self.hasAuthority = hasAuthority
            self.canNotifyRoom = canNotifyRoom
            self.audience = audience
        }

        public static let none = Scope()

        /// Desktop's `companyChannel && composerChannel.mentionRoom`.
        public var allowsRoomMention: Bool { isCompanyChannel && hasAuthority && canNotifyRoom }

        /// Desktop's `matrixRoomMentionNeedsConfirmation`.
        public var needsConfirmation: Bool { (audience ?? 0) >= RoomMentionRules.confirmAt }

        /// Room intent can go out without a confirmation step the phone
        /// cannot show yet. An unknown audience fails closed.
        public var sendsRoomMention: Bool {
            guard allowsRoomMention, let audience else { return false }
            return audience < RoomMentionRules.confirmAt
        }
    }

    public static func offersSuggestion(for query: String, scope: Scope) -> Bool {
        scope.sendsRoomMention && "channel".hasPrefix(query.lowercased())
    }

    public static func insert(into draft: String, scope: Scope) -> String? {
        guard let query = MentionRules.activeQuery(in: draft),
              offersSuggestion(for: query, scope: scope),
              let marker = draft.lastIndex(of: "@") else { return nil }
        return String(draft[..<marker]) + token + " "
    }

    /// Desktop `matrixRoomMentionRequested`: an authorized whole token,
    /// case-insensitive, preceded by the start, a space or an opening
    /// bracket, and followed by the end, a space or punctuation.
    public static func requested(in text: String, scope: Scope) -> Bool {
        scope.sendsRoomMention && contains(token, in: text)
    }

    /// Whether the text carries either whole-room token, so the send adds an
    /// empty `m.mentions` when it has no other intent.
    public static func mentionsRoomToken(_ text: String) -> Bool {
        contains(token, in: text) || contains(legacyToken, in: text)
    }

    static func contains(_ token: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: token, options: [.caseInsensitive],
                                     range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex
                || text[text.index(before: range.lowerBound)].isWhitespace
                || "([{".contains(text[text.index(before: range.lowerBound)])
            let afterOK = range.upperBound == text.endIndex
                || text[range.upperBound].isWhitespace
                || ".,!?;:)]}".contains(text[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
