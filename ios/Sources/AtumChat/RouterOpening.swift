/// The wave-2 deep-link seam shared by Home, push, Store and app-bot notice
/// buttons. The concrete app `Router` owns tab paths and presentation cleanup;
/// feature lanes call only these frozen names.
@MainActor
public protocol RouterOpening: AnyObject {
    /// Select Home and open exactly this joined, listed room. A concrete
    /// router replaces another open chat instead of stacking chats.
    func open(roomId: String)

    /// Select Home and enter first contact for a catalog app with no room.
    /// S5 P1 remains gated; freezing the signature does not enable it.
    func open(app: String)
}
