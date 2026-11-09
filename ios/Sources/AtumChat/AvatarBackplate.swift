import Foundation

/// One pixel read from decoded avatar art, as straight (not premultiplied)
/// 8-bit RGBA.
public struct AvatarPixel: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Decides whether decoded avatar art needs a colour behind it so the face
/// reads as the squircle the frame is.
///
/// The frame clips every face to a squircle, but a clip cannot fill what the
/// artwork leaves transparent. Round art (Andy's and Demoza's original logos)
/// is a flat disc on a transparent square: inside the squircle it still reads
/// as a circle, with the page showing in the four corners. The catalogue rule
/// is full-bleed opaque squares, but a disc can still arrive (an old catalogue
/// row, a cached Matrix profile avatar, a partner's own icon), so the phone
/// fills the squircle with the disc's own colour behind it. The artwork is not
/// moved, scaled or recoloured.
///
/// Only a *flat-rimmed, solid cut-out* is filled: the four corners are
/// transparent, the four edge midpoints are opaque and the same colour, and the
/// interior (the centre and four inner points) is opaque too. A ring or donut
/// has the same rim but a hole; filling it would paint over the hole, so it is
/// left as it is, like every other shape (art that already fills its square, a
/// glyph on nothing, a gradient or photo disc).
public enum AvatarBackplatePolicy {
    /// At or below this alpha a corner counts as transparent.
    public static let transparentAlphaMaximum: UInt8 = 24
    /// At or above this alpha an edge midpoint counts as opaque.
    public static let opaqueAlphaMinimum: UInt8 = 232
    /// The widest spread, per channel, among the edge midpoints that still
    /// counts as one flat colour.
    public static let flatRimTolerance = 20

    /// - Parameters:
    ///   - corners: top-left, top-right, bottom-left, bottom-right, a pixel or
    ///     two inside the image.
    ///   - edges: top, bottom, left, right midpoints, a pixel or two inside
    ///     the image.
    ///   - interior: the centre and the four points a quarter of the way in
    ///     from the corners. All five must be opaque: a transparent interior is
    ///     a hole (a ring), not a flat disc.
    /// - Returns: the opaque colour to paint behind the art, or nil.
    public static func backplate(corners: [AvatarPixel], edges: [AvatarPixel],
                                 interior: [AvatarPixel]) -> AvatarPixel? {
        guard corners.count == 4, edges.count == 4, interior.count == 5,
              corners.allSatisfy({ $0.alpha <= transparentAlphaMaximum }),
              edges.allSatisfy({ $0.alpha >= opaqueAlphaMinimum }),
              interior.allSatisfy({ $0.alpha >= opaqueAlphaMinimum }) else { return nil }
        let reds = edges.map { Int($0.red) }
        let greens = edges.map { Int($0.green) }
        let blues = edges.map { Int($0.blue) }
        for channel in [reds, greens, blues] {
            guard let low = channel.min(), let high = channel.max(),
                  high - low <= flatRimTolerance else { return nil }
        }
        return AvatarPixel(red: UInt8(reds.reduce(0, +) / 4),
                           green: UInt8(greens.reduce(0, +) / 4),
                           blue: UInt8(blues.reduce(0, +) / 4))
    }
}
