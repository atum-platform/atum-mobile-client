import Foundation

/// Where the long-press overlay (B20, FlowPhone3 › Message actions) puts its
/// three parts: the reaction capsule, the lifted copy of the pressed message
/// and the menu. Pure geometry, so the rules are tested without a screen.
///
/// - The preview stays where the message was pressed whenever it can.
/// - The capsule and the menu sit on opposite sides of the preview, so
///   neither ever covers it or the other: the capsule above and the menu
///   below; for a message low on the screen they flip (menu above, capsule
///   below) instead of moving the message.
/// - When neither arrangement fits in place, the whole stack moves only as
///   far as it must to stay inside the safe area.
/// - A preview taller than the room left by the capsule and the menu is cut
///   to that height (`previewHeight`), so nothing ever runs off the screen.
///
/// Coordinates are the overlay's own (y grows downwards); `bounds` is the
/// band the stack may use, already inset from the safe area.
public struct MessageMenuLayout: Equatable, Sendable {
    public enum Arrangement: Equatable, Sendable {
        /// Capsule, preview, menu (top to bottom).
        case reactionsAbove
        /// Menu, preview, capsule (top to bottom).
        case menuAbove
    }

    public var arrangement: Arrangement
    /// The capsule's top, or nil when the message offers no reactions.
    public var reactionsTop: Double?
    public var previewTop: Double
    /// The preview's height after any cut (at most the measured one).
    public var previewHeight: Double
    public var menuTop: Double

    /// - Parameters:
    ///   - sourceTop: the pressed row's top, in overlay coordinates.
    ///   - bounds: the band the stack may occupy (top...bottom).
    ///   - reactions: the capsule's height; nil for no capsule.
    ///   - preview: the preview's natural height.
    ///   - menu: the menu's height (0 for no menu rows).
    ///   - gap: the space between two parts.
    public static func place(sourceTop: Double, bounds: ClosedRange<Double>, reactions: Double?,
                             preview: Double, menu: Double, gap: Double = 8) -> MessageMenuLayout {
        let top = bounds.lowerBound, bottom = bounds.upperBound
        let reactionsBand = reactions.map { $0 + gap } ?? 0
        let menuBand = menu > 0 ? menu + gap : 0
        let previewHeight = max(0, min(preview, bottom - top - reactionsBand - menuBand))
        // The message's own place, clamped so the preview itself is on screen.
        let anchored = min(max(sourceTop, top), max(top, bottom - previewHeight))

        func fits(above: Double, below: Double) -> Bool {
            anchored - above >= top && anchored + previewHeight + below <= bottom
        }

        let arrangement: Arrangement
        let previewTop: Double
        if fits(above: reactionsBand, below: menuBand) {
            arrangement = .reactionsAbove
            previewTop = anchored
        } else if fits(above: menuBand, below: reactionsBand) {
            arrangement = .menuAbove
            previewTop = anchored
        } else {
            // Shift: keep the menu on the side with more room.
            let roomAbove = anchored - top
            let roomBelow = bottom - (anchored + previewHeight)
            arrangement = roomBelow >= roomAbove ? .reactionsAbove : .menuAbove
            let above = arrangement == .reactionsAbove ? reactionsBand : menuBand
            let total = reactionsBand + previewHeight + menuBand
            let stackTop = min(max(anchored - above, top), max(top, bottom - total))
            previewTop = stackTop + above
        }

        switch arrangement {
        case .reactionsAbove:
            return MessageMenuLayout(arrangement: arrangement,
                                     reactionsTop: reactions.map { previewTop - gap - $0 },
                                     previewTop: previewTop, previewHeight: previewHeight,
                                     menuTop: previewTop + previewHeight + (menu > 0 ? gap : 0))
        case .menuAbove:
            return MessageMenuLayout(arrangement: arrangement,
                                     reactionsTop: reactions.map { _ in previewTop + previewHeight + gap },
                                     previewTop: previewTop, previewHeight: previewHeight,
                                     menuTop: previewTop - (menu > 0 ? gap + menu : 0))
        }
    }
}
