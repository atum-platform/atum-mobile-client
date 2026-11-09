import Foundation

/// App-specific colour policy.  It converts only validated catalog hex into
/// a presentation decision; SwiftUI turns the returned hex into `Color`.
public enum AppBrand {
    public static let onAccentHex = "#1B1D22"
    public static let minimumContrast: Double = 4.5

    public enum ButtonFill: Equatable, Hashable, Sendable {
        case accent(hex: String, labelHex: String)
        case primary
    }

    public struct Resolved: Equatable, Hashable, Sendable {
        public var buttonFill: ButtonFill
        public var avatarRingHex: String?

        public init(buttonFill: ButtonFill, avatarRingHex: String?) {
            self.buttonFill = buttonFill
            self.avatarRingHex = avatarRingHex
        }
    }

    /// An app accent is safe only when the fixed `onAccent` label meets WCAG
    /// AA normal-text contrast.  Invalid/missing/low-contrast input always
    /// falls back to Atum's primary button and no avatar ring.
    public static func resolve(accentHex: String?) -> Resolved {
        guard let accentHex, let normalized = normalizedHex(accentHex),
              let ratio = contrastRatio(foregroundHex: onAccentHex, backgroundHex: normalized),
              ratio >= minimumContrast else {
            return Resolved(buttonFill: .primary, avatarRingHex: nil)
        }
        return Resolved(buttonFill: .accent(hex: normalized, labelHex: onAccentHex), avatarRingHex: normalized)
    }

    public static func contrastRatio(foregroundHex: String, backgroundHex: String) -> Double? {
        guard let foreground = rgb(foregroundHex), let background = rgb(backgroundHex) else { return nil }
        let brighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (brighter + 0.05) / (darker + 0.05)
    }

    /// Returns a canonical uppercase `#RRGGBB` only; catalog colour values do
    /// not accept shorthand, alpha, whitespace or arbitrary CSS syntax.
    public static func normalizedHex(_ value: String) -> String? {
        guard value.utf8.count == 7, value.first == "#" else { return nil }
        let digits = value.dropFirst()
        guard digits.unicodeScalars.allSatisfy({
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 65 && $0.value <= 70) ||
            ($0.value >= 97 && $0.value <= 102)
        }) else { return nil }
        return "#" + digits.uppercased()
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard let normalized = normalizedHex(hex) else { return nil }
        func channel(_ start: String.Index) -> Double? {
            let end = normalized.index(start, offsetBy: 2)
            guard let value = UInt8(normalized[start..<end], radix: 16) else { return nil }
            return Double(value) / 255
        }
        let first = normalized.index(after: normalized.startIndex)
        let second = normalized.index(first, offsetBy: 2)
        let third = normalized.index(second, offsetBy: 2)
        guard let red = channel(first), let green = channel(second), let blue = channel(third) else { return nil }
        return (red, green, blue)
    }

    private static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}
