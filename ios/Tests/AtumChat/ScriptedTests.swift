import XCTest
@testable import AtumChat

/// The scripted source (plan §2.10): every scenario plays through the real
/// reducer and projection, the SDK's placement rules hold, and the scenarios
/// carry what their U checks need.
final class ScriptedTests: XCTestCase {
    private typealias Cast = ScriptedCast
    private typealias Output = ScriptedTimelinePlayer.Output

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2027-01-15 15:00 UTC: a fixed launch time, far from midnight.
    private let env = ScriptedEnvironment(reference: Date(timeIntervalSince1970: 1_800_025_200), calendar: utc)

    private func script(_ name: String) throws -> ScriptedScript {
        try XCTUnwrap(ScriptedScenarios.selection(named: name, environment: env)?.chat, name)
    }

    private func player(_ script: ScriptedScript) -> ScriptedTimelinePlayer {
        ScriptedTimelinePlayer(script: script, reference: env.reference, calendar: env.calendar)
    }

    /// Mirrors what a store does: applies every batch to its own buffer and
    /// returns each batch's change kind.
    private struct Mirror {
        var buffer = TimelineBuffer()
        var typing: [String] = []
        var pagination: PaginationState?
        var changes: [SnapshotChange] = []

        mutating func take(_ outputs: [Output], file: StaticString = #filePath, line: UInt = #line) {
            for output in outputs {
                switch output {
                case let .diffs(diffs):
                    do { changes.append(try buffer.apply(diffs)) } catch {
                        XCTFail("batch did not apply: \(error) \(ChatDiff.probeShape(diffs))", file: file, line: line)
                    }
                case let .typing(userIDs): typing = userIDs
                case let .pagination(status): pagination = status
                }
            }
        }
    }

    // MARK: Registry

    func testEveryNamedScenarioBuildsAndUnknownNamesDoNot() {
        for name in ScriptedScenarios.allNames {
            let selection = ScriptedScenarios.selection(named: name, environment: env)
            XCTAssertNotNil(selection, name)
            XCTAssertTrue(selection?.chat != nil || selection?.roster != nil, name)
            XCTAssertEqual(selection?.chat?.name ?? name, name)
        }
        XCTAssertNil(ScriptedScenarios.selection(named: "chat.nope", environment: env))
        XCTAssertEqual(Set(ScriptedScenarios.allNames).count, ScriptedScenarios.allNames.count)
        XCTAssertTrue(ScriptedScenarios.allNames.contains("chat.actions"))
        XCTAssertTrue(ScriptedScenarios.allNames.contains("chat.kinds"))
    }

    func testLaunchArgumentsPickTheS1ScenariosThroughTheEnum() {
        let arguments = ScriptedScenarios.arguments(name: ScriptedScenarios.chatKinds)
        XCTAssertEqual(arguments, ["-AtumUITestNoAnimations", "-AtumScripted", "chat.kinds"])
        XCTAssertEqual(AtumLaunchArguments(arguments).scriptedScenario, .chatKinds,
                       "the day-1 amendment added it to the enum")
        XCTAssertEqual(AtumLaunchArguments.arguments(scenario: .chatActions),
                       ScriptedScenarios.arguments(name: ScriptedScenarios.chatActions))
        XCTAssertNil(AtumLaunchArguments(ScriptedScenarios.arguments(name: "chat.nope")).scriptedScenario)
        XCTAssertTrue(AtumLaunchArguments(arguments).disablesAnimations)
        XCTAssertEqual(ScriptedScenarios.name(in: arguments), "chat.kinds")
        XCTAssertEqual(ScriptedScenarios.selection(arguments: arguments, environment: env)?.chat?.name, "chat.kinds")
        XCTAssertNil(ScriptedScenarios.name(in: ["-AtumScripted"]))
        XCTAssertNil(ScriptedScenarios.selection(arguments: [], environment: env))
        let frozen = AtumLaunchArguments.arguments(scenario: .chatLong)
        XCTAssertEqual(ScriptedScenarios.name(in: frozen), "chat.long")
    }

    // MARK: Every scenario plays cleanly

    func testEveryChatScenarioPlaysThroughWithBatchesThatFitAndUniqueIDs() throws {
        for name in ScriptedScenarios.allNames {
            guard let script = ScriptedScenarios.selection(named: name, environment: env)?.chat else { continue }
            var player = player(script)
            var mirror = Mirror()
            mirror.take(player.open())
            mirror.take(player.advance(to: 120))
            while player.hasOlderPages {
                mirror.take(player.beginPagination())
                mirror.take(player.servePage().outputs)
            }
            XCTAssertEqual(mirror.buffer, player.buffer, name)
            let ids = mirror.buffer.items.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(name): duplicate IDs")
            XCTAssertEqual(mirror.pagination, .idle(hitTimelineStart: true), name)
            XCTAssertEqual(mirror.buffer.items.first?.kind, .timelineStart, "\(name): the start header leads")
            XCTAssertTrue(mirror.typing.isEmpty, "\(name): typing ends")
            assertOneDividerPerDay(mirror.buffer.items, name)
            for item in mirror.buffer.items where item.kind.isEventContent {
                XCTAssertTrue(item.sender.hasSuffix(":atum.test"), "\(name): synthetic senders only")
                XCTAssertEqual(item.isOwn, item.sender == script.context.ownUserID, "\(name) \(item.id)")
            }
        }
    }

