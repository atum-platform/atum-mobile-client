import AtumChat
import Foundation
import XCTest
@testable import AtumNativeAPI

/// Home search's Messages and Files: desktop's company search
/// (`shared/matrix-company-search-query.ts`, `electron/matrix/main-company-search.ts`,
/// `src/matrix/company-message-search.ts`). Rooms and people are generic fixtures.
final class CompanyMessageSearchTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-2a39c7cf131c"
    private let general = CompanySearchTarget(channelID: "00000000-0000-4000-8000-000000000001",
                                              roomID: "!general:example.invalid", channelName: "general")
    private let design = CompanySearchTarget(channelID: "00000000-0000-4000-8000-000000000002",
                                             roomID: "!design:example.invalid", channelName: "Thiết kế")

    // MARK: Query

    func testQueryKeepsWordsPhrasesAndOneOfEachOperator() {
        let parsed = CompanySearchQuery.parse(#"  launch "ra mắt" from:@minh in:#general after:2026-11-01 "#)
        XCTAssertEqual(parsed.terms, [.init(value: "launch", quoted: false), .init(value: "ra mắt", quoted: true)])
        XCTAssertEqual(parsed.from, "@minh")
        XCTAssertEqual(parsed.inChannel, "#general")
        XCTAssertEqual(parsed.after, "2026-11-01")
        XCTAssertEqual(parsed.serverTerm, "launch ra mắt")
        XCTAssertTrue(parsed.problems.isEmpty)
        XCTAssertFalse(parsed.needsLoadedHistory)

        // A colon that is not one of the four operators is a word.
        XCTAssertEqual(CompanySearchQuery.parse("https://atum.test").terms.map(\.value), ["https://atum.test"])
        XCTAssertTrue(CompanySearchQuery.parse("from:me").needsLoadedHistory)
    }

    func testQueryProblemsMatchTheDesktopParser() {
        XCTAssertEqual(CompanySearchQuery.parse(#""open"#).problems, [.unterminatedQuote])
        XCTAssertEqual(CompanySearchQuery.parse("from:me from:@lan").problems, [.duplicateOperator])
        XCTAssertEqual(CompanySearchQuery.parse("from:lan").problems, [.invalidOperator])
        XCTAssertEqual(CompanySearchQuery.parse("in:general").problems, [.invalidOperator])
        XCTAssertEqual(CompanySearchQuery.parse("before:2026-02-30").problems, [.invalidDate])
        XCTAssertEqual(CompanySearchQuery.parse("before:2026-11-01 after:2026-11-02").problems, [.invalidRange])
        XCTAssertEqual(CompanySearchQuery.parse(#"say \"hi"#).terms.map(\.value), [#"say"#, #"\"hi"#])
        XCTAssertEqual(CompanySearchQuery.parse(#""say \"hi\"""#).terms.map(\.value), [#"say "hi""#])
    }

    func testOnlyAQueryDesktopMainAcceptsIsAsked() {
        XCTAssertNil(CompanyMessageSearch.query("a"))
        XCTAssertNil(CompanyMessageSearch.query(String(repeating: "a", count: 201)))
        XCTAssertNil(CompanyMessageSearch.query("from:lan"))
        XCTAssertEqual(CompanyMessageSearch.query("  đà lạt ")?.serverTerm, "đà lạt")
    }

    func testTermsAndDatesFoldAsOnDesktop() {
        let parsed = CompanySearchQuery.parse("da lat after:2026-11-01 before:2026-11-03")
        XCTAssertTrue(parsed.termsMatch("Chuyến đi   Đà Lạt tuần sau"))
        XCTAssertFalse(parsed.termsMatch("Đà Nẵng"))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(parsed.dateMatches(milliseconds: 1_793_577_600_000, timeZone: utc)) // 2026-11-02
        XCTAssertTrue(parsed.dateMatches(milliseconds: 1_793_491_200_000, timeZone: utc)) // 2026-11-01, inclusive
        XCTAssertFalse(parsed.dateMatches(milliseconds: 1_793_664_000_000, timeZone: utc)) // 2026-11-03, exclusive
    }

    // MARK: Targets

    func testTargetsAreReadyChannelsAndConversationsInIDOrder() throws {
        let read = try CompanyWorkspaceWire.decodeChannelDirectory(Data("""
        {"schemaVersion":2,"channels":[
          \(channelEntry(id: "00000000-0000-4000-8000-00000000000c", name: "ready", state: "active", room: "!c:example.invalid")),
          \(channelEntry(id: "00000000-0000-4000-8000-00000000000a", name: "archived", state: "archived", room: "!a:example.invalid")),
          \(channelEntry(id: "00000000-0000-4000-8000-00000000000b", name: "provisioning", state: "provisioning", room: "!b:example.invalid")),
          \(channelEntry(id: "00000000-0000-4000-8000-00000000000d", name: "no room", state: "active", room: nil))
        ]}
        """.utf8))
        guard case let .v1_1(channels) = read else { return XCTFail("not a 1.1 channel directory") }
        let packURL = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.5", withExtension: nil))
        let conversations = try CompanyConversationWire.decodeDirectory(
            Data(contentsOf: packURL.appendingPathComponent("fixtures/conversation-directory.response.json")))

        let targets = CompanySearchTarget.targets(channels: channels, conversations: conversations)
        XCTAssertEqual(targets.map(\.channelName), ["archived", "ready", "Anh, Bảo"])
        XCTAssertEqual(targets.map(\.isConversation), [false, false, true])
        XCTAssertEqual(targets.last?.roomID, "!dm:example.invalid")
    }

    func testAdmittedRoomsAreJoinedUnencryptedAndNarrowedByIn() throws {
        let all = [general, design]
        let joined: (String) -> Bool = { $0 != "!left:example.invalid" }
        let plain = try XCTUnwrap(CompanyMessageSearch.query("launch"))
        XCTAssertEqual(CompanyMessageSearch.admitted(all, query: plain, isJoined: joined,
                                                     encryption: { $0 == self.design.roomID }), [general])
        let inDesign = try XCTUnwrap(CompanyMessageSearch.query("launch in:#thiet-ke"))
        XCTAssertEqual(CompanyMessageSearch.admitted(all, query: inDesign, isJoined: joined, encryption: { _ in false }), [])
        let inDesignSpaced = try XCTUnwrap(CompanyMessageSearch.query("launch in:#THIẾT"))
        XCTAssertEqual(CompanyMessageSearch.admitted([general, design], query: inDesignSpaced, isJoined: joined,
                                                     encryption: { _ in false }), [])
        let inGeneral = try XCTUnwrap(CompanyMessageSearch.query("launch in:#General"))
        XCTAssertEqual(CompanyMessageSearch.admitted(all, query: inGeneral, isJoined: joined,
                                                     encryption: { _ in false }), [general])
    }

    /// Review blocker 2: unknown encryption (nil, the SDK does not know yet)
    /// is not admitted; only an explicit `false` is.
    func testUnknownEncryptionIsNotAdmitted() throws {
        let plain = try XCTUnwrap(CompanyMessageSearch.query("launch"))
        let encryption: (String) -> Bool? = { $0 == self.general.roomID ? false : nil }
        XCTAssertEqual(CompanyMessageSearch.admitted([general, design], query: plain, isJoined: { _ in true },
                                                     encryption: encryption), [general])
        XCTAssertEqual(CompanyMessageSearch.admitted([general, design], query: plain, isJoined: { _ in true },
                                                     encryption: { _ in nil }), [])
        let eligibility = CompanySearchEligibility(targets: [company: [general, design]], isJoined: { _ in true },
                                                   encryption: encryption)
        XCTAssertTrue(eligibility.allows(companyID: company, channelID: general.channelID, roomID: general.roomID))
        XCTAssertFalse(eligibility.allows(companyID: company, channelID: design.channelID, roomID: design.roomID))
    }

    /// Review blocker 1: an answer, or a result already on screen, keeps
    /// only rooms still joined, known unencrypted and listed with the same
    /// company and channel binding.
    func testEligibilityDropsResultsWhoseRoomIsNoLongerReadable() {
        let results = [result(general, "$g"), result(design, "$d")]
        let readable = CompanySearchEligibility(targets: [company: [general, design]], isJoined: { _ in true },
                                                encryption: { _ in false })
        XCTAssertEqual(readable.retained(results).map(\.eventID), ["$g", "$d"])
        // Room A (design) left while its search was pending; B still joined.
        let left = CompanySearchEligibility(targets: [company: [general, design]],
                                            isJoined: { $0 != self.design.roomID }, encryption: { _ in false })
        XCTAssertEqual(left.retained(results).map(\.eventID), ["$g"])
        // Encryption turned on in general.
        let encrypted = CompanySearchEligibility(targets: [company: [general, design]], isJoined: { _ in true },
                                                 encryption: { $0 == self.general.roomID })
        XCTAssertEqual(encrypted.retained(results).map(\.eventID), ["$d"])
        // The directory no longer lists design.
        let unlisted = CompanySearchEligibility(targets: [company: [general]], isJoined: { _ in true },
                                                encryption: { _ in false })
        XCTAssertEqual(unlisted.retained(results).map(\.eventID), ["$g"])
        // Same room, another channel binding or another company: not this result.
        let rebound = CompanySearchEligibility(bindings: [company: [general.roomID: "other-channel"],
                                                          "other-company": [design.roomID: design.channelID]])
        XCTAssertEqual(rebound.retained(results), [])
        XCTAssertEqual(CompanySearchEligibility().retained(results), [])
    }

    /// Review should-fix 3: a tap is checked before and after the async
    /// event read; access lost during the read fails the open.
    @MainActor
    func testOpenIsCheckedBeforeAndAfterTheEventRead() async {
        let target = result(general, "$g", thread: "$root")
        var current = CompanySearchEligibility(targets: [company: [general]], isJoined: { _ in true },
                                               encryption: { _ in false })
        var reads = 0
        let same: () async -> (sender: String, threadRootID: String?)? = {
            reads += 1
            return (sender: target.sender, threadRootID: "$root")
        }
        var opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: same)
        XCTAssertTrue(opened)

        // Left during the read.
        opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: {
            current = CompanySearchEligibility()
            return (sender: target.sender, threadRootID: "$root")
        })
        XCTAssertFalse(opened)

        // Already gone before: the event is not read at all.
        reads = 0
        opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: same)
        XCTAssertFalse(opened)
        XCTAssertEqual(reads, 0)

        // Still readable, but another message or thread: refused.
        current = CompanySearchEligibility(targets: [company: [general]], isJoined: { _ in true },
                                           encryption: { _ in false })
        opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: {
            (sender: "@other:atum.test", threadRootID: "$root")
        })
        XCTAssertFalse(opened)
        opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: {
            (sender: target.sender, threadRootID: nil)
        })
        XCTAssertFalse(opened)
        opened = await CompanyMessageSearch.confirmOpen(target, eligibility: { current }, read: { nil })
        XCTAssertFalse(opened)
    }

    /// Round 2, item 3: the member reader reads the whole list in bounded
    /// chunks and caps only matches. With the old 10,000-record total cap, a
    /// sender at record 10,001, here behind 10,000 departed records, was missed.
    func testMemberReaderFindsASenderPastTenThousandRecords() {
        var departed = (0..<10_000).map {
            CompanySearchMember(userID: "@gone\($0):atum.test", names: ["Gone \($0)"], membership: "leave")
        }
        departed.append(CompanySearchMember(userID: "@minh:atum.test", names: ["Minh"], membership: "join"))
        let chunks = Counter()
        XCTAssertEqual(CompanySearchMemberReader.senders(from: "@minh", next: chunked(departed, count: chunks)),
                       ["@minh:atum.test"])
        XCTAssertEqual(chunks.value, 52, "10,001 records in 51 chunks of up to 200, then the end")

        // A departed match past 10,000 counts too.
        var behind = (0..<12_000).map {
            CompanySearchMember(userID: "@gone\($0):atum.test", names: ["Gone"], membership: "leave")
        }
        behind.append(CompanySearchMember(userID: "@minh:atum.test", names: ["Minh"], membership: "leave"))
        XCTAssertEqual(CompanySearchMemberReader.senders(from: "@minh", next: chunked(behind, count: chunks)),
                       ["@minh:atum.test"])

        // Only matches are capped.
        let many = (0..<600).map { CompanySearchMember(userID: "@minh\($0):atum.test", names: ["Minh"], membership: "join") }
        XCTAssertEqual(CompanySearchMemberReader.senders(from: "@minh", next: chunked(many, count: chunks)).count,
                       CompanySearchMemberReader.maximumMatches)
    }

    private final class Counter { var value = 0 }

    private func chunked(_ members: [CompanySearchMember], count: Counter) -> () -> [CompanySearchMember]? {
        var offset = 0
        return {
            count.value += 1
            guard offset < members.count else { return nil }
            let end = min(offset + Int(CompanySearchMemberReader.chunkSize), members.count)
            defer { offset = end }
            return Array(members[offset..<end])
        }
    }

    /// Review should-fix 4: one queue, at most four at once, in arrival
    /// order; a job cancelled while it waits never starts.
    @MainActor
    func testSearchQueueRunsAtMostFourInOrderAndSkipsCancelledWork() async {
        let limiter = CompanySearchLimiter(limit: 4)
        var active = 0
        var peak = 0
        var started = [Int]()
        var gates = [Int: CheckedContinuation<Void, Never>]()
        let tasks = (0..<10).map { index in
            Task { @MainActor in
                await limiter.run { () async -> Int in
                    active += 1
                    peak = max(peak, active)
                    started.append(index)
                    await withCheckedContinuation { gates[index] = $0 }
                    active -= 1
                    return index
                }
            }
        }
        while started.count < 4 { await Task.yield() }
        XCTAssertEqual(started, [0, 1, 2, 3])
        XCTAssertEqual(limiter.running, 4)
        // Cancel two waiting jobs; they never start.
        tasks[4].cancel()
        tasks[7].cancel()
        for _ in 0..<50 { await Task.yield() }
        // Let the running jobs finish one by one; each frees its slot to the
        // next waiting job in arrival order.
        var released = 0
        var spins = 0
        while released < 8, spins < 100_000 {
            spins += 1
            if let index = started.first(where: { gates[$0] != nil }), let gate = gates.removeValue(forKey: index) {
                gate.resume()
                released += 1
            }
            await Task.yield()
        }
        XCTAssertEqual(released, 8, "the queue stalled")
        var answers = [Int?]()
        for task in tasks { answers.append(await task.value) }
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(answers[4], nil)
        XCTAssertEqual(answers[7], nil)
        XCTAssertEqual(started, [0, 1, 2, 3, 5, 6, 8, 9])
        XCTAssertEqual(limiter.running, 0)
    }

    func testFromMatchesALocalpartOrAName() {
        XCTAssertTrue(CompanyMessageSearch.memberMatches(userID: "@minh:atum.test", names: ["Minh N"], from: "@minh"))
        XCTAssertTrue(CompanyMessageSearch.memberMatches(userID: "@u1:atum.test", names: ["Thảo"], from: "@thao"))
        XCTAssertFalse(CompanyMessageSearch.memberMatches(userID: "@minhanh:atum.test", names: [], from: "@minh"))
    }

    // MARK: Request and answer

    func testRequestBodyIsMatrixSearchOverTheAdmittedRooms() throws {
        let query = try XCTUnwrap(CompanyMessageSearch.query("launch from:@minh"))
        let body = try CompanyMessageSearch.requestBody(query: query, tab: .files, roomIDs: [general.roomID],
                                                        senders: ["@minh:atum.test"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap((object["search_categories"] as? [String: Any])?["room_events"] as? [String: Any])
        XCTAssertEqual(events["search_term"] as? String, "launch")
        XCTAssertEqual(events["order_by"] as? String, "recent")
        let filter = try XCTUnwrap(events["filter"] as? [String: Any])
        XCTAssertEqual(filter["rooms"] as? [String], [general.roomID])
        XCTAssertEqual(filter["senders"] as? [String], ["@minh:atum.test"])
        XCTAssertEqual(filter["types"] as? [String], ["m.room.message"])
        XCTAssertEqual(filter["contains_url"] as? Bool, true)
        XCTAssertEqual(filter["limit"] as? Int, 10)

        let messages = try CompanyMessageSearch.requestBody(query: query, tab: .messages, roomIDs: [], senders: nil)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: messages) as? [String: Any])
        let plainFilter = (((plain["search_categories"] as? [String: Any])?["room_events"] as? [String: Any])?["filter"]
            as? [String: Any]) ?? [:]
        XCTAssertNil(plainFilter["contains_url"])
        XCTAssertNil(plainFilter["senders"])
    }

    func testMessagesKeepTextThatHoldsTheWholeQueryAndSkipOtherRelations() throws {
        let query = try XCTUnwrap(CompanyMessageSearch.query("launch review"))
        let answer = response([
            event("$1", room: general.roomID, body: "Can we move the **launch review** to Thursday?"),
            event("$2", room: general.roomID, body: "review the launch"),             // words apart
            event("$3", room: design.roomID, body: "launch review in a thread", thread: "$root"),
            event("$4", room: general.roomID, body: "launch review edit", relation: ["rel_type": "m.replace", "event_id": "$1"]),
            event("$5", room: general.roomID, body: "launch review", msgtype: "m.notice"),
            event("$6", room: general.roomID, body: "launch review", redacted: true),
            event("$1", room: general.roomID, body: "Can we move the launch review to Thursday?"), // repeated
            event("$7", room: general.roomID, body: "launch review root", thread: "$7"),
        ])
        let results = try XCTUnwrap(CompanyMessageSearch.results(responseJSON: answer, companyID: company, tab: .messages,
                                                                  query: query, targets: [general, design]))
        XCTAssertEqual(results.map(\.eventID), ["$1", "$3"])
        XCTAssertEqual(results[0].snippet, "Can we move the launch review to Thursday?")
        XCTAssertEqual(results[0].channelName, "general")
        XCTAssertEqual(results[1].threadRootID, "$root")
        XCTAssertEqual(results[1].channelName, "Thiết kế")
        XCTAssertNil(results[0].file)
    }

    func testFilesMatchTheFileNameAndCarryItsType() throws {
        let query = try XCTUnwrap(CompanyMessageSearch.query("deck"))
        let answer = response([
            event("$f1", room: general.roomID, body: "launch-deck.pdf", msgtype: "m.file",
                  info: ["mimetype": "application/pdf", "size": 1200]),
            event("$f2", room: general.roomID, body: "photo", msgtype: "m.image", filename: "deck.HEIC"),
            event("$f3", room: general.roomID, body: "notes.txt", msgtype: "m.file"),
            event("$f4", room: general.roomID, body: "deck words", msgtype: "m.text"),
        ])
        let results = try XCTUnwrap(CompanyMessageSearch.results(responseJSON: answer, companyID: company, tab: .files,
                                                                  query: query, targets: [general]))
        XCTAssertEqual(results.map(\.text), ["launch-deck.pdf", "deck.HEIC"])
        XCTAssertEqual(results.map { $0.file?.type }, [.pdfs, .images])
        XCTAssertEqual(results[0].file?.size, 1200)
        XCTAssertEqual(CompanyMessageSearch.fileType(name: "plan.docx", mimeType: nil, msgtype: "m.file"), .documents)
        XCTAssertEqual(CompanyMessageSearch.fileType(name: "a.zip", mimeType: "application/zip", msgtype: "m.file"), .other)
    }

    func testAnAnswerFromARoomNotAskedRefusesTheCompany() throws {
        let query = try XCTUnwrap(CompanyMessageSearch.query("launch"))
        let answer = response([event("$x", room: "!elsewhere:example.invalid", body: "launch")])
        XCTAssertNil(CompanyMessageSearch.results(responseJSON: answer, companyID: company, tab: .messages,
                                                  query: query, targets: [general]))
        XCTAssertNil(CompanyMessageSearch.results(responseJSON: Data("{}".utf8), companyID: company, tab: .messages,
                                                  query: query, targets: [general]))
    }

    func testAtMostTenResultsPerCompany() throws {
        let query = try XCTUnwrap(CompanyMessageSearch.query("launch"))
        let answer = response((1...12).map { event("$\($0)", room: general.roomID, body: "launch \($0)") })
        let results = try XCTUnwrap(CompanyMessageSearch.results(responseJSON: answer, companyID: company, tab: .messages,
                                                                  query: query, targets: [general]))
        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(results.first?.eventID, "$1")
    }

    func testCompaniesMergeInIDOrderEachInServerOrder() {
        func result(_ company: String, _ id: String) -> CompanySearchResult {
            CompanySearchResult(companyID: company, channelID: "c", roomID: "!r:x", channelName: "n", eventID: id,
                                sender: "@s:x", snippet: id, at: 0)
        }
        let merged = CompanyMessageSearch.merged([
            "b-company": [result("b-company", "$b1"), result("b-company", "$b2")],
            "a-company": [result("a-company", "$a2"), result("a-company", "$a1")],
            "c-company": [],
        ])
        XCTAssertEqual(merged.map(\.eventID), ["$a2", "$a1", "$b1", "$b2"])
    }

    func testLongMessagesAreCutAroundTheirMatch() {
        let body = String(repeating: "x", count: 900) + " launch " + String(repeating: "y", count: 900)
        let snippet = CompanyMessageSearch.snippet(body, query: "launch")
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("launch"))
        XCTAssertEqual(snippet.count, 602)
        XCTAssertEqual(CompanyMessageSearch.snippet("short", query: "x"), "short")
    }

    // MARK: Helpers

    private func result(_ target: CompanySearchTarget, _ id: String, thread: String? = nil) -> CompanySearchResult {
        CompanySearchResult(companyID: company, channelID: target.channelID, roomID: target.roomID,
                            channelName: target.channelName, eventID: id, sender: "@minh:atum.test",
                            snippet: "launch", at: 0, threadRootID: thread)
    }

    private func channelEntry(id: String, name: String, state: String, room: String?) -> String {
        let roomJSON = room.map { #"{"state":"ready","roomId":"\#($0)"}"# } ?? #"{"state":"provisioning","roomId":null}"#
        return """
        {"schemaVersion":2,"channel":{"id":"\(id)","companyId":"\(company)","displayName":"\(name)",
        "visibility":"company","state":"\(state)","projectId":null,"authorityGeneration":1,"channelGeneration":1},
        "memberCount":2,"room":\(roomJSON)}
        """
    }

    private func event(_ id: String, room: String, body: String, msgtype: String = "m.text", thread: String? = nil,
                       relation: [String: Any]? = nil, redacted: Bool = false, filename: String? = nil,
                       info: [String: Any]? = nil) -> [String: Any] {
        var content: [String: Any] = ["msgtype": msgtype, "body": body]
        if let thread { content["m.relates_to"] = ["rel_type": "m.thread", "event_id": thread] }
        if let relation { content["m.relates_to"] = relation }
        if let filename { content["filename"] = filename }
        if let info { content["info"] = info }
        var event: [String: Any] = ["type": "m.room.message", "room_id": room, "event_id": id,
                                    "sender": "@minh:atum.test", "origin_server_ts": 1_762_000_000_000,
                                    "content": content]
        if redacted { event["unsigned"] = ["redacted_because": ["type": "m.room.redaction"]] }
        return event
    }

    private func response(_ events: [[String: Any]]) -> Data {
        let object: [String: Any] = ["search_categories": ["room_events": [
            "count": events.count, "results": events.map { ["rank": 1, "result": $0] },
        ]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
