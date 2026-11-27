import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

extension LiveMatrixSession {
    /// Apply current personal-roster authority to the SDK's complete known
    /// room list. The scope gate is independent of Home's filter, text and
    /// current page. Unknown company classification must fail closed.
    func personalMessageSearch(allowsRoom: @escaping @MainActor (String) -> Bool) -> PersonalMessageSearch {
        PersonalMessageSearch(
            transport: LiveAppModel.homeCompanySearchService.transport,
            rooms: { [weak self] in
                guard let self, (try? runtime.requireCurrent()) != nil else { return [] }
                return runtime.client.rooms().compactMap { room in
                    let id = room.id()
                    guard room.membership() == .joined, !room.isSpace(), allowsRoom(id) else { return nil }
                    let encrypted: Bool? = switch room.encryptionState() {
                    case .encrypted: true
                    case .notEncrypted: false
                    case .unknown: nil
                    }
                    return PersonalMessageSearch.Room(id: id, name: MatrixPersonName.readableRoomName(room.displayName()),
                                                      isEncrypted: encrypted)
                }
            },
            ignoredUsers: { try await self.searchIgnoredUsers() },
            endpoint: { try self.companySearchEndpoint() })
    }

    func joinedSearchRoom(_ id: String) -> Room? {
        guard (try? runtime.requireCurrent()) != nil,
              let room = try? runtime.client.getRoom(roomId: id),
              room.membership() == .joined, !room.isSpace() else { return nil }
        return room
    }

    func searchIgnoredUsers() async throws -> Set<String> {
        try runtime.requireCurrent()
        let raw = try await runtime.client.accountData(eventType: "m.ignored_user_list")
        try runtime.requireCurrent()
        guard let raw else { return [] }
        // The SDK stores the whole account-data event.
        let event = try JSONDecoder().decode(IgnoredSearchUsers.self, from: Data(raw.utf8))
        return Set(event.content.ignoredUsers.keys)
    }

    /// Revalidate a hit immediately before opening its focused timeline.
    /// The caller supplies the same current visibility gate used to render
    /// hits and retains the generation check through focused placement.
    func confirmSearchTarget(_ hit: GlobalChatSearchHit, scope: GlobalChatSearchScope,
                             isVisible: @MainActor (String) -> Bool,
                             isCurrent: @MainActor () -> Bool) async -> ChatSearchEventTarget? {
        let target = hit.id
        func eligibleRoom() -> Room? {
            guard !Task.isCancelled, isCurrent(), isVisible(target.roomID),
                  let room = joinedSearchRoom(target.roomID) else { return nil }
            let expected: EncryptionState = scope == .plain ? .notEncrypted : .encrypted
            return room.encryptionState() == expected ? room : nil
        }
        guard let room = eligibleRoom(),
              let event = try? await room.loadOrFetchEvent(eventId: target.eventID),
              eligibleRoom() != nil, event.eventId() == target.eventID, event.senderId() == hit.senderID,
              case let .messageLike(content)? = try? event.content(),
              case let .roomMessage(messageType, _) = content, case .text = messageType,
              event.threadRootEventId() == target.threadRootID,
              let ignored = try? await searchIgnoredUsers(), !ignored.contains(hit.senderID),
              eligibleRoom() != nil else { return nil }
        return target
    }
}

extension ChatSearchEventTarget {
    /// Keep the reply ID for both SDK context lookup and transcript scroll.
    /// Automatic focus uses the event's actual thread relation.
    func timelineFocus(hideThreadedEvents: Bool) -> TimelineFocus {
        .event(eventId: eventID, numContextEvents: 25,
               threadMode: .automatic(hideThreadedEvents: hideThreadedEvents))
    }
}

private struct IgnoredSearchUsers: Decodable {
    struct Content: Decodable {
        struct User: Decodable {}
        let ignoredUsers: [String: User]
        enum CodingKeys: String, CodingKey { case ignoredUsers = "ignored_users" }
    }

    let content: Content
}