    private func assertOneDividerPerDay(_ items: [ChatItem], _ name: String, file: StaticString = #filePath,
                                        line: UInt = #line) {
        var days = Set<Date>()
        var currentDay: Date?
        for item in items {
            if case let .dayDivider(day) = item.kind {
                XCTAssertTrue(days.insert(day).inserted, "\(name): two dividers for one day", file: file, line: line)
                currentDay = day
            } else if item.kind.isEventContent {
                XCTAssertEqual(currentDay, env.calendar.startOfDay(for: item.timestamp),
                               "\(name): \(item.id) sits under the wrong day", file: file, line: line)
            }
        }
    }

    // MARK: chat.long (G-scroll)

    func testChatLongHasFiveHundredMixedMessagesAndLoadsThemInPagesThatPrepend() throws {
        let long = try script(ScriptedScenario.chatLong.rawValue)
        let allEvents = (long.initial + long.olderPages.joined()).filter(\.kind.isEventContent)
        XCTAssertEqual(allEvents.count, 500)
        XCTAssertEqual(long.initial.filter(\.kind.isEventContent).count, 120)
        XCTAssertTrue(long.olderPages.allSatisfy { $0.filter(\.kind.isEventContent).count <= 20 })
        XCTAssertTrue(allEvents.contains { if case .image = $0.kind { true } else { false } }, "image boxes")
        XCTAssertTrue(allEvents.contains { if case .file = $0.kind { true } else { false } }, "file rows")
        XCTAssertTrue(allEvents.contains { $0.body.contains("```swift") && $0.body.split(separator: "\n").count >= 10 },
                      "long code blocks")
        XCTAssertTrue(allEvents.contains { $0.kind == .notice }, "working lines")
        XCTAssertGreaterThanOrEqual(Set(allEvents.map { env.calendar.startOfDay(for: $0.timestamp) }).count, 7)

        var player = player(long)
        var mirror = Mirror()
        mirror.take(player.open())
        XCTAssertEqual(mirror.changes, [.reset])
        XCTAssertEqual(mirror.pagination, .idle(hitTimelineStart: false))
        var pages = 0
        while player.hasOlderPages {
            mirror.take(player.beginPagination())
            XCTAssertEqual(mirror.pagination, .paginating)
            let result = player.servePage()
            mirror.take(result.outputs)
            pages += 1
            guard case .prependedAtStart = mirror.changes.last else {
                return XCTFail("page \(pages) was \(String(describing: mirror.changes.last)), not a prepend")
            }
            XCTAssertEqual(result.hitTimelineStart, !player.hasOlderPages)
        }
        XCTAssertEqual(pages, long.olderPages.count)
        XCTAssertEqual(mirror.buffer.items.filter(\.kind.isEventContent).count, 500)
        XCTAssertEqual(player.servePage().hitTimelineStart, true, "asking again at the start changes nothing")
    }

    func testChatLongEventsServeTheGScrollChecks() throws {
        let long = try script(ScriptedScenario.chatLong.rawValue)
        var player = player(long)
        var mirror = Mirror()
        mirror.take(player.open())

        mirror.take(player.advance(to: 4))
        XCTAssertEqual(mirror.typing, [Cast.atum], "check 2: dots first")
        mirror.take(player.advance(to: 6))
        XCTAssertEqual(mirror.changes.last, .appendedAtEnd(count: 1, localEcho: false))
        XCTAssertTrue(mirror.typing.isEmpty)
        let rows = Projection.rows(mirror.buffer.items, context: long.context)
        XCTAssertEqual(rows.last?.id, "chat.long.step-01")
        XCTAssertFalse(rows.last?.showsQuote ?? true, "an answer under its question needs no quote")

        // Check 3: scrolled up three screens, three messages then the dots.
        var follow = FollowPolicy()
        follow.handle(.geometry(distanceFromBottom: 2100, distanceFromTop: 9000, viewportHeight: 700, motion: .user))
        let before = mirror.changes.count
        mirror.take(player.advance(to: 23))
        for change in mirror.changes[before...] { follow.handle(FollowInput.from(change)) }
        XCTAssertEqual(follow.pill, .count(3))
        XCTAssertEqual(mirror.typing, [Cast.atum])
        mirror.take(player.advance(to: 30))
        XCTAssertTrue(mirror.typing.isEmpty)

        // Check 7: the working line shows, is edited in place, then hides.
        mirror.take(player.advance(to: 41))
        var visible = Projection.rows(mirror.buffer.items, context: long.context).map(\.id)
        XCTAssertTrue(visible.contains("chat.long.step-06"))
        mirror.take(player.advance(to: 43))
        XCTAssertEqual(mirror.changes.last, .inPlace)
        XCTAssertEqual(mirror.buffer.items.first { $0.id == "chat.long.step-06" }?.body, "Đang xử lý… sắp xong")
        mirror.take(player.advance(to: 46))
        visible = Projection.rows(mirror.buffer.items, context: long.context).map(\.id)
        XCTAssertFalse(visible.contains("chat.long.step-06"), "the answer supersedes the working line")
        XCTAssertTrue(visible.contains("chat.long.step-07"))

        // Check 8: a tall answer at the bottom keeps the view pinned.
        mirror.take(player.advance(to: 62))
        let tall = try XCTUnwrap(mirror.buffer.items.last)
        XCTAssertEqual(tall.id, "chat.long.step-09")
        XCTAssertGreaterThanOrEqual(tall.body.split(separator: "\n").count, 40)
        var pinned = FollowPolicy()
        let command = pinned.handle(FollowInput.from(try XCTUnwrap(mirror.changes.last)))
        XCTAssertEqual(command, .scrollToBottom(animated: false))
    }

