import AtumChat
import AtumDesign
import SwiftUI

/// Home's notification bell (W4-E3, atum-desktop PR #48 `attention-indicator.tsx`):
/// the one place the app asks the person to act. Quiet while nothing needs
/// them, wearing a small amber badge while something does. It opens a short
/// list (a popover, as on desktop) whose rows act from themselves; with
/// nothing to do it says so. It never opens by itself; a new item is announced
/// once to VoiceOver.
struct AttentionBell: View {
    let design: LiveDesign
    let items: [AttentionBellPolicy.Kind]
    let open: (AttentionBellPolicy.Kind) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var presented = false
    @State private var announced: Set<AttentionBellPolicy.Kind>?

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Button { presented = true } label: {
            Image(atum.symbol(.bell))
                .font(.system(size: 19, weight: .light))
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if !items.isEmpty {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 8, height: 8)
                            .offset(x: -11, y: 11)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(atum.color(.ink, scheme: scheme))
        .modifier(LiveGlass(design: design, radius: 22))
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityIdentifier("home.bell")
        .accessibilityValue(Text(verbatim: items.isEmpty ? "" : String(items.count)))
        .popover(isPresented: $presented, arrowEdge: .top) {
            list
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: items, initial: true) { _, current in
            let now = Set(current)
            defer { announced = now }
            guard let previous = announced, let added = current.first(where: { !previous.contains($0) }) else {
                if current.isEmpty { presented = false }
                return
            }
            AccessibilityNotification.Announcement(
                design.text(AttentionBellPolicy.prefixKey) + " " + label(added)).post()
        }
    }

    private var badgeColor: Color {
        design.kit.color(.warn, scheme: scheme)
    }

    private func label(_ kind: AttentionBellPolicy.Kind) -> String {
        design.text(AttentionBellPolicy.labelKey(kind))
    }

    /// One item says itself; several say how many (desktop `count`).
    private var summary: String {
        items.count == 1 ? label(items[0])
            : design.text(AttentionBellPolicy.countKey, arguments: [.number(Int64(items.count))])
    }

    private var spokenLabel: String {
        items.isEmpty ? design.text(AttentionBellPolicy.notificationsKey)
            : design.text(AttentionBellPolicy.prefixKey) + " " + summary
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(design.text(AttentionBellPolicy.notificationsKey))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text(design.text(AttentionBellPolicy.nothingKey))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                    .accessibilityIdentifier("home.bell.nothing")
            } else {
                ForEach(items, id: \.self) { kind in
                    Button {
                        presented = false
                        open(kind)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(badgeColor).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(verbatim: label(kind))
                                .font(.subheadline)
                                .foregroundStyle(atum.color(.ink, scheme: scheme))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            Image(atum.symbol(.chevronRight))
                                .font(.caption)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.bell.item." + kind.rawValue)
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 300, alignment: .leading)
        .background(atum.color(.ground, scheme: scheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.bell.list")
    }
}
