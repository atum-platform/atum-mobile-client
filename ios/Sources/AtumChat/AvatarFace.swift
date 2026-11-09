import Foundation

/// What one avatar shows. Every avatar is the same squircle; the only
/// decision is whether the image fills it or a monogram stands in until an
/// image exists. There is no mark, ring or second frame inside the squircle.
public enum AvatarFace: Equatable, Sendable {
    case image
    case monogram(String)
}

public enum AvatarFacePolicy {
    public static func face(hasImage: Bool, name: String) -> AvatarFace {
        hasImage ? .image : .monogram(AvatarMonogram.text(for: name))
    }
}

public enum AvatarMonogram {
    /// The first letter of a display name, ignoring a leading `@` on a
    /// Matrix handle. An empty name keeps the existing `?` fallback.
    public static func text(for name: String) -> String {
        let trimmed = name.drop(while: { $0 == "@" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}