    // MARK: Sending

    func testASendShowsAClockThenSentThenSeenThenDotsThenTheAnswer() throws {
        let send = try script(ScriptedScenario.chatSend.rawValue)
        var player = player(send)
        var mirror = Mirror()
        mirror.take(player.open())
        mirror.take(player.advance(to: 1))
        let (id, outputs) = player.send(text: "*hi* 1. a_b_")
        mirror.take(outputs)
        XCTAssertEqual(mirror.changes.last, .appendedAtEnd(count: 0, localEcho: true))
        var echo = try XCTUnwrap(mirror.buffer.items.last)
        XCTAssertEqual(echo.id, id)
        XCTAssertEqual(echo.body, "*hi* 1. a_b_", "plain text, exactly as typed")
        XCTAssertEqual(echo.delivery, .sending())
        XCTAssertEqual(Delivery.mark(for: echo), .sending)

        mirror.take(player.advance(to: 2.45))
        XCTAssertEqual(mirror.buffer.items.last?.delivery, .sending(), "U4: still the clock until the 1.5 s acceptance")
        mirror.take(player.advance(to: 2.55))
        echo = try XCTUnwrap(mirror.buffer.items.last)
        XCTAssertEqual(echo.delivery, .sent(eventID: "$" + id))
        XCTAssertEqual(echo.id, id, "the display ID never changes")
        mirror.take(player.advance(to: 2.7))
        echo = try XCTUnwrap(mirror.buffer.items.last)
        XCTAssertEqual(echo.delivery, .remote)
        XCTAssertFalse(echo.isLocalEcho)
        XCTAssertEqual(echo.eventOrTransactionId, .event("$" + id))

        mirror.take(player.advance(to: 5.1))
        XCTAssertFalse(mirror.buffer.items.last?.receiptUserIDs.contains(Cast.atum) ?? true,
                       "U4b: Sent stays for 2.5 s before the receipt")
        mirror.take(player.advance(to: 5.2))
        XCTAssertEqual(mirror.buffer.items.last?.receiptUserIDs, [Cast.atum], "Seen: the agent's receipt")
        XCTAssertFalse(mirror.buffer.items.dropLast().contains { $0.receiptUserIDs.contains(Cast.atum) },
                       "the receipt moved rather than copied")
        mirror.take(player.advance(to: 6.7))
        XCTAssertEqual(mirror.typing, [Cast.atum])
        mirror.take(player.advance(to: 8.7))
        let answer = try XCTUnwrap(mirror.buffer.items.last)
        XCTAssertEqual(answer.sender, Cast.atum)
        XCTAssertEqual(answer.replyTo, "$" + id)
        XCTAssertEqual(answer.resultFor, "$" + id)
        XCTAssertTrue(mirror.typing.isEmpty)
        XCTAssertFalse(try XCTUnwrap(Projection.rows(mirror.buffer.items, context: send.context).last).showsQuote)
    }

    func testARemoteMessageLandsAboveMyPendingEchoAndStillCountsAsNew() {
        let script = ScriptedScript(name: "test.placement", title: "T", context: ScriptedChats.assistant,
                                    initial: [ScriptedChats.answer("old", "cũ")],
                                    steps: [ScriptedStep(at: 2, .arrive(ScriptedChats.answer("new", "mới")))],
                                    sends: .staysSending)
        var player = player(script)
        var mirror = Mirror()
        mirror.take(player.open())
        mirror.take(player.send(text: "đang gửi").outputs)
        mirror.take(player.advance(to: 2))
        XCTAssertEqual(mirror.buffer.items.map(\.id), ["test.placement.start", "old", "new", "test.placement.send-1"])
        XCTAssertEqual(mirror.changes.last, .appendedAtEnd(count: 1, localEcho: false))
    }

