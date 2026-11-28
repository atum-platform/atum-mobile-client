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
        let generation = accountScopeGeneration
        var actions = AgentDeskActions(agentUserID: context.agent.matrixUser?.rawValue,
                                       steers: context.agent.runsOnHermes)
        guard context.agent.runsOnHermes else { return actions }
        // The client checks this at transport start, including its 401 retry.
        let current: NativeDomainClient.DeskSendCheck = { [weak self] in
            guard let self, accountScopeGeneration == generation,
                  let now = agentDeskContext(roomID: roomID) else { return false }
            return now.client === client && now.agent.principal == principal && now.agent.runsOnHermes
        }
        actions.schedule = AgentDeskActions.liveSchedule(client: client, agent: principal, current: current)
        actions.files = { (path: String?) async -> HostAgentDesk.FilesOutcome in
            do { return .listed(try await client.hostDeskFiles(agent: principal, path: path, canSend: current)) }
            catch is HostAgentDesk.ReadBusy { return .busy }
            catch NativeDomainClientFailure.cancelled { return .cancelled }
            catch { return .failed }
        }
        actions.control = { control in await client.hostAgentControl(agent: principal, control, canSend: current) }
        return actions.fenced(by: current)
    }
}

extension AgentDeskActions {
    static func liveSchedule(client: NativeDomainClient, agent: NativeID,
                             current: @escaping NativeDomainClient.DeskSendCheck)
        -> @MainActor () async throws -> HostAgentDesk.Schedule? {
        { try await client.hostDeskSchedule(agent: agent, canSend: current) }
    }

    /// Check the desk context before entering a host call and after it returns.
    func fenced(by current: @escaping @MainActor () -> Bool) -> AgentDeskActions {
        var fenced = self
        if let schedule {
            fenced.schedule = {
                guard current() else { return nil }
                do {
                    let read = try await schedule()
                    return current() ? read : nil
                } catch {
                    guard current() else { return nil }
                    throw error
                }
            }
        }
        if let files {
            fenced.files = { path in
                guard current() else { return .cancelled }
                let outcome = await files(path)
                return current() ? outcome : .cancelled
            }
        }
        if let control {
            fenced.control = { request in
                guard current() else { return .cancelled }
                let outcome = await control(request)
                return current() ? outcome : .cancelled
            }
        }
        return fenced
    }
}
