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
        // Checked before every send and again on every reply: nothing is sent,
        // and nothing lands, after the account, client or agent changed or the
        // agent stopped running on Hermes.
        let current: @MainActor () -> Bool = { [weak self] in
            guard let now = self?.agentDeskContext(roomID: roomID) else { return false }
            return now.client === client && now.agent.principal == principal && now.agent.runsOnHermes
        }
        actions.schedule = { try? await client.hostDeskSchedule(agent: principal) }
        actions.files = { (path: String?) async -> HostAgentDesk.FilesOutcome in
            do { return .listed(try await client.hostDeskFiles(agent: principal, path: path)) }
            catch is HostAgentDesk.ReadBusy { return .busy }
            catch { return .failed }
        }
        actions.control = { control in await client.hostAgentControl(agent: principal, control) }
        return actions.fenced(by: current)
    }
}

extension AgentDeskActions {
    /// Every host call checks `current` before it is sent and again when it
    /// answers: a call is never sent, and a reply never lands, once the
    /// account, client or agent changed or the agent left Hermes.
    func fenced(by current: @escaping @MainActor () -> Bool) -> AgentDeskActions {
        var fenced = self
        if let schedule {
            fenced.schedule = {
                guard current() else { return nil }
                let read = await schedule()
                return current() ? read : nil
            }
        }
        if let files {
            fenced.files = { path in
                guard current() else { return .failed }
                let outcome = await files(path)
                return current() ? outcome : .failed
            }
        }
        if let control {
            fenced.control = { request in
                guard current() else { return .failed }
                let outcome = await control(request)
                return current() ? outcome : .failed
            }
        }
        return fenced
    }
}
