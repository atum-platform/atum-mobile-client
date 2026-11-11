import AtumChat
import Foundation
import XCTest
@testable import AtumNativeAPI

/// TS-6b: the desktop's thread rules (atum-desktop `threads.ts`, `company-threads.tsx`).
final class CompanyThreadsPolicyTests: XCTestCase {
    private let room = "!general:example.test"
    private let other = "!design:example.test"

    private func message(_ id: String, at sentAt: Int64, own: Bool = false, mentions: Bool = false,
                         sender: String = "@lan:example.test") -> CompanyThreadMessage {
        CompanyThreadMessage(eventID: id, senderID: own ? "@me:example.test" : sender, senderName: "Lan",
                             isOwn: own, body: "body " + id, sentAt: sentAt, mentionsViewer: mentions)
    }

    private func activity(_ event: String, root: String, room: String? = nil, kind: CompanyActivityKind = .threadReply,
                          unread: Bool = true) -> CompanyActivityItem {
        CompanyActivityItem(roomID: room ?? self.room, eventID: event, kind: kind, body: "x",
                            senderID: "@lan:example.test", sentAt: 1, unread: unread, threadRootID: root)
    }

    // MARK: Attention record

    func testAttentionParsesOnlyTheDesktopShape() {
        let good = #"{"v":1,"followed":["$a"],"unfollowed":["$b"]}"#
        XCTAssertEqual(CompanyThreadAttention.parse(good), CompanyThreadAttention(followed: ["$a"], unfollowed: ["$b"]))
        let empty = CompanyThreadAttention()
        XCTAssertEqual(CompanyThreadAttention.parse(nil), empty)
        for bad in [#"{"v":2,"followed":[],"unfollowed":[]}"#,
                    #"{"v":1,"followed":[]}"#,
                    #"{"v":1,"followed":[],"unfollowed":[],"extra":1}"#,
                    #"{"v":true,"followed":[],"unfollowed":[]}"#,
                    #"{"v":1,"followed":["$a","$a"],"unfollowed":[]}"#,
                    #"{"v":1,"followed":["$a"],"unfollowed":["$a"]}"#,
                    #"{"v":1,"followed":["not-an-event"],"unfollowed":[]}"#,
                    #"{"v":1,"followed":"$a","unfollowed":[]}"#,
                    "not json"] {
            XCTAssertEqual(CompanyThreadAttention.parse(bad), empty, bad)
        }
    }

