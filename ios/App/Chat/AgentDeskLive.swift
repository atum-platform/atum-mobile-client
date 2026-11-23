import AtumNativeAPI
import Foundation

/// The live agent's desk (W4-E3, atum-desktop PR #51) over the platform
/// routes desktop calls. Reads `LiveAppModel` only through
/// `agentDeskContext(roomID:)`; it never touches turn state.
extension LiveAppModel {
    /// The desk for an assistant room whose agent is on the roster. The host
    /// routes (its schedule, its own files, Pause and routine switches) are
    /// offered only for a `runtime: "hermes"` agent, as on desktop.
    func agentDeskActions(roomID: String) -> AgentDeskActions? {
        guard let context = agentDeskContext(roomID: roomID) else { return nil }
        let client = context.client
        let principal = context.agent.principal
        var actions = AgentDeskActions(agentUserID: context.agent.matrixUser?.rawValue,
                                       steers: context.agent.runsOnHermes)
        guard context.agent.runsOnHermes else { return actions }
        // A reply that lands after the account, client or agent changed is dropped.
        let current: @MainActor () -> Bool = { [weak self] in
            guard let now = self?.agentDeskContext(roomID: roomID) else { return false }
            return now.client === client && now.agent.principal == principal
        }
        actions.schedule = { () async -> HostAgentDesk.Schedule? in
            let schedule = try? await client.hostDeskSchedule(agent: principal)
            return current() ? schedule : nil
        }
        actions.files = { (path: String?) async -> HostAgentDesk.Files? in
            let files = try? await client.hostDeskFiles(agent: principal, path: path)
            return current() ? files : nil
        }
        actions.control = { (control: HostAgentDesk.Control) async -> HostAgentDesk.ControlOutcome in
            let outcome = await client.hostAgentControl(agent: principal, control)
            return current() ? outcome : .failed
        }
        return actions
    }
}
