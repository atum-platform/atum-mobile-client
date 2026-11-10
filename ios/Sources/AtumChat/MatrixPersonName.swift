import Foundation

/// How a person is named on screen (desktop `src/matrix/person-name.ts`,
/// ledger AC8). A Matrix ID is identity, never a name: new people's IDs are
/// opaque (`@user-<32 hex>`, agents `@agent-<20 hex>`), so nothing here ever
/// returns one as a name or a handle. A person shows as the name they set;
/// their @handle shows only when the alias directory said it is theirs.
/// Someone from another server keeps their full address in view, so a
/// familiar name never passes them off as someone here.
public enum MatrixPersonName {
    /// What to call someone, and the second line beside it.
    public struct Label: Equatable, Sendable {
        /// Their name, else their @handle, else a readable legacy localpart,
        /// else the caller's word for someone unnamed. Never an opaque ID.
        public let name: String
        /// Their @handle beside a name, or another server's full address.
        public let address: String?

        public init(name: String, address: String? = nil) {
            self.name = name
            self.address = address
        }
    }

    /// The part of a Matrix ID before the server (`@minh:atum.chat` → `minh`);
    /// empty for anything that is not a Matrix ID.
    public static func localpart(_ userID: String) -> String {
        guard userID.hasPrefix("@"), let colon = userID.firstIndex(of: ":") else { return "" }
        return String(userID[userID.index(after: userID.startIndex)..<colon])
    }

    /// Whether a Matrix ID is one of Atum's opaque, allocated IDs (people,
    /// agents, app proxies and the reserved families).
    public static func isOpaque(_ userID: String) -> Bool {
        isOpaqueLocalpart(localpart(userID))
    }

    /// A handle as the directory spells it (3–32, a letter first), or nil.
    public static func validHandle(_ handle: String?) -> String? {
        guard let handle, handle.range(of: #"^[a-z][a-z0-9_]{2,31}$"#, options: .regularExpression) != nil
        else { return nil }
        return handle
    }

    /// The name someone set, as a person reads it, or nil when they set none.
    /// The SDK reports a missing name as the Matrix ID and adds " (@id)" to a
    /// name two members share; MAS used to fall back to the localpart. None of
    /// those is a name.
    public static func name(_ raw: String?, userID: String) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let suffix = " (\(userID))"
        if name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.isEmpty || name == userID || (name == localpart(userID) && isOpaque(userID)) { return nil }
        // A "name" that is somebody's opaque ID (or only IDs) is still not a name.
        let rest = name.replacingOccurrences(of: opaqueIDInText, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s,()]"#, with: "", options: .regularExpression)
        return rest.isEmpty ? nil : name
    }

    /// A person as people see them. `handle` is only ever a directory-verified
    /// handle for this exact Matrix ID; `unnamed` is the localized word for
    /// someone with no name (`src.matrix.conversation-copy.copies.unnamed`).
    public static func label(name raw: String?, handle: String?, userID: String,
                             ownerUserID: String? = nil, unnamed: String) -> Label {
        let name = name(raw, userID: userID)
        if isRemote(userID, ownerUserID: ownerUserID) {
            return name.map { Label(name: $0, address: userID) } ?? Label(name: userID)
        }
        let verified = validHandle(handle)
        if let name { return Label(name: name, address: verified.map { "@" + $0 }) }
        if let verified { return Label(name: "@" + verified) }
        // An early readable ID (`@minh:…`) still reads as a name. It is not
        // shown as a handle: the directory may give that handle to someone else.
        let local = localpart(userID)
        return Label(name: !local.isEmpty && !isOpaque(userID) ? local : unnamed)
    }

    /// A room name as the chat list may show it, or nil (desktop
    /// `matrixReadableRoomName`). The SDK names an unnamed chat after its
    /// members, using a member's ID when they set no name and adding " (@id)"
    /// to a shared one: the suffixes go, and a name still built from an ID
    /// (or a bare room ID) is no name.
    public static func readableRoomName(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.replacingOccurrences(
            of: #"\s*\(@(user|agent|app|service|system)-[0-9a-f]{16,}:[^\s,()]+\)"#,
            with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.range(of: opaqueIDInText, options: .regularExpression) == nil,
              !(cleaned.hasPrefix("!") && cleaned.contains(":")) else { return nil }
        return cleaned
    }

    /// The name a list shows for someone, with no second line.
    public static func shown(_ raw: String?, userID: String, unnamed: String) -> String {
        label(name: raw, handle: nil, userID: userID, unnamed: unnamed).name
    }

    /// Someone on another homeserver than the signed-in person. An unknown
    /// owner means nobody is remote.
    public static func isRemote(_ userID: String, ownerUserID: String?) -> Bool {
        guard let ownServer = server(ownerUserID) else { return false }
        return server(userID) != ownServer
    }

    private static func server(_ userID: String?) -> String? {
        guard let userID, let colon = userID.firstIndex(of: ":"), colon > userID.startIndex else { return nil }
        return String(userID[userID.index(after: colon)...])
    }

    private static func isOpaqueLocalpart(_ localpart: String) -> Bool {
        localpart.range(of: #"^(user|agent|app|service|system)-[0-9a-f]{16,}$"#, options: .regularExpression) != nil
    }

    /// An Atum-shaped Matrix ID anywhere in a string.
    private static let opaqueIDInText = #"@(user|agent|app|service|system)-[0-9a-f]{16,}:[^\s,()]+"#
}
