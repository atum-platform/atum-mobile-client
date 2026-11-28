import AtumChat
import AtumDesign
import Foundation

/// The words of chat parity ML6 (S10 forward, S11 link cards, S14 room
/// mentions, S15 room upgrades). Forward and link-card words are exported
/// desktop `chat-copy` keys. Room-upgrade words come from desktop #160
/// (`room-upgrade-copy.ts`), which postdates the pin: they read the export
/// first and fall back to `RoomUpgradePendingCopy` (verbatim desktop values).
/// `@room` is the Matrix token itself, never translated.
@MainActor
struct ChatActionsCopy {
    let design: LiveDesign

    private static let chat = "src.matrix.chat-copy.copies."

    private func chat(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(Self.chat + key, arguments: arguments)
    }

    // MARK: S10 forward (desktop `forward-dialog.tsx`)

    var forward: String { chat("forward") }
    var forwardTitle: String { chat("forwardTitle") }
    var forwardSearch: String { chat("forwardSearch") }
    var forwardSend: String { chat("forwardSend") }
    func forwardSendTo(_ name: String) -> String { chat("forwardSendTo", [.text(name)]) }
    var forwardEmpty: String { chat("forwardEmpty") }
    func forwardTeamOnly(_ team: String) -> String { chat("forwardTeamOnly", [.text(team)]) }
    var forwardEncryptedOnly: String { chat("forwardEncryptedOnly") }
    var sent: String { chat("sent") }
    var retry: String { chat("retry") }
    var errorGeneric: String { chat("errorGeneric") }

    // MARK: S11 link cards (desktop `link-preview-card.tsx`)

    var hideLinkPreview: String { chat("hideLinkPreview") }

    // MARK: S15 room upgrades (desktop #160 `room-upgrade-band.tsx`)

    func upgrade(_ key: RoomUpgradePendingCopy.Key) -> String {
        if design.copy.contains(key.exportKey) { return design.text(key.exportKey) }
        return RoomUpgradePendingCopy.text(key, locale: design.locale)
    }
}
