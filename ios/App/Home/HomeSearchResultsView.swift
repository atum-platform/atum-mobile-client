import AtumChat
import AtumNativeAPI
import SwiftUI

// ML3 S1/S2/S16 Home views: mockup M1 (`m1-p-results`), desktop #158
// (`roster-message-results.tsx`) and #154 (roster filter). Values come from
// `HomeSearchController.shown` and `ChatRoomListFilterSession`; these views
// only draw them.

/// Search and filter words: the pinned export first, then the pending table
/// (`ChatSearchPendingCopy`), so a repin that carries a key takes over.
@MainActor
struct HomeSearchWords {
    let design: LiveDesign

    func text(_ key: ChatSearchCopyKey) -> String {
        design.copy.contains(key.rawValue)
            ? design.text(key.rawValue)
            : ChatSearchPendingCopy.text(key, locale: design.locale)
    }

    func filter(_ filter: ChatRoomListFilter) -> String {
        switch filter {
        case .all: text(.filterAll)
        case .unread: text(.filterUnread)
        case .favourites: text(.filterFavourites)
        }
    }

    /// The one coverage line; a match day reads as the reader's short date.
    func coverage(_ line: ChatSearchCoverageLine) -> String {
        let locale = Locale(identifier: design.locale)
        return line.text(word: text) { milliseconds in
            Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
                .formatted(.dateTime.day().month(.abbreviated).locale(locale))
        }
    }
}

/// A Kit chip (`.ak-chip`): a capsule, 32 pt, quiet outline; the chosen chip
/// is ink with on-ink words. Disabled chips stay in place (no layout jump)
/// and read as unavailable.
struct HomeChip: View {
    let design: LiveDesign
    let title: String
    let selected: Bool
    var enabled = true
    var leadingGlyph: AtumGlyph?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: atum.kit.space(.s1)) {
                if let leadingGlyph {
                    Image(atum.symbol(leadingGlyph))
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? atum.color(.onInk, scheme: scheme) : atum.color(.ink, scheme: scheme))
            .padding(.horizontal, atum.kit.space(.s3))
            .frame(minHeight: atum.kit.controlHeight(.md))
            .background {
                if selected {
                    Capsule().fill(atum.color(.ink, scheme: scheme))
                } else {
                    Capsule().strokeBorder(atum.color(.frame, scheme: scheme), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// S16: All / Unread / Favourites above the roster. Availability is
/// computed on the unfiltered roster; an unavailable filter stays drawn but
/// disabled, so the row never jumps while unread state changes.
struct HomeFilterChips: View {
    let design: LiveDesign
    let selection: ChatRoomListFilter
    let available: [ChatRoomListFilter]
    let select: (ChatRoomListFilter) -> Void
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var words: HomeSearchWords { HomeSearchWords(design: design) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: words.text(.filterMenu)))
        .accessibilityIdentifier("home.filters")
    }

    private var chips: some View {
        HStack(spacing: atum.kit.space(.s2)) {
            ForEach(ChatRoomListFilter.allCases, id: \.self) { filter in
                HomeChip(design: design, title: words.filter(filter), selected: filter == selection,
                         enabled: available.contains(filter)) { select(filter) }
                    .accessibilityIdentifier("home.filter.\(filter.rawValue)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// S2: the device-only scope, chosen before typing. Choosing clears the
/// field (the engine's `reset`); the private term never reaches any remote
/// source or the roster's own name matching.
struct HomeSearchScopeChips: View {
    let design: LiveDesign
    let scope: GlobalChatSearchScope
    let select: (GlobalChatSearchScope) -> Void
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var words: HomeSearchWords { HomeSearchWords(design: design) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.search.scope")
    }

    private var chips: some View {
        HStack(spacing: atum.kit.space(.s2)) {
            HomeChip(design: design, title: words.text(.plain), selected: scope == .plain) { select(.plain) }
                .accessibilityIdentifier("home.search.scope.plain")
            HomeChip(design: design, title: words.text(.device), selected: scope == .deviceOnly,
                     leadingGlyph: .lock) { select(.deviceOnly) }
                .accessibilityIdentifier("home.search.scope.device")
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// M1 decision 2: one card per chat, under the chat's face and name, the
/// company's name trailing for a company chat only (owner decision Q1).
/// Each hit is its own button: the snippet with the match marked, then
/// "Sender · time", a small lock after the time for a private hit.
struct HomeMessageGroupCard<Face: View>: View {
    let design: LiveDesign
    let group: ChatSearchResultGroup<HomeMessageHit>
    let roomName: String
    let query: String
    let time: (Int64) -> String
    let disabled: Bool
    let open: (HomeMessageHit) -> Void
    @ViewBuilder let face: () -> Face
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(group.hits.enumerated()), id: \.element.id) { index, hit in
                if index > 0 {
                    Rectangle()
                        .fill(atum.color(.frame, scheme: scheme))
                        .frame(height: 1 / displayScale) // design-lint: allow hairline
                }
                hitButton(hit)
            }
        }
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.messages.room.\(group.roomID)")
    }

    private var header: some View {
        HStack(spacing: kit.space(.s2)) {
            face()
                .accessibilityHidden(true)
            Text(verbatim: roomName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: kit.space(.s2))
            if let label = group.hits.first?.companyLabel {
                Text(verbatim: label)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, kit.space(.s4))
        .padding(.top, kit.space(.s3))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func hitButton(_ hit: HomeMessageHit) -> some View {
        Button { open(hit) } label: {
            VStack(alignment: .leading, spacing: kit.space(.s1)) {
                Text(marked(hit.snippet))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: kit.space(.s1)) {
                    Text(verbatim: meta(hit))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .lineLimit(1)
                    if hit.isPrivate {
                        Image(atum.symbol(.lock))
                            .font(.caption2)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, kit.space(.s4))
            .padding(.vertical, kit.space(.s3))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [roomName, hit.snippet, meta(hit)].joined(separator: ", ")))
        .accessibilityIdentifier("home.messages.\(hit.target.eventID)")
    }

    private func meta(_ hit: HomeMessageHit) -> String {
        [hit.senderName, time(hit.timestamp)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The query's places in the snippet, bold on the quiet selection fill.
    /// The snippet itself is never searched again to choose what opens.
    private func marked(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        for range in ChatSearchSnippetMarks.ranges(in: snippet, query: query) {
            guard let marked = Range(range, in: text) else { continue }
            text[marked].inlinePresentationIntent = .stronglyEmphasized
            text[marked].backgroundColor = atum.kitColor(.fillSelected, scheme: scheme)
        }
        return text
    }
}

/// M1 decision 4: one quiet line at the foot of the results.
struct HomeSearchCoverageLine: View {
    let design: LiveDesign
    let line: ChatSearchCoverageLine
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Text(verbatim: HomeSearchWords(design: design).coverage(line))
            .font(.footnote)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home.search.coverage")
    }
}
