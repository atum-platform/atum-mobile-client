import Foundation
import XCTest
@testable import AtumNativeAPI

/// Home search's company fan-out through `CompanySearchService.search`, the
/// entry point the app's `homeCompanySearch` calls for both tabs. The transport
/// is a fake that records every request body; nothing here touches a network.
@MainActor
final class CompanySearchServiceTests: XCTestCase {
    private let companyA = "00000000-0000-4000-8000-00000000000a"
    private let companyB = "00000000-0000-4000-8000-00000000000b"
    private let general = CompanySearchTarget(channelID: "00000000-0000-4000-8000-000000000001",
                                              roomID: "!general:example.invalid", channelName: "general")
    private let design = CompanySearchTarget(channelID: "00000000-0000-4000-8000-000000000002",
                                             roomID: "!design:example.invalid", channelName: "design")
    private let studio = CompanySearchTarget(channelID: "00000000-0000-4000-8000-000000000003",
                                             roomID: "!studio:example.invalid", channelName: "studio")

    /// Answers every room it is asked about with one message per room and tab.
    @MainActor
    private final class FakeTransport: CompanySearchTransport {
        var bodies = [[String: Any]]()
        var active = 0
        var peak = 0
        /// Runs after the request is recorded, before the answer is returned.
        var beforeAnswer: () -> Void = {}
        /// Senders whose messages the server holds (any membership now).
        var authors = ["@minh:atum.test"]

        func search(body: Data, endpoint: CompanySearchEndpoint) async throws -> Data {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            bodies.append(object)
            active += 1
            peak = max(peak, active)
            for _ in 0..<5 { await Task.yield() }
            active -= 1
            beforeAnswer()
            let events = (object["search_categories"] as? [String: Any])?["room_events"] as? [String: Any]
            let filter = events?["filter"] as? [String: Any] ?? [:]
            let files = filter["contains_url"] as? Bool == true
            let rooms = filter["rooms"] as? [String] ?? []
            let senders = filter["senders"] as? [String] ?? authors
            let results: [[String: Any]] = rooms.flatMap { room in
                senders.filter(authors.contains).map { sender -> [String: Any] in
                    let local = String(room.dropFirst().prefix(while: { $0 != ":" }))
                    let id = "$" + local + (files ? "-file" : "-msg")
                    let content: [String: Any] = files
                        ? ["msgtype": "m.file", "body": "launch-deck.pdf"]
                        : ["msgtype": "m.text", "body": "the launch plan"]
                    return ["rank": 1, "result": ["type": "m.room.message", "room_id": room, "event_id": id,
                                                  "sender": sender, "origin_server_ts": 1_762_000_000_000,
                                                  "content": content]]
                }
            }
            return try JSONSerialization.data(withJSONObject: ["search_categories": ["room_events": [
                "count": results.count, "results": results]]])
        }

        func rooms(_ index: Int) -> [String] {
            (((bodies[index]["search_categories"] as? [String: Any])?["room_events"] as? [String: Any])?["filter"]
                as? [String: Any])?["rooms"] as? [String] ?? []
        }

        var allRooms: [String] { bodies.indices.flatMap(rooms) }
    }

    private var limiterMade = 0
    private var transportMade = 0
    private var transport = FakeTransport()
    private var eligibility = CompanySearchEligibility()
    private var membersRead: (String) -> [CompanySearchMember] = { _ in [] }
    private var onMemberRead: (String) -> Void = { _ in }

    private func service(limit: Int) -> CompanySearchService {
        CompanySearchService(
            makeLimiter: { self.limiterMade += 1; return CompanySearchLimiter(limit: limit) },
            makeTransport: { self.transportMade += 1; return self.transport })
    }

    private var targets: [String: [CompanySearchTarget]] { [companyA: [general, design], companyB: [studio]] }

    private func environment() -> CompanySearchService.Environment {
        CompanySearchService.Environment(
            targets: { self.targets },
            eligibility: { self.eligibility },
            ownUserID: { "@me:atum.test" },
            senders: { roomID, from in
                let members = self.membersRead(roomID)
                self.onMemberRead(roomID)
                var offset = 0
                return CompanySearchMemberReader.senders(from: from) {
                    guard offset < members.count else { return nil }
                    defer { offset = members.count }
                    return members
                }
            },
            endpoint: {
                CompanySearchEndpoint(url: URL(string: "https://matrix.example.invalid/_matrix/client/v3/search")!,
                                      bearer: "test", stillCurrent: {})
            })
    }

    private func allEligible() -> CompanySearchEligibility {
        CompanySearchEligibility(targets: targets, isJoined: { _ in true }, encryption: { _ in false })
    }

    private func without(_ room: CompanySearchTarget) -> CompanySearchEligibility {
        CompanySearchEligibility(targets: targets, isJoined: { _ in true },
                                 encryption: { $0 == room.roomID })   // turned encrypted
    }

    // MARK: Round 2, item 4 counterfactual: one queue and one session for both tabs

