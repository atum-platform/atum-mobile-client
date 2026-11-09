import XCTest
@testable import AtumChat

/// Every row of the §2.5 table, plus the hotfix's transcript rules this
/// policy took over from `MobileTranscriptFollowPolicy` (one source of truth).
final class FollowPolicyTests: XCTestCase {
    private let screen = 700.0

    private func geometry(_ distance: Double, _ motion: ScrollMotion = .idle) -> FollowInput {
        .geometry(distanceFromBottom: distance, distanceFromTop: screen * 5, viewportHeight: screen, motion: motion)
    }

    private func detached(by distance: Double = 300) -> FollowPolicy {
        var policy = FollowPolicy()
        policy.handle(geometry(distance, .user))
        return policy
    }

    // MARK: opened

    func testOpenedScrollsToTheBottomAndReattaches() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(.opened), .scrollToBottom(animated: false))
        var away = detached()
        XCTAssertEqual(away.handle(.opened), .scrollToBottom(animated: false))
        XCTAssertEqual(away.state, .following)
    }

    // MARK: geometry

    func testNearTheBottomStaysOrReattachesAndClearsTheCount() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(geometry(0)), .none)
        XCTAssertEqual(policy.state, .following)
        var away = detached()
        away.handle(.appended(count: 2, localEcho: false))
        XCTAssertEqual(away.handle(geometry(FollowPolicy.nearBottomPoints, .user)), .none)
        XCTAssertEqual(away.state, .following)
        XCTAssertEqual(away.pill, .hidden)
    }

    func testThePersonScrollingAwayDetachesOnce() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(geometry(300, .user)), .none)
        XCTAssertEqual(policy.state, .detached(newCount: 0))
        policy.handle(.appended(count: 1, localEcho: false))
        policy.handle(geometry(900, .user))
        XCTAssertEqual(policy.state, .detached(newCount: 1), "scrolling further keeps the count")
    }

    func testAnUnrequestedAnimatedScrollCountsAsThePersons() {
        // The system's scroll-to-top is animated; it must not be fought.
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(geometry(400, .animating)), .none)
        XCTAssertEqual(policy.state, .detached(newCount: 0))
    }

    func testGrowthWithNobodyScrollingStaysPinnedWhileFollowingOnly() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(geometry(180)), .scrollToBottom(animated: false),
                       "a new row, the keyboard or the composer grew while following")
        XCTAssertEqual(policy.state, .following)
        var away = detached()
        XCTAssertEqual(away.handle(geometry(520)), .none, "a message arriving while scrolled up never moves the view")
    }

    func testNonFiniteGeometryIsIgnoredAndShortTranscriptsAreAtTheBottom() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(geometry(-400, .user)), .none)
        XCTAssertEqual(policy.state, .following)
        XCTAssertEqual(policy.handle(geometry(.nan)), .none)
        XCTAssertEqual(policy.handle(geometry(.infinity, .user)), .none)
        XCTAssertEqual(policy.state, .following)
    }

    // MARK: appended

    func testASendFromThisDeviceAlwaysShowsIt() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(.appended(count: 0, localEcho: true)), .scrollToBottom(animated: false))
        var away = detached(by: 900)
        away.handle(.appended(count: 3, localEcho: false))
        XCTAssertEqual(away.handle(.appended(count: 0, localEcho: true)), .scrollToBottom(animated: false))
        XCTAssertEqual(away.state, .following)
    }

    func testMyMessageFromAnotherDeviceIsCountedNotFollowed() {
        // localEcho is false for the Mac's copy: same Matrix user, other device.
        var away = detached()
        XCTAssertEqual(away.handle(.appended(count: 1, localEcho: false)), .none)
        XCTAssertEqual(away.state, .detached(newCount: 1))
        XCTAssertEqual(away.pill, .count(1))
    }

    func testIncomingWhileFollowingStaysPinnedHoweverTall() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(.appended(count: 1, localEcho: false)), .scrollToBottom(animated: false))
        // The answer is two screens tall: its layout pushes the end down with
        // nobody scrolling, and the view follows it to its end (B3).
        XCTAssertEqual(policy.handle(geometry(screen * 2)), .scrollToBottom(animated: false))
        XCTAssertEqual(policy.state, .following)
        XCTAssertEqual(policy.pill, .hidden)
    }

    func testIncomingWhileDetachedAddsToTheCountAndNoticesAddNothing() {
        var away = detached()
        away.handle(.appended(count: 2, localEcho: false))
        away.handle(.appended(count: 0, localEcho: false)) // a notice
        XCTAssertEqual(away.state, .detached(newCount: 2))
    }

    // MARK: prepended and in-place changes

    func testPrependedNeverScrollsWithoutAnAnchor() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(.prepended), .none)
        var away = detached()
        XCTAssertEqual(away.handle(.prepended), .none)
        XCTAssertEqual(away.state, .detached(newCount: 0))
    }

    func testPrependedWhileDetachedLeavesTheMeasuredAnchorToTheView() {
        // §2.4 Prepend: TranscriptView holds its measured anchor directly.
        var away = detached(by: 3000)
        XCTAssertEqual(away.handle(.prepended), .none)
        XCTAssertEqual(away.state, .detached(newCount: 0), "older history never counts")
    }

    func testPrependedWhileFollowingIsLeftToTheBottomRule() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.handle(.prepended), .none)
        XCTAssertEqual(policy.handle(geometry(400)), .scrollToBottom(animated: false),
                       "older rows above a short chat pushed the bottom down")
    }

    func testTheTopDistanceIsForPaginationOnly() {
        for motion: [ScrollMotion] in [[.user], [.idle], [.user, .idle]] {
            var nearTop = FollowPolicy()
            var farFromTop = FollowPolicy()
            for step in motion {
                XCTAssertEqual(
                    nearTop.handle(.geometry(distanceFromBottom: 300, distanceFromTop: 0, viewportHeight: screen,
                                             motion: step)),
                    farFromTop.handle(.geometry(distanceFromBottom: 300, distanceFromTop: 50_000,
                                                viewportHeight: screen, motion: step)))
            }
            XCTAssertEqual(nearTop, farFromTop)
        }
    }

    func testTypingEditsKeyboardComposerAndResetKeepTheLastRowVisibleWhileFollowingOnly() {
        for input: FollowInput in [.typingShown, .inPlaceEdit, .keyboardWillShow, .composerGrew, .reset] {
            var policy = FollowPolicy()
            XCTAssertEqual(policy.handle(input), .scrollToBottom(animated: false), "\(input)")
            var away = detached()
            XCTAssertEqual(away.handle(input), .none, "\(input)")
            XCTAssertEqual(away.state, .detached(newCount: 0))
        }
    }

    // MARK: jump

    func testJumpTappedAnimatesToTheBottomAndItsAnimationDoesNotDetach() {
        var away = detached(by: 2000)
        away.handle(.appended(count: 3, localEcho: false))
        XCTAssertEqual(away.handle(.jumpTapped), .scrollToBottom(animated: true))
        XCTAssertEqual(away.state, .following)
        XCTAssertEqual(away.pill, .hidden)
        XCTAssertEqual(away.handle(geometry(1200, .animating)), .none)
        XCTAssertEqual(away.state, .following, "the pill's own animation is not the person scrolling")
        away.handle(geometry(0))
        // Once at the bottom, a later animated scroll away is the person's again.
        away.handle(geometry(500, .animating))
        XCTAssertEqual(away.state, .detached(newCount: 0))
    }

    func testThePersonInterruptingTheJumpDetachesAgain() {
        var away = detached(by: 2000)
        away.handle(.jumpTapped)
        away.handle(geometry(1500, .user))
        XCTAssertEqual(away.state, .detached(newCount: 0))
    }

    // MARK: pill

    func testThePillIsAnArrowOnlyOnceMoreThanAScreenUpAndACountFromOne() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.pill, .hidden)
        policy.handle(geometry(300, .user))
        XCTAssertEqual(policy.state, .detached(newCount: 0))
        XCTAssertEqual(policy.pill, .hidden, "less than one screen up")
        policy.handle(geometry(screen + 1, .user))
        XCTAssertEqual(policy.pill, .arrow)
        policy.handle(.appended(count: 1, localEcho: false))
        XCTAssertEqual(policy.pill, .count(1))
        policy.handle(geometry(100, .user))
        XCTAssertEqual(policy.pill, .count(1), "the count shows at any distance")
    }

    func testTheTranscriptAccessibilityValue() {
        var policy = FollowPolicy()
        XCTAssertEqual(policy.accessibilityValue, "following")
        policy.handle(geometry(300, .user))
        policy.handle(.appended(count: 3, localEcho: false))
        XCTAssertEqual(policy.accessibilityValue, "detached:3")
    }

    // MARK: snapshot change mapping

    func testEachSnapshotChangeMapsToItsInput() {
        XCTAssertEqual(FollowInput.from(.reset), .reset)
        XCTAssertEqual(FollowInput.from(.appendedAtEnd(count: 2, localEcho: false)), .appended(count: 2, localEcho: false))
        XCTAssertEqual(FollowInput.from(.prependedAtStart(count: 20)), .prepended)
        XCTAssertEqual(FollowInput.from(.inPlace), .inPlaceEdit)
        XCTAssertEqual(FollowInput.from(.mixed(appendedAtEnd: 1, localEcho: false)), .appended(count: 1, localEcho: false))
        XCTAssertEqual(FollowInput.from(.mixed(appendedAtEnd: 0, localEcho: true)), .appended(count: 0, localEcho: true))
        XCTAssertEqual(FollowInput.from(.mixed(appendedAtEnd: 0, localEcho: false)), .inPlaceEdit)
    }

    func testAnAnswerArrivingAboveMyFailedMessageIsCounted() throws {
        // B4: matrix-sdk-ui inserts remote events above a parked local echo.
        var buffer = TimelineBuffer(items: [F.mine("q"), F.echo("f", delivery: .failed(isRecoverable: true))])
        var policy = FollowPolicy()
        policy.handle(geometry(2000, .user))
        let change = try buffer.apply([.insert(index: 1, item: F.text("a", from: F.agent, replyTo: "$q"))])
        XCTAssertEqual(policy.handle(.from(change)), .none, "the view does not move")
        XCTAssertEqual(policy.state, .detached(newCount: 1))
        XCTAssertEqual(policy.pill, .count(1))
    }

    func testOlderHistoryWhileDetachedDoesNotMovePolicyOrIncrementThePill() throws {
        var buffer = TimelineBuffer(items: [F.divider("d1"), F.text("x", from: F.agent), F.mine("y")])
        var policy = FollowPolicy()
        policy.handle(geometry(1500, .user))
        let change = try buffer.apply([.pushFront(F.text("o1", from: F.agent)), .pushFront(F.mine("o2")),
                                       .remove(index: 2), .pushFront(F.divider("d0"))])
        XCTAssertEqual(policy.handle(.from(change)), .none)
        XCTAssertEqual(policy.pill, .arrow)
    }

    func testThreeIncomingWhileScrolledUpThreeScreensReadsThree() throws {
        // G-scroll check 3 and U3, as data: the buffer's change drives the count.
        var buffer = TimelineBuffer(items: [F.mine("q")])
        var policy = FollowPolicy()
        policy.handle(geometry(screen * 3, .user))
        for id in ["a", "b", "c"] {
            let change = try buffer.apply([.pushBack(F.text(id, from: F.agent))])
            XCTAssertEqual(policy.handle(.from(change)), .none)
        }
        policy.handle(.typingShown)
        XCTAssertEqual(policy.pill, .count(3))
    }

    // MARK: what the store republishes (the layout loop guard)

    /// The store republishes the policy only when what a view shows changes:
    /// the follow state or the pill. A scroll frame that moves the distances
    /// and nothing else is not republished (S1 checkpoint 1 §4: republishing
    /// it from inside a layout pass laid the screen out again, forever).
    func testOnlyAChangeInStateOrPillNeedsPublishing() {
        var policy = FollowPolicy()
        let published = policy
        policy.handle(geometry(3, .user))
        XCTAssertNotEqual(policy, published, "the distances moved")
        XCTAssertFalse(policy.needsPublishing(over: published), "still following")

        policy.handle(geometry(300, .user))
        XCTAssertTrue(policy.needsPublishing(over: published), "detached")
        let detachedNear = policy
        policy.handle(geometry(320, .user))
        XCTAssertFalse(policy.needsPublishing(over: detachedNear), "detached(0), still no arrow")
        policy.handle(geometry(screen * 2, .user))
        XCTAssertEqual(policy.pill, .arrow)
        XCTAssertTrue(policy.needsPublishing(over: detachedNear), "the arrow appeared with the same state")
        let arrow = policy
        policy.handle(.appended(count: 2, localEcho: false))
        XCTAssertTrue(policy.needsPublishing(over: arrow), "the count changed")
    }
}
