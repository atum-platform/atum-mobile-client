@testable import AtumMobile
import XCTest

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
