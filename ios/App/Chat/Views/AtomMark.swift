import AtumDesign
import SwiftUI

/// The Kit working atom (the exported `marks/atom.json`), in the current
/// foreground colour, at rest.
///
/// Schema 2 (atum-app PR #823, Kit): one orbit circle, the centred nucleus
/// and one electron at its resting angle. Schema 1 (older pins): three tilted
/// orbits and the nucleus. `AtomWait` is the moving form.
struct AtomMark: View {
    /// Degrees from the top, clockwise; nil rests the electron where the
    /// export says (schema 2 only).
    var electronAngle: Double?

    var body: some View {
        Canvas { context, size in
            guard let geometry = AtomGeometry.vendored else { return }
            geometry.draw(in: &context, size: size, electronAngle: electronAngle)
        }
    }
}

/// Atum's only animated wait affordance.
///
/// Schema 2: the electron turns +360° every `motion.durationMs` (1600 ms),
/// linear, repeating; Reduce Motion leaves it at `restingAngleDegrees` (−45°).
/// Schema 1: one electron on each orbit on the exported alternate curve.
/// Debug UI tests (`-AtumUITestNoAnimations`) keep it at rest.
struct AtomWait: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let geometry = AtomGeometry.vendored, geometry.schema == .single {
            // Debug UI tests run without animations (`-AtumUITestNoAnimations`),
            // so XCUITest sees an idle app: the electron rests there too.
            if reduceMotion || ChatMotion.disabledForUITests {
                AtomMark()
            } else {
                TimelineView(.animation) { context in
                    AtomMark(electronAngle: geometry.electronAngle(at: context.date))
                }
            }
        } else {
            LegacyAtomWait()
        }
    }
}

/// The decoded `marks/atom.json`, either schema, in its own viewBox units.
struct AtomGeometry: Equatable, Sendable {
    enum Schema: Equatable, Sendable { case single, legacy }

    struct Orbit: Equatable, Sendable {
        var center: CGPoint
        /// Equal for the schema-2 circle; schema 1 orbits are ellipses.
        var radius: CGSize
        var rotationDegrees: Double
    }

    var schema: Schema
    var viewBox: CGSize
    var orbits: [Orbit]
    var strokeWidth: Double
    var strokeOpacity: Double
    var nucleusDiameterPercent: Double
    var electronDiameterPercent: Double
    var electronMinimumDiameter: Double
    var restingAngleDegrees: Double
    var durationMs: Double

    static let vendored: AtomGeometry? = try? decode(AtumDesign.data(for: "marks/atom.json"))