    func testBothTabsShareOneQueueAndOneSession() async {
        eligibility = allEligible()
        let search = service(limit: 1)
        let env = environment()
        async let messages = search.search("launch", tab: .messages, environment: env)
        async let files = search.search("launch", tab: .files, environment: env)
        let (foundMessages, foundFiles) = await (messages, files)
        XCTAssertEqual(limiterMade, 1, "one queue")
        XCTAssertEqual(transportMade, 1, "one session")
        XCTAssertEqual(transport.bodies.count, 4, "two companies × two tabs through the one transport")
        XCTAssertEqual(transport.peak, 1, "the one queue (limit 1) held both tabs' work")
        // Company-id order is kept: company A's rooms, then B's.
        XCTAssertEqual(foundMessages.map(\.roomID), [general.roomID, design.roomID, studio.roomID])
        XCTAssertEqual(foundFiles.map(\.text), ["launch-deck.pdf", "launch-deck.pdf", "launch-deck.pdf"])
        XCTAssertEqual(search.limiter.running, 0)
    }

    // MARK: Round 2, item 2: eligibility re-checked once the job has its slot

    func testARoomEncryptedWhileItsJobIsQueuedIsNeverSearched() async {
        eligibility = allEligible()
        let search = service(limit: 1)
        // Something else holds the only slot.
        var release: CheckedContinuation<Void, Never>?
        let holder = Task { @MainActor in
            await search.limiter.run { await withCheckedContinuation { release = $0 } }
        }
        while release == nil { await Task.yield() }
        let pending = Task { @MainActor in
            await search.search("launch", tab: .messages, environment: self.environment())
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.bodies.isEmpty, "the search is still queued")
        // While queued: design is encrypted.
        eligibility = without(design)
        release?.resume()
        _ = await holder.value
        let found = await pending.value
        XCTAssertFalse(transport.allRooms.contains(design.roomID), "a queued job searched a room encrypted meanwhile")
        XCTAssertEqual(transport.allRooms.sorted(), [general.roomID, studio.roomID].sorted())
        XCTAssertFalse(found.contains { $0.roomID == design.roomID })
    }

    func testARoomLeftDuringTheMemberReadsIsNeverSearched() async {
        eligibility = allEligible()
        membersRead = { _ in [CompanySearchMember(userID: "@minh:atum.test", names: ["Minh"], membership: "join")] }
        // Reading general's members, design becomes encrypted.
        onMemberRead = { room in if room == self.general.roomID { self.eligibility = self.without(self.design) } }
        let found = await service(limit: 4).search("launch from:@minh", tab: .messages, environment: environment())
        XCTAssertFalse(transport.allRooms.contains(design.roomID))
        XCTAssertTrue(transport.allRooms.contains(general.roomID))
        XCTAssertFalse(found.contains { $0.roomID == design.roomID })
    }

    // MARK: Round 1, item 1, through the read entry point: the arrival filter

    func testAnAnswerForARoomLeftInFlightIsDropped() async {
        eligibility = allEligible()
        // The server answers for general and design; meanwhile general is left.
        transport.beforeAnswer = {
            self.eligibility = CompanySearchEligibility(targets: self.targets,
                                                        isJoined: { $0 != self.general.roomID },
                                                        encryption: { _ in false })
        }
        let found = await service(limit: 4).search("launch", tab: .messages, environment: environment())
        XCTAssertTrue(transport.allRooms.contains(general.roomID), "general was eligible when asked")
        XCTAssertFalse(found.contains { $0.roomID == general.roomID }, "its answer arrived after the leave")
        XCTAssertTrue(found.contains { $0.roomID == design.roomID })
    }

    // MARK: Round 2, from: through the live reader: a former member's old message

    func testFromFindsAFormerMembersHistoricalMessageThroughTheReader() async {
        eligibility = allEligible()
        // Minh left general long ago; their old message is still on the server.
        membersRead = { room in
            room == self.general.roomID
                ? [CompanySearchMember(userID: "@lan:atum.test", names: ["Lan"], membership: "join"),
                   CompanySearchMember(userID: "@minh:atum.test", names: ["Minh"], membership: "leave")]
                : []
        }
        let found = await service(limit: 4).search("launch from:@minh", tab: .messages, environment: environment())
        let senders = transport.bodies.compactMap {
            (((($0["search_categories"] as? [String: Any])?["room_events"] as? [String: Any])?["filter"]
                as? [String: Any])?["senders"] as? [String])
        }
        XCTAssertTrue(senders.allSatisfy { $0 == ["@minh:atum.test"] } && !senders.isEmpty,
                      "the former member is the sender filter: \(senders)")
        XCTAssertEqual(found.map(\.sender), ["@minh:atum.test", "@minh:atum.test"])
        XCTAssertEqual(found.first?.roomID, general.roomID)
    }

    // MARK: Cancellation

    func testACancelledSearchStartsNothingMore() async {
        eligibility = allEligible()
        let search = service(limit: 1)
        var release: CheckedContinuation<Void, Never>?
        let holder = Task { @MainActor in
            await search.limiter.run { await withCheckedContinuation { release = $0 } }
        }
        while release == nil { await Task.yield() }
        let pending = Task { @MainActor in
            await search.search("launch", tab: .messages, environment: self.environment())
        }
        for _ in 0..<20 { await Task.yield() }
        pending.cancel()
        for _ in 0..<20 { await Task.yield() }
        release?.resume()
        _ = await holder.value
        let found = await pending.value
        XCTAssertEqual(found, [])
        XCTAssertTrue(transport.bodies.isEmpty, "a cancelled, queued search sent a request")
    }
}
