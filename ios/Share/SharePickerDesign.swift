import AtumNativeAPI
import Foundation
import SwiftUI

/// The extension's design inputs: the same Kit token file the app vendors (bundled
/// alone, not the app's design bundle) and the Phosphor subset in Share/Assets.xcassets.
enum SharePickerDesign {
    static let tokenResource = "atum-kit-tokens"

    static func kit(bundle: Bundle = .main) -> AtumKit? {
        guard let url = bundle.url(forResource: tokenResource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? AtumKit(data: data)
    }

    /// Asset names; scripts/generate-phosphor-symbols.py `SHARE_ALIASES` emits exactly these.
    enum Glyph: String, CaseIterable {
        case alert = "ph.warning-circle"
        case check = "ph.check"
        case checkCircle = "ph.check-circle"
        case file = "ph.file"
        case image = "ph.image"
        case text = "ph.file-text"
        case link = "ph.link"
        case video = "ph.film-strip"
    }

    /// Home's face for this chat (`ShareChat.face` comes from the roster row's kind).
    static func avatarKind(_ chat: ShareChat) -> AtumAvatarKind {
        switch chat.face {
        case .atum: .atum
        case .assistant: .assistant
        case .app: .app
        case .group: .group
        case .person: .person
        case nil: chat.isGroup ? .group : .person
        }
    }
}

/// Cached avatar thumbnails the extension may read. The extension never fetches:
/// the App Group holds the authenticated 192 px faces the notification service
/// cached, the same bytes Share Suggestions donate.
struct ShareAvatarSource: Sendable {
    static let pixelSide = 192
    let data: @Sendable (String) -> Data?

    static let appGroup = ShareAvatarSource { uri in
        (try? NotificationSharedStore())?.cachedAvatar(uri: uri, pixelSide: pixelSide)
    }
}

extension Image {
    init(share glyph: SharePickerDesign.Glyph) { self.init(glyph.rawValue) }
}
