import Foundation

/// The idempotency key of a model-choice write whose outcome may be unknown.
///
/// A write that failed in transit may have reached the provider, so an explicit
/// retry must replay it under the same request ID. But the key identifies one
/// operation: a different pick must never ride a stale key, or the platform
/// could answer the old operation for the new request. The key is therefore
/// kept together with the payload it was made for.
///
/// - `begin(_:)` returns the pending ID only for an identical payload; any other
///   payload gets a fresh ID and the stale pending one is dropped.
/// - `settled()` ends the operation (saved, or a definitive refusal such as a
///   conflict); a transport failure leaves it pending.
public struct ModelWriteRequests<Payload: Hashable & Sendable>: Sendable {
    private struct Entry: Sendable {
        let payload: Payload
        let id: NativeID
    }

    private var entry: Entry?

    public init() {}

    /// The payload whose outcome is unknown, if any.
    public var pendingPayload: Payload? { entry?.payload }

    public mutating func begin(_ payload: Payload,
                               makeID: () -> NativeID = Self.freshID) -> NativeID {
        if let entry, entry.payload == payload { return entry.id }
        let id = makeID()
        entry = Entry(payload: payload, id: id)
        return id
    }

    public mutating func settled() { entry = nil }

    public static func freshID() -> NativeID {
        // A lowercase UUID is always a valid `NativeID`.
        // swiftlint:disable:next force_try
        try! NativeID(UUID().uuidString.lowercased())
    }
}
