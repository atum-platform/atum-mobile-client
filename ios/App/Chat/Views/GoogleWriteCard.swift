import AtumNativeAPI
import SwiftUI

/// The owner's pending Google writes for one surface (W4-AA2, desktop #134
/// `MatrixGoogleWriteProposals` and `MatrixGoogleWorkWriteProposals`): an
/// assistant chat's cards above its composer, or Work's cards at the top of
/// Home. `GoogleWriteProposalStore` owns the list, the decisions and their
/// reconciliation; the surface registers while it is on screen and draws what
/// the store projects.
@MainActor
enum GoogleWriteCards {
    struct Shown: Identifiable {
        let id: GoogleWriteProposalCard.ID
        let presentation: GoogleWriteCardPresentation
    }

    /// The cards this surface draws, in the store's order; an unsupported one draws nothing.
    static func shown(_ store: GoogleWriteProposalStore, surface: GoogleWriteProposalSurface,
                      design: LiveDesign) -> [Shown] {
        store.cards(for: surface).compactMap { card in
            GoogleWriteCardPresentation(card, resolve: { design.text($0) }).map { Shown(id: card.id, presentation: $0) }
        }
    }

    /// The card bound to the store: a decision carries the ID captured from this projection.
    static func card(_ shown: Shown, store: GoogleWriteProposalStore, design: LiveDesign) -> some View {
        GoogleWriteCard(presentation: shown.presentation, design: design) { action in
            let id = shown.id
            Task { await store.decide(action == .approve ? .approve : .decline, cardID: id) }
        }
        .accessibilityIdentifier("google-write.card.\(shown.id.proposalID.rawValue)")
    }
}

/// The store and the Matrix room an assistant chat reads its proposals for.
struct GoogleWriteChatBinding {
    let store: GoogleWriteProposalStore
    let roomID: String
}

/// An assistant chat's cards, above its composer as on desktop. They scroll
/// inside at most `maxHeight`, so a long draft at a large text size never
/// pushes the composer off screen.
struct GoogleWriteChatCards: View {
    let store: GoogleWriteProposalStore
    let roomID: String
    let design: LiveDesign
    /// Changes with the chat's newest event: a refresh hint, never the source of a card.
    let activity: String?
    let maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let surface = GoogleWriteProposalSurface.assistant(roomID: roomID)
        let shown = GoogleWriteCards.shown(store, surface: surface, design: design)
        VStack(spacing: 0) {
            // Always present, so the surface stays registered while no card is listed.
            Color.clear
                .frame(height: 0)
                .googleWriteSurface(store, surface, activity: activity)
            if !shown.isEmpty {
                ScrollView {
                    VStack(spacing: design.kit.space(.s2)) {
                        ForEach(shown) { GoogleWriteCards.card($0, store: store, design: design) }
                    }
                    .padding(.horizontal, design.kit.space(.s4))
                    .padding(.vertical, design.kit.space(.s2))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: maxHeight > 0 ? min(contentHeight, maxHeight) : contentHeight)
                .accessibilityIdentifier("google-write.chat")
            }
        }
    }
}

/// Registers a surface with the store while it is on screen, with the store
/// session captured at that moment, and registers again when the session
/// changes. An assistant surface forwards its chat's activity as a refresh hint.
private struct GoogleWriteSurfaceRegistration: ViewModifier {
    let store: GoogleWriteProposalStore?
    let surface: GoogleWriteProposalSurface
    let activity: String?

    @State private var registered: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { register() }
            .onDisappear { unregister() }
            .onChange(of: store?.session) { _, _ in
                unregister()
                register()
            }
            .onChange(of: activity) { _, _ in
                if case let .assistant(roomID) = surface, let store {
                    store.hintAssistantMessage(roomID: roomID, session: store.session)
                }
            }
    }

    private func register() {
        guard let store else { return }
        let session = store.session
        registered = session
        store.setVisible(true, for: surface, session: session)
    }

    private func unregister() {
        guard let session = registered else { return }
        registered = nil
        store?.setVisible(false, for: surface, session: session)
    }
}

extension View {
    /// A nil store (no signed-in owner feed) registers nothing.
    func googleWriteSurface(_ store: GoogleWriteProposalStore?, _ surface: GoogleWriteProposalSurface,
                            activity: String? = nil) -> some View {
        modifier(GoogleWriteSurfaceRegistration(store: store, surface: surface, activity: activity))
    }
}

/// One Google write card. Open, it asks its question over the exact draft
/// (plain text, never markdown) with Approve and Decline; settled, it folds to
/// one line naming the request and one saying how it ended.
struct GoogleWriteCard: View {
    let presentation: GoogleWriteCardPresentation
    let design: LiveDesign
    let decide: (GoogleWriteCardPresentation.Action) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var kit: AtumKit { design.kit }

