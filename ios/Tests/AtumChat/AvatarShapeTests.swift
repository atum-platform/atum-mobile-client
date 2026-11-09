import AtumChat
import XCTest
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// face is a circle. Stated as invariants, so adding a kind needs a decision
/// here rather than a new snapshot.
final class AvatarShapeTests: XCTestCase {
    func testAppsAreSquirclesAndEveryOtherKindIsACircle() {
        for kind in AvatarKind.allCases {
            XCTAssertEqual(AvatarShapePolicy.frame(for: kind), kind == .app ? .squircle : .circle, "\(kind)")
        }
    }

    func testTheRadiusFollowsTheFrameAtEverySize() {
        for side in [18.0, 20.0, 32.0, 36.0, 44.0, 52.0, 72.0] {
            for kind in AvatarKind.allCases {
                let radius = AvatarShapePolicy.cornerRadius(for: kind, side: side)
                switch AvatarShapePolicy.frame(for: kind) {
                case .circle:
                    XCTAssertEqual(radius, side / 2, accuracy: 0.0001, "\(kind) is round")
                case .squircle:
                    XCTAssertGreaterThan(radius, 0, "\(kind) must not be a square")
                    XCTAssertLessThan(radius, side / 2, "\(kind) must not be a circle")
                    XCTAssertEqual(radius, side * AvatarShapePolicy.appCornerRadiusRatio, accuracy: 0.0001)
                }
            }
        }
    }
}

final class AvatarBackplateTests: XCTestCase {
    private let clear = AvatarPixel(red: 0, green: 0, blue: 0, alpha: 0)
    private let andyGreen = AvatarPixel(red: 0x5A, green: 0x9B, blue: 0x8A)
    private let white = AvatarPixel(red: 255, green: 255, blue: 255)

    private func edges(_ pixel: AvatarPixel) -> [AvatarPixel] { Array(repeating: pixel, count: 4) }

    /// The centre and four inner points of a solid disc.
    private var solid: [AvatarPixel] { Array(repeating: andyGreen, count: 5) }

    /// The policy with a solid interior unless a test says otherwise.
    private func backplate(corners: [AvatarPixel], edges: [AvatarPixel],
                           interior: [AvatarPixel]? = nil) -> AvatarPixel? {
        AvatarBackplatePolicy.backplate(corners: corners, edges: edges, interior: interior ?? solid)
    }

    func testAFlatDiscWithTransparentCornersIsFilledWithItsOwnColour() {
        // `andy-bot.png`: a green disc on a transparent square.
        let fill = backplate(corners: Array(repeating: clear, count: 4),
                                                   edges: edges(andyGreen))
        XCTAssertEqual(fill, andyGreen)
        // Demoza's original logo: a white disc.
        XCTAssertEqual(backplate(corners: Array(repeating: clear, count: 4),
                                                       edges: edges(white)), white)
    }

    func testAntialiasedAndSlightlyUnevenRimsStillCountAsFlat() {
        let rim = [AvatarPixel(red: 90, green: 155, blue: 138, alpha: 250),
                   AvatarPixel(red: 92, green: 154, blue: 140, alpha: 255),
                   AvatarPixel(red: 88, green: 157, blue: 137, alpha: 244),
                   AvatarPixel(red: 91, green: 155, blue: 139, alpha: 255)]
        let corners = Array(repeating: AvatarPixel(red: 9, green: 9, blue: 9, alpha: 20), count: 4)
        let fill = backplate(corners: corners, edges: rim)
        XCTAssertEqual(fill, AvatarPixel(red: 90, green: 155, blue: 138))
    }

    func testArtThatAlreadyFillsItsSquareIsLeftAlone() {
        // `andy-bot-v2.png` and any full-bleed catalogue art.
        XCTAssertNil(backplate(corners: Array(repeating: andyGreen, count: 4),
                                                     edges: edges(andyGreen)))
        // One opaque corner is enough: the art reaches into the square.
        let corners = [clear, clear, clear, andyGreen]
        XCTAssertNil(backplate(corners: corners, edges: edges(andyGreen)))
    }

    func testAGlyphOnNothingAndSemiTransparentArtAreNotInventedABackground() {
        XCTAssertNil(backplate(corners: Array(repeating: clear, count: 4),
                                                     edges: edges(clear)),
                     "a logo on a transparent square has no rim to match")
        let half = AvatarPixel(red: 10, green: 10, blue: 10, alpha: 128)
        XCTAssertNil(backplate(corners: Array(repeating: half, count: 4),
                                                     edges: edges(andyGreen)))
        XCTAssertNil(backplate(corners: Array(repeating: clear, count: 4),
                                                     edges: edges(AvatarPixel(red: 90, green: 155, blue: 138, alpha: 200))))
    }

    func testAGradientOrPhotoRimIsNotFlattened() {
        let rim = [andyGreen, white, andyGreen, white]
        XCTAssertNil(backplate(corners: Array(repeating: clear, count: 4), edges: rim))
    }

    func testMalformedSamplesAreRefused() {
        XCTAssertNil(backplate(corners: [], edges: []))
        XCTAssertNil(backplate(corners: Array(repeating: clear, count: 3),
                                                     edges: edges(andyGreen)))
        XCTAssertNil(backplate(corners: Array(repeating: clear, count: 4),
                                                     edges: Array(repeating: andyGreen, count: 5)))
    }

    func testARingKeepsItsHoleHoweverFlatItsRim() {
        let rim = Array(repeating: clear, count: 4)
        // A donut: the rim is the same flat colour, the centre is transparent.
        XCTAssertNil(backplate(corners: rim, edges: edges(andyGreen),
                               interior: [clear] + Array(repeating: andyGreen, count: 4)),
                     "a hole at the centre is not filled")
        // A thin ring: every inner point is inside the hole.
        XCTAssertNil(backplate(corners: rim, edges: edges(andyGreen),
                               interior: Array(repeating: clear, count: 5)))
        // One inner point in a hole is enough to leave the art alone.
        XCTAssertNil(backplate(corners: rim, edges: edges(andyGreen),
                               interior: Array(repeating: andyGreen, count: 4) + [clear]))
        // Semi-transparent inside is not a flat disc either.
        let half = AvatarPixel(red: 0x5A, green: 0x9B, blue: 0x8A, alpha: 128)
        XCTAssertNil(backplate(corners: rim, edges: edges(andyGreen),
                               interior: Array(repeating: half, count: 5)))
        // The same rim with a solid interior is still the disc that gets filled.
        XCTAssertEqual(backplate(corners: rim, edges: edges(andyGreen)), andyGreen)
    }

    func testTheInteriorMustBeTheFivePointsTheSamplerReads() {
        let rim = Array(repeating: clear, count: 4)
        XCTAssertNil(AvatarBackplatePolicy.backplate(corners: rim, edges: edges(andyGreen), interior: []))
        XCTAssertNil(AvatarBackplatePolicy.backplate(corners: rim, edges: edges(andyGreen),
                                                     interior: Array(repeating: andyGreen, count: 4)))
    }
}
