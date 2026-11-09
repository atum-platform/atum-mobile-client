import Foundation
import ImageIO
import XCTest
@testable import AtumDesign

final class FounderRavenAssetTests: XCTestCase {
    func testVariantSelectionMatchesTheApprovedSizeSurfaceAndScale() {
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 1),
                       "marks/founder-raven.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 2),
                       "marks/founder-raven@2x.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 3),
                       "marks/founder-raven@3x.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: true, pointSize: 22, scale: 2),
                       "marks/founder-raven-on-bone-small@2x.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: true, pointSize: 48, scale: 3),
                       "marks/founder-raven-on-bone-small@3x.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 48.1, scale: 1),
                       "marks/founder-raven.png",
                       "the small cut is exactly 48 pt and below")
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 0.5),
                       "marks/founder-raven.png")
        XCTAssertEqual(FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 8),
                       "marks/founder-raven@3x.png")
    }

    func testAllTwelveExportedPngsDecodeAtTheExactPixelDimensions() throws {
        let cases: [(String, Int)] = [
            ("marks/founder-raven.png", 64),
            ("marks/founder-raven@2x.png", 128),
            ("marks/founder-raven@3x.png", 192),
            ("marks/founder-raven-small.png", 48),
            ("marks/founder-raven-small@2x.png", 96),
            ("marks/founder-raven-small@3x.png", 144),
            ("marks/founder-raven-on-bone.png", 64),
            ("marks/founder-raven-on-bone@2x.png", 128),
            ("marks/founder-raven-on-bone@3x.png", 192),
            ("marks/founder-raven-on-bone-small.png", 48),
            ("marks/founder-raven-on-bone-small@2x.png", 96),
            ("marks/founder-raven-on-bone-small@3x.png", 144),
        ]
        for (path, side) in cases {
            let data = try AtumDesign.data(for: path)
            XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], path)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), path)
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], path
            )
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, side, path)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, side, path)
            XCTAssertEqual((properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue,
                           true, path)
        }
    }

    func testSelectedBytesAreManifestedAndDistinct() throws {
        let paths = [
            FounderRavenAsset.path(isDark: false, pointSize: 64, scale: 1),
            FounderRavenAsset.path(isDark: false, pointSize: 48, scale: 2),
            FounderRavenAsset.path(isDark: true, pointSize: 64, scale: 3),
            FounderRavenAsset.path(isDark: true, pointSize: 24, scale: 3),
        ]
        var digests = Set<Data>()
        for path in paths {
            let data = try FounderRavenAsset.data(
                isDark: path.contains("on-bone"),
                pointSize: path.contains("-small") ? 24 : 64,
                scale: path.contains("@3x") ? 3 : path.contains("@2x") ? 2 : 1
            )
            XCTAssertFalse(data.isEmpty, path)
            digests.insert(data)
        }
        XCTAssertEqual(digests.count, paths.count)
    }
}
