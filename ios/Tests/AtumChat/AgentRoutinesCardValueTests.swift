import XCTest
@testable import AtumChat

final class AgentRoutinesCardValueTests: XCTestCase {
    func testZeroRoutinesReadsAsChuaCoInsteadOfZero() {
        XCTAssertEqual(AgentRoutinesCardValue.text(count: 0), "Chưa có")
        XCTAssertEqual(AgentRoutinesCardValue.text(count: -1), "Chưa có")
    }

    func testCountRendersAsVietnameseWorkItems() {
        XCTAssertEqual(AgentRoutinesCardValue.text(count: 1), "1 việc")
        XCTAssertEqual(AgentRoutinesCardValue.text(count: 3), "3 việc")
        XCTAssertEqual(AgentRoutinesCardValue.text(count: 64), "64 việc")
    }
}
