import Foundation

/// One request's completion gate. Timeout never waits for a cooperative fetch;
/// late results and concurrent OS expiry cannot invoke the handler a second time.
public final class PushDelivery<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: Value
    private var handler: ((Value) -> Void)?
    private var tasks: [Task<Void, Never>] = []

    public init(fallback: Value, handler: @escaping (Value) -> Void) {
        self.fallback = fallback; self.handler = handler
    }

    public func start(
        waitForDeadline: @escaping @Sendable () async throws -> Void,
        onDeadline: @escaping @Sendable () -> Void = {},
        onFailure: @escaping @Sendable (any Error) -> Void = { _ in },
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        let deadline = Task { [weak self] in
            do { try await waitForDeadline(); self?.expire(onDelivery: onDeadline) }
            catch { /* Cancellation after delivery. */ }
        }
        retain(deadline)
        let work = Task { [weak self] in
            do { self?.finish(try await fetch()) }
            catch { self?.expire(onDelivery: { onFailure(error) }) }
        }
        retain(work)
    }

    public func expire(onDelivery: () -> Void = {}) { finish(fallback, onDelivery: onDelivery) }

    public func finish(_ value: Value, onDelivery: () -> Void = {}) {
        let completion = lock.withLock { () -> (((Value) -> Void), [Task<Void, Never>])? in
            guard let handler else { return nil }
            self.handler = nil
            let pending = tasks; tasks.removeAll()
            return (handler, pending)
        }
        guard let (handler, pending) = completion else { return }
        pending.forEach { $0.cancel() }
        onDelivery()
        handler(value)
    }

    private func retain(_ task: Task<Void, Never>) {
        let finished = lock.withLock {
            guard handler != nil else { return true }
            tasks.append(task)
            return false
        }
        if finished { task.cancel() }
    }
}
