import AtumDesign
import AtumChat
import Foundation

/// Every word the chat shows, by exported key (revamp plan §3.10;
/// coordinator decision 8, 2026-10-11: copy comes only from the atum-app
/// exports, no sentence is written in Swift). Keys are named as in the WS-C
/// inventory (atum-app  on
/// `lane/mobile-s1-copy`; its prefixes: `chat.` = `src.matrix.chat-copy.copies.`,
/// `phone.` = `src.matrix.mobile-copy.mobileChatCopy.`, `phoneDevice.` =
/// `src.matrix.mobile-device-copy.mobileDeviceCopy.`, `phoneApp.` =
/// `src.matrix.mobile-copy.mobilePhoneCopy.`, `matrix.` = `src.matrix.copy.copies.`).
///
/// This is the one copy helper of the chat. The pinned export contains every
/// key in the phone consumer contract; a missing key or mismatched argument
/// is a programming error rather than a Swift-authored fallback.
@MainActor
struct ChatCopy {
    typealias Key = ChatCopyKey

    let design: LiveDesign

    init(design: LiveDesign) {
        self.design = design
    }

    /// The localized text for `key` in the app's language.
    func text(_ key: Key, _ arguments: AtumCopy.Argument...) -> String {
        Self.text(design, key.rawValue, arguments)
    }

    /// The localized text for `key` in the app's language.
    static func text(_ design: LiveDesign, _ key: Key, _ arguments: [AtumCopy.Argument] = []) -> String {
        text(design, key.rawValue, arguments)
    }

    /// The localized text for a full exported key. Missing keys and argument
    /// mismatches fail like every other production `LiveDesign` lookup.
    static func text(_ design: LiveDesign, _ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}
