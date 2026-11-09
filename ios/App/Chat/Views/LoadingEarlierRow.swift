import SwiftUI

/// B5: a small static atom at the top while older history loads. The atom is
/// the only sign of work: no words and no accessibility label.
struct LoadingEarlierRow: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AtomWait()
            .foregroundStyle(theme?.color("muted", scheme) ?? .secondary)
            .frame(width: 22, height: 22)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}
