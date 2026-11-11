import XCTest
@testable import AtumChat

/// In-chat search walks the timeline back page by page and re-projects the
/// whole loaded buffer after every page (`ChatHistorySearch.run`). The Seen
/// faces, run times and edit marks (#38) must keep that walk linear in the
/// page count, not quadratic in the loaded items, or the hosted
/// `testSearchBarAtAccessibilitySizePassesTheAudit` scan stalls.
final class TimelineScanPerformanceTests: XCTestCase {
    private let total = ChatHistorySearch.eventBound
    private let page = Int(ChatHistorySearch.pageEvents)

    /// Worst case for the new work: my messages all carry receipts (a Seen
    /// row each), the agent answers every one (a run time each), edits sprinkled in.
    private func timeline() -> [ChatItem] {
        (0..<total).map { index in
            var item: ChatItem
            if index.isMultiple(of: 2) {
                item = F.mine("m\(index)", "câu hỏi \(index)", minute: index)
                item.receiptUserIDs = [F.agent, F.friend, F.other]
            } else {
                item = F.text("a\(index)", from: F.agent, "trả lời \(index)", minute: index, replyTo: "m\(index - 1)")
                item.senderName = "Atum"
                item.senderAvatarURI = "mxc://example.test/atum"
            }
            item.isEdited = index % 7 == 0
            return item
        }
    }

    /// Operations counted, not seconds: every projected row of a pass is one
    /// unit, and a linear walk projects `sum(page * k)` rows over its passes.
    func testProjectingTheTimelinePageByPageStaysLinearPerPass() {
        let all = timeline()
        let context = F.assistantRoom()
        var index = ChatSearchIndex()
        var projectedRows = 0
        var passes = 0
        let started = Date()
        var loaded = page
        while loaded <= total {
            let items = Array(all.suffix(loaded))
            let rows = Projection.rows(items, context: context, options: .s1)
            XCTAssertEqual(rows.count, loaded, "the new work adds and hides no rows")
            XCTAssertTrue(index.matches(in: rows, query: "không-có-đâu").isEmpty)
            projectedRows += rows.count
            passes += 1
            loaded += page
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(passes, total / page)
        // One pass over `loaded` rows stays within a constant factor of its size.
        XCTAssertEqual(projectedRows, (1...passes).reduce(0) { $0 + $1 * page })
        // The whole walk: ~48k rows projected. Generous for a debug build on a
        // loaded runner; a quadratic pass (n² = 4.8M per pass) misses it by far.
        XCTAssertLessThan(elapsed, 20, "scanning \(total) messages page by page took \(elapsed) s")
        print("timeline-scan: \(passes) passes, \(projectedRows) rows, \(elapsed) s")
    }

    /// One projection of the whole 2200-message timeline.
    func testOneFullProjectionIsFast() {
        let all = timeline()
        let started = Date()
        let rows = Projection.rows(all, context: F.assistantRoom(), options: .s1)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(rows.count, total)
        XCTAssertLessThan(elapsed, 2, "one projection of \(total) rows took \(elapsed) s")
        print("timeline-scan-single: \(elapsed) s")
    }
}
