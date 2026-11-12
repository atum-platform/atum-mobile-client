import Foundation

/// What the app knows about one room that the notification extension cannot
/// work out from the SDK alone: whether it is an assistant's or an app's chat,
/// a Team Space channel or conversation, the name Team Space gives it, the
/// company logo, and the header face the app drew for it. The app writes it to
/// the shared App Group (`NotificationSharedStore`); it is never read from a
/// push payload.
public struct NotificationRoomEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The person's own assistant (primary or another agent).
        case assistant
        /// A catalog app's bot chat.
        case appBot
        /// A Team Space company channel.
        case teamChannel
        /// A Team Space group conversation.
        case teamConversation
        /// A Team Space one-to-one conversation (a person chat).
        case teamDirect
    }

    public var kind: Kind
    /// The Team Space label, "# channel · Company" or "Title · Company".
    public var groupName: String?
    /// The company's logo (`mxc://`), the group image when the room has none.
    public var companyLogoURI: String?
    /// The company's name, for the monogram when there is no image at all.
    public var companyName: String?
    /// The face the app drew for this room's chat header, as a file the app
    /// wrote into the shared store (`<64 hex>.png`). Assistants and apps only.
    public var faceFile: String?
    /// The name under that face (the agent's or app's), for the monogram.
    public var faceName: String?

    public init(kind: Kind, groupName: String? = nil, companyLogoURI: String? = nil,
                companyName: String? = nil, faceFile: String? = nil, faceName: String? = nil) {
        self.kind = kind; self.groupName = groupName; self.companyLogoURI = companyLogoURI
        self.companyName = companyName; self.faceFile = faceFile; self.faceName = faceName
    }
}

/// One account's room directory. Bound to the account's Matrix user ID so a
/// file left by an earlier account is never applied to the next one.
public struct NotificationRoomDirectory: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Bounds the file the extension decodes inside its memory budget.
    public static let maximumRooms = 512

    public var version: Int
    public var ownUserID: String
    public var rooms: [String: NotificationRoomEntry]

    public init(ownUserID: String, rooms: [String: NotificationRoomEntry]) {
        version = Self.currentVersion
        self.ownUserID = ownUserID
        self.rooms = rooms
    }
}

/// Which image is the notification's big one, and whether iOS should show it
/// as a person's message or a group's. Pure: the extension fetches the
/// candidates in order and draws the monogram when none loads.
public enum CommunicationNotificationPolicy {
    /// Where an image can come from. Matrix URIs come from the SDK's own
    /// notification item or the app's directory; never from the push.
    public enum ImageSource: Equatable, Sendable {
        case matrix(String)
        case appFace(String)
    }

    public enum Style: Equatable, Sendable {
        /// The sender is the conversation: their face is the big image.
        case person
        /// iOS group style: the group's image is the big one, the sender is
        /// named on the message.
        case group(name: String)
    }

    public struct Plan: Equatable, Sendable {
        public let style: Style
        /// Tried in order; the first one that loads wins.
        public let images: [ImageSource]
        /// Drawn as the app's monogram when none of `images` loads.
        public let monogramName: String

        public init(style: Style, images: [ImageSource], monogramName: String) {
            self.style = style; self.images = images; self.monogramName = monogramName
        }
    }

    /// The SDK facts the plan needs, already projected away from SDK types.
    public struct Input: Equatable, Sendable {
        public let roomID: String
        public let senderName: String
        public let senderAvatarURI: String?
        /// The room's validated display name (`RichPushPresentation`'s group title).
        public let roomName: String?
        public let roomAvatarURI: String?
        public let isDirect: Bool

        public init(roomID: String, senderName: String, senderAvatarURI: String?,
                    roomName: String?, roomAvatarURI: String?, isDirect: Bool) {
            self.roomID = roomID; self.senderName = senderName; self.senderAvatarURI = senderAvatarURI
            self.roomName = roomName; self.roomAvatarURI = roomAvatarURI; self.isDirect = isDirect
        }
    }

    /// Nil keeps today's plain content (no resolved sender or no group name).
    public static func plan(_ input: Input, entry: NotificationRoomEntry?) -> Plan? {
        let sender = input.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty else { return nil }
        let senderPhoto = matrix(input.senderAvatarURI)
        let roomPhoto = matrix(input.roomAvatarURI)
        switch entry?.kind {
        case .assistant?, .appBot?:
            // The chat header's face: the app's own drawing, then the room's
            // photo (an agent room's avatar is the agent's), then the bot's
            // member photo. The monogram names the agent as the header does.
            let face = entry?.faceFile.flatMap(validFaceFile).map { ImageSource.appFace($0) }
            let name = clean(entry?.faceName) ?? sender
            return Plan(style: .person, images: unique([face, roomPhoto, senderPhoto]), monogramName: name)
        case .teamChannel?, .teamConversation?:
            guard let group = clean(entry?.groupName) ?? clean(input.roomName) else { return nil }
            let logo = matrix(entry?.companyLogoURI)
            return Plan(style: .group(name: group), images: unique([roomPhoto, logo]),
                        monogramName: clean(entry?.companyName) ?? group)
        case .teamDirect?:
            return Plan(style: .person, images: unique([senderPhoto]), monogramName: sender)
        case nil:
            if input.isDirect {
                return Plan(style: .person, images: unique([senderPhoto]), monogramName: sender)
            }
            guard let group = clean(input.roomName) else { return nil }
            return Plan(style: .group(name: group), images: unique([roomPhoto]), monogramName: group)
        }
    }

    /// The directory entry the extension may trust for a room: the file must
    /// belong to this account and be a version it understands.
    public static func entry(roomID: String, ownUserID: String,
                             directory: NotificationRoomDirectory?) -> NotificationRoomEntry? {
        guard let directory, directory.version == NotificationRoomDirectory.currentVersion,
              directory.ownUserID == ownUserID else { return nil }
        return directory.rooms[roomID]
    }

    /// Only Matrix content URIs with a server and a media ID are fetched.
    static func matrix(_ raw: String?) -> ImageSource? {
        guard let raw, raw.count <= 512, raw.hasPrefix("mxc://") else { return nil }
        let parts = raw.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) || $0 == "?" || $0 == "#" })
        else { return nil }
        return .matrix(raw)
    }

    /// A face file name the app wrote: 64 lowercase hex digits and `.png`.
    public static func validFaceFile(_ raw: String) -> String? {
        raw.range(of: #"^[0-9a-f]{64}\.png$"#, options: .regularExpression) == nil ? nil : raw
    }

    private static func clean(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func unique(_ sources: [ImageSource?]) -> [ImageSource] {
        var result = [ImageSource]()
        for case let source? in sources where !result.contains(source) { result.append(source) }
        return result
    }
}
