import Foundation
import XCTest
@testable import AtumChat

/// The S0 probe-log API (§2.10) and the Debug launch arguments.
final class ProbeAndLaunchTests: XCTestCase {
    private final class Collect: ProbeSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProbeRecord] = []
        var records: [ProbeRecord] { lock.lock(); defer { lock.unlock() }; return stored }
        func write(_ record: ProbeRecord) { lock.lock(); stored.append(record); lock.unlock() }
    }

    override func tearDown() {
        ProbeLog.install(nil)
        super.tearDown()
    }

    func testMarkIsANoOpWithoutASink() {
        ProbeLog.install(nil)
        XCTAssertFalse(ProbeLog.isEnabled)
        ProbeLog.mark(.sendTapped, id: "tap-1") // nothing to observe, nothing crashes
    }

    func testMarkWritesOneRecordPerPointToTheInstalledSink() {
        let sink = Collect()
        ProbeLog.install(sink)
        XCTAssertTrue(ProbeLog.isEnabled)
        ProbeLog.mark(.sendTapped, id: "tap-1")
        ProbeLog.mark(.sendRowShown, id: "tap-1", fields: ["rowID": "row-9"])
        XCTAssertEqual(sink.records.map(\.point), ["send.tap", "send.row"])
        XCTAssertEqual(sink.records.map(\.id), ["tap-1", "tap-1"])
        XCTAssertEqual(sink.records[1].fields, ["rowID": "row-9"])
        XCTAssertLessThanOrEqual(sink.records[0].uptimeMs, sink.records[1].uptimeMs)
    }

    func testARecordIsOneSortedJSONLine() throws {
        let record = ProbeLog.record(.itemIdentity, id: nil,
                                     fields: ["uniqueId": "u1", "eventOrTransactionId": "txn-1", "phase": "local"],
                                     uptime: 12.3456, now: Date(timeIntervalSince1970: 1_800_000_000.25))
        let line = record.jsonLine()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(record.uptimeMs, 12346)
        XCTAssertTrue(line.hasPrefix("{\"fields\":{\"eventOrTransactionId\":\"txn-1\",\"phase\":\"local\",\"uniqueId\":\"u1\"}"))
        XCTAssertTrue(line.contains("\"point\":\"item.identity\""))
        XCTAssertTrue(line.contains("\"wall\":\"2027-01-15T08:00:00.250Z\""))
        XCTAssertEqual(try JSONDecoder().decode(ProbeRecord.self, from: Data(line.utf8)), record)
    }

    func testProbePointNamesAreUnique() {
        let names = ProbePoint.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testLaunchArgumentsRoundTrip() {
        let values = AtumLaunchArguments.arguments(scenario: .chatLong)
        XCTAssertEqual(values, ["-AtumUITestNoAnimations", "-AtumScripted", "chat.long"])
        let parsed = AtumLaunchArguments(["/path/AtumMobile"] + values)
        XCTAssertTrue(parsed.disablesAnimations)
        XCTAssertEqual(parsed.scriptedScenario, .chatLong)
    }

    func testTappingTheIconPassesNothing() {
        let parsed = AtumLaunchArguments(["/path/AtumMobile"])
        XCTAssertFalse(parsed.disablesAnimations)
        XCTAssertNil(parsed.scriptedScenario)
        XCTAssertNil(AtumLaunchArguments(["x", "-AtumScripted"]).scriptedScenario, "a flag with no value")
        XCTAssertNil(AtumLaunchArguments(["x", "-AtumScripted", "chat.unknown"]).scriptedScenario)
    }

    func testEveryScenarioNameParses() {
        for scenario in ScriptedScenario.allCases {
            XCTAssertEqual(AtumLaunchArguments(["x", "-AtumScripted", scenario.rawValue]).scriptedScenario, scenario)
        }
    }

    func testAccessibilityIDs() {
        XCTAssertEqual(AccessibilityID.row(id: "abc"), "row.abc")
        XCTAssertEqual(AccessibilityID.sendFailed, "send.failed")
        XCTAssertEqual(AccessibilityID.chatGreeting, "chat.greeting")
        XCTAssertEqual(AccessibilityID.transcriptValue(.following), "following")
        XCTAssertEqual(AccessibilityID.transcriptValue(.detached(newCount: 4)), "detached:4")
    }
}