    func testFailedSendsRetryByRecoverabilityAndDeleteRemovesOnlyPendingSends() throws {
        let fails = try script(ScriptedScenario.chatSendFails.rawValue)
        var player = player(fails)
        var mirror = Mirror()
        mirror.take(player.open())
        let parked = "chat.send-fails.parked"
        XCTAssertEqual(mirror.buffer.items.last?.delivery, .failed(isRecoverable: false), "D8: a failure survives")

        let (id, outputs) = player.send(text: "a")
        mirror.take(outputs)
        mirror.take(player.advance(to: 0.65))
        XCTAssertEqual(mirror.buffer.items.first { $0.id == id }?.delivery, .failed(isRecoverable: true))
        XCTAssertEqual(Delivery.mark(for: try XCTUnwrap(mirror.buffer.items.first { $0.id == id })), .failed)

        let reEnabled = player.enableSendQueue()
        XCTAssertEqual(reEnabled, [], "as the pinned SDK, re-enabling the queue emits nothing")
        mirror.take(reEnabled)
        XCTAssertEqual(mirror.buffer.items.first { $0.id == id }?.delivery, .failed(isRecoverable: true),
                       "the failure stays until the resend settles: a clock here is the store's own")
        XCTAssertEqual(mirror.buffer.items.first { $0.id == parked }?.delivery, .failed(isRecoverable: false),
                       "re-enabling the queue does not touch a parked request")
        mirror.take(player.advance(to: 2.2))
        XCTAssertEqual(mirror.buffer.items.first { $0.id == id }?.delivery, .sent(eventID: "$" + id))

        let retried = player.retrySend(itemID: parked)
        XCTAssertTrue(retried.retried)
        mirror.take(retried.outputs)
        XCTAssertEqual(mirror.buffer.items.first { $0.id == parked }?.delivery, .sending())
        XCTAssertFalse(player.retrySend(itemID: parked).retried, "only a failed send retries")

        let (second, secondOutputs) = player.send(text: "b")
        mirror.take(secondOutputs)
        let removed = player.abortSend(itemID: second)
        XCTAssertTrue(removed.removed)
        mirror.take(removed.outputs)
        XCTAssertFalse(mirror.buffer.items.contains { $0.id == second }, "Xóa removes the row")
        mirror.take(player.advance(to: 10))
        XCTAssertFalse(mirror.buffer.items.contains { $0.id == second }, "a removed send never settles")
        XCTAssertFalse(player.abortSend(itemID: "chat.send-fails.0001").removed, "nobody else's message")
        XCTAssertFalse(player.abortSend(itemID: id).removed, "a send that went out stays")
    }

    private func delivery(_ id: String, in mirror: Mirror) -> ChatDelivery? {
        mirror.buffer.items.first { $0.id == id }?.delivery
    }

    /// Two sends, the first failing recoverably at 0.6 s.
    private func twoSendsAfterARecoverableFailure() throws
        -> (player: ScriptedTimelinePlayer, mirror: Mirror, first: String, second: String) {
        var player = player(try script(ScriptedScenario.chatSendFails.rawValue))
        var mirror = Mirror()
        mirror.take(player.open())
        let (first, firstOutputs) = player.send(text: "a")
        mirror.take(firstOutputs)
        mirror.take(player.advance(to: 0.1))
        let (second, secondOutputs) = player.send(text: "b")
        mirror.take(secondOutputs)
        mirror.take(player.advance(to: 0.65))
        XCTAssertEqual(delivery(first, in: mirror), .failed(isRecoverable: true))
        XCTAssertFalse(player.isSendQueueEnabled, "a recoverable failure disables the room's queue")
        return (player, mirror, first, second)
    }

    func testARecoverableFailureHoldsLaterSendsUntilTheQueueIsReEnabled() throws {
        var (player, mirror, first, second) = try twoSendsAfterARecoverableFailure()
        mirror.take(player.advance(to: 5))
        XCTAssertEqual(delivery(second, in: mirror), .sending(), "it waits behind the failed send, never fails on its own")
        let (third, thirdOutputs) = player.send(text: "c")
        mirror.take(thirdOutputs)
        mirror.take(player.advance(to: 10))
        XCTAssertEqual(delivery(third, in: mirror), .sending(), "a send into a disabled queue waits too")

        mirror.take(player.enableSendQueue())
        XCTAssertTrue(player.isSendQueueEnabled)
        XCTAssertEqual(delivery(first, in: mirror), .failed(isRecoverable: true), "no update until the resend settles")
        XCTAssertEqual(delivery(second, in: mirror), .sending())
        mirror.take(player.advance(to: 11.55))
        for id in [first, second, third] {
            XCTAssertEqual(delivery(id, in: mirror), .sent(eventID: "$" + id), "everything behind it goes out")
        }
        let order = mirror.buffer.items.map(\.id).filter { [first, second, third].contains($0) }
        XCTAssertEqual(order, [first, second, third], "in the order they were sent")
    }

