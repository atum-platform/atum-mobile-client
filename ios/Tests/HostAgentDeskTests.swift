import Foundation
import XCTest
@testable import AtumNativeAPI

/// The agent's desk contract and rules (W4-E3), as desktop #51 reads and
/// checks them (`shared/matrix-agent-desk.ts`, `src/matrix/agent-desk.tsx`).
final class HostAgentDeskTests: XCTestCase {
    private func job(_ id: String, _ state: String, next: String? = nil, reason: String? = nil) -> String {
        let nextValue = next.map { "\"\($0)\"" } ?? "null"
        let reasonPart = reason.map { #","pausedReason":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","name":"\#(id)","kind":"cron","display":"d","timezone":null,"state":"\#(state)","nextRunAt":\#(nextValue),"lastRunAt":null,"lastStatus":null,"expr":null,"minutes":null,"runAt":null\#(reasonPart)}"#
    }

    private func schedule(_ jobs: [String]) throws -> HostAgentDesk.Schedule {
        try HostAgentDesk.schedule(Data(#"{"read":"schedule","observedAt":1,"truncated":false,"jobs":[\#(jobs.joined(separator: ","))]}"#.utf8))
    }

    func testScheduleDecodesStrictlyWithAnOptionalPausedReason() throws {
        let read = try schedule([job("a", "scheduled", next: "2026-11-24T08:00:00+07:00"),
                                 job("b", "paused", reason: "owner_routine_off")])
        XCTAssertEqual(read.jobs.map(\.state), [.scheduled, .paused])
        XCTAssertNotNil(read.jobs[0].nextRunAt)
        XCTAssertEqual(read.jobs[1].pausedReason, "owner_routine_off")
        XCTAssertThrowsError(try HostAgentDesk.schedule(Data(#"{"read":"schedule","observedAt":1,"truncated":false,"jobs":[],"extra":1}"#.utf8)))
        XCTAssertThrowsError(try schedule([job("a", "sleeping")]))
    }

    func testAMalformedPausedReasonCostsOnlyThatReason() throws {
        let long = String(repeating: "x", count: 161)
        let read = try schedule([job("a", "paused", reason: long), job("b", "paused", reason: "  ")])
        XCTAssertEqual(read.jobs.map(\.pausedReason), [nil, nil])
    }

    func testFilesRefuseUnsafeNamesAndAnswerOnlyTheFolderAsked() throws {
        let good = Data(#"{"read":"files","root":"home","path":"","truncated":false,"rows":[{"name":"a","kind":"folder","size":0,"modifiedAt":0}]}"#.utf8)
        XCTAssertEqual(try HostAgentDesk.files(good, for: nil).rows.first?.kind, .folder)
        XCTAssertThrowsError(try HostAgentDesk.files(good, for: "home/a"))
        let unsafe = Data(#"{"read":"files","root":"home","path":"","truncated":false,"rows":[{"name":"../x","kind":"file","size":0,"modifiedAt":0}]}"#.utf8)
        XCTAssertThrowsError(try HostAgentDesk.files(unsafe, for: nil))
    }

    func testDeskPathsFollowTheContract() {
        XCTAssertTrue(HostAgentDesk.isValidPath("home"))
        XCTAssertTrue(HostAgentDesk.isValidPath("work/reports/q3"))
        for bad in ["/home", "home/../x", "home/./x", "docs", "home\\x", "home/\u{7}", "home//x"] {
            XCTAssertFalse(HostAgentDesk.isValidPath(bad), bad)
        }
        XCTAssertNil(HostAgentDesk.parent(of: "home/reports"))
        XCTAssertEqual(HostAgentDesk.parent(of: "home/reports/q3"), "home/reports")
        XCTAssertThrowsError(try HostAgentDesk.deskBody(agent: NativeID("7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e42"),
                                                        read: .files(path: "/etc")))
    }

    func testPausedOnlyWhenNothingCanStartOnItsOwn() throws {
        XCTAssertFalse(HostAgentDesk.isPaused(nil))
        XCTAssertFalse(HostAgentDesk.isPaused(try schedule([job("a", "scheduled"), job("b", "paused")]).jobs))
        XCTAssertTrue(HostAgentDesk.isPaused(try schedule([job("a", "paused"), job("b", "completed")]).jobs))
        XCTAssertFalse(HostAgentDesk.isPaused(try schedule([job("a", "completed")]).jobs))
    }

    func testOptimisticSwitchesMoveOnlyWhatTheControlNames() throws {
        let jobs = try schedule([job("a", "scheduled"), job("b", "running"), job("c", "paused"), job("d", "error")]).jobs
        XCTAssertEqual(HostAgentDesk.optimistic(.pause, jobs).map(\.state), [.paused, .paused, .paused, .error])
        XCTAssertEqual(HostAgentDesk.optimistic(.resume, jobs).map(\.state), [.scheduled, .running, .scheduled, .error])
        XCTAssertEqual(HostAgentDesk.optimistic(.routineOff(job: "a"), jobs).map(\.state), [.paused, .running, .paused, .error])
        XCTAssertEqual(HostAgentDesk.optimistic(.routineOn(job: "c"), jobs).map(\.state), [.scheduled, .running, .scheduled, .error])
        XCTAssertFalse(HostAgentDesk.isSwitchable(jobs[3]))
    }

    func testAControlThatChangedNothingOrFailedRollsBack() {
        XCTAssertEqual(HostAgentDesk.resolve(.changed(0), for: .pause, retried: false), .keep)
        XCTAssertEqual(HostAgentDesk.resolve(.changed(0), for: .resume, retried: false), .rollBack)
        XCTAssertEqual(HostAgentDesk.resolve(.changed(2), for: .resume, retried: false), .keep)
        XCTAssertEqual(HostAgentDesk.resolve(.busy, for: .pause, retried: false), .retryAfterCooldown)
        XCTAssertEqual(HostAgentDesk.resolve(.busy, for: .pause, retried: true), .rollBackFailed)
        XCTAssertEqual(HostAgentDesk.resolve(.stopped, for: .pause, retried: false), .rollBackStopped)
        XCTAssertEqual(HostAgentDesk.resolve(.failed, for: .pause, retried: false), .rollBackFailed)
        XCTAssertEqual(HostAgentDesk.resolve(.cancelled, for: .pause, retried: false), .rollBack)
    }

    func testARollBackUndoesOnlyWhatItsOwnControlMoved() {
        typealias Job = HostAgentDesk.Job
        let before = [Job(id: "a", name: "A", state: .scheduled), Job(id: "b", name: "B", state: .scheduled)]
        // A then B switched off; B's change landed after A's optimistic one.
        let afterA = HostAgentDesk.optimistic(.routineOff(job: "a"), before)
        let afterB = HostAgentDesk.optimistic(.routineOff(job: "b"), afterA)
        // A fails: only A comes back on, B stays off.
        let undone = HostAgentDesk.rollBack(.routineOff(job: "a"), from: before, in: afterB)
        XCTAssertEqual(undone.map(\.state), [.scheduled, .paused])
        // A field something else changed since is not touched.
        var moved = afterA
        moved[0].state = .running
        XCTAssertEqual(HostAgentDesk.rollBack(.routineOff(job: "a"), from: before, in: moved)[0].state, .running)
        // Pause rolls back every routine it paused, and only those.
        let mixed = [Job(id: "a", name: "A", state: .scheduled), Job(id: "b", name: "B", state: .paused)]
        let paused = HostAgentDesk.optimistic(.pause, mixed)
        XCTAssertEqual(HostAgentDesk.rollBack(.pause, from: mixed, in: paused).map(\.state), [.scheduled, .paused])
    }

    func testARoutineSwitchedOffOnItsOwnSwitchSaysNothingMore() throws {
        let jobs = try schedule([job("a", "paused", reason: "owner_routine_off"), job("b", "paused", reason: "owner_pause"),
                                 job("c", "paused"), job("d", "scheduled", next: "2026-11-24T08:00:00.000+07:00")]).jobs
        XCTAssertEqual(HostAgentDesk.routineLine(jobs[0]), .nothing)
        XCTAssertEqual(HostAgentDesk.routineLine(jobs[1]), .paused)
        XCTAssertEqual(HostAgentDesk.routineLine(jobs[2]), .paused)
        guard case .next = HostAgentDesk.routineLine(jobs[3]) else { return XCTFail("no next run") }
    }

    func testControlBodiesAndRepliesAreDesktopsExactShapes() throws {
        let agent = try NativeID("7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e42")
        XCTAssertEqual(String(decoding: try HostAgentDesk.Control.pause.body(agent: agent), as: UTF8.self),
                       #"{"action":"pause","agent":"7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e42"}"#)
        XCTAssertThrowsError(try HostAgentDesk.Control.routineOn(job: "").body(agent: agent))
        XCTAssertEqual(try HostAgentDesk.controlReply(Data(#"{"action":"pause","changed":3}"#.utf8), for: .pause).changed, 3)
        XCTAssertThrowsError(try HostAgentDesk.controlReply(Data(#"{"action":"pause","changed":3,"x":1}"#.utf8), for: .pause))
    }

    func testTheRosterSaysWhichAgentsRunOnHermes() throws {
        func agent(_ runtime: String) -> String {
            #"[{"id":"0b1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e41","identity_id":null,"display_name":"Luna","slug":null,"avatar":"","avatar_url":null,"is_default":false,"lifecycle_revision":1,"identity_revision":0,"definition_revision":0,"status":"active","principal":"7c1e2d3f-4a5b-4c6d-8e7f-9a0b1c2d3e42","matrixUser":"@luna:atumplatform.com"\#(runtime)}]"#
        }
        XCTAssertEqual(try NativeAPI.decode(AgentsResponse.self, from: Data(agent(#","runtime":"hermes""#).utf8)).agents.first?.runsOnHermes, true)
        XCTAssertEqual(try NativeAPI.decode(AgentsResponse.self, from: Data(agent(#","runtime":"other""#).utf8)).agents.first?.runsOnHermes, false)
        XCTAssertEqual(try NativeAPI.decode(AgentsResponse.self, from: Data(agent("").utf8)).agents.first?.runsOnHermes, false)
    }
}
