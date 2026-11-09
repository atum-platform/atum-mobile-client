import Foundation
import XCTest
@testable import AtumNativeAPI

final class AgentRoutinesTests: XCTestCase {
    private let assistant = "00000000-0000-4000-8000-32cfb078b995"
    private let principal = "00000000-0000-4000-8000-7d54ce62756b"
    private let routine = "00000000-0000-4000-8000-736e81c7ee66"

    private func snapshot(schedule: String = "{\"kind\":\"weekly\",\"hour\":8,\"minute\":30,\"weekdays\":[1,2,3,4,5]}") -> Data {
        Data("""
        {"profile":"atum.agent-routines/1","assistantId":"\(assistant)",
        "assistantPrincipal":"\(principal)","serverTime":1800000000000,"legacyState":"clear","routines":[{
        "id":"\(routine)","title":"Morning brief","instruction":"Summarize my priorities.",
        "schedule":\(schedule),"timezone":"Asia/Ho_Chi_Minh","enabled":true,
        "notifications":false,"revision":3,"nextRunAt":1800003600000,"lastRun":null}]}
        """.utf8)
    }

    private func snapshot(legacyState: String, routines: String) -> Data {
        Data("""
        {"profile":"atum.agent-routines/1","assistantId":"\(assistant)",
        "assistantPrincipal":"\(principal)","serverTime":1800000000000,
        "legacyState":"\(legacyState)","routines":\(routines)}
        """.utf8)
    }

    private func routineJSON(id: String, title: String, schedule: String) -> String {
        """
        {"id":"\(id)","title":"\(title)","instruction":"Summarize my priorities.",
        "schedule":\(schedule),"timezone":"Asia/Ho_Chi_Minh","enabled":true,
        "notifications":false,"revision":2,"nextRunAt":1800003600000,"lastRun":null}
        """
    }

    func testUnknownScheduleKindToleratesFutureNamesButNotBlankOnes() throws {
        func schedule(_ json: String) throws -> AgentRoutineSchedule {
            let value = try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                             from: snapshot(schedule: json))
            guard let schedule = value.routines.first?.schedule else {
                throw ContractViolation.missingField
            }
            return schedule
        }
        let future = try schedule("{\"kind\":\"every-2-hours\"}")
        XCTAssertEqual(future, .unsupported(kind: "every-2-hours"))
        XCTAssertTrue(future.isReadOnly)
        XCTAssertEqual(try schedule("{\"kind\":\" interval \"}"), .unsupported(kind: "interval"))

