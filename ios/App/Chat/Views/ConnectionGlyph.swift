import SwiftUI

// B30 (revamp plan §1.9): a quiet `wifi.slash` in the navigation bar only
// while the sync service is offline or in error; never words in the
// transcript. The app root sets the `showsConnectionGlyph` environment value
// from the current runtime's `SessionLifecycle`
// (`SessionLifecycleControlling.showsConnectionGlyph`, which follows
// `SessionLifecyclePolicy`; the wiring lane does it in `AppRoot`); the
// chat screen puts this view in its toolbar. Accessibility label "Đang kết
// nối" (exported copy), one label for offline and error.
struct ConnectionGlyph: View {
    let design: LiveDesign

    @Environment(\.showsConnectionGlyph) private var showsGlyph
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if showsGlyph {
            // A bar draws no custom symbol (iOS 26), so the bar bitmap.
            design.barIcon(AtumGlyph.cloudOff.rawValue)
                .foregroundStyle(design.color("muted", scheme: scheme))
                .accessibilityLabel(ChatCopy.text(design, ChatCopy.Key.connecting))
                .accessibilityIdentifier("chat.connection")
        }
    }
}