    var body: some View {
        Group {
            switch presentation.phase {
            case let .open(canDecide, busy, retryLine):
                open(canDecide: canDecide, busy: busy, retryLine: retryLine)
            case let .settled(summary, line):
                settled(summary: summary, line: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: announcement) { _, line in
            if let line { AccessibilityNotification.Announcement(line).post() }
        }
    }

    /// Desktop's `role="status"` lines: how a card ended, or that Atum was unreachable.
    private var announcement: String? {
        switch presentation.phase {
        case let .open(_, _, retryLine): retryLine
        case let .settled(_, line): line
        }
    }

    // MARK: Open

    private func open(canDecide: Bool, busy: GoogleWriteCardPresentation.Action?, retryLine: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous)
        return VStack(alignment: .leading, spacing: kit.space(.s3)) {
            HStack(alignment: .firstTextBaseline, spacing: kit.space(.s2)) {
                icon(.ink)
                Text(verbatim: presentation.question)
                    .font(kit.font(.bodyStrong))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            fields
            if let notice = presentation.approvalNotice {
                Text(verbatim: notice)
                    .font(kit.font(.caption))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
            actions(canDecide: canDecide, busy: busy)
            if let retryLine {
                Text(verbatim: retryLine)
                    .font(kit.font(.caption))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .accessibilityIdentifier("google-write.retry")
            }
        }
        .padding(kit.space(.s4))
        .background(kit.color(.surface, scheme: scheme), in: shape)
        .atumKitElevation(.one, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: presentation.question))
        .accessibilityValue(Text(verbatim: busy.map(busyWord) ?? ""))
    }

    @ViewBuilder private var fields: some View {
        let rows = presentation.blocks.compactMap { block -> (String, GoogleWriteCardPresentation.Value)? in
            if case let .row(label, value) = block { return (label, value) }
            return nil
        }
        if !rows.isEmpty {
            if typeSize.isAccessibilitySize {
                // Large text stacks each label over its value, so neither is squeezed to a sliver.
                VStack(alignment: .leading, spacing: kit.space(.s2)) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: kit.space(.s1)) {
                            label(row.0)
                            value(row.1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: kit.space(.s4),
                     verticalSpacing: kit.space(.s1)) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            label(row.0)
                            value(row.1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        ForEach(Array(presentation.blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .row:
                EmptyView()
            case let .note(text):
                Text(verbatim: text)
                    .font(kit.font(.caption))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
            case let .text(text):
                exact(text, muted: false)
            case let .quote(label, text, truncatedNote):
                HStack(alignment: .top, spacing: kit.space(.s3)) {
                    Capsule()
                        .fill(kit.color(.line, scheme: scheme))
                        .frame(width: 2) // design-lint: allow, desktop's 2 pt quote rule
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: kit.space(.s1)) {
                        Text(verbatim: label)
                            .font(kit.font(.caption))
                            .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        exact(text, muted: true)
                        if let truncatedNote {
                            Text(verbatim: truncatedNote)
                                .font(kit.font(.caption))
                                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(kit.font(.callout))
            .foregroundStyle(kit.color(.ink3, scheme: scheme))
    }

    private func value(_ value: GoogleWriteCardPresentation.Value) -> some View {
        let locale = Locale(identifier: design.locale)
        let text = switch value {
        case let .text(text), let .removal(text): text
        case let .time(time): GoogleWriteCardPresentation.time(time, locale: locale, timeZone: .current)
        case let .attachments(files): GoogleWriteCardPresentation.attachments(files, locale: locale)
        }
        return Text(verbatim: text)
            .font(kit.font(.callout))
            .foregroundStyle(kit.color(.ink, scheme: scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Exactly as written: line breaks kept, never markdown (`Text(verbatim:)`).
    private func exact(_ text: String, muted: Bool) -> some View {
        Text(verbatim: text)
            .font(kit.font(.callout))
            .foregroundStyle(kit.color(muted ? .ink2 : .ink, scheme: scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder private func actions(canDecide: Bool, busy: GoogleWriteCardPresentation.Action?) -> some View {
        let approve = Button { decide(.approve) } label: {
            HStack(spacing: kit.space(.s2)) {
                if busy == .approve {
                    ProgressView()
                        .controlSize(.small)
                        .tint(kit.color(.onInk, scheme: scheme))
                        .accessibilityHidden(true)
                }
                Text(verbatim: design.text(busy == .approve ? GoogleWriteCardPresentation.Keys.approving
                                                            : GoogleWriteCardPresentation.Keys.approve))
            }
        }
        .buttonStyle(AtumKitButtonStyle(kind: .primary, height: .regular))
        .disabled(!canDecide)
        .accessibilityIdentifier("google-write.approve")
        let decline = Button { decide(.decline) } label: {
            Text(verbatim: design.text(busy == .decline ? GoogleWriteCardPresentation.Keys.declining
                                                        : GoogleWriteCardPresentation.Keys.decline))
        }
        .buttonStyle(.atumPlain)
        .disabled(!canDecide)
        .accessibilityIdentifier("google-write.decline")

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: kit.space(.s2)) {
                if presentation.showsApprove { approve }
                decline
            }
        } else {
            HStack(spacing: kit.space(.s2)) {
                if presentation.showsApprove { approve }
                decline
            }
        }
    }

    private func busyWord(_ action: GoogleWriteCardPresentation.Action) -> String {
        design.text(action == .approve ? GoogleWriteCardPresentation.Keys.approving
                                       : GoogleWriteCardPresentation.Keys.declining)
    }

    // MARK: Settled

    private func settled(summary: String, line: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous)
        return VStack(alignment: .leading, spacing: kit.space(.s1)) {
            HStack(alignment: .firstTextBaseline, spacing: kit.space(.s2)) {
                icon(.ink2)
                Text(verbatim: summary)
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Text(verbatim: line)
                .font(kit.font(.caption))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("google-write.settled")
        }
        .padding(.horizontal, kit.space(.s4))
        .padding(.vertical, kit.space(.s3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kit.color(.sunk, scheme: scheme), in: shape)
        .accessibilityElement(children: .combine)
    }

    private func icon(_ role: AtumKit.ColorRole) -> some View {
        let glyph: AtumGlyph = switch presentation.glyph {
        case .mail: .mail
        case .calendar: .calendar
        case .draft: .pencil
        case .mailbox: .inbox
        case .label: .tag
        }
        return Image(design.symbol(glyph.rawValue))
            .font(kit.font(.callout))
            .foregroundStyle(kit.color(role, scheme: scheme))
            .accessibilityHidden(true)
    }
}
