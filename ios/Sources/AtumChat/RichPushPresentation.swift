import Foundation

/// SDK-free projection of a fetched notification. Raw event JSON is never display input.
public struct RichPushItem: Sendable {
    public enum Kind: Sendable {
        case text(String), notice(String), emote(String)
        case image, video, audio, file, location, sticker, invite, undecryptable, unsupported
    }
    public let senderID: String
    public let senderName: String?
    public let roomName: String?
    public let isDirect: Bool
    public let kind: Kind

    public init(senderID: String, senderName: String?, roomName: String?, isDirect: Bool, kind: Kind) {
        self.senderID = senderID; self.senderName = senderName; self.roomName = roomName
        self.isDirect = isDirect; self.kind = kind
    }
}

public enum RichPushPresentation {
    public struct Copy: Sendable {
        public let generic: String
        public let unnamed, image, video, audio, file, sticker, invite: String?
        public init(generic: String, unnamed: String? = nil, image: String? = nil, video: String? = nil,
                    audio: String? = nil, file: String? = nil, sticker: String? = nil, invite: String? = nil) {
            self.generic = generic; self.unnamed = unnamed; self.image = image; self.video = video
            self.audio = audio; self.file = file; self.sticker = sticker; self.invite = invite
        }
    }
    public struct Content: Equatable, Sendable {
        public let title, subtitle, body: String
    }
    public enum Result: Equatable, Sendable {
        case generic, suppress, content(Content)
    }

    public static func map(_ item: RichPushItem, ownUserID: String, copy: Copy) -> Result {
        guard item.senderID != ownUserID else { return .suppress }
        switch item.kind {
        case .undecryptable, .unsupported: return .generic
        default: break
        }
        guard let sender = displayName(item.senderName, userID: item.senderID) ?? copy.unnamed else { return .generic }
        let body: String
        switch item.kind {
        case let .text(text), let .notice(text): body = text
        // Matrix emotes are already the action: /me waves -> "Name waves".
        case let .emote(action):
            guard !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .generic }
            body = sender + " " + action
        case .image: body = copy.image ?? copy.generic
        case .video: body = copy.video ?? copy.generic
        case .audio: body = copy.audio ?? copy.generic
        case .file: body = copy.file ?? copy.generic
        case .sticker: body = copy.sticker ?? copy.generic
        case .invite: body = copy.invite ?? copy.generic
        case .location:
            // PENDING-COPY: no exported location notification phrase.
            body = copy.generic
        case .undecryptable, .unsupported: return .generic
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .generic }
        if item.isDirect {
            return .content(Content(title: sender, subtitle: "", body: body))
        }
        guard let room = displayName(item.roomName, userID: item.senderID) else { return .generic }
        // Element X's group layout: room title, sender subtitle, message body.
        return .content(Content(title: room, subtitle: sender, body: body))
    }

    private static func displayName(_ raw: String?, userID: String) -> String? {
        guard let name = MatrixPersonName.name(raw, userID: userID),
              name != MatrixPersonName.localpart(userID),
              name != userID.split(separator: ":", maxSplits: 1).last.map(String.init),
              name.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:[:][0-9]+)?$"#, options: .regularExpression) == nil,
              !name.contains("@"), !name.hasPrefix("!"), !name.hasPrefix("#"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }
}
