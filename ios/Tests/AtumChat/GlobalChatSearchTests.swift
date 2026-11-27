import XCTest
@testable import AtumChat

@MainActor
final class GlobalChatSearchTests: XCTestCase {
    func testScopeChangeClearsQueryAndRejectsOldInputAndRemoteCompletion() async {
        let remote = SuspendedSearch()
        var privateTerms: [String] = []
        let engine = GlobalChatSearch<String, String>(debounce: .zero, plain: remote.run,
                                                      device: { term, _ in
            privateTerms.append(term)
            return term
        })
        let plain = engine.input
        engine.submit("invoice", for: plain)
        await fulfillment(of: [remote.started], timeout: 2)

        engine.reset(to: .deviceOnly)
        XCTAssertEqual(engine.query, "")
        guard case .idle = engine.result else { return XCTFail("Old results survived scope change") }
        engine.submit("queued keystroke", for: plain)
        XCTAssertEqual(engine.query, "")
        let device = engine.input
        let result = completed(engine)
        engine.submit("private canary", for: device)
        await fulfillment(of: [result], timeout: 2)
        remote.finish("remote late answer")
        await fulfillment(of: [remote.returned], timeout: 2)
        guard case .device(let reply) = engine.result else { return XCTFail("Late remote answer was shown") }
        XCTAssertEqual(reply, "private canary")
        XCTAssertEqual(remote.terms, ["invoice"])
        XCTAssertEqual(privateTerms, ["private canary"])
        XCTAssertTrue(remote.wasCancelled)

        engine.reset()
        XCTAssertEqual(engine.query, "")
        engine.submit("late private keystroke", for: device)
        XCTAssertEqual(engine.query, "")
        XCTAssertEqual(remote.terms, ["invoice"])
    }

    func testEmptyOrSupersededDebounceCannotStartRemoteSources() async {
        var plainTerms: [String] = []
        let engine = GlobalChatSearch<String, String>(debounce: .milliseconds(10), plain: { term, _ in
            plainTerms.append(term)
            return term
        }, device: { term, _ in term })
        engine.submit("a", for: engine.input)
        guard case .idle = engine.result else { return XCTFail("Short term started search") }
        engine.submit("cancelled before debounce", for: engine.input)
        engine.reset(to: .deviceOnly)
        let result = completed(engine)
        engine.submit("device only", for: engine.input)
        await fulfillment(of: [result], timeout: 2)
        XCTAssertEqual(plainTerms, [])
    }

    func testResultIdentityKeepsExactEventAndThreadRoute() {
        let first = ChatSearchEventTarget(roomID: "!room:test", eventID: "$first")
        let second = ChatSearchEventTarget(roomID: "!room:test", eventID: "$second", threadRootID: "$root")
        let hits = [first, second].map {
            GlobalChatSearchHit(target: $0, roomName: nil, senderID: "@user:test", snippet: "same body", timestamp: 1)
        }
        XCTAssertEqual(hits.map(\.id), [first, second])
        XCTAssertEqual(hits[1].id.eventID, "$second")
        XCTAssertEqual(hits[1].id.threadRootID, "$root")
    }

    private func completed(_ engine: GlobalChatSearch<String, String>) -> XCTestExpectation {
        let expectation = expectation(description: "Search publishes completed result")
        engine.onChange = { [weak engine] in
            if case .device? = engine?.result { expectation.fulfill() }
        }
        return expectation
    }
}

@MainActor
private final class SuspendedSearch {
    private(set) var terms: [String] = []
    private(set) var wasCancelled = false
    private var pending: CheckedContinuation<String, Never>?
    let started = XCTestExpectation(description: "Remote source started")
    let returned = XCTestExpectation(description: "Remote source returned")

    func run(_ term: String, isCurrent: GlobalChatSearch<String, String>.IsCurrent) async -> String {
        terms.append(term)
        let answer = await withCheckedContinuation {
            pending = $0
            started.fulfill()
        }
        wasCancelled = Task.isCancelled && !isCurrent()
        returned.fulfill()
        return answer
    }

    func finish(_ value: String) { pending?.resume(returning: value); pending = nil }
}
