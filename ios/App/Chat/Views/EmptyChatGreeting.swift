import AtumChat
import SwiftUI

/// B2, §3.3, U10: the greeting in an empty chat, shown once the start of the
/// room is reached. It uses the Kit's Display role (system semibold, STYLE §10);
/// the Kit boards allow no serif anywhere.
struct EmptyChatGreeting: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            Text(theme.copy.text(.greeting))
                .font(.system(.largeTitle, weight: .semibold))
                .foregroundStyle(theme.color("ink", scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityIdentifier(AccessibilityID.chatGreeting)
        }
    }
}