    func testDeletingTheFailedSendLeavesTheQueueAsleepUntilItIsReEnabled() throws {
        var (player, mirror, first, second) = try twoSendsAfterARecoverableFailure()
        let removed = player.abortSend(itemID: first)
        XCTAssertTrue(removed.removed)
        mirror.take(removed.outputs)
        mirror.take(player.advance(to: 30))
        XCTAssertEqual(delivery(second, in: mirror), .sending(),
                       "U5: without a re-enable after Xóa the next message stays Đang gửi")
        XCTAssertFalse(player.isSendQueueEnabled)
        mirror.take(player.enableSendQueue())
        mirror.take(player.advance(to: 31.55))
        XCTAssertEqual(delivery(second, in: mirror), .sent(eventID: "$" + second))
    }

    func testRetryingAParkedRequestBehindADisabledQueueWaitsForTheQueue() throws {
        var (player, mirror, first, _) = try twoSendsAfterARecoverableFailure()
        let parked = "chat.send-fails.parked"
        let retried = player.retrySend(itemID: parked)
        XCTAssertTrue(retried.retried)
        mirror.take(retried.outputs)
        XCTAssertEqual(delivery(parked, in: mirror), .sending())
        mirror.take(player.advance(to: 20))
        XCTAssertEqual(delivery(parked, in: mirror), .sending(), "unparking does not wake a disabled queue")
        mirror.take(player.enableSendQueue())
        mirror.take(player.advance(to: 21.55))
        XCTAssertEqual(delivery(parked, in: mirror), .sent(eventID: "$" + parked))
        XCTAssertEqual(delivery(first, in: mirror), .sent(eventID: "$" + first))
    }

    func testASendJustAfterMidnightAndAnArrivalShareOneDayDivider() {
        // 2027-01-15 23:59:58 UTC: the send at 3 s and the arrival at 4 s
        // both fall on the 16th.
        let reference = env.reference.addingTimeInterval(9 * 3600 - 2)
        var old = ScriptedChats.answer("old", "cũ")
        old.timestamp = reference.addingTimeInterval(-60)
        let oldDay = env.calendar.startOfDay(for: old.timestamp)
        let script = ScriptedScript(name: "test.midnight", title: "Atum", context: ScriptedChats.assistant,
                                    initial: [ChatItem(id: "test.midnight.day-0", kind: .dayDivider(oldDay),
                                                       timestamp: oldDay), old],
                                    steps: [ScriptedStep(at: 4, .arrive(ScriptedChats.answer("new", "mới")))],
                                    sends: .staysSending)
        var player = ScriptedTimelinePlayer(script: script, reference: reference, calendar: env.calendar)
        var mirror = Mirror()
        mirror.take(player.open())
        mirror.take(player.advance(to: 3))
        let (echo, outputs) = player.send(text: "sau nửa đêm")
        mirror.take(outputs)
        mirror.take(player.advance(to: 4))
        let dividers = mirror.buffer.items.filter { if case .dayDivider = $0.kind { true } else { false } }
        XCTAssertEqual(dividers.count, 2, "one for each day")
        XCTAssertEqual(mirror.buffer.items.map(\.id).suffix(3), [dividers[1].id, "new", echo])
        assertOneDividerPerDay(mirror.buffer.items, script.name)
    }

    // MARK: Focused scenarios

    func testReplyAtBottomShowsTheEditedWorkingLineThenHidesIt() throws {
        let reply = try script(ScriptedScenario.chatReplyAtBottom.rawValue)
        var player = player(reply)
        var mirror = Mirror()
        mirror.take(player.open())
        mirror.take(player.advance(to: 3.5))
        let working = "chat.reply-at-bottom.working"
        XCTAssertTrue(Projection.rows(mirror.buffer.items, context: reply.context).contains { $0.id == working })
        XCTAssertEqual(mirror.buffer.items.first { $0.id == working }?.isEdited, true)
        mirror.take(player.advance(to: 5.5))
        let rows = Projection.rows(mirror.buffer.items, context: reply.context)
        XCTAssertFalse(rows.contains { $0.id == working })
        XCTAssertEqual(rows.last?.id, "chat.reply-at-bottom.answer")
    }

    func testMyMessageFromTheMacCountsInThePillAndDoesNotMoveTheView() throws {
        let own = try script(ScriptedScenario.chatOwnOtherDevice.rawValue)
        var player = player(own)
        var mirror = Mirror()
        mirror.take(player.open())
        var follow = FollowPolicy()
        follow.handle(.geometry(distanceFromBottom: 2000, distanceFromTop: 9000, viewportHeight: 700, motion: .user))
        mirror.take(player.advance(to: 5))
        let change = try XCTUnwrap(mirror.changes.last)
        XCTAssertEqual(change, .appendedAtEnd(count: 1, localEcho: false))
        let command = follow.handle(FollowInput.from(change))
        XCTAssertEqual(command, .none, "the view does not move")
        XCTAssertEqual(follow.pill, .count(1))
        XCTAssertEqual(mirror.buffer.items.last?.isOwn, true)
    }

