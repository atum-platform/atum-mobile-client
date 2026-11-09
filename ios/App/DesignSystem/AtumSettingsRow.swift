import SwiftUI

/// One settings row, drawn to FlowPhone2 › Settings: a 20 pt light glyph in
/// ink-2, the title in `.body` ink, the value in `.body` ink-3, a light
/// caret in ink-4, at least 52 pt tall on a Kit `surface` group row. One
/// button and one accessibility element.
struct AtumSettingsRow: View {
    enum Indicator: Sendable {
        case push
        case external

        fileprivate var glyph: AtumGlyph {
            switch self {
            case .push: .chevronRight
            case .external: .arrowUpRight
            }
        }
    }

    let glyph: AtumGlyph
    let title: String
    var value: String?
    let indicator: Indicator?
    var identifier: String? = nil
    let action: () -> Void

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let atum {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(atum.symbol(glyph))
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    labels(atum)
                    if let indicator {
                        Image(atum.symbol(indicator.glyph))
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(atum.kitColor(.ink4, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(atum.kitColor(.surface, scheme: scheme))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier ?? "")
        }
    }

    @ViewBuilder private func labels(_ atum: AtumVisualSystem) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                titleText(atum)
                valueText(atum)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                titleText(atum)
                Spacer(minLength: 8)
                valueText(atum)
            }
        }
    }

    private func titleText(_ atum: AtumVisualSystem) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    @ViewBuilder private func valueText(_ atum: AtumVisualSystem) -> some View {
        if let value, !value.isEmpty {
            Text(value)
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    private var accessibilityLabel: String {
        [title, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

