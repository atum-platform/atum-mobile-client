import XCTest
@testable import AtumChat

/// B10–B12: who is typing, where it shows, and the typing-out throttle.
final class TypingTests: XCTestCase {
    private let names = [F.agent: "Atum", F.friend: "Minh Anh", F.other: "Lan", F.me: "Tôi"]

    // MARK: TypingNames

    func testMyOwnUserIsDroppedWhateverTheSDKReports() {
        XCTAssertEqual(TypingNames.others([F.me], ownUserID: F.me), [])
        XCTAssertEqual(TypingNames.others([F.agent, F.me], ownUserID: F.me), [F.agent])
        XCTAssertEqual(TypingNames.displayNames([F.me, F.agent], ownUserID: F.me, kind: .assistant, roomTitle: "Atum",
                                                name: { self.names[$0] }),
                       ["Atum"])
    }

    func testOrderIsTheSDKsAndRepeatsAndEmptyIDsAreDropped() {
        XCTAssertEqual(TypingNames.others([F.friend, "", F.other, F.friend], ownUserID: F.me), [F.friend, F.other])
    }

    func testATyperWithoutAUsableNameIsLeftOffThePeopleLine() {
        for kind in [RoomKind.person, .group] {
            let shown = TypingNames.displayNames([F.friend, "@nameless:example.test", F.other], ownUserID: F.me,
                                                 kind: kind, roomTitle: "Nhóm", name: { self.names[$0] })
            XCTAssertEqual(shown, ["Minh Anh", "Lan"], "\(kind)")
            XCTAssertEqual(TypingNames.displayNames([F.friend], ownUserID: F.me, kind: kind, roomTitle: "Nhóm",
                                                    name: { _ in "" }), [], "\(kind)")
        }
    }

    func testAnUnnamedAgentOrBotStillShowsTheDotsUnderTheRoomTitle() {
        for kind in [RoomKind.assistant, .appBot] {
            let names = TypingNames.displayNames([F.agent], ownUserID: F.me, kind: kind, roomTitle: "Moon",
                                                 name: { _ in nil })
            XCTAssertEqual(names, ["Moon"], "\(kind): before the profile lookup lands")
            let rows = Projection.rows([F.text("a", from: F.agent)], context: F.assistantRoom(),
                                       typingNames: TypingNames.presentation(kind: kind, names: names).rowNames)
            XCTAssertEqual(rows.last?.item.kind, .typing(names: ["Moon"]), "\(kind)")
            XCTAssertEqual(TypingNames.displayNames([F.agent, "@helper:example.test"], ownUserID: F.me, kind: kind,
                                                    roomTitle: "Moon", name: { _ in nil }), ["Moon"],
                           "\(kind): the title once")
            XCTAssertEqual(TypingNames.displayNames([F.agent], ownUserID: F.me, kind: kind, roomTitle: "Moon",
                                                    name: { self.names[$0] }), ["Atum"],
                           "\(kind): a known name wins")
            XCTAssertEqual(TypingNames.displayNames([F.me], ownUserID: F.me, kind: kind, roomTitle: "Moon",
                                                    name: { _ in nil }), [],
                           "\(kind): my own typing never shows")
        }
    }

    func testPeopleLineNamesUpToThreeThenSaysMany() {
        XCTAssertEqual(TypingNames.line([]), .nobody)
        XCTAssertEqual(TypingNames.line(["A"]), .names(["A"]))
        XCTAssertEqual(TypingNames.line(["A", "B", "C"]), .names(["A", "B", "C"]))
        XCTAssertEqual(TypingNames.line(["A", "B", "C", "D"]), .many)
    }