    func testScrolledUpScenarioBringsExactlyThreeMessagesThenDots() throws {
        let up = try script(ScriptedScenario.chatReplyScrolledUp.rawValue)
        var player = player(up)
        var mirror = Mirror()
        mirror.take(player.open())
        XCTAssertGreaterThanOrEqual(mirror.buffer.items.filter(\.kind.isEventContent).count, 150)
        var follow = FollowPolicy()
        follow.handle(.geometry(distanceFromBottom: 2100, distanceFromTop: 9000, viewportHeight: 700, motion: .user))
        let before = mirror.changes.count
        mirror.take(player.advance(to: 20))
        for change in mirror.changes[before...] { follow.handle(FollowInput.from(change)) }
        XCTAssertEqual(follow.pill, .count(3))
    }

    func testEmptyChatIsAtItsStartAtOnce() throws {
        let empty = try script(ScriptedScenario.chatEmpty.rawValue)
        var player = player(empty)
        XCTAssertEqual(player.open(), [.diffs([.reset([ChatItem(id: "chat.empty.start", kind: .timelineStart)])]),
                                       .pagination(.idle(hitTimelineStart: true))])
        XCTAssertNil(player.nextEventTime)
    }

    func testPaginateScenarioHasTwoScreensCachedAndFivePages() throws {
        let paginate = try script(ScriptedScenario.chatPaginate.rawValue)
        XCTAssertEqual(paginate.initial.filter(\.kind.isEventContent).count, 40)
        XCTAssertEqual(paginate.olderPages.count, 5)
    }

    func testPeopleChatShowsTypingAsALineAndNoNamesOnTheirBubbles() throws {
        let people = try script(ScriptedScenario.chatPeople.rawValue)
        XCTAssertEqual(people.context.kind, .person)
        let rows = ScriptedScenarios.rows(people, after: 4, environment: env)
        XCTAssertFalse(rows.contains { if case .typing = $0.item.kind { true } else { false } },
                       "people typing is the line above the composer")
        var player = player(people)
        var mirror = Mirror()
        mirror.take(player.open())
        mirror.take(player.advance(to: 4))
        let names = TypingNames.displayNames(mirror.typing, ownUserID: people.context.ownUserID, kind: .person,
                                             roomTitle: people.title, name: people.name(for:))
        XCTAssertEqual(TypingNames.presentation(kind: .person, names: names).line, .names(["Minh Anh"]))
        let items = people.initial
        XCTAssertTrue(items.contains { $0.isEdited && !$0.isOwn }, "a person's edit")
        XCTAssertTrue(items.contains { $0.replyTo != nil && !$0.isOwn }, "a person's reply")
        XCTAssertEqual(items.last { $0.isOwn }?.receiptUserIDs, [Cast.minhAnh], "Đã xem")
    }

    func testKindsScenarioCarriesEveryPlaceholderAndMediaKind() throws {
        let kinds = try script(ScriptedScenarios.chatKinds)
        let items = kinds.initial
        for reason in [ChatItem.PlaceholderReason.unsupported, .redacted, .undecryptableOldHistory, .undecryptable] {
            XCTAssertTrue(items.contains { $0.kind == .placeholder(reason) }, "\(reason)")
        }
        XCTAssertTrue(items.contains { $0.kind == .image(width: 1200, height: 900) })
        XCTAssertTrue(items.contains { $0.kind == .image(width: nil, height: nil) })
        XCTAssertEqual(items.filter { if case .file = $0.kind { true } else { false } }.count, 3)
        XCTAssertTrue(items.contains { $0.kind == .notice && !kinds.context.agentUserIDs.contains($0.sender) })
        XCTAssertTrue(items.contains { $0.kind == .readMarker })
        XCTAssertTrue(items.contains { $0.kind == .roomState })
        XCTAssertEqual(items.first { $0.isOwn }?.receiptUserIDs.count, 2, "Đã xem · 2")
        let rows = ScriptedScenarios.rows(kinds, environment: env)
        XCTAssertFalse(rows.contains { $0.item.kind == .roomState }, "room state never shows")
        XCTAssertTrue(rows.contains { $0.showsQuote }, "a person's reply quotes")
    }

