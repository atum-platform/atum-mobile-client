import SwiftUI
import UIKit

/// The phone's three motion tokens. Every visible state change uses one of them, never a
/// bare curve, a bare `withAnimation {}` or `.default` (`scripts/design_lint.py` checks).
///
/// - `quick`: state swaps, chips, toggles.
/// - `standard`: scroll-to, expand and collapse.
/// - `send`: sending a message, presenting the message menu.
///
/// Under Reduce Motion every token becomes a 0.15 s ease, and `motionTransition` swaps its
/// transition for a plain fade, so nothing slides or springs.
///
/// Use the view helpers, which read Reduce Motion for you:
/// `.motion(.quick, value: x)`, `.motionTransition(.move(edge: .bottom))` and
/// `withMotion(.send) { … }`.
enum Motion: CaseIterable, Sendable {
    case quick
    case standard
    case send

    /// How long the Reduce Motion fade lasts, for every token.
    static let reducedDuration: TimeInterval = 0.15

    /// The full-motion curve.
    var animation: Animation {
        switch self {
        case .quick: .snappy(duration: 0.2)
        case .standard: .smooth(duration: 0.3)
        case .send: .spring(duration: 0.3, bounce: 0.15)
        }
    }

    /// The curve to run: the token's own, or the short Reduce Motion ease.
    func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: Self.reducedDuration) : animation
    }

    /// The transition to pair with a token: `base`, or a plain fade under Reduce Motion.
    static func transition(_ base: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : base
    }
}

extension View {
    /// Animates changes to `value` with a motion token, honouring Reduce Motion.
    func motion<Value: Equatable>(_ motion: Motion, value: Value) -> some View {
        modifier(MotionAnimationModifier(motion: motion, value: value))
    }

    /// Inserts and removes this view with `base`, or a fade under Reduce Motion. The insert
    /// or removal itself must run inside `withMotion` or under `.motion(_:value:)`.
    func motionTransition(_ base: AnyTransition) -> some View {
        modifier(MotionTransitionModifier(base: base))
    }
}

/// Runs `body` inside a motion token's animation. `reduceMotion` defaults to the system
/// setting; a view that already reads `\.accessibilityReduceMotion` passes its own.
@MainActor
@discardableResult
func withMotion<Result>(_ motion: Motion,
                        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled,
                        _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.animation(reduceMotion: reduceMotion), body)
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    let motion: Motion
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

private struct MotionTransitionModifier: ViewModifier {
    let base: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(Motion.transition(base, reduceMotion: reduceMotion))
    }
}
