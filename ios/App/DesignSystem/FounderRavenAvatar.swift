import AtumDesign
import SwiftUI
import UIKit

/// The approved local raven for the exact Founder room only. Bytes come from
/// the committed design export and are rendered as a square image with no
/// recolouring or stretching. Other people keep the ordinary human avatar.
struct FounderRavenAvatar: View {
    let size: CGFloat
    let fallbackName: String

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(AtumAvatar.shape(size: size))
            } else {
                // Never an initial: this person has a real face; the bundled
                // raven is already on its way.
                AtumAvatar(kind: .person, name: fallbackName,
                           placeholder: .neutral, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: Request(size: size, scale: displayScale, isDark: scheme == .dark)) {
            image = nil
            guard let data = try? FounderRavenAsset.data(
                isDark: scheme == .dark, pointSize: size, scale: displayScale
            ), let decoded = UIImage(data: data) else { return }
            image = decoded
        }
    }

    private struct Request: Hashable {
        let size: CGFloat
        let scale: CGFloat
        let isDark: Bool
    }
}
