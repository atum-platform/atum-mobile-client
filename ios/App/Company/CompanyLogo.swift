import SwiftUI

/// A company's mark: an app tile (Kit STYLE §5, a squircle with a `line`
/// edge, "Team space … pins the company: its app tile"). It draws the logo the
/// platform wrote to the company's channels (`m.room.avatar`, read through
/// authenticated Matrix media), and the Kit monogram only when there is no
/// logo. While a logo loads the tile stays neutral, so a monogram never flashes
/// before the real mark.
struct CompanyLogo: View {
    let name: String
    let logoURI: String?
    let size: CGFloat
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @State private var art: AtumAvatarArt?
    @State private var failed = false

    var body: some View {
        AtumAvatar(kind: .app, name: name, art: art,
                   placeholder: logoURI != nil && !failed ? .neutral : .monogram,
                   size: size)
            .task(id: logoURI) {
                art = nil
                failed = false
                guard let logoURI else { return }
                let loaded = await AtumAvatarCandidateLoader.load(
                    matrixURI: logoURI,
                    pixelSide: AtumAvatar.thumbnailPixelSide(for: size),
                    loadMatrixThumbnail: loadMatrixThumbnail,
                    remoteCandidates: [])
                guard !Task.isCancelled else { return }
                art = loaded
                failed = loaded == nil
            }
            .accessibilityHidden(true)
    }
}
