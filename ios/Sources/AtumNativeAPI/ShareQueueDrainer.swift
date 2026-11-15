import Foundation

/// One foreground consumer. Prepare before claiming; ambiguous SDK handoffs require a decision.
@MainActor
public final class ShareQueueDrainer {
    public enum Outcome: Equatable { case complete, retryLater, needsReview }
    private var running = false
    public init() {}
    public func drain(queue: ShareQueue, account: ShareAccount,
                      prepare: (ShareJob, ShareJob.Delivery) async throws -> Void,
                      send: (ShareJob, ShareJob.Delivery) async throws -> Void) async throws -> Outcome {
        guard !running else { return .retryLater }
        running = true
        defer { running = false }
        var outcome = Outcome.complete
        for var job in try queue.jobs(account: account) {
            for i in job.deliveries.indices {
                let delivery = job.deliveries[i]
                if delivery.state == .accepted { continue }
                if delivery.state == .handingOff { outcome = .needsReview; continue }
                do { try Task.checkCancellation(); try await prepare(job, delivery) }
                catch { if outcome != .needsReview { outcome = .retryLater }; continue }
                job.deliveries[i].state = .handingOff
                try queue.save(job)
                do {
                    try await send(job, delivery)
                    job.deliveries[i].state = .accepted
                    try queue.save(job)
                } catch {
                    // The SDK may already own the message. Never auto-resubmit after this boundary.
                    outcome = .needsReview
                }
            }
            if job.deliveries.allSatisfy({ $0.state == .accepted }) { try queue.remove(job.id) }
        }
        return outcome
    }
    /// Explicit retry after the owner has checked for already-delivered copies.
    public func retryUncertain(queue: ShareQueue, account: ShareAccount) throws {
        for var job in try queue.jobs(account: account) {
            for i in job.deliveries.indices where job.deliveries[i].state == .handingOff { job.deliveries[i].state = .pending }
            try queue.save(job)
        }
    }
    public func discard(queue: ShareQueue, account: ShareAccount) throws {
        for job in try queue.jobs(account: account) { try queue.remove(job.id) }
    }
}
