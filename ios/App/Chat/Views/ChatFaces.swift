import AtumChat
import SwiftUI

/// One squircle face in the chat (§9.1): the room's agent or bot, a group
/// member, or a reader in a Seen row. `matrixAvatarURI` is the Matrix media
/// URI; `avatar` is the product identity Home shows for the room (the
/// eclipse, the agent's photo, the catalog app's avatar).
struct ChatFace: Equatable {
    var name: String
    var kind: AtumAvatarKind
    var matrixAvatarURI: String?
    var avatar: LiveProductAvatar?
    var sha256: String?
    var candidates: [LiveProductRemoteArt]

    static func room(_ avatar: LiveProductAvatar?, matrixURI: String?, sha256: String?,
                     candidates: [LiveProductRemoteArt], name: String,
                     kind: AtumAvatarKind) -> ChatFace {
        ChatFace(name: name, kind: kind, matrixAvatarURI: matrixURI, avatar: avatar,
                 sha256: sha256, candidates: candidates)
    }

    /// An incoming sender's face: in a 1:1 chat the room's agent or app keeps
    /// the room's own photo; a person, and every member of a group (an app
    /// or an assistant included), uses their Matrix profile avatar, an app's
    /// in a squircle (`AvatarKind.member`).
    static func incoming(_ item: ChatItem, kind: RoomKind, roomTitle: String,
                         roomFace: ChatFace?, members: [String: ChatInfoMember]) -> ChatFace {
        if let member = members[item.sender] {
            return memberFace(member, kind: kind, roomFace: roomFace)
        }
        if let roomFace, kind.senderWearsRoomFace {
            let name = item.senderName?.isEmpty == false ? item.senderName! : roomTitle
            return ChatFace(name: name, kind: roomFace.kind,
                            matrixAvatarURI: item.senderAvatarURI ?? roomFace.matrixAvatarURI,
                            avatar: roomFace.avatar, sha256: roomFace.sha256,
                            candidates: roomFace.candidates)
        }
        let name = item.senderName?.isEmpty == false ? item.senderName! : roomTitle
        return ChatFace(name: name, kind: kind == .assistant ? .assistant : .person,
                        matrixAvatarURI: item.senderAvatarURI, avatar: nil, sha256: nil,
                        candidates: [])
    }

    /// A reader in a Seen row, as desktop's `MatrixSendState` draws one: the
    /// member's own photo when the member list has them; in a 1:1 chat (my
    /// assistant's, an app's, a person's) the room's face, which is the
    /// reader's (desktop: the agent's roster photo); otherwise the profile
    /// the reader's own messages carry (`ChatReader`: a Team Space channel
    /// or a member list still loading). The monogram is the last resort, of
    /// the display name, never of the raw Matrix ID.
    ///
    /// Before 2026-11-11 an unknown reader always fell back to a monogram of
    /// its Matrix ID: the phone loads no member list for assistant, app and
    /// Team Space chats, so the agent's Seen face was "@" or a bare letter.
    static func reader(_ reader: ChatReader, kind: RoomKind, roomFace: ChatFace?,
                       members: [String: ChatInfoMember]) -> ChatFace {
        if let member = members[reader.userID] {
            return memberFace(member, kind: kind, roomFace: roomFace)
        }
        if kind.senderWearsRoomFace, let roomFace {
            return ChatFace(name: reader.name ?? roomFace.name, kind: roomFace.kind,
                            matrixAvatarURI: roomFace.matrixAvatarURI ?? reader.avatarURI,
                            avatar: roomFace.avatar, sha256: roomFace.sha256,
                            candidates: roomFace.candidates)
        }
        return ChatFace(name: readerName(reader), kind: .person, matrixAvatarURI: reader.avatarURI,
                        avatar: nil, sha256: nil, candidates: [])
    }

    /// The reader's name for the tap list and the monogram: the member's,
    /// the profile's, else the Matrix ID's localpart.
    static func readerName(_ reader: ChatReader, members: [String: ChatInfoMember] = [:]) -> String {
        if let name = members[reader.userID]?.name, !name.isEmpty { return name }
        if let name = reader.name, !name.isEmpty { return name }
        return MatrixPersonName.localpart(reader.userID)
    }

    /// A known member's face. Before 2026-11-05 an agent or app member always
    /// borrowed the room's face, so in a group it wore the group's photo.
    private static func memberFace(_ member: ChatInfoMember, kind: RoomKind,
                                   roomFace: ChatFace?) -> ChatFace {
        if member.isAssistant || member.isApp, kind.senderWearsRoomFace, let roomFace {
            return ChatFace(name: member.name.isEmpty ? roomFace.name : member.name,
                            kind: roomFace.kind, matrixAvatarURI: roomFace.matrixAvatarURI,
                            avatar: roomFace.avatar, sha256: roomFace.sha256,
                            candidates: roomFace.candidates)
        }
        return ChatFace(name: member.name,
                        kind: .member(isApp: member.isApp, isAssistant: member.isAssistant),
                        matrixAvatarURI: member.matrixAvatarURI, avatar: nil, sha256: nil,
                        candidates: [])
    }
}

/// The shared squircle renderer for rows, the typing bubble and Seen marks.
/// It never starts a network read for a raw `mxc` URI: the app's Matrix client
/// owns that (and its cache), as on Home and in the info sheet.
struct ChatFaceView: View {
    let face: ChatFace
    let size: CGFloat

    @Environment(\.chatLoadMatrixThumbnail) private var loadMatrixThumbnail
    @State private var art: AtumAvatarArt?

    var body: some View {
        AtumAvatar(kind: face.kind, name: face.name, art: art,
                   mark: face.avatar?.agentMark, size: size)
            .task(id: Request(face: face, size: size)) {
                art = nil
                let pixelSide = AtumAvatar.thumbnailPixelSide(for: size)
                art = await AtumAvatarCandidateLoader.load(
                    matrixURI: face.matrixAvatarURI,
                    pixelSide: pixelSide,
                    loadMatrixThumbnail: loadMatrixThumbnail,
                    remoteCandidates: AtumAvatarCandidateLoader.candidates(
                        avatar: face.avatar,
                        sha256: face.sha256,
                        declared: face.candidates
                    )
                )
            }
    }

    private struct Request: Hashable {
        let description: String
        let size: CGFloat

        init(face: ChatFace, size: CGFloat) {
            description = String(describing: face)
            self.size = size
        }
    }
}
