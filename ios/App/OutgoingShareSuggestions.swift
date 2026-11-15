import AtumNativeAPI
import Foundation
import Intents

/// The app installs a live resolver, so hidden/archived/left rooms cannot donate via stale cache.
@MainActor
final class OutgoingShareSuggestions {
    static let shared = OutgoingShareSuggestions()
    var resolve: ((String) -> ShareChat?)?
    private let defaults: UserDefaults
    private let donate: @MainActor (INInteraction) async throws -> Void
    private let delete: @MainActor (String) async throws -> Void
    init(defaults: UserDefaults = .standard,
         donate: @escaping @MainActor (INInteraction) async throws -> Void = { try await $0.donate() },
         delete: @escaping @MainActor (String) async throws -> Void = { try await ShareSuggestions.delete(roomID: $0) }) {
        self.defaults = defaults; self.donate = donate; self.delete = delete
    }
    private let key = "atum.share.donatedGroups.v1"
    private var groups: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    func sent(roomID: String) async {
        guard let chat = resolve?(roomID), !chat.recipients.isEmpty else { return }
        var known = groups; known.insert(roomID)
        // Persist before donation so a crash cannot lose the deletion index.
        defaults.set(Array(known), forKey: key)
        let store = try? NotificationSharedStore()
        let avatar = chat.avatarURI.flatMap { store?.cachedAvatar(uri: $0, pixelSide: 192) }
        let interaction = ShareSuggestions.interaction(chat: chat, avatar: avatar)
        try? await donate(interaction)
        // A hide/leave/sign-out racing the async donation must delete its late result too.
        if resolve?(roomID) == nil { await remove(roomID: roomID) }
    }
    func remove(roomID: String) async {
        do {
            try await delete(roomID)
            var known = groups; known.remove(roomID); defaults.set(Array(known), forKey: key)
        } catch { /* Keep failed deletions indexed for the next reconciliation/sign-out. */ }
    }
    func reconcile(eligible: Set<String>) async {
        for room in groups.subtracting(eligible) { await remove(roomID: room) }
    }
    func removeAll() async { await reconcile(eligible: []) }
}
