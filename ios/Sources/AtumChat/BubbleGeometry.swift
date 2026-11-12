import Foundation
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// bubbles"), on plain numbers so it is tested without a screen.
///
/// - A bubble hugs its content: a short message gets a small bubble, a longer
///   one grows until the widest bubble, then wraps (Messages, WhatsApp,
///   Telegram).
/// - The widest bubble leaves a fixed gap on the far side, as Telegram does
///   (owner, 2026-11-11). Its far edge stops `farSideGap` points short of the
///   screen's edge, so a long assistant reply uses the phone's width instead
///   of a share of it. Desktop's `max-w-[min(36rem,78%)]` is bound by its
///   36rem cap on a Mac window; the 78% was never the binding rule there, so
///   this is a phone layout decision, not a parity change. The 36rem cap is
///   kept (`widest`) and only binds in landscape and on iPad.
/// - The face gutter in a group sits on the near side, inside the row: the
///   far gap stays the same, so a group's bubbles are narrower than a 1:1
///   chat's by the gutter (Telegram does the same).
/// - Parts that would stretch to any width they are offered (a code block, a
///   table, a rule, a row of Bot API buttons, the Show more label) do not
///   widen the bubble on their own: they take the width the text sets, or
///   their natural width when that is wider.
public enum BubbleGeometry {
    /// The gap between the widest bubble's far edge and the screen's edge.
    /// 48 pt: Telegram's measured gap is about 50 pt on the same screen; 48
    /// stays on the 4 pt grid and is two face widths, so incoming and
    /// outgoing columns never meet. The row's own side margin is part of it.
    public static let farSideGap: Double = 48
    /// Desktop's 36rem cap: never binds on an iPhone in portrait.
    public static let widest: Double = 576
    /// Never narrower than this, however small the row (a 96 pt image box).
    public static let minimumMaxWidth: Double = 96

    /// The widest a bubble may be in a row `row` points wide whose edges sit
    /// `margin` points in from the screen's, with a face gutter `gutter`
    /// points wide on its near side (0 when the chat draws no faces, or for
    /// my own bubbles).
    public static func maxWidth(row: Double, gutter: Double = 0, margin: Double = 16) -> Double {
        let far = max(0, farSideGap - margin)
        let width = min(widest, row - gutter - far).rounded(.down)
        return max(minimumMaxWidth, width)
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

    /// Wrapped text reports its longest line with that line's trailing
    /// space (SwiftUI hangs the space past the edge but counts it), so a
    /// wrapped bubble is up to one space wider than its words. Offered any
    /// width between the words and that width the text keeps its line
    /// breaks, so the bubble narrows to the narrowest width, at most `slack`
    /// (one space) below `width`, that keeps the same height
    /// (`keepsHeight`). Measured in `docs/ports/bubble-width-collapse.md`.
    public static func tightWidth(from width: Double, slack: Double, floor: Double = 0,
                                  keepsHeight: (Double) -> Bool) -> Double {
        var low = max(floor, width - slack)
        var high = width
        guard low < high else { return width }
        // Half points: layout values are kept to half a point elsewhere too.
        func half(_ value: Double) -> Double { (value * 2).rounded(.up) / 2 }
        if keepsHeight(low) { return min(width, half(low)) }
        while high - low > 0.25 {
            let middle = (low + high) / 2
            if keepsHeight(middle) { high = middle } else { low = middle }
        }
        return min(width, half(high))
    }
}
