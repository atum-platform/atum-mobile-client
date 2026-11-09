import XCTest
@testable import AtumChat

/// B12 across a new session's typing controller: only editing a non-empty
/// draft sends a typing notice, so an untouched saved draft is never replayed
/// into the controller a chat open or a token renewal builds.
final class DraftTypingReplayTests: XCTestCase {
    private let now: TimeInterval = 10_000

    func testANewSessionWithAnUntouchedDraftSendsNoNotice() {
        // Opening a chat with a saved draft: no edit in this visit.
        XCTAssertFalse(DraftTypingReplay.replays(draft: "saved text", lastEditAt: nil, now: now))
        // A renewal minutes after the last keystroke.
        XCTAssertFalse(DraftTypingReplay.replays(draft: "saved text", lastEditAt: now - 240, now: now))
        // Exactly at the typing-out pause, the notice would already be over.
        XCTAssertFalse(DraftTypingReplay.replays(draft: "saved text",
                                                 lastEditAt: now - TypingNoticePolicy.pauseSeconds, now: now))
    }

    func testARenewalWhileThePersonIsStillTypingKeepsTheNoticeAlive() {
        XCTAssertTrue(DraftTypingReplay.replays(draft: "typing", lastEditAt: now - 1, now: now))
        XCTAssertTrue(DraftTypingReplay.replays(draft: "typing",
                                                lastEditAt: now - TypingNoticePolicy.pauseSeconds + 0.1, now: now))
    }

    func testAnEmptyOrBlankDraftIsNeverReplayed() {
        XCTAssertFalse(DraftTypingReplay.replays(draft: "", lastEditAt: now, now: now))
        XCTAssertFalse(DraftTypingReplay.replays(draft: "  \n", lastEditAt: now, now: now))
    }

    func testAClockThatMovedBackwardsReplaysNothing() {
        XCTAssertFalse(DraftTypingReplay.replays(draft: "typing", lastEditAt: now + 5, now: now))
    }

    func testAReplayedDraftSendsExactlyWhatAnEditWouldOnAFreshPolicy() {
        // What the new controller does with a replayed draft: one typing
        // notice, as the person's own edit would send.
        var policy = TypingNoticePolicy(kind: .person)
        XCTAssertEqual(policy.draftChanged("typing", now: now), .typing)
    }
}
