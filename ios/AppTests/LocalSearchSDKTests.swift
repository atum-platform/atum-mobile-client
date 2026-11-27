import Foundation
import MatrixRustSDK
import XCTest
@testable import AtumMobile

@MainActor
final class LocalSearchSDKTests: XCTestCase {
    func testResultsExcludeRedactionsIgnoredSendersAndRemovedRooms() {
        let body = "Private hit"
        let text = MsgLikeKind.message(content: MessageContent(
            msgType: .text(content: TextMessageContent(body: body, formatted: nil)),
            body: body, isEdited: false, mentions: nil))
        func result(room: String = "!joined:test", id: String, sender: String = "@sender:test",
                    kind: MsgLikeKind, threadRoot: String? = nil) -> SearchServiceResult {
            let content = MsgLikeContent(kind: kind, inReplyTo: nil, threadRoot: threadRoot, threadSummary: nil)
            return .message(roomId: room, result: MessageSearchResult(
                eventId: id, sender: sender, senderProfile: .unavailable,
                content: .msgLike(content: content), timestamp: 1))
        }
        let hit = result(id: "$hit", kind: text, threadRoot: "$root")
        let snapshots = [hit, hit, result(id: "$redacted", kind: .redacted),
                         result(id: "$ignored", sender: "@ignored:test", kind: text),
                         result(room: "!removed:test", id: "$left", kind: text)]
        let admitted = LocalSearchSource.admitted(snapshots, rooms: ["!joined:test": nil],
                                                   ignored: ["@ignored:test"], query: "Private")
        XCTAssertEqual(admitted.map(\.id.eventID), ["$hit"])
        XCTAssertEqual(admitted.first?.id.threadRootID, "$root")
        XCTAssertTrue(LocalSearchSource.admitted(snapshots, rooms: [:], ignored: [], query: "Private").isEmpty)
    }

    /// Exercise the linked producer's builder, query, pagination, result
    /// subscription and backfill handle with a synthetic offline session.
    func testPinnedSearchBinaryWithEmptyStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = "http://127.0.0.1:9"
        let client = try await MatrixLocalSearchStore.configure(
            ClientBuilder(), cacheDirectory: root, sessionSecret: UUID().uuidString)
            .homeserverUrl(url: local)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .disableAutomaticTokenRefresh()
            .autoEnableCrossSigning(autoEnableCrossSigning: false)
            .autoEnableBackups(autoEnableBackups: false)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .build()
        try await client.restoreSession(session: Session(accessToken: "fixture", refreshToken: nil,
                                                         userId: "@search:localhost", deviceId: "FIXTURE",
                                                         homeserverUrl: local, oauthData: nil,
                                                         slidingSyncVersion: .native))
        let backfill = client.runSearchBackfill(strategy: .foreground)
        defer { backfill.cancel() }
        let search = client.searchService()
        try await search.setQuery(query: "private scope canary")
        try await search.paginate()
        let hits = await LocalSearchSource.snapshot(of: search)
        XCTAssertTrue(hits.isEmpty)
        XCTAssertEqual(search.paginationState(), .idle(endReached: true))
    }
}
