@testable import AtumMobile
import AtumDesign
import Foundation
import UIKit
import XCTest

/// The Kit's glyphs on the phone: the working atom (either `marks/atom.json`
/// schema) and the Phosphor custom symbols behind every glyph alias.
@MainActor
final class KitGlyphTests: XCTestCase {
    /// atum-app `fix/kit-working-atom` (PR #823) `marks/atom.json`, schema 2.
    private let schema2 = Data("""
    {"color":"currentColor","electron":{"diameterPercent":13,"minimumDiameterPx":2.25,"restingAngleDegrees":-45},
     "kind":"atom","motion":{"direction":"clockwise","durationMs":1600,"reducedMotion":"static","repeats":"infinite",
     "timing":"linear"},"nucleus":{"diameterPercent":15},"orbit":{"center":{"x":12,"y":12},"radius":10.5},
     "schemaVersion":2,"stroke":{"nonScaling":true,"opacity":0.55,"width":1},"viewBox":{"height":24,"width":24}}
    """.utf8)

    func testSchemaTwoDecodesOneOrbitAndOneElectron() throws {
        let atom = try AtomGeometry.decode(schema2)
        XCTAssertEqual(atom.schema, .single)
        XCTAssertEqual(atom.orbits.count, 1)
        XCTAssertEqual(atom.orbits[0].radius.width, atom.orbits[0].radius.height)
        XCTAssertEqual(atom.restingAngleDegrees, -45)
        XCTAssertEqual(atom.durationMs, 1600)
        XCTAssertEqual(atom.nucleusDiameterPercent, 15)
    }

    /// 0° is the top of the orbit and angles run clockwise.
    func testElectronAngleIsMeasuredClockwiseFromTheTop() throws {
        let atom = try AtomGeometry.decode(schema2)
        let r = atom.orbits[0].radius.width
        let top = atom.electronCenter(angleDegrees: 0)
        XCTAssertEqual(top.x, 12, accuracy: 1e-9)
        XCTAssertEqual(top.y, 12 - r, accuracy: 1e-9)
        let right = atom.electronCenter(angleDegrees: 90)
        XCTAssertEqual(right.x, 12 + r, accuracy: 1e-9)
        XCTAssertEqual(right.y, 12, accuracy: 1e-9)
        let resting = atom.electronCenter(angleDegrees: atom.restingAngleDegrees)
        XCTAssertLessThan(resting.x, 12, "−45° rests up and to the left")
        XCTAssertLessThan(resting.y, 12)
    }

    /// One linear turn per period, starting from the resting angle.
    func testElectronTurnsOnceAPeriodLinearly() throws {
        let atom = try AtomGeometry.decode(schema2)
        let period = atom.durationMs / 1000
        let start = Date(timeIntervalSinceReferenceDate: period * 1000)
        /// The signed difference of two angles, in (−180, 180].
        func turn(_ a: Double, _ b: Double) -> Double {
            let d = (a - b).truncatingRemainder(dividingBy: 360)
            return d > 180 ? d - 360 : (d <= -180 ? d + 360 : d)
        }
        XCTAssertEqual(turn(atom.electronAngle(at: start), atom.restingAngleDegrees), 0, accuracy: 1e-3)
        XCTAssertEqual(turn(atom.electronAngle(at: start.addingTimeInterval(period / 4)),
                            atom.restingAngleDegrees + 90), 0, accuracy: 1e-3)
        XCTAssertEqual(turn(atom.electronAngle(at: start.addingTimeInterval(period / 2)),
                            atom.restingAngleDegrees + 180), 0, accuracy: 1e-3)
    }

    /// The shipped resource, not just the schema-2 decoding fixture, must
    /// match desktop's single-orbit working mark (owner reference, #47).
    func testVendoredWorkingAtomIsTheDesktopSingleOrbitMark() throws {
        let atom = try XCTUnwrap(AtomGeometry.vendored)
        XCTAssertEqual(atom.schema, .single)
        XCTAssertEqual(atom.orbits.count, 1)
        XCTAssertEqual(atom.nucleusDiameterPercent, 15)
    }

    /// Every glyph alias the app draws resolves to a Phosphor custom symbol
    /// that is compiled into the app's asset catalogue.
    func testEveryGlyphAliasIsACompiledPhosphorSymbol() {
        XCTAssertFalse(PhosphorSymbols.aliases.isEmpty)
        for (alias, name) in PhosphorSymbols.aliases {
            XCTAssertTrue(name.hasPrefix("ph."), alias)
            XCTAssertNotNil(UIImage(named: name), "\(alias) → \(name) is not in Assets.xcassets")
        }
    }

    /// Every typed glyph the views use has a Phosphor mapping, so no call
    /// site can reach the precondition.
    func testEveryTypedGlyphHasAPhosphorSymbol() {
        for glyph in AtumGlyph.allCases {
            XCTAssertNotNil(PhosphorSymbols.aliases[glyph.rawValue], glyph.rawValue)
        }
    }
}

/// Settings › Ignored people never shows an opaque allocated Matrix ID.
final class IgnoredPersonNameTests: XCTestCase {
    func testNameThenReadableAddressThenTheUnnamedWord() {
        XCTAssertEqual(IgnoredPerson(userID: "@lan:atum.test", name: "Lan").shownName(unnamed: "U"), "Lan")
        // A readable early localpart is a name, not a handle (desktop person-name.ts).
        XCTAssertEqual(IgnoredPerson(userID: "@lan:atum.test", name: " ").shownName(unnamed: "U"), "lan")
        XCTAssertEqual(IgnoredPerson(userID: "@user-0123456789abcdef01:atum.test", name: nil)
            .shownName(unnamed: "U"), "U")
        // MAS's old fallback name (the opaque localpart) is no name either.
        XCTAssertEqual(IgnoredPerson(userID: "@user-0123456789abcdef01:atum.test",
                                     name: "user-0123456789abcdef01").shownName(unnamed: "U"), "U")
    }
}
