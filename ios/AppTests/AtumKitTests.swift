@testable import AtumMobile
import AtumDesign
import Foundation
import SwiftUI
import XCTest

final class AtumKitTests: XCTestCase {
    /// A complete export in the generated shape, built from the reader's own role lists so
    /// the decoding and validation are exercised without the vendored file.
    private func export(dropping dropped: String? = nil, schemaVersion: Int = 1) throws -> Data {
        func table<Key: RawRepresentable & CaseIterable>(_: Key.Type, _ value: Any) -> [String: Any]
            where Key.RawValue == String {
            Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.rawValue, value) }.filter { $0.0 != dropped })
        }
        let rgba: [String: Any] = ["red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1]
        let layer: [String: Any] = ["x": 0, "y": 1, "blur": 2, "spread": 0, "color": rgba]
        let gradient: [String: Any] = ["angleDegrees": 180, "stops": [["color": rgba, "location": 0],
                                                                      ["color": rgba, "location": 1]]]
        let type: [String: Any] = ["size": 13, "lineHeight": 18, "weight": 600, "family": "text"]
        let json: [String: Any] = [
            "schemaVersion": schemaVersion, "kitVersion": "0.1.0", "colorSpace": "sRGB",
            "light": table(AtumKit.ColorRole.self, rgba), "dark": table(AtumKit.ColorRole.self, rgba),
            "gradients": ["light": ["monogram": gradient], "dark": ["monogram": gradient]],
            "shadows": ["light": table(AtumKit.ShadowLevel.self, [layer]),
                        "dark": table(AtumKit.ShadowLevel.self, [layer])],
            "type": table(AtumKit.TypeRole.self, type),
            "space": table(AtumKit.Space.self, 4), "radius": table(AtumKit.Radius.self, 14),
            "controlHeight": table(AtumKit.ControlHeight.self, 32), "icon": ["md": 18],
            "motion": ["ease": [0.32, 0.72, 0, 1]], "glass": ["blur": 24, "saturate": 170],
            "phone": ["controlHeight": table(AtumKit.PhoneControlHeight.self, 44), "appIconCornerRatio": 0.2237]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testDecodesACompleteExport() throws {
        let kit = try AtumKit(data: export())
        XCTAssertEqual(kit.rgba(.ink, scheme: .dark), AtumKit.RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        XCTAssertEqual(kit.radius(.xxl), 14)
        XCTAssertEqual(kit.space(.s12), 4)
        XCTAssertEqual(kit.phoneControlHeight(.primary), 44)
        XCTAssertEqual(kit.shadow(.two, scheme: .light).first?.blur, 2)
    }

    func testRefusesAnExportMissingARoleTheReaderNames() throws {
        XCTAssertThrowsError(try AtumKit(data: export(dropping: "panel-rim"))) { error in
            XCTAssertEqual(error as? AtumKit.LoadError, .missingToken("light.panel-rim"))
        }
        XCTAssertThrowsError(try AtumKit(data: export(dropping: "body-strong"))) { error in
            XCTAssertEqual(error as? AtumKit.LoadError, .missingToken("type.body-strong"))
        }
        XCTAssertThrowsError(try AtumKit(data: export(schemaVersion: 2))) { error in
            XCTAssertEqual(error as? AtumKit.LoadError, .unsupportedSchema(2))
        }
    }

    func testTypeRolesFollowDynamicType() {
        let expected: [AtumKit.TypeRole: Font.TextStyle] = [
            .display: .largeTitle, .title: .title2, .headline: .headline, .chat: .body,
            .body: .body, .bodyStrong: .body, .callout: .subheadline, .caption: .caption
        ]
        for role in AtumKit.TypeRole.allCases {
            XCTAssertEqual(role.textStyle, expected[role], role.rawValue)
        }
        XCTAssertEqual(AtumKit.weight(400), .regular)
        XCTAssertEqual(AtumKit.weight(500), .medium)
        XCTAssertEqual(AtumKit.weight(600), .semibold)
    }

    func testNoticeToneColoursOnlyTheIcon() {
        XCTAssertEqual(AtumNoticeTone.neutral.iconRole, .ink2)
        XCTAssertEqual(AtumNoticeTone.warning.iconRole, .warn)
        XCTAssertEqual(AtumNoticeTone.danger.iconRole, .danger)
    }

    @MainActor
    func testMonogramUsesFirstAndLastInitials() {
        XCTAssertEqual(AtumMonogramAvatar.initials("Nguyễn Văn An"), "NA")
        XCTAssertEqual(AtumMonogramAvatar.initials("linh"), "L")
        XCTAssertEqual(AtumMonogramAvatar.initials("  "), "")
    }

    func testAppIconIsAContinuousSquircle() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let expected = RoundedRectangle(cornerRadius: 100 * 0.2237, style: .continuous).path(in: rect)
        XCTAssertEqual(AtumAppIconShape().path(in: rect).boundingRect, expected.boundingRect)
        XCTAssertEqual(AtumAppIconShape().path(in: rect).description, expected.description)
        XCTAssertEqual(AtumAppIconShape().inset(by: 10).path(in: rect).boundingRect, rect.insetBy(dx: 10, dy: 10))
    }

    /// The committed export must carry the kit tokens required by the importer.
    func testVendoredExportCarriesTheApprovedKitValues() throws {
        let kit = try AtumKit.vendored()
        XCTAssertEqual(kit.tokens.kitVersion, "0.1.0")
        XCTAssertEqual(kit.rgba(.ink, scheme: .light),
                       AtumKit.RGBA(red: 0x1B / 255, green: 0x1D / 255, blue: 0x22 / 255, alpha: 1))
        XCTAssertEqual(kit.rgba(.ink, scheme: .dark),
                       AtumKit.RGBA(red: 0xEC / 255, green: 0xED / 255, blue: 0xF0 / 255, alpha: 1))
        XCTAssertEqual(kit.radius(.lg), 14)
        XCTAssertEqual(kit.radius(.xl), 20)
        XCTAssertEqual(kit.space(.s4), 16)
        XCTAssertEqual(kit.controlHeight(.md), 32)
        XCTAssertEqual(kit.phoneControlHeight(.primary), 50)
        XCTAssertEqual(kit.phoneControlHeight(.regular), 44)
        XCTAssertEqual(CGFloat(kit.tokens.phone.appIconCornerRatio), AtumAppIconShape.cornerRatio)
    }

    /// Every legacy role the map names is a real `phone-design.json` role, and a mapped role
    /// resolves through `LiveDesign` to the Kit token, so pre-Kit call sites draw Kit colours.
    @MainActor
    func testLegacyPaletteRolesResolveToKitTokens() throws {
        let design = try LiveDesign()
        for (legacy, role) in AtumKitLegacyRoles.table {
            XCTAssertNotNil(design.palette.light[legacy], legacy)
            XCTAssertNotNil(design.palette.dark[legacy], legacy)
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(design.color(legacy, scheme: scheme), design.kit.color(role, scheme: scheme), legacy)
            }
        }
        // Your own bubble is ink in light (Kit), never the legacy light grey.
        XCTAssertEqual(design.kit.rgba(.bubbleOwn, scheme: .light), design.kit.rgba(.ink, scheme: .light))
    }
}