    static func decode(_ data: Data) throws -> AtomGeometry {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let viewBox = CGSize(width: raw.viewBox.width, height: raw.viewBox.height)
        let stroke = (width: raw.stroke.width, opacity: raw.stroke.opacity)
        if let orbit = raw.orbit {
            return AtomGeometry(schema: .single, viewBox: viewBox,
                                orbits: [Orbit(center: CGPoint(x: orbit.center.x, y: orbit.center.y),
                                               radius: CGSize(width: orbit.radius, height: orbit.radius),
                                               rotationDegrees: 0)],
                                strokeWidth: stroke.width, strokeOpacity: stroke.opacity,
                                nucleusDiameterPercent: raw.nucleus.diameterPercent,
                                electronDiameterPercent: raw.electron?.diameterPercent ?? 13,
                                electronMinimumDiameter: raw.electron?.minimumDiameterPx ?? 2.25,
                                restingAngleDegrees: raw.electron?.restingAngleDegrees ?? -45,
                                durationMs: raw.motion?.durationMs ?? 1600)
        }
        guard let orbits = raw.orbits, !orbits.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "atom.json has no orbit"))
        }
        return AtomGeometry(schema: .legacy, viewBox: viewBox,
                            orbits: orbits.map {
                                Orbit(center: CGPoint(x: $0.center.x, y: $0.center.y),
                                      radius: CGSize(width: $0.radius.x, height: $0.radius.y),
                                      rotationDegrees: $0.rotationDegrees)
                            },
                            strokeWidth: stroke.width, strokeOpacity: stroke.opacity,
                            nucleusDiameterPercent: raw.nucleus.diameterPercent,
                            electronDiameterPercent: raw.electron?.diameterPercent ?? 13,
                            electronMinimumDiameter: raw.electron?.minimumDiameterPx ?? 2.25,
                            restingAngleDegrees: raw.electron?.restingAngleDegrees ?? -45,
                            durationMs: raw.motion?.durationMs ?? 1600)
    }

    /// The electron's centre for an angle in degrees: 0° is the top of the
    /// orbit, angles run clockwise (x = cx + r·sin θ, y = cy − r·cos θ).
    func electronCenter(angleDegrees: Double) -> CGPoint {
        let orbit = orbits[0]
        let theta = angleDegrees * .pi / 180
        return CGPoint(x: orbit.center.x + orbit.radius.width * sin(theta),
                       y: orbit.center.y - orbit.radius.height * cos(theta))
    }

    /// One linear turn per `durationMs`, starting from the resting angle.
    func electronAngle(at date: Date) -> Double {
        let period = max(durationMs, 1) / 1000
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return restingAngleDegrees + 360 * progress
    }

    func draw(in context: inout GraphicsContext, size: CGSize, electronAngle: Double?) {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        let origin = CGPoint(x: (size.width - viewBox.width * scale) / 2,
                             y: (size.height - viewBox.height * scale) / 2)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        let style = GraphicsContext.Shading.foreground

        var ring = context
        ring.opacity = strokeOpacity
        for orbit in orbits {
            let ellipse = Path(ellipseIn: CGRect(x: -orbit.radius.width * scale, y: -orbit.radius.height * scale,
                                                 width: orbit.radius.width * 2 * scale,
                                                 height: orbit.radius.height * 2 * scale))
            let center = point(orbit.center)
            ring.stroke(ellipse.applying(CGAffineTransform(rotationAngle: orbit.rotationDegrees * .pi / 180)
                            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))),
                        with: style, lineWidth: strokeWidth)
        }

        let nucleus = viewBox.width * nucleusDiameterPercent / 100 * scale
        let middle = point(CGPoint(x: viewBox.width / 2, y: viewBox.height / 2))
        context.fill(Path(ellipseIn: CGRect(x: middle.x - nucleus / 2, y: middle.y - nucleus / 2,
                                            width: nucleus, height: nucleus)), with: style)

        guard schema == .single else { return }
        let electron = max(electronMinimumDiameter, viewBox.width * electronDiameterPercent / 100 * scale)
        let center = point(electronCenter(angleDegrees: electronAngle ?? restingAngleDegrees))
        context.fill(Path(ellipseIn: CGRect(x: center.x - electron / 2, y: center.y - electron / 2,
                                            width: electron, height: electron)), with: style)
    }

    private struct Raw: Decodable {
        struct Box: Decodable { let width: Double; let height: Double }
        struct Point: Decodable { let x: Double; let y: Double }
        struct SingleOrbit: Decodable { let center: Point; let radius: Double }
        struct LegacyOrbit: Decodable { let center: Point; let radius: Point; let rotationDegrees: Double }
        struct Stroke: Decodable { let opacity: Double; let width: Double }
        struct Nucleus: Decodable { let diameterPercent: Double }
        struct Electron: Decodable {
            let diameterPercent: Double
            let minimumDiameterPx: Double?
            let restingAngleDegrees: Double?
        }
        struct Motion: Decodable { let durationMs: Double? }

        let viewBox: Box
        /// Schema 2.
        let orbit: SingleOrbit?
        /// Schema 1.
        let orbits: [LegacyOrbit]?
        let stroke: Stroke
        let nucleus: Nucleus
        let electron: Electron?
        let motion: Motion?
    }
}

/// Schema 1's wait: one electron on each of the three orbits, on the
/// exported 1.6-second alternate curve. Kept so an older pin still moves.
private struct LegacyAtomWait: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0.0

    var body: some View {
        AtomMark()
            .overlay {
                if !reduceMotion {
                    LegacyAtomElectrons(phase: phase)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                phase = 0
                withAnimation(.timingCurve(0.37, 0, 0.63, 1, duration: 0.8)
                    .repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                phase = 0
                guard !reduced else { return }
                withAnimation(.timingCurve(0.37, 0, 0.63, 1, duration: 0.8)
                    .repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

private struct LegacyAtomElectrons: View {
    let phase: Double

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let scale = min(size.width, size.height) / 24
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radii = CGSize(width: 10.5 * scale, height: 3.48 * scale)
                let rotations = [0.0, 60.0, -60.0]
                let offsets = [0.0, -2.0 / 3.0, -4.0 / 3.0]
                let diameter = max(2.25, 24 * 0.13 * scale)

                for (index, rotation) in rotations.enumerated() {
                    let angle = .pi * (phase + offsets[index])
                    let x = radii.width * cos(angle)
                    let y = radii.height * sin(angle)
                    let radians = rotation * .pi / 180
                    let point = CGPoint(x: center.x + x * cos(radians) - y * sin(radians),
                                        y: center.y + x * sin(radians) + y * cos(radians))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - diameter / 2,
                                                        y: point.y - diameter / 2,
                                                        width: diameter, height: diameter)),
                                 with: .foreground)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
