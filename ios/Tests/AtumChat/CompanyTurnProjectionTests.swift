import XCTest
@testable import AtumChat

final class CompanyTurnProjectionTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-000000000001"
    private let principal = "00000000-0000-4000-8000-000000000002"
    private let channel = "00000000-0000-4000-8000-000000000003"
    private let member = "00000000-0000-4000-8000-000000000004"
    private let incarnation = "00000000-0000-4000-8000-000000000005"
    private let room = "!company:example.test"

    private func context(privateCos: Bool = false) -> RoomContext {
        var result = RoomContext(kind: privateCos ? .person : .group, ownUserID: F.me,
                                 isCompanyPrivateCos: privateCos)
        let binding = CompanyTurnBinding(companyID: company, agentPrincipal: principal,
            agentUserID: F.agent, roomID: room, audience: privateCos
                ? .privateCos(memberPrincipal: member, membershipIncarnation: incarnation) : .channel(id: channel))
        result.companyTurnScope = privateCos ? .privateCos(binding: binding)
            : .channel(threadRoot: "$root", binding: binding)
        return result
    }

    /// The company-channel-progress and company-private-interim pack shapes.
    private func wire(privateCos: Bool = false, interim: Bool = false, revision: Int = 0,
                      phase: String = "working", task: String = "00000000-0000-4000-8000-000000000006")
        -> [String: Any] {
        var marker: [String: Any] = [
            "profile": "atum.agent-turns/1.6", "scope": "company", "companyId": company,
            "agentPrincipal": principal, "audience": privateCos
                ? ["kind": "private", "memberPrincipal": member, "membershipIncarnation": incarnation]
                : ["kind": "channel", "channelId": channel],
            "roomId": room, "threadRootEventId": "$root", "revision": revision,
            "taskId": task, "invocationId": "00000000-0000-4000-8000-000000000007"
        ]
        var content: [String: Any] = [
            "msgtype": interim ? "m.text" : "m.notice", "body": "Company update",
            "m.relates_to": ["rel_type": "m.thread", "event_id": "$root", "is_falling_back": false,
                             "m.in_reply_to": ["event_id": "$question"]]
        ]
        if interim {
            content["io.atum.interim"] = true
            content["io.atum.company"] = marker
        } else {
            marker["phase"] = phase
            marker["kind"] = phase == "settled" ? "settled" : "todo"
            content["io.atum.progress"] = marker
        }
        return content
    }

    private func json(_ value: [String: Any]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func item(_ id: String, _ content: [String: Any], sender: String = F.agent,
                      original: String? = nil, at: Date = F.at(0)) throws -> ChatItem {
        var row = ChatItem(id: id, kind: (content["msgtype"] as? String == "m.text") ? .message : .notice,
                           sender: sender, timestamp: at, eventOrTransactionId: .event("$" + id),
                           body: content["body"] as? String ?? "", isEdited: original != nil,
                           replyTo: "$question", threadRoot: "$root")
        let envelope: [String: Any] = [
            "event_id": "$" + id, "sender": sender, "room_id": room, "content": content,
            "origin_server_ts": Int(at.timeIntervalSince1970 * 1_000)
        ]
        try AtumTurnMarkers.parse(json: json(envelope), originalJSON: original).apply(to: &row)
        return row
    }

    func testOnlyBoundChannelThreadAndPrivateCosRenderTheCompanyFooter() throws {
        for privateCos in [false, true] {
            let context = context(privateCos: privateCos)
            let progress = try item("line", wire(privateCos: privateCos))
            let interim = try item("interim", wire(privateCos: privateCos, interim: true))
            let answer = F.text("other-task", from: F.agent, replyTo: "$different", threadRoot: "$root")
            let rows = Projection.rows([progress, interim, answer], context: context)
            XCTAssertEqual(F.ids(rows), ["interim", "other-task", Projection.typingRowID])
            XCTAssertTrue(rows[0].item.interim)

            var unbound = context
            unbound.companyTurnScope = privateCos ? .privateCos(binding: nil)
                : .channel(threadRoot: "$root", binding: nil)
            let plain = Projection.rows([progress, interim], context: unbound)
            XCTAssertEqual(F.ids(plain), ["line", "interim"])
            XCTAssertFalse(plain[1].item.interim)
        }
    }

    func testWrongSenderThreadOrPersonalMarkerIsPlainCompanyContent() throws {
        let context = context()
        let stranger = try item("stranger", wire(), sender: F.other)
        var differentThread = context
        differentThread.companyTurnScope = .channel(threadRoot: "$different", binding: context.activeCompanyBinding)
        let progress = try item("line", wire())
        var personal = F.notice("personal", from: F.agent)
        personal.progress = ChatProgress(phase: .working)
        XCTAssertEqual(F.ids(Projection.rows([stranger, personal], context: context)), ["stranger", "personal"])
        XCTAssertEqual(F.ids(Projection.rows([progress], context: differentThread)), ["line"])
        var channelTimeline = context
        channelTimeline.companyTurnScope = .channel(threadRoot: nil, binding: context.activeCompanyBinding)
        XCTAssertEqual(F.ids(Projection.rows([progress], context: channelTimeline)), ["line"])
    }

    func testCompanyFooterDisappearsWhileTheNextRoomBindingIsAttaching() throws {
        let bound = context()
        let note = F.text("question", from: F.me)
        let progress = try item("line", wire())
        var projector = TimelineProjector(generation: 1, context: bound)
        var conversation = ConversationCore(context: bound, draft: "keep my draft")
        _ = conversation.receive(try projector.apply([.append([note, progress])], now: F.at(0)), now: F.at(0))
        XCTAssertEqual(F.ids(conversation.snapshot.rows), ["question", Projection.typingRowID])

        var unbound = bound
        unbound.companyTurnScope = .channel(threadRoot: "$root", binding: nil)
        conversation.detached()
        conversation.updateContext(unbound)
        XCTAssertEqual(F.ids(conversation.snapshot.rows), ["question"])
        XCTAssertEqual(conversation.draft, "keep my draft")
    }

    func testCompanyShapeRejectsLeakedFieldsWrongAudienceAndThreadFallback() throws {
        var content = wire()
        var raw = try XCTUnwrap(content["io.atum.progress"] as? [String: Any])
        raw["toolArguments"] = ["synthetic"]
        content["io.atum.progress"] = raw
        XCTAssertNil(try item("leak", content).companyTurn)

        content = wire()
        raw = try XCTUnwrap(content["io.atum.progress"] as? [String: Any])
        raw["audience"] = ["kind": "channel", "channelId": channel, "memberPrincipal": member]
        content["io.atum.progress"] = raw
        XCTAssertNil(try item("mixed", content).companyTurn)

        content = wire()
        var relation = try XCTUnwrap(content["m.relates_to"] as? [String: Any])
        relation["is_falling_back"] = true
        content["m.relates_to"] = relation
        XCTAssertNil(try item("fallback", content).companyTurn)
    }

    func testCompanySettlementFencesOnlyItsExactTurnAndPersistsAcrossEdits() throws {
        var projector = TimelineProjector(generation: 1, context: context())
        let first = try item("first", wire())
        let other = try item("other", wire(task: "00000000-0000-4000-8000-000000000099"))
        let original = try json(["event_id": "$first", "sender": F.agent, "content": wire()])
        let settled = wire(revision: 1, phase: "settled")
        var edit = settled
        edit["m.new_content"] = settled
        edit["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$first"]
        let end = try item("first", edit, original: original)
        XCTAssertEqual(end.progress?.phase, .settled)
        XCTAssertNotNil(try projector.apply([.append([first])], now: F.at(0)).snapshot.rows.last)
        XCTAssertTrue(try projector.apply([.set(index: 0, item: end)], now: F.at(0)).snapshot.rows.isEmpty)
        XCTAssertTrue(try projector.apply([.set(index: 0, item: first)], now: F.at(0)).snapshot.rows.isEmpty)
        XCTAssertEqual(F.ids(try projector.apply([.append([other])], now: F.at(0)).snapshot.rows),
                       [Projection.typingRowID])

        let retargeted = wire(revision: 1, task: "00000000-0000-4000-8000-000000000099")
        edit = retargeted
        edit["m.new_content"] = retargeted
        edit["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$first"]
        XCTAssertNil(try item("first", edit, original: original).companyTurn)
    }

    func testSameRevisionCompanyInterimKeepsAcceptedContentAndTakesIncomingMetadata() throws {
        let accepted = try item("interim", wire(interim: true))
        var projector = TimelineProjector(generation: 1, context: context())
        _ = try projector.apply([.append([accepted])], now: F.at(0))

        var incoming = accepted
        incoming.body = "A same-revision replacement"
        incoming.reactions = [ChatReaction(key: "👍", senderIDs: [F.me])]
        incoming.receiptUserIDs = [F.other]
        incoming.senderName = "Updated name"
        let projected = try projector.apply([.set(index: 0, item: incoming)], now: F.at(0))
        let row = try XCTUnwrap(projected.snapshot.rows.first?.item)
        XCTAssertEqual(row.body, accepted.body)
        XCTAssertEqual(row.companyTurn, accepted.companyTurn)
        XCTAssertTrue(row.interim)
        XCTAssertEqual(row.reactions, incoming.reactions)
        XCTAssertEqual(row.receiptUserIDs, incoming.receiptUserIDs)
        XCTAssertEqual(row.senderName, incoming.senderName)
    }

    func testCompanyFooterExpiresOnTheProjectionClockAndARevisionCanReviveIt() throws {
        var projector = TimelineProjector(generation: 1, context: context())
        let first = try item("first", wire())
        let live = try projector.apply([.append([first])], now: F.at(0))
        XCTAssertEqual(live.nextNoAnswerChange, F.at(9).addingTimeInterval(0.001))
        XCTAssertTrue(projector.project(now: F.at(10)).snapshot.rows.isEmpty)
        let newer = try item("first", wire(revision: 1), at: F.at(10))
        XCTAssertEqual(F.ids(try projector.apply([.set(index: 0, item: newer)], now: F.at(10)).snapshot.rows),
                       [Projection.typingRowID])
    }
}