    func testSettingWritesTheSortedRecordAndMovesTheRoot() throws {
        let start = CompanyThreadAttention(followed: ["$z"], unfollowed: ["$a"])
        let followed = try XCTUnwrap(start.setting("$a", followed: true))
        XCTAssertEqual(followed, CompanyThreadAttention(followed: ["$a", "$z"], unfollowed: []))
        XCTAssertEqual(followed.contentJSON, #"{"followed":["$a","$z"],"unfollowed":[],"v":1}"#)
        let unfollowed = try XCTUnwrap(followed.setting("$z", followed: false))
        XCTAssertEqual(unfollowed.contentJSON, #"{"followed":["$a"],"unfollowed":["$z"],"v":1}"#)
        XCTAssertEqual(CompanyThreadAttention.parse(unfollowed.contentJSON), unfollowed, "round trip")
        XCTAssertNil(start.setting("nope", followed: true))
    }

    func testSettingRefusesPastTheLimit() {
        let full = CompanyThreadAttention(followed: Set((0..<1_000).map { "$e\($0)" }))
        XCTAssertNil(full.setting("$new", followed: true))
        XCTAssertNotNil(full.setting("$e1", followed: true), "already in: still 1000")
    }

    func testFollowRuleUnfollowWinsThenFollowThenAutomatic() {
        let attention = CompanyThreadAttention(followed: ["$f"], unfollowed: ["$u"])
        XCTAssertFalse(attention.isFollowed("$u", automatic: true))
        XCTAssertTrue(attention.isFollowed("$f", automatic: false))
        XCTAssertTrue(attention.isFollowed("$x", automatic: true))
        XCTAssertFalse(attention.isFollowed("$x", automatic: false))
    }

    // MARK: Projection

    func testProjectionReadsUnreadMentionsAndFollowFromTheServer() {
        let threads = CompanyThreads.project(
            roomID: room,
            roots: [(root: message("$r1", at: 100), latest: message("$l1", at: 500), replyCount: 3),
                    (root: message("$r2", at: 200, own: true), latest: nil, replyCount: 0),
                    (root: message("$r3", at: 300), latest: message("$l3", at: 400, mentions: true), replyCount: 1),
                    (root: message("$r1", at: 100), latest: nil, replyCount: 9)],
            attention: CompanyThreadAttention(unfollowed: ["$r2"]),
            activity: [activity("$l1", root: "$r1"), activity("$m1", root: "$r1", kind: .mention),
                       activity("$old", root: "$r3", unread: false),
                       activity("$x", root: "$r1", room: other)])
        XCTAssertEqual(threads.map(\.root.eventID), ["$r1", "$r3", "$r2"], "newest activity first, one row per root")
        XCTAssertEqual(threads[0].lastActivityAt, 500)
        XCTAssertTrue(threads[0].unread)
        XCTAssertEqual(threads[0].highlights, 1)
        XCTAssertTrue(threads[0].followed, "a mention in the thread follows it")
        XCTAssertFalse(threads[1].unread, "read notifications are read")
        XCTAssertTrue(threads[1].followed, "the newest reply names me")
        XCTAssertFalse(threads[2].followed, "my own root, explicitly unfollowed")
        XCTAssertEqual(threads[2].replyCount, 0)
    }

    func testCompanyListIsFencedToTheDirectoryAndCapped() {
        let make = { (roomID: String, id: String, at: Int64) in
            CompanyThread(roomID: roomID, root: self.message(id, at: at), latest: nil, replyCount: 1)
        }
        let list = CompanyThreads.company([make(room, "$a", 1), make(other, "$b", 2), make("!gone:x", "$c", 3)],
                                          allowedRoomIDs: [room, other])
        XCTAssertEqual(list.map(\.root.eventID), ["$b", "$a"])
        let many = (0..<250).map { make(room, "$e\($0)", Int64($0)) }
        XCTAssertEqual(CompanyThreads.company(many, allowedRoomIDs: [room]).count, 200)
    }

    func testFiltersAndBadge() {
        var unread = CompanyThread(roomID: room, root: message("$a", at: 1), latest: nil, replyCount: 1, unread: true)
        let followed = CompanyThread(roomID: room, root: message("$b", at: 2), latest: nil, replyCount: 1,
                                     followed: true)
        XCTAssertEqual(CompanyThreads.filter([unread, followed], by: .recent).count, 2)
        XCTAssertEqual(CompanyThreads.filter([unread, followed], by: .following).map(\.root.eventID), ["$b"])
        XCTAssertEqual(CompanyThreads.filter([unread, followed], by: .unread).map(\.root.eventID), ["$a"])
        XCTAssertEqual(CompanyThreads.badge([unread, followed]), .dot)
        unread.highlights = 2
        XCTAssertEqual(CompanyThreads.badge([unread, followed]), .mention(2))
        XCTAssertEqual(CompanyThreads.badge([followed]), .none)
        XCTAssertFalse(TeamSpaceSidebarEntries(threads: 0, saved: 0, drafts: 0).threads)
        XCTAssertTrue(TeamSpaceSidebarEntries(threads: 1, saved: 0, drafts: 0).threads)
    }

    // MARK: Row overrides

    func testOverridesHoldUntilSyncAgreesOrANewerReplyArrives() {
        let thread = CompanyThread(roomID: room, root: message("$a", at: 1), latest: message("$l", at: 10),
                                   replyCount: 1, unread: true, followed: false)
        let tapped = CompanyThreadOverride(followed: true, unread: false, readAt: 10)
        let shown = tapped.applied(to: thread)
        XCTAssertTrue(shown.followed)
        XCTAssertFalse(shown.unread)
        // Sync has not caught up: both stay.
        XCTAssertEqual(CompanyThreadOverride.reconcile([thread.id: tapped], with: [thread])[thread.id], tapped)
        // Sync agrees on follow and read: nothing left.
        var synced = thread
        synced.followed = true
        synced.unread = false
        XCTAssertTrue(CompanyThreadOverride.reconcile([thread.id: tapped], with: [synced]).isEmpty)
        // A newer reply makes the thread unread again, whatever the tap said.
        let newer = CompanyThread(roomID: room, root: message("$a", at: 1), latest: message("$n", at: 20),
                                  replyCount: 2, unread: true, followed: true)
        XCTAssertTrue(tapped.applied(to: newer).unread)
        XCTAssertTrue(CompanyThreadOverride.reconcile([thread.id: tapped], with: [newer]).isEmpty)
        // Marking read clears its mentions too, until a newer reply.
        var mentioned = thread
        mentioned.highlights = 2
        XCTAssertEqual(tapped.applied(to: mentioned).highlights, 0)
        var newerMention = newer
        newerMention.highlights = 1
        XCTAssertEqual(tapped.applied(to: newerMention).highlights, 1)
        // A thread that is gone drops its override.
        XCTAssertTrue(CompanyThreadOverride.reconcile([thread.id: tapped], with: []).isEmpty)
    }
}
