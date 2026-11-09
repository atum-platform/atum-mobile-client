import SwiftUI

/// The two exported Proton cuts from `marks/proton.json`.
///
/// The ring uses even-odd fill and the bar remains a separate shape, matching
/// the desktop mark without turning it into text or a bundled bitmap.
struct ProtonMark: View {
    enum Cut: Sendable {
        case small
        case regular

        fileprivate var baseSize: CGFloat { self == .small ? 13 : 22 }
        fileprivate var relativeTextStyle: Font.TextStyle { self == .small ? .subheadline : .title2 }
        fileprivate var outer: CGRect {
            self == .small
                ? CGRect(x: 9, y: 9, width: 46, height: 46)
                : CGRect(x: 9.5, y: 9.5, width: 45, height: 45)
        }
        fileprivate var inner: CGRect {
            self == .small
                ? CGRect(x: 16, y: 20, width: 28, height: 28)
                : CGRect(x: 13.1, y: 15.9, width: 35, height: 35)
        }
        fileprivate var bar: CGRect {
            self == .small
                ? CGRect(x: 28, y: 3, width: 8, height: 58)
                : CGRect(x: 29.4, y: 4, width: 5.2, height: 56)
        }
        fileprivate var barRadius: CGFloat { self == .small ? 0 : 2.6 }
    }

    let cut: Cut
    @ScaledMetric private var scaledSize: CGFloat

    init(_ cut: Cut) {
        self.cut = cut
        _scaledSize = ScaledMetric(wrappedValue: cut.baseSize, relativeTo: cut.relativeTextStyle)
    }

    var body: some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 64
            context.translateBy(x: (canvas.width - 64 * scale) / 2,
                                y: (canvas.height - 64 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            var ring = Path()
            ring.addEllipse(in: cut.outer)
            ring.addEllipse(in: cut.inner)
            context.fill(ring, with: .foreground, style: FillStyle(eoFill: true))

            let bar = Path(roundedRect: cut.bar, cornerRadius: cut.barRadius)
            context.fill(bar, with: .foreground)
        }
        .frame(width: scaledSize, height: scaledSize)
        .accessibilityHidden(true)
    }
}