        for blank in ["", "   ", "\\n\\t"] {
            XCTAssertThrowsError(try schedule("{\"kind\":\"\(blank)\"}")) { error in
                XCTAssertEqual(error as? ContractViolation, .invalidValue)
            }
        }
    }

    func testUnknownScheduleKindStaysReadOnlyWithoutHidingOtherRows() throws {
        let unknown = routineJSON(id: "00000000-0000-4000-8000-736e81c7ee66",
                                  title: "Every two hours",
                                  schedule: "{\"kind\":\"interval\",\"everyHours\":2}")
        let daily = routineJSON(id: "00000000-0000-4000-8000-c2100016f8f4",
                                title: "Morning brief",
                                schedule: "{\"kind\":\"daily\",\"hour\":8,\"minute\":0}")
        let value = try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                         from: snapshot(legacyState: "clear",
                                                        routines: "[\(unknown),\(daily)]"))
        XCTAssertEqual(value.routines.count, 2)
        XCTAssertEqual(value.routines.first?.schedule, .unsupported(kind: "interval"))
        XCTAssertNil(value.routines.first?.schedule.kind)
        XCTAssertTrue(try XCTUnwrap(value.routines.first).schedule.isReadOnly)
        XCTAssertFalse(try XCTUnwrap(value.routines.last).schedule.isReadOnly)
        XCTAssertThrowsError(try JSONEncoder().encode(XCTUnwrap(value.routines.first?.schedule)))
        XCTAssertNoThrow(try JSONEncoder().encode(XCTUnwrap(value.routines.last?.schedule)))
        let editable = try XCTUnwrap(value.routines.last)
        XCTAssertNoThrow(try JSONEncoder().encode(AgentRoutineUpdate(
            requestId: NativeID("00000000-0000-4000-8000-ab798b5c9eee"),
            routine: editable, title: editable.title, instruction: editable.instruction,
            schedule: editable.schedule, timezone: editable.timezone,
            enabled: editable.enabled, notifications: editable.notifications)))
    }

    @MainActor
    func testUnknownLegacyStateIsPreparingAndFailedProbeRetries() async throws {
        let value = try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                         from: snapshot(legacyState: "unknown", routines: "[]"))
        var reads = 0
        let probe = AgentRoutinesProbe(read: {
            reads += 1
            return reads == 1 ? .failed : .value(value)
        })
        await probe.probe()
        XCTAssertEqual(probe.phase, .failed)
        XCTAssertNil(probe.snapshot)
        await probe.probe()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(probe.phase, .preparing)
        XCTAssertEqual(probe.snapshot?.legacyState, .unknown)
    }

    @MainActor
    func testReopeningTheCardProbesTheServerAgain() async throws {
        let value = try NativeAPI.decode(AgentRoutinesSnapshot.self, from: snapshot())
        var reads = 0
        let probe = AgentRoutinesProbe(read: {
            reads += 1
            return .value(value)
        })
        await probe.probe()
        XCTAssertEqual(probe.phase, .ready)
        XCTAssertEqual(probe.routineCount, 1)
        await probe.probe()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(probe.phase, .ready)
    }

    @MainActor
    func testProbeSkipsWhileLoadingAndCancelledResultNeverLands() async throws {
        let value = try NativeAPI.decode(AgentRoutinesSnapshot.self, from: snapshot())
        var continuations: [CheckedContinuation<AgentRoutinesLoadResult, Never>] = []
        var reads = 0
        let probe = AgentRoutinesProbe(read: {
            reads += 1
            return await withCheckedContinuation { continuations.append($0) }
        })

        let first = Task { await probe.probe() }
        await waitUntil { reads == 1 }
        XCTAssertEqual(probe.phase, .loading)
        let skipped = await probe.probe()
        XCTAssertNil(skipped)
        XCTAssertEqual(reads, 1)

        probe.cancel()
        first.cancel()
        continuations[0].resume(returning: .value(value))
        _ = await first.value
        XCTAssertEqual(probe.phase, .idle)
        XCTAssertNil(probe.snapshot)
        XCTAssertNil(probe.routineCount)

        let second = Task { await probe.probe() }
        await waitUntil { reads == 2 }
        continuations[1].resume(returning: .value(value))
        let phase = await second.value
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(probe.phase, .ready)
        XCTAssertEqual(probe.routineCount, 1)
    }

    @MainActor
    func testReadyProbeExposesCountForTheCardValue() async throws {
        let empty = try AgentRoutinesSnapshot(assistantID: NativeID(assistant),
                                              assistantPrincipal: NativeID(principal),
                                              serverTime: 1_800_000_000_000,
                                              legacyState: .clear, routines: [])
        let probe = AgentRoutinesProbe(read: { .value(empty) })
        await probe.probe()
        XCTAssertEqual(probe.phase, .ready)
        XCTAssertEqual(probe.routineCount, 0)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition not reached")
    }

    func testSnapshotDecodesClosedStructuredScheduleAndRequiredNulls() throws {
        let value = try NativeAPI.decode(AgentRoutinesSnapshot.self, from: snapshot())
        XCTAssertEqual(value.assistantID.rawValue, assistant)
        XCTAssertEqual(value.routines.first?.schedule,
                       .weekly(hour: 8, minute: 30, weekdays: [1, 2, 3, 4, 5]))
        XCTAssertFalse(try XCTUnwrap(value.routines.first).notifications)
        XCTAssertNil(value.routines.first?.lastRun)

        XCTAssertThrowsError(try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                                  from: snapshot(schedule: "{\"kind\":\"daily\",\"hour\":8,\"minute\":0,\"cron\":\"0 8 * * *\"}")))
        XCTAssertThrowsError(try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                                  from: snapshot(schedule: "{\"kind\":\"weekly\",\"hour\":8,\"minute\":0,\"weekdays\":[1.0]}")))
        let missingNull = Data(String(decoding: snapshot(), as: UTF8.self)
            .replacingOccurrences(of: ",\"lastRun\":null", with: "").utf8)
        XCTAssertThrowsError(try NativeAPI.decode(AgentRoutinesSnapshot.self, from: missingNull))
    }

    func testInstructionScalarAndByteLimitsMatchProvider() throws {
        func body(_ instruction: String) -> Data {
            let raw = String(decoding: snapshot(), as: UTF8.self)
                .replacingOccurrences(of: "Summarize my priorities.", with: instruction)
            return Data(raw.utf8)
        }
        XCTAssertNoThrow(try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                              from: body(String(repeating: "a", count: 20_000))))
        XCTAssertThrowsError(try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                                  from: body(String(repeating: "a", count: 20_001))))
        XCTAssertNoThrow(try NativeAPI.decode(AgentRoutinesSnapshot.self,
                                              from: body(String(repeating: "é", count: 20_000))))
    }

    func testWritesCarryOnlyHumanScheduleCASAndStableRequestIdentity() throws {
        let request = try NativeID("00000000-0000-4000-8000-ab798b5c9eee")
        let create = try AgentRoutineCreate(
            requestId: request, title: "  Morning brief  ", instruction: " Summarize. ",
            schedule: .daily(hour: 8, minute: 30), timezone: "Asia/Ho_Chi_Minh",
            enabled: true, notifications: true
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["operation", "requestId", "title", "instruction",
                                              "schedule", "timezone", "enabled", "notifications"]))
        XCTAssertEqual(object["operation"] as? String, "create")
        XCTAssertEqual(object["title"] as? String, "Morning brief")
        XCTAssertNil(object["cron"])

        let current = try XCTUnwrap(NativeAPI.decode(AgentRoutinesSnapshot.self, from: snapshot()).routines.first)
        let update = try AgentRoutineUpdate(requestId: request, routine: current, title: current.title,
                                            instruction: current.instruction, schedule: current.schedule,
                                            timezone: current.timezone, enabled: false, notifications: false)
        let updateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        XCTAssertEqual(updateObject["routineId"] as? String, routine)
        XCTAssertEqual(updateObject["expectedRevision"] as? Int, 3)
        let action = AgentRoutineAction(operation: .run, requestId: request, routine: current)
        let actionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        XCTAssertEqual(Set(actionObject.keys), Set(["operation", "requestId", "routineId", "expectedRevision"]))
    }

    func testInvalidTimezoneBoundsAndDuplicateRunsFailClosed() throws {
        XCTAssertThrowsError(try AgentRoutineCreate(
            requestId: NativeID("00000000-0000-4000-8000-ab798b5c9eee"),
            title: "Brief", instruction: "Do it", schedule: .monthly(day: 29, hour: 8, minute: 0),
            timezone: "Asia/Ho_Chi_Minh", enabled: true, notifications: true
        ))
        XCTAssertThrowsError(try AgentRoutineCreate(
            requestId: NativeID("00000000-0000-4000-8000-ab798b5c9eee"),
            title: "Brief", instruction: "Do it", schedule: .daily(hour: 8, minute: 0),
            timezone: "Not/A_Zone", enabled: true, notifications: true
        ))

        let run = "{\"occurrenceId\":\"00000000-0000-4000-8000-c2100016f8f4\",\"scheduledAt\":1,\"state\":\"completed\",\"outcome\":\"answered\"}"
        let data = Data("{\"profile\":\"atum.agent-routine-runs/1\",\"routineId\":\"\(routine)\",\"runs\":[\(run),\(run)]}".utf8)
        XCTAssertThrowsError(try NativeAPI.decode(AgentRoutineRunsSnapshot.self, from: data))
    }
}
