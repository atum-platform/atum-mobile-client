import SwiftUI

/// B5: the start of the room. It has no words (WS-C inventory: the start
/// header is not named), only room above the first message.
struct TimelineStartRow: View {
    var body: some View {
        Color.clear
            .frame(height: 12)
            .accessibilityHidden(true)
    }
}
