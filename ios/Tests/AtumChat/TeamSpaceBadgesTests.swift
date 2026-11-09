import XCTest
@testable import AtumChat

/// Workplace unread and mention marks (U1/U4): the channel row uses Home's
/// `Badge` rule; the company and the tab fold their channels.
final class TeamSpaceBadgesTests: XCTestCase {
    private func input(h: Int = 0, n: Int = 0, activity: Bool = false, muted: Bool = false) -> Badge.Input {
        Badge.Input(highlights: h, notifications: n, hasUnreadActivity: activity, isMuted: muted)
    }

    func testChannelRowsReuseTheHomeRuleAndBoldOnlyWhatMatters() {
        XCTAssertEqual(Badge.mark(for: input(h: 2, n: 5)), .mention(5))
        XCTAssertTrue(TeamSpaceBadges.isBold(.mention(1)))
        XCTAssertTrue(TeamSpaceBadges.isBold(.count(3)))
        XCTAssertTrue(TeamSpaceBadges.isBold(.dot))
        XCTAssertFalse(TeamSpaceBadges.isBold(.quietDot))
        XCTAssertFalse(TeamSpaceBadges.isBold(.none))
    }

    func testACompanyShowsMentionsAsAPillElseADot() {
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(h: 1, n: 2), input(h: 1, n: 1)]), .mention(3))
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(n: 4), input()]), .dot)
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(n: 4, muted: true)]), .quietDot)
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(), input()]), .none)
        XCTAssertEqual(TeamSpaceBadges.company(channels: []), .none)
    }

    /// The one rule desktop uses for a company's channels: a mention is a
    /// number capped at 99+, anything else unread is a dot.
    func testTheCompanyBadgeRuleAcrossMentionCounts() {
        func text(_ badge: Badge) -> String? { badge.pillNumber.map(Badge.pillText) }

        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(h: 0, n: 0)]), .none, "0 mentions: nothing")
        let one = TeamSpaceBadges.company(channels: [input(h: 1, n: 1)])
        XCTAssertEqual(one, .mention(1))
        XCTAssertEqual(text(one), "1")
        let ninetyNine = TeamSpaceBadges.company(channels: [input(h: 99, n: 99)])
        XCTAssertEqual(ninetyNine, .mention(99))
        XCTAssertEqual(text(ninetyNine), "99", "99 prints as itself")
        let hundred = TeamSpaceBadges.company(channels: [input(h: 60, n: 60), input(h: 40, n: 41)])
        XCTAssertEqual(hundred, .mention(101))
        XCTAssertEqual(text(hundred), "99+", "100 and more print as 99+")
        XCTAssertEqual(text(TeamSpaceBadges.company(channels: [input(h: 100, n: 100)])), "99+")
        XCTAssertTrue(hundred.isCapped)
        XCTAssertFalse(ninetyNine.isCapped)
    }

    func testUnreadWithoutMentionsIsADotNeverANumber() {
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(n: 250)]), .dot, "250 plain notifications: still a dot")
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(activity: true)]), .quietDot)
        XCTAssertEqual(TeamSpaceBadges.company(channels: [
            Badge.Input(isMarkedUnread: true)]), .dot)
        XCTAssertNil(TeamSpaceBadges.company(channels: [input(n: 250)]).pillNumber)
    }

    func testAMutedChannelCountsOnlyItsMentionsAndTheNumberIsTheLargerTotal() {
        // Desktop sums notifications (a muted channel adds only its mentions),
        // and a mention's number is the larger of that sum and the mentions.
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(h: 2, n: 9, muted: true), input(n: 3)]), .mention(5))
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(h: 1, n: 1), input(n: 7)]), .mention(8))
        XCTAssertEqual(TeamSpaceBadges.company(channels: [input(h: 5, n: 2)]), .mention(5))
    }

    func testTheSwitcherShowsNoMarkOnTheCompanyYouAreIn() {
        XCTAssertEqual(TeamSpaceBadges.switcherMark(.mention(4), isActive: true), .none)
        XCTAssertEqual(TeamSpaceBadges.switcherMark(.dot, isActive: true), .none)
        XCTAssertEqual(TeamSpaceBadges.switcherMark(.mention(4), isActive: false), .mention(4))
        XCTAssertEqual(TeamSpaceBadges.switcherMark(.dot, isActive: false), .dot)
        XCTAssertEqual(TeamSpaceBadges.switcherMark(.none, isActive: false), .none)
    }

    func testTheTabShowsMentionsThenInvitationsThenADot() {
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [.mention(2), .dot], pendingInvitations: 1), .mention(2))
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [.dot], pendingInvitations: 2), .count(2))
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [.dot, .none], pendingInvitations: 0), .dot)
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [.quietDot], pendingInvitations: 0), .none)
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [], pendingInvitations: 0), .none)
    }

    /// The scripted Home roster (Anka active, Studio): the tab folds every company
    /// through `company(channels:)`, never through the switcher's hide-the-active rule.
    func testTheTabCountsEveryCompanyIncludingTheActiveOne() {
        let anka = TeamSpaceBadges.company(channels: [
            input(h: 2, n: 4, activity: true), input(n: 3, activity: true),
            input(n: 5, activity: true, muted: true), input(),
        ])
        let studio = TeamSpaceBadges.company(channels: [input(n: 1, activity: true)])
        XCTAssertEqual(anka, .mention(7), "4 + 3 notifications; the muted channel adds only its mentions")
        XCTAssertEqual(studio, .dot)
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [anka, studio], pendingInvitations: 1), .mention(7))
        XCTAssertEqual(TeamSpaceBadges.switcherMark(anka, isActive: true), .none, "the sheet may hide it")
        XCTAssertEqual(TeamSpaceBadges.tab(companies: [studio], pendingInvitations: 0), .dot,
                       "without the active company the tab would lose its mentions")
    }

    func testCompanyMentionsCountTowardTheAppIconLikeHome() {
        let rows = [
            Badge.AppIconRow(input: input(h: 1, n: 3)),
            Badge.AppIconRow(input: input(n: 2)),
            Badge.AppIconRow(input: input(h: 4, n: 4, muted: true)),
        ]
        XCTAssertEqual(Badge.appIconCount(rows), 5)
    }
}
