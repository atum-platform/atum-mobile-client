import AtumNativeAPI
import Intents
import XCTest

@MainActor
final class ShareSuggestionsTests: XCTestCase {
    let chat = ShareChat(id: "!chat:example.com", name: "Friends", isGroup: true, recipients: ["@friend:example.com"])
    func testOutgoingGroupShapeAndAvatar() {
        let value = ShareSuggestions.interaction(chat: chat)
        let intent = value.intent as! INSendMessageIntent
        XCTAssertEqual(value.direction, .outgoing); XCTAssertEqual(value.groupIdentifier, chat.id)
        XCTAssertEqual(intent.conversationIdentifier, chat.id)
        XCTAssertEqual(intent.speakableGroupName?.spokenPhrase, chat.name)
        XCTAssertEqual(intent.recipients?.first?.personHandle?.value, chat.recipients[0])
        XCTAssertNotNil(intent.recipients?.first?.image); XCTAssertNil(intent.content)
    }
    func testDirectShape() {
        let person = ShareChat(id: "!dm:example.com", name: "Person", isGroup: false, recipients: ["@person:example.com"])
        let intent = ShareSuggestions.interaction(chat: person).intent as! INSendMessageIntent
        XCTAssertNil(intent.speakableGroupName); XCTAssertEqual(intent.recipients?.first?.displayName, "Person")
        XCTAssertNotNil(intent.recipients?.first?.image)
    }
    func testIntentPreselectsConversation() {
        let intent = ShareSuggestions.interaction(chat: chat).intent
        XCTAssertEqual(ShareSuggestions.preselection(intent: intent, chats: [chat]), [chat.id])
    }
    func testStaleOrMissingIntentCannotSelectHiddenConversation() {
        XCTAssertTrue(ShareSuggestions.preselection(intent: ShareSuggestions.interaction(chat: chat).intent, chats: []).isEmpty)
        XCTAssertTrue(ShareSuggestions.preselection(intent: nil, chats: [chat]).isEmpty)
    }
    func testDeletionUsesGroupIdentifier() async throws {
        var deleted: String?
        try await ShareSuggestions.delete(roomID: chat.id) { deleted = $0 }
        XCTAssertEqual(deleted, chat.id)
    }
}

@MainActor
final class ShareComposerModelTests: XCTestCase {
    private func fixture() throws -> (ShareQueue, ShareAccount, ShareChat) {
        let q = ShareQueue(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let account = ShareAccount(userID: "@owner:example.com", generation: UUID())
        let chat = ShareChat(id: "!dm:example.com", name: "Alice", isGroup: false, recipients: ["@alice:example.com"])
        try q.publish(ShareDirectory(account: account, chats: [chat]))
        addTeardownBlock { try? FileManager.default.removeItem(at: q.root) }
        return (q, account, chat)
    }
    private var provider: NSItemProvider { NSItemProvider(item: "body" as NSString, typeIdentifier: "public.plain-text") }
    func testPreselectionCaptionAndQueuedResult() async throws {
        let (q, account, chat) = try fixture()
        let model = ShareComposerModel(queue: q, account: { account })
        await model.load(providers: [provider], intent: ShareSuggestions.interaction(chat: chat).intent)
        XCTAssertEqual(model.phase, .ready); XCTAssertTrue(model.canSend)
        model.caption = "caption"; model.send()
        XCTAssertEqual(model.phase, .queued); XCTAssertFalse(model.canSend)
        XCTAssertEqual(try q.jobs(account: account).first?.caption, "caption")
    }
    func testSearchAndToggle() async throws {
        let (q, account, chat) = try fixture(); let model = ShareComposerModel(queue: q, account: { account })
        await model.load(providers: [provider], intent: nil)
        XCTAssertFalse(model.canSend); model.toggle(chat); XCTAssertTrue(model.canSend)
        model.search = "ali"; XCTAssertEqual(model.chats, [chat])
        model.search = "missing"; XCTAssertTrue(model.chats.isEmpty)
        model.toggle(chat); XCTAssertFalse(model.canSend)
    }
    func testAccountChangeAtSendKeepsIntakeUncommitted() async throws {
        let (q, account, chat) = try fixture(); var current = account
        let model = ShareComposerModel(queue: q, account: { current })
        await model.load(providers: [provider], intent: nil); model.toggle(chat)
        current = ShareAccount(userID: "@other:example.com", generation: UUID()); model.send()
        XCTAssertNotNil(model.error); XCTAssertTrue(try q.jobs(account: account).isEmpty)
    }
    func testCancelDoesNotCommit() async throws {
        let (q, account, _) = try fixture(); let model = ShareComposerModel(queue: q, account: { account })
        await model.load(providers: [provider], intent: nil); model.cancel()
        XCTAssertTrue(try q.jobs(account: account).isEmpty)
    }
}

@MainActor
final class OutgoingShareSuggestionsTests: XCTestCase {
    private let chat = ShareChat(id: "!chat:example.com", name: "Chat", isGroup: false, recipients: ["@friend:example.com"])
    private func defaults() -> UserDefaults {
        let name = "share-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testHiddenOrArchivedResolverSuppressesDonation() async {
        var donated = 0
        let sut = OutgoingShareSuggestions(defaults: defaults(), donate: { _ in donated += 1 })
        sut.resolve = { _ in nil }
        await sut.sent(roomID: chat.id)
        XCTAssertEqual(donated, 0)
    }
    func testSignOutDeletesAllPersistedGroups() async {
        let store = defaults(); var deleted = [String]()
        let sut = OutgoingShareSuggestions(defaults: store, donate: { _ in }, delete: { deleted.append($0) })
        sut.resolve = { [chat] _ in chat }; await sut.sent(roomID: chat.id)
        // A new coordinator must recover the deletion index after process termination.
        let resumed = OutgoingShareSuggestions(defaults: store, delete: { deleted.append($0) })
        await resumed.removeAll()
        XCTAssertEqual(deleted, [chat.id])
    }
    func testLeaveDeletesOnlyItsGroup() async {
        var deleted = [String]()
        let sut = OutgoingShareSuggestions(defaults: defaults(), donate: { _ in }, delete: { deleted.append($0) })
        sut.resolve = { [chat] _ in chat }; await sut.sent(roomID: chat.id)
        await sut.remove(roomID: chat.id); await sut.removeAll()
        XCTAssertEqual(deleted, [chat.id])
    }
    func testFailedDeletionIsRetried() async {
        var attempts = 0
        let sut = OutgoingShareSuggestions(defaults: defaults(), donate: { _ in }, delete: { _ in
            attempts += 1
            if attempts == 1 { throw ShareQueueFailure.unavailable }
        })
        sut.resolve = { [chat] _ in chat }; await sut.sent(roomID: chat.id)
        await sut.removeAll(); await sut.removeAll(); await sut.removeAll()
        XCTAssertEqual(attempts, 2)
    }
    func testDonationFinishingAfterSignOutIsDeleted() async {
        var deleted = [String]()
        var sut: OutgoingShareSuggestions!
        sut = OutgoingShareSuggestions(defaults: defaults(), donate: { _ in sut.resolve = nil }, delete: { deleted.append($0) })
        sut.resolve = { [chat] _ in chat }; await sut.sent(roomID: chat.id)
        XCTAssertEqual(deleted, [chat.id])
    }
}