    func testAgentsAndBotsGetTheRowPeopleGetTheLine() {
        for kind in [RoomKind.assistant, .appBot] {
            let presentation = TypingNames.presentation(kind: kind, names: ["Atum"])
            XCTAssertEqual(presentation, TypingPresentation(rowNames: ["Atum"], line: .nobody), "\(kind)")
        }
        for kind in [RoomKind.person, .group] {
            let presentation = TypingNames.presentation(kind: kind, names: ["Minh Anh"])
            XCTAssertEqual(presentation, TypingPresentation(rowNames: [], line: .names(["Minh Anh"])), "\(kind)")
        }
        XCTAssertEqual(TypingNames.presentation(kind: .group, names: ["A", "B", "C", "D"]).line, .many)
    }

    func testPeopleRoomsNeverGetATypingRowInTheTranscript() {
        let items = [F.text("a", from: F.friend)]
        let presentation = TypingNames.presentation(kind: .person, names: ["Minh Anh"])
        let rows = Projection.rows(items, context: F.personRoom(), typingNames: presentation.rowNames)
        XCTAssertFalse(rows.contains { if case .typing = $0.item.kind { true } else { false } })
        let agentRows = Projection.rows(items, context: F.assistantRoom(),
                                        typingNames: TypingNames.presentation(kind: .assistant, names: ["Atum"]).rowNames)
        XCTAssertEqual(agentRows.last?.item.kind, .typing(names: ["Atum"]))
    }

    // MARK: TypingNoticePolicy

    func testAgentAndBotRoomsSendNothing() {
        for kind in [RoomKind.assistant, .appBot] {
            var policy = TypingNoticePolicy(kind: kind)
            XCTAssertEqual(policy.draftChanged("xin chào", now: 0), .none, "\(kind)")
            XCTAssertEqual(policy.sent(), .none)
            XCTAssertNil(policy.pauseDeadline)
        }
    }

    func testEditingSendsAtMostOneNoticeEveryThreeSeconds() {
        var policy = TypingNoticePolicy(kind: .person)
        XCTAssertEqual(policy.draftChanged("x", now: 10), .typing)
        XCTAssertEqual(policy.draftChanged("xi", now: 11), .none)
        XCTAssertEqual(policy.draftChanged("xin", now: 12.9), .none)
        XCTAssertEqual(policy.draftChanged("xin ", now: 13), .typing, "still typing after 3 s keeps it alive")
        XCTAssertEqual(policy.draftChanged("xin c", now: 14), .none)
        XCTAssertTrue(policy.isTyping)
    }

    func testAWhitespaceDraftIsEmptyAndClearingStops() {
        var policy = TypingNoticePolicy(kind: .group)
        XCTAssertEqual(policy.draftChanged("  \n", now: 0), .none, "nothing to stop yet")
        XCTAssertEqual(policy.draftChanged("a", now: 1), .typing)
        XCTAssertEqual(policy.draftChanged(" ", now: 2), .stopped)
        XCTAssertEqual(policy.draftChanged("", now: 3), .none, "stopped only once")
        XCTAssertEqual(policy.draftChanged("b", now: 3.5), .typing, "a new draft starts at once")
    }

    func testSendingAndLeavingStop() {
        var policy = TypingNoticePolicy(kind: .person)
        _ = policy.draftChanged("a", now: 0)
        XCTAssertEqual(policy.sent(), .stopped)
        XCTAssertEqual(policy.sent(), .none)
        _ = policy.draftChanged("b", now: 1)
        XCTAssertEqual(policy.left(), .stopped)
        XCTAssertEqual(policy.left(), .none)
    }

    func testASixSecondPauseStopsAndEachEditMovesTheDeadline() {
        var policy = TypingNoticePolicy(kind: .person)
        _ = policy.draftChanged("a", now: 0)
        XCTAssertEqual(policy.pauseDeadline, 6)
        _ = policy.draftChanged("ab", now: 2)
        XCTAssertEqual(policy.pauseDeadline, 8)
        XCTAssertEqual(policy.tick(now: 6), .none, "the last edit was at 2 s")
        XCTAssertEqual(policy.tick(now: 8), .stopped)
        XCTAssertNil(policy.pauseDeadline)
        XCTAssertEqual(policy.tick(now: 20), .none)
    }
}
