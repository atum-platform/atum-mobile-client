import AtumChat
import Foundation

/// HC-7: what the Home long-press and the chat panel need for Rename and
/// Block, read from the live session. Additive: the model's own state is
/// untouched; names and ignores come back through sync.
extension LiveAppModel {
    /// Rename's request for a person or group chat (`ChatMenuPolicy`): the
    /// name it goes by now, and whether it renames the group for everyone.
    func renameRequest(roomID: String) async -> ChatRenameRequest? {
        guard let session = liveMatrix, offersPersonalExits(roomID: roomID),
              let room = session.rooms.first(where: { $0.roomID == roomID }) else { return nil }
        let isGroup = !(room.isDirect && room.memberCount <= 2)
        let menuRoom: ChatMenuPolicy.Room = isGroup ? .group : .person
        guard ChatMenuPolicy.offersRename(menuRoom), roomID != founderRoomID else { return nil }
        let canName = isGroup ? await session.groupDetailsPowers(roomID: roomID).name : false
        guard liveMatrix === session else { return nil }
        let shared = ChatMenuPolicy.renamesForEveryone(menuRoom, canName: canName)
        let current = shared ? room.displayName : (room.privateTitle ?? room.displayName)
        return ChatRenameRequest(roomID: roomID, current: current, shared: shared)
    }

    func rename(_ request: ChatRenameRequest, to name: String) async -> Bool {
        guard let session = liveMatrix, ChatPrivateTitle.canSave(name, shared: request.shared) else { return false }
        return request.shared
            ? await session.setGroupName(roomID: request.roomID, name: name)
            : await session.setPrivateTitle(roomID: request.roomID, title: name)
    }

    /// The other person of a person chat, the one Block applies to. The
    /// Founder's own account keeps the Founder chat (`ChatExitPolicy`).
    func blockablePeer(roomID: String) -> String? {
        guard let session = liveMatrix, offersPersonalExits(roomID: roomID),
              let room = session.rooms.first(where: { $0.roomID == roomID }),
              room.isDirect, room.memberCount <= 2 else { return nil }
        let isFounder = roomID == founderRoomID
        guard ChatExitPolicy.mayIgnore(memberIsAssistant: false, memberIsSelf: false,
                                       in: isFounder ? .founder : .person,
                                       viewerIsFounder: isFounderAccount) else { return nil }
        // `memberUserIDs` already leaves this account out.
        return ChatMenuPolicy.blockablePeer(isFounder ? .founder : .person, memberUserIDs: room.memberUserIDs,
                                            ownUserID: "", nonPersonUserIDs: [])
    }

    /// The people this account ignores (Matrix `m.ignored_user_list`).
    func blockedUserIDs() async -> Set<String> {
        guard let people = await ignoredPeople() else { return [] }
        return Set(people.map(\.userID))
    }
}
