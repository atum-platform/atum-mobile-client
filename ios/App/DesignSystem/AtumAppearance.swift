import SwiftUI
import UIKit

/// Settings › General › Appearance (desktop: General › Look › Appearance):
/// follow the system, or always light, or always dark. Saved on this phone and
/// applied to every window at once, sheets included.
enum AtumAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// `UserDefaults` key. A launch argument (`-atum.appearance dark`) sets it
    /// for one run, which is how the captures force each mode.
    static let storageKey = "atum.appearance"

    static func current(_ defaults: UserDefaults = .standard) -> AtumAppearance {
        defaults.string(forKey: storageKey).flatMap(AtumAppearance.init(rawValue:)) ?? .system
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// The exported option words (the phone's own appearance rows).
    var copyKey: String {
        switch self {
        case .system: "src.matrix.mobile-device-copy.mobileDeviceCopy.appearanceRows0Label"
        case .light: "src.matrix.mobile-device-copy.mobileDeviceCopy.appearanceRows1Label"
        case .dark: "src.matrix.mobile-device-copy.mobileDeviceCopy.appearanceRows2Label"
        }
    }

    static let titleKey = "desktop.atum.settings.appearance"

    /// Sets the override on every window of every connected scene.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.overrideUserInterfaceStyle != interfaceStyle {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
}

/// Applies the saved appearance from a leaf view, so a change re-renders only
/// this empty view, never the app's root (whose initialisers load the model).
struct LiveAppearanceApplier: View {
    @AppStorage(AtumAppearance.storageKey) private var stored = AtumAppearance.system.rawValue

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: stored, initial: true) { _, value in
                (AtumAppearance(rawValue: value) ?? .system).apply()
            }
    }
}

/// A Phosphor glyph for a navigation-bar or toolbar button. iOS 26 bar buttons
/// draw nothing for a Regular-M-only custom symbol (they do draw it in rows,
/// menus and the tab bar), so a bar gets the same symbol drawn once into a
/// template bitmap at the bar's 17 pt, tinted like any bar image.
@MainActor
enum AtumBarIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String, pointSize: CGFloat = 17) -> Image {
        let key = "\(name)@\(pointSize)"
        if let cached = cache[key] { return Image(uiImage: cached).renderingMode(.template) }
        guard let symbol = UIImage(named: name)?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: pointSize)) else {
            return Image(name)
        }
        let bitmap = UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = bitmap
        return Image(uiImage: bitmap).renderingMode(.template)
    }
}

extension AtumVisualSystem {
    /// `AtumBarIcon` for a typed glyph.
    func barIcon(_ glyph: AtumGlyph) -> Image { AtumBarIcon.image(symbol(glyph)) }
}

extension LiveDesign {
    func barIcon(_ alias: String) -> Image { AtumBarIcon.image(symbol(alias)) }
}
