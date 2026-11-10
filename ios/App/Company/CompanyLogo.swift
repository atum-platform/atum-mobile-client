import SwiftUI

/// A company's mark: a circle (owner ruling 2, 2026-10-28: people, assistants,
/// groups and companies are circles; only apps are squircles). It draws the
/// logo the platform wrote to the company's channels (`m.room.avatar`, read
/// through authenticated Matrix media), and the Kit monogram only when there is
/// no logo. While a logo loads the face stays neutral, so a monogram never
/// flashes before the real mark.
struct CompanyLogo: View {
    let name: String
    let logoURI: String?
    let size: CGFloat
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    var body: some View {
        MatrixFace(kind: .group, name: name, matrixURI: logoURI, size: size,
                   loadMatrixThumbnail: loadMatrixThumbnail)
    }
}

/// One Team Space face: a member's photo, the company's logo or an
/// assistant's mark, loaded from its `mxc://` URI through the app's
/// authenticated thumbnail path. With no URI (or a failed load) it is the Kit
/// monogram of `name`.
struct MatrixFace: View {
    let kind: AtumAvatarKind
    let name: String
    let matrixURI: String?
    let size: CGFloat
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @State private var art: AtumAvatarArt?
    @State private var failed = false

    var body: some View {
        AtumAvatar(kind: kind, name: name, art: art,
                   placeholder: matrixURI != nil && !failed ? .neutral : .monogram,
                   size: size)
            .task(id: matrixURI) {
                art = nil
                failed = false
                guard let matrixURI else { return }
                let loaded = await AtumAvatarCandidateLoader.load(
                    matrixURI: matrixURI,
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

/// A group conversation's face: two overlapping round faces (desktop
/// `ConversationGroupAvatar`), the second one ringed in the page colour so the
/// overlap reads.
struct MatrixGroupFace: View {
    struct Person: Equatable {
        let name: String
        let matrixURI: String?
    }

    let people: [Person]
    let size: CGFloat
    let ring: Color
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    var body: some View {
        let small = size * 0.72
        ZStack(alignment: .topLeading) {
            if let first = people.first {
                MatrixFace(kind: .person, name: first.name, matrixURI: first.matrixURI, size: small,
                           loadMatrixThumbnail: loadMatrixThumbnail)
            }
            if people.count > 1 {
                let second = people[1]
                MatrixFace(kind: .person, name: second.name, matrixURI: second.matrixURI, size: small,
                           loadMatrixThumbnail: loadMatrixThumbnail)
                    .padding(1.5)
                    .background(Circle().fill(ring))
                    .offset(x: size - small - 1.5, y: size - small - 1.5)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
