import Foundation

/// Whose face an avatar is. The kind decides the frame (Atum Kit STYLE §5,
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// apps (and companies and Store items, which are drawn as apps) are
/// squircles. The 2026-10-17 "one squircle everywhere" rule is retired.
public enum AvatarKind: Sendable, Equatable, CaseIterable {
    case atum
    case assistant
    case app
    case person
    case group

    /// A room member's face: an app is a squircle (Kit rule, STYLE §5),
    /// whether it chats 1:1 or sits in a group; an assistant and a person
    /// are circles.
    public static func member(isApp: Bool, isAssistant: Bool) -> AvatarKind {
        isApp ? .app : (isAssistant ? .assistant : .person)
    }
}

/// The two frames a face can have.
public enum AvatarFrame: Sendable, Equatable {
    case circle
    /// Apple's continuous-corner app-icon tile.
    case squircle
}

/// The one place that decides each kind's frame.
public enum AvatarShapePolicy {
    /// Corner radius over side for an app tile (`atum-kit-tokens.json` ›
    /// `phone.appIconCornerRatio`), drawn with `.continuous` corners.
    public static let appCornerRadiusRatio = 0.2237

    public static func frame(for kind: AvatarKind) -> AvatarFrame {
        kind == .app ? .squircle : .circle
    }

    /// The corner radius for a face of `kind` drawn `side` points wide: half
    /// the side for a circle, the app-icon ratio for a squircle.
    public static func cornerRadius(for kind: AvatarKind, side: Double) -> Double {
        switch frame(for: kind) {
        case .circle: side / 2
        case .squircle: side * appCornerRadiusRatio
        }
    }
}