    func testActionsScenarioQuotesOnlyAnAnswerThatIsNotDirectlyUnderItsQuestion() throws {
        let actions = try script(ScriptedScenarios.chatActions)
        let rows = ScriptedScenarios.rows(actions, environment: env)
        let answers = rows.filter { $0.item.sender == Cast.atum }
        XCTAssertEqual(answers.map(\.showsQuote), [false, true])
        XCTAssertTrue(rows.contains { !$0.item.reactions.isEmpty && $0.item.isOwn })
        XCTAssertTrue(rows.contains { !$0.item.reactions.isEmpty && !$0.item.isOwn })
        var player = player(actions)
        var mirror = Mirror()
        mirror.take(player.open())
        let target = try XCTUnwrap(answers.first?.id)
        mirror.take(player.toggleReaction(itemID: target, key: "👍"))
        XCTAssertTrue(mirror.buffer.items.first { $0.id == target }?.reactions.isEmpty ?? false, "my 👍 toggled off")
        mirror.take(player.toggleReaction(itemID: target, key: "😂"))
        XCTAssertEqual(mirror.buffer.items.first { $0.id == target }?.reactions,
                       [ChatReaction(key: "😂", senderIDs: [Cast.me])])
        let mine = try XCTUnwrap(rows.last { $0.item.isOwn }?.id)
        mirror.take(player.redact(itemID: mine))
        XCTAssertEqual(mirror.buffer.items.first { $0.id == mine }?.kind, .placeholder(.redacted))
        mirror.take(player.edit(itemID: target, text: "sửa"))
        XCTAssertEqual(mirror.buffer.items.first { $0.id == target }?.isEdited, true)
        XCTAssertEqual(mirror.changes.suffix(4), [.inPlace, .inPlace, .inPlace, .inPlace])
    }

    func testMoonScenariosShowTheNoticeRoomAndHideTheMissingRoom() throws {
        let notice = try script(ScriptedScenario.botMoonNotice.rawValue)
        XCTAssertEqual(notice.context.kind, .appBot)
        let botNotice = try XCTUnwrap(notice.initial.first { $0.kind == .notice })
        XCTAssertEqual(botNotice.sender, Cast.moon)
        XCTAssertEqual(botNotice.body.split(separator: "\n", omittingEmptySubsequences: false).count, 2)
        XCTAssertNotNil(botNotice.appBotMeta)
        XCTAssertTrue(notice.initial.contains { $0.body.contains("https://pay.payos.vn/") }, "the purchase hold case")

        let noRoom = try XCTUnwrap(ScriptedScenarios.selection(named: ScriptedScenario.botMoonNoRoom.rawValue,
                                                               environment: env)?.roster)
        XCTAssertTrue(noRoom.apps.contains { $0.botUserID == Cast.moon })
        XCTAssertFalse(noRoom.rooms.contains { $0.members == [Cast.moon] && !$0.encrypted },
                       "no plain Moon room, so no Moon row")
        XCTAssertTrue(noRoom.rooms.contains { $0.members == [Cast.andy] && !$0.encrypted })
        let roster = try XCTUnwrap(ScriptedScenarios.selection(named: ScriptedScenario.homeRoster.rawValue,
                                                               environment: env)?.roster)
        for room in roster.rooms {
            if let opens = room.opens { XCTAssertNotNil(ScriptedScenarios.selection(named: opens, environment: env), opens) }
        }
    }

    func testPreviewRowsRunTheRealProjection() throws {
        let long = try script(ScriptedScenario.chatLong.rawValue)
        let open = ScriptedScenarios.rows(long, environment: env)
        XCTAssertTrue(open.last?.isLatest ?? false)
        let typing = ScriptedScenarios.rows(long, after: 5, environment: env)
        XCTAssertEqual(typing.last?.item.kind, .typing(names: ["Atum"]))
        let answered = ScriptedScenarios.rows(long, after: 6.5, environment: env)
        XCTAssertEqual(answered.last?.id, "chat.long.step-01")
    }

    // MARK: The real-time source

    func testTheSourceOpensSendsAndPaginatesInOrder() async throws {
        let paginate = try script(ScriptedScenario.chatPaginate.rawValue)
        let source = ScriptedTimelineSource(script: paginate, reference: env.reference, calendar: env.calendar)
        await source.start()
        let id = await source.sendEcho(text: "xin chào")
        let hit = await source.paginateBackwards()
        XCTAssertFalse(hit)
        await source.stop()
        var received: [Output] = []
        for await output in source.outputs { received.append(Self.playerOutput(output)) }
        guard case let .diffs(first)? = received.first, case .reset = first.first else {
            return XCTFail("the open's reset comes first: \(received.prefix(1))")
        }
        XCTAssertTrue(received.contains(.diffs([.pushBack(ChatItem(id: id, kind: .message, sender: Cast.me, isOwn: true,
                                                                  isLocalEcho: true,
                                                                  timestamp: try echoTimestamp(received, id),
                                                                  delivery: .sending(),
                                                                  eventOrTransactionId: .transaction("txn-" + id),
                                                                  body: "xin chào"))])))
        let statuses = received.compactMap { if case let .pagination(status) = $0 { status } else { nil } }
        XCTAssertEqual(statuses, [.idle(hitTimelineStart: false), .paginating, .idle(hitTimelineStart: false)])
        var mirror = Mirror()
        mirror.take(received)
        XCTAssertEqual(mirror.buffer.items.filter(\.kind.isEventContent).count, 61)
    }

    private struct EchoMissing: Error {}

