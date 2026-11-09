import Foundation

/// The approved Founder raven raster family from the committed design export.
/// The bytes are used directly by the app; this type only selects the exact
/// variant and never redraws, recolours or rescales into a new asset.
public enum FounderRavenAsset {
    /// Light surfaces, above 48 pt.
    public static let full = "marks/founder-raven"
    /// Light surfaces, 48 pt and below.
    public static let small = "marks/founder-raven-small"
    /// Dark surfaces, above 48 pt.
    public static let onBone = "marks/founder-raven-on-bone"
    /// Dark surfaces, 48 pt and below.
    public static let onBoneSmall = "marks/founder-raven-on-bone-small"

    /// The exact resource path for the Founder's square face. `pointSize` is
    /// the intended rendered edge; `scale` is the display scale (1, 2, 3).
    public static func path(isDark: Bool, pointSize: CGFloat, scale: CGFloat) -> String {
        let base: String
        if pointSize <= 48 {
            base = isDark ? onBoneSmall : small
        } else {
            base = isDark ? onBone : full
        }
        let pixelScale = scale.isFinite ? max(1, min(3, Int(scale.rounded()))) : 1
        let suffix = pixelScale == 3 ? "@3x" : pixelScale == 2 ? "@2x" : ""
        return base + suffix + ".png"
    }

    /// The exact exported bytes. Missing or unmanifested resources refuse.
    public static func data(isDark: Bool, pointSize: CGFloat, scale: CGFloat) throws -> Data {
        try AtumDesign.data(for: path(isDark: isDark, pointSize: pointSize, scale: scale))
    }
}
