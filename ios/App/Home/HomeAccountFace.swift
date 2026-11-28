import AtumChat
import AtumDesign
import SwiftUI

/// Home's account face, which also carries what needs the person (P6, owner
/// decision 6, 28 Nov 2026). Desktop removed its bell (owner, 2026-11-24): what
/// waits sits at the top of the rail's account face, which wears a red dot
/// meanwhile (`rail-account.tsx`, `attention-indicator.tsx`). The phone does
/// the same with the causes it knows (`AttentionBellPolicy`):
///
/// - Nothing waits: the face opens Settings, as before.
/// - Something waits: the face wears the dot. It opens the old bell's short
///   list (a popover, as desktop's menu), whose rows act from themselves,
///   with Settings as its last row, desktop's attention-then-account order.
///
/// It never opens by itself; a new item is announced once to VoiceOver.
struct HomeAccountFace: View {
    let design: LiveDesign
    let name: String
    let art: AtumAvatarArt?
    let items: [AttentionBellPolicy.Kind]
    let openSettings: () -> Void
    let open: (AttentionBellPolicy.Kind) -> Void

    /// The face in the bar, inside the system's 44 pt target.
    static let size: CGFloat = 36

    @Environment(\.colorScheme) private var scheme
    @State private var presented = false
    @State private var announced: Set<AttentionBellPolicy.Kind>?

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }

    var body: some View {
        Button {
            if items.isEmpty { openSettings() } else { presented = true }
        } label: {
            AtumAvatar(kind: .person, name: name, art: art, size: Self.size)
                .overlay(alignment: .topTrailing) {
                    if !items.isEmpty {
                        // Desktop's face badge: a red dot with a ground ring.
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(atum.color(.ground, scheme: scheme), lineWidth: 2))
                            .transition(.opacity)
                            .accessibilityIdentifier("home.account.badge")
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityValue(Text(verbatim: items.isEmpty ? "" : String(items.count)))
        .accessibilityIdentifier("home.account")
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
        kit.color(.danger, scheme: scheme)
    }

    private var settingsTitle: String { design.text("desktop.atum.settings.title") }

    private func label(_ kind: AttentionBellPolicy.Kind) -> String {
        design.text(AttentionBellPolicy.labelKey(kind))
    }

    /// One item says itself; several say how many (desktop `count`).
    private var summary: String {
        items.count == 1 ? label(items[0])
            : design.text(AttentionBellPolicy.countKey, arguments: [.number(Int64(items.count))])
    }

    /// Settings, then what waits (desktop `Account: name · attention`).
    private var spokenLabel: String {
        items.isEmpty ? settingsTitle
            : settingsTitle + ", " + design.text(AttentionBellPolicy.prefixKey) + " " + summary
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: kit.space(.s1)) {
            Text(design.text(AttentionBellPolicy.notificationsKey))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .padding(.horizontal, kit.space(.s3))
                .padding(.top, kit.space(.s3))
                .padding(.bottom, kit.space(.s2))
                .accessibilityAddTraits(.isHeader)
            ForEach(items, id: \.self) { kind in
                row(title: label(kind), dot: true) {
                    presented = false
                    open(kind)
                }
                .accessibilityIdentifier("home.account.attention." + kind.rawValue)
            }
            Divider()
                .padding(.horizontal, kit.space(.s3))
            row(title: settingsTitle, dot: false) {
                presented = false
                openSettings()
            }
            .accessibilityIdentifier("home.account.settings")
            .padding(.bottom, kit.space(.s2))
        }
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.account.attention")
    }

    private func row(title: String, dot: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: kit.space(.s2)) {
                if dot {
                    Circle().fill(badgeColor).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(2)
                Spacer(minLength: kit.space(.s2))
                Image(atum.symbol(.chevronRight))
                    .font(.caption)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, kit.space(.s3))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