    /// The source's output back in the player's terms (reply details dropped).
    private static func playerOutput(_ output: ChatTimelineOutput) -> Output {
        switch output {
        case let .batch(batch): .diffs(batch.diffs)
        case let .typing(userIDs): .typing(userIDs)
        case let .pagination(state): .pagination(state)
        }
    }

    // MARK: The source through the store's protocol (contract amendment, S1 day 1)

    func testThePlayerFindsTheItemAStoreRefNames() throws {
        var player = player(try script(ScriptedScenario.chatSend.rawValue))
        _ = player.open()
        let sent = player.send(text: "xin chào")
        XCTAssertEqual(player.itemID(for: .transaction("txn-" + sent.itemID)), sent.itemID)
        let remote = try XCTUnwrap(player.buffer.items.last { $0.kind == .message && !$0.isLocalEcho })
        XCTAssertEqual(player.itemID(for: try XCTUnwrap(remote.eventOrTransactionId)), remote.id)
        XCTAssertNil(player.itemID(for: .event("$nope")))
        _ = player.advance(to: 1.51)
        let accepted = try XCTUnwrap(player.buffer.items.first { $0.id == sent.itemID })
        let eventID = try XCTUnwrap(accepted.eventID, "the SDK accepted it: .sent carries the event ID")
        XCTAssertEqual(player.itemID(for: .event(eventID)), sent.itemID,
                       "a ref to the accepted echo's event ID finds the echo before its remote copy lands")
    }

    func testRepliesCarryTheDetailsTheSDKWouldGive() throws {
        let actions = try script(ScriptedScenarios.chatActions)
        var player = player(actions)
        _ = player.open()
        let replies = player.buffer.items.filter { $0.replyTo != nil }
        XCTAssertFalse(replies.isEmpty)
        for reply in replies {
            let details = try XCTUnwrap(player.replyDetails(for: reply))
            XCTAssertEqual(details.eventID, reply.replyTo)
            let original = try XCTUnwrap(player.buffer.items.first { $0.eventID == reply.replyTo })
            XCTAssertEqual(details.state, .ready(sender: original.sender, senderName: original.senderName,
                                                 preview: ReplyPreview(kind: original.kind, body: original.body)))
        }
        var orphan = replies[0]
        orphan.replyTo = "$not-loaded"
        XCTAssertEqual(player.replyDetails(for: orphan)?.state, .unavailable)
        XCTAssertNil(player.replyDetails(for: ChatItem(id: "x", kind: .message)))
    }

    func testTheSourceWorksThroughTheStoresProtocol() async throws {
        let actions = try script(ScriptedScenarios.chatActions)
        let source: any ChatTimelineSource = ScriptedTimelineSource(script: actions, reference: env.reference,
                                                                    calendar: env.calendar)
        await source.start()
        let queueEnabled = await source.isSendQueueEnabled()
        XCTAssertTrue(queueEnabled)
        try await source.send(text: "*hi* 1. a_b_", replyTo: nil)
        do {
            try await source.retrySend(.event("$nope"))
            XCTFail("the SDK throws for an item it does not know")
        } catch let error as ScriptedTimelineError {
            XCTAssertEqual(error, .unknownItem)
        }
        await source.stop()
        var batches: [ChatTimelineBatch] = []
        for await output in source.outputs { if case let .batch(batch) = output { batches.append(batch) } }
        let open = try XCTUnwrap(batches.first)
        guard case let .reset(items)? = open.diffs.first else { return XCTFail("the open's reset comes first") }
        let replyIDs = Set(items.filter { $0.replyTo != nil }.map(\.id))
        XCTAssertFalse(replyIDs.isEmpty)
        XCTAssertEqual(Set(open.replyDetails.keys), replyIDs, "every reply in the batch has its details")
        let echo = try XCTUnwrap(batches.dropFirst().flatMap(\.diffs).flatMap(\.carriedItems).last { $0.isLocalEcho })
        XCTAssertEqual(echo.body, "*hi* 1. a_b_", "plain text, exactly as typed")
        XCTAssertEqual(echo.delivery, .sending())
    }

    func testDeletingThroughTheProtocolRemovesTheEchoByItsRef() async throws {
        let send = try script(ScriptedScenario.chatSendFails.rawValue)
        let source = ScriptedTimelineSource(script: send, reference: env.reference, calendar: env.calendar)
        await source.start()
        let id = await source.sendEcho(text: "một")
        try await source.toggleReaction(.transaction("txn-" + id), key: "👍")
        try await source.abortSend(.transaction("txn-" + id))
        await source.stop()
        var mirror = Mirror()
        for await output in source.outputs { mirror.take([Self.playerOutput(output)]) }
        XCTAssertFalse(mirror.buffer.items.contains { $0.id == id }, "Xóa removed the pending send")
    }

    private func echoTimestamp(_ outputs: [Output], _ id: String) throws -> Date {
        for case let .diffs(diffs) in outputs {
            for case let .pushBack(item) in diffs where item.id == id { return item.timestamp }
        }
        XCTFail("the send's echo was never pushed")
        throw EchoMissing()
    }
}
