@testable import AtumMobile
import XCTest
import AtumNativeAPI

/// HC-6: the chat header's line under the name (desktop
/// `data-matrix-agent-title` and the group header topic).
@MainActor
final class HomeChatsWave3StateTests: XCTestCase {
    func testSubtitleIsTheAssistantsTitleOrTheGroupsTopic() {
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!a", title: "Lan", subtitle: "Trợ lý viết",
                                                       kind: .assistant)), "Trợ lý viết")
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!g", title: "Nhóm", kind: .group(memberCount: 3),
                                                       topic: "  Đi\nĐà Lạt ")), "Đi Đà Lạt")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!g", title: "Nhóm", kind: .group(memberCount: 3),
                                                     topic: "   ")), "an empty topic draws nothing")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!p", title: "Hoa", subtitle: "x", kind: .person)),
                     "a person chat has none")
        XCTAssertEqual(ChatTitleCapsule.subtitle(.init(roomID: "!f", title: "Founder", subtitle: "Atum",
                                                       kind: .person, isFounder: true)), "Atum")
        XCTAssertNil(ChatTitleCapsule.subtitle(.init(roomID: "!m", title: "Moon", subtitle: "x", kind: .app(nil))))
    }

    func testSearchIsOfferedInPersonalChatsOnly() {
        let personal = ChatInfoPresentation(roomID: "!p", title: "Hoa", kind: .person)
        XCTAssertTrue(ChatScreen.offersSearch(info: personal, conversation: nil))
        XCTAssertTrue(ChatScreen.offersSearch(info: nil, conversation: nil))
    }

    func testSearchSessionCountsStepsAndCloses() {
        let session = ChatSearchSession()
        session.open()
        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(session.searching)
        session.close()
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.query, "")
        XCTAssertTrue(session.highlights.isEmpty)
    }
}

@MainActor
final class PeopleHandleSearchTests: XCTestCase {
    private let own = "@fake_owner:example.test"
    private let target = "@fake_person:example.test"
    private var row: HomeGroupCandidate {
        HomeGroupCandidate(id: target, name: "Fake Person", kind: .person, avatarURL: "mxc://example.test/fake")
    }
    private func assignment(kind: String = "human", user: String? = nil) throws -> AliasLookupResponse {
        let json = """
        {"state":"assigned","handle":"fake_person","principal":"00000000-0000-4000-8000-000000000001","kind":"\(kind)","generation":1,"matrixUser":"\(user ?? target)"}
        """
        // Contract types read integers through the raw-JSON userInfo, so a
        // plain JSONDecoder throws `invalidValue`: decode as the client does.
        return try NativeAPI.decode(AliasLookupResponse.self, from: Data(json.utf8))
    }
    func testHitIsFirst() async throws {
        let hit = try assignment()
        let other = HomeGroupCandidate(id: "@fake_other:example.test", name: "Other", kind: .person)
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [other] })
        XCTAssertEqual(result?.map(\.id), [target, other.id])
        XCTAssertEqual(result?.first?.name, "@fake_person")
    }
    func testMatchingRowKeepsProfileAndHasNoDuplicate() async throws {
        let hit = try assignment()
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [self.row] })
        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.first?.name, row.name)
        XCTAssertEqual(result?.first?.avatarURL, row.avatarURL)
        XCTAssertEqual(result?.first?.handle, "fake_person")
    }
    func testLookupFailurePreservesDirectory() async {
        struct Failure: Error {}
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in throw Failure() }, directory: { _ in [self.row] })
        XCTAssertEqual(result, [row])
    }
    func testDirectoryFailureReturnsHit() async throws {
        let hit = try assignment()
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in nil })
        XCTAssertEqual(result?.map(\.id), [target])
    }
    func testLeadingAtIsStripped() async {
        _ = await HomePeopleSearch.search(" @fake_person ", ownUserID: own, excluded: [],
            lookup: { handle in XCTAssertEqual(handle.rawValue, "fake_person"); return nil },
            directory: { term in XCTAssertEqual(term, "fake_person"); return [] })
    }
    func testOwnUserExcludedFromBothSources() async throws {
        let hit = try assignment(user: own)
        let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
            lookup: { _ in hit }, directory: { _ in [HomeGroupCandidate(id: self.own, name: "Owner", kind: .person)] })
        XCTAssertEqual(result, [])
    }
    func testNonHumanAssignmentIgnored() async throws {
        for kind in ["agent", "app", "organization"] {
            let hit = try assignment(kind: kind)
            let result = await HomePeopleSearch.search("fake_person", ownUserID: own, excluded: [],
                lookup: { _ in hit }, directory: { _ in [] })
            XCTAssertEqual(result, [])
        }
    }
    func testMinimumAvoidsTransport() async {
        let result = await HomePeopleSearch.search("@f", ownUserID: own, excluded: [],
            lookup: { _ in XCTFail("short query"); return nil },
            directory: { _ in XCTFail("short query"); return [] })
        XCTAssertEqual(result, [])
    }
}
