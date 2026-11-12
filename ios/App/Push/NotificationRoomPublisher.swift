import AtumChat
import AtumNativeAPI
import SwiftUI
import UIKit

/// Hands the notification extension what only the app knows about a room
/// (`NotificationRoomDirectory`): which rooms are assistant or app chats and
/// the face their chat header draws, and which are Team Space channels or
/// conversations, with the name Team Space gives them and the company logo.
/// Everything comes from the app's own classification (the same policies
/// `conversationInfo` and Team Space use); the extension never reads a room's
/// kind, name or image from a push.
@MainActor
enum NotificationRoomPublisher {
    /// Assistant and app chats are a handful; the bound keeps a misbehaving
    /// roster from drawing hundreds of faces.
    static let maximumFaces = 32
    /// The face is drawn at 64 pt at 3x, the size `CommunicationNotification` hands iOS.
    static let facePointSize: CGFloat = 64

    /// One chat-header face to draw, as `ChatInfoAvatar` draws it.
    struct Face: Equatable {
        let roomID: String
        let kind: AtumAvatarKind
        let name: String
        let avatar: LiveProductAvatar?
        let matrixURI: String?
        let sha256: String?
        let candidates: [LiveProductRemoteArt]

        /// Everything that changes the drawing; its hash names the file.
        var identity: String {
            ["face-v1", String(describing: kind), name, String(describing: avatar), matrixURI ?? "",
             sha256 ?? "", candidates.map { $0.url.absoluteString + "#" + ($0.sha256 ?? "") }.joined(separator: ",")]
                .joined(separator: "\u{0}")
        }
        var fileName: String { NotificationSharedStore.faceFileName(identity: identity) }
        /// A face that should show a photo. When the photo cannot load now,
        /// no face is written (rather than caching a monogram under its name).
        var expectsPhoto: Bool {
            if matrixURI != nil || !candidates.isEmpty { return true }
            if case .photo = avatar { return true }
            return false
        }
    }

    struct Input: Equatable {
        let ownUserID: String
        /// Entries without `faceFile`; `publish` adds it once the face exists.
        let rooms: [String: NotificationRoomEntry]
        let faces: [Face]
    }

    static func input(ownUserID: String?, rooms: [LiveProductRoom],
                      workspace: CompanyWorkspaceModel) -> Input? {
        guard let ownUserID, !ownUserID.isEmpty else { return nil }
        let logos = workspace.logoURIs(from: rooms)
        var entries = [String: NotificationRoomEntry]()
        var faces = [Face]()
        for room in rooms where room.id.hasPrefix("!") && !room.isInvitation {
            let label = workspace.teamSpaceRoomLabel(roomID: room.id)
            let company = label.flatMap { workspace.companyName($0.companyID) }
            let groupName = label.map { [$0.name, company].compactMap { $0 }.joined(separator: " · ") }
            let logo = label.flatMap { logos[$0.companyID] }
            if let claim = workspace.conversationClaim(roomID: room.id) {
                entries[room.id] = NotificationRoomEntry(
                    kind: claim.kind == .dm ? .teamDirect : .teamConversation,
                    groupName: groupName, companyLogoURI: logos[claim.companyID], companyName: company)
            } else if room.kind == .agent {
                entries[room.id] = NotificationRoomEntry(kind: room.isAppBotRoom ? .appBot : .assistant,
                                                         faceName: room.title)
                if faces.count < maximumFaces {
                    faces.append(Face(roomID: room.id,
                                      kind: room.avatar == .eclipse ? .atum : (room.isAppBotRoom ? .app : .assistant),
                                      name: room.title, avatar: room.avatar, matrixURI: room.matrixAvatarURL,
                                      sha256: room.avatarSHA256, candidates: room.avatarCandidates))
                }
            } else if workspace.isCompanyChannel(room.id) {
                entries[room.id] = NotificationRoomEntry(kind: .teamChannel, groupName: groupName,
                                                         companyLogoURI: logo, companyName: company)
            }
        }
        return Input(ownUserID: ownUserID, rooms: entries, faces: faces)
    }

    /// Draws any face not already on disk, then writes the directory naming
    /// the faces that exist and prunes the rest. Best effort: a failure only
    /// leaves the extension on its SDK-only rules.
    static func publish(_ input: Input, design: LiveDesign,
                        loadMatrixThumbnail: @escaping (String, Int) async -> Data?) async {
        guard let store = try? NotificationSharedStore() else { return }
        var rooms = input.rooms
        var kept = Set<String>()
        for face in input.faces {
            guard !Task.isCancelled else { return }
            let name = face.fileName
            if !store.hasFace(name) {
                guard let png = await draw(face, design: design, loadMatrixThumbnail: loadMatrixThumbnail),
                      !Task.isCancelled, (try? store.writeFace(png, name: name)) != nil else { continue }
            }
            kept.insert(name)
            rooms[face.roomID]?.faceFile = name
        }
        guard !Task.isCancelled else { return }
        try? store.writeDirectory(NotificationRoomDirectory(ownUserID: input.ownUserID, rooms: rooms))
        store.pruneFaces(keeping: kept)
    }

    static func draw(_ face: Face, design: LiveDesign,
                     loadMatrixThumbnail: @escaping (String, Int) async -> Data?) async -> Data? {
        let pixelSide = AtumAvatar.thumbnailPixelSide(for: facePointSize)
        let art = await AtumAvatarCandidateLoader.load(
            matrixURI: face.matrixURI, pixelSide: pixelSide, loadMatrixThumbnail: loadMatrixThumbnail,
            remoteCandidates: AtumAvatarCandidateLoader.candidates(avatar: face.avatar, sha256: face.sha256,
                                                                   declared: face.candidates))
        if art == nil, face.expectsPhoto { return nil }
        return render(face, art: art, design: design)
    }

    /// One bitmap for both appearances, so the light scheme, at the default
    /// text size (the face's `@ScaledMetric` must not grow it).
    static func render(_ face: Face, art: AtumAvatarArt?, design: LiveDesign) -> Data? {
        let view = AtumAvatar(kind: face.kind, name: face.name, art: art, mark: face.avatar?.agentMark,
                              size: facePointSize)
            .atumDesign(design)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }

    /// Sign-out: one account's faces, cached avatars and room names go.
    nonisolated static func removeAll() {
        (try? NotificationSharedStore())?.removeAll()
    }
}
