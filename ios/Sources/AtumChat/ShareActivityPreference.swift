import Foundation
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// §9.1): whether other people see this account's read receipts and typing.
/// On by default, like Zalo, and shared with desktop through the same Matrix
/// account-data event (`io.atum.desktop.share_activity`).
///
/// Off keeps receipts private (`m.read.private`) and sends no typing notice.
/// The switch is a human preference, never agent configuration or execution
/// authority.
public enum ShareActivityPreference {
    public static let eventType = "io.atum.desktop.share_activity"

    /// Desktop's account data is `{"version":1,"value":bool}`. Absent,
    /// unreadable, or the wrong shape means the default: on.
    public static func value(fromAccountData json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["value"] as? Bool else {
            return true
        }
        return value
    }

    /// The account-data content this phone writes back.
    public static func accountDataJSON(sharing: Bool) -> String {
        "{\"version\":1,\"value\":\(sharing ? "true" : "false")}"
    }

    /// The receipt the owner's open chat sends at the bottom of the screen.
    public static func receipt(sharing: Bool) -> ChatReceipt {
        sharing ? .readPublic : .readPrivate
    }
}
