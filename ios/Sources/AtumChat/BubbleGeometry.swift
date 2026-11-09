import Foundation
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// bubbles"), on plain numbers so it is tested without a screen.
///
/// - A bubble hugs its content: a short message gets a small bubble, a longer
///   one grows until the widest bubble, then wraps (Messages, WhatsApp).
/// - The widest bubble is 78% of the row (desktop geometry, B17). The face
///   gutter in a group sits beside the bubble, outside that width: a group's
///   long bubble is as wide as a 1:1 chat's, never narrower because of the
///   face. It only shrinks when the gutter would push it past the row.
/// - Parts that would stretch to any width they are offered (a code block, a
///   table, a rule, a row of Bot API buttons) do not widen the bubble on
///   their own: they take the width the text sets, or their natural width
///   when that is wider.
public enum BubbleGeometry {
    /// The widest bubble, as a share of the row (B17, desktop's 78%).
    public static let maxFraction: Double = 0.78
    /// Never narrower than this, however small the row (a 96 pt image box).
    public static let minimumMaxWidth: Double = 96

    /// The widest a bubble may be in a row `row` points wide, with a face
    /// gutter `gutter` points wide on its leading side (0 when the chat draws
    /// no faces, or for my own bubbles).
    public static func maxWidth(row: Double, gutter: Double = 0) -> Double {
        let share = (row * maxFraction).rounded(.down)
        return max(minimumMaxWidth, min(share, row - gutter))
    }

    /// The bubble's content width, from its stacked parts.
    ///
    /// - `fitted`: each part's width when offered `limit` (wrapped text
    ///   reports its longest line; a stretchy part reports `limit`).
    /// - `natural`: each part's width when offered no width at all (text on
    ///   one line; a stretchy part its own content's width).
    ///
    /// Each part counts the narrower of the two; the widest part sets the
    /// bubble; never wider than `limit`.
    public static func hugWidth(fitted: [Double], natural: [Double], limit: Double) -> Double {
        var width = 0.0
        for index in fitted.indices {
            let part = index < natural.count ? min(fitted[index], natural[index]) : fitted[index]
            width = max(width, part)
        }
        return min(width.rounded(.up), limit)
    }
}
