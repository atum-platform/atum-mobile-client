#if DEBUG
import AtumChat
import AtumNativeAPI
import Foundation

/// Debug only: the `chat.agent-desk` scenario's host routes (W4-E3). The
/// schedule and file listings are JSON in the Shell's exact shapes, decoded by
/// the real wire types. Controls are recorded for the UI probe and answer
/// `{changed: 1}`; `-AtumScriptedDeskStopped` answers 409 (its computer is off).
/// No network.
@MainActor
enum ScriptedAgentDesk {
    static func actions(scenario: String,
                        arguments: [String] = ProcessInfo.processInfo.arguments) -> AgentDeskActions? {
        guard scenario == ScriptedScenario.chatAgentDesk.rawValue else { return nil }
        let stopped = arguments.contains("-AtumScriptedDeskStopped")
        return AgentDeskActions(
            agentUserID: ScriptedCast.atum,
            steers: true,
            schedule: { try? NativeAPI.decode(HostAgentDesk.Schedule.self, from: Data(schedule.utf8)) },
            files: { path in
                let json = path == nil ? home : path == "home/reports" ? reports : nil
                return json.flatMap { try? HostAgentDesk.files(Data($0.utf8), for: path) }
                    .map(HostAgentDesk.FilesOutcome.listed) ?? .failed
            },
            control: { control in
                UITestProbe.append("control \(control.action)", to: "agent-desk.txt")
                try? await Task.sleep(for: .milliseconds(300))
                return stopped ? .stopped : .changed(1)
            }
        )
    }

    private static let schedule = #"""
    {"read":"schedule","observedAt":1763100000000,"truncated":false,"jobs":[
     {"id":"job-brief","name":"Bản tin sáng","kind":"cron","display":"0 8 * * 1-5","timezone":"Asia/Ho_Chi_Minh",
      "state":"scheduled","nextRunAt":"2026-11-24T08:00:00+07:00","lastRunAt":null,"lastStatus":null,
      "expr":"0 8 * * 1-5","minutes":null,"runAt":null},
     {"id":"job-review","name":"Tổng kết tuần","kind":"cron","display":"0 17 * * 5","timezone":"Asia/Ho_Chi_Minh",
      "state":"paused","nextRunAt":null,"lastRunAt":"2026-11-21T17:00:00+07:00","lastStatus":"ok",
      "expr":"0 17 * * 5","minutes":null,"runAt":null,"pausedReason":"owner_routine_off"}]}
    """#

    private static let home = #"""
    {"read":"files","root":"home","path":"","truncated":false,"rows":[
     {"name":"reports","kind":"folder","size":0,"modifiedAt":1763700000000},
     {"name":"notes.md","kind":"file","size":2048,"modifiedAt":1763800000000}]}
    """#

    private static let reports = #"""
    {"read":"files","root":"home","path":"reports","truncated":false,"rows":[
     {"name":"q3-summary.md","kind":"file","size":6144,"modifiedAt":1763600000000}]}
    """#
}
#endif
