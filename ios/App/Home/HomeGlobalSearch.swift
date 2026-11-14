import AtumNativeAPI
import SwiftUI

// Home search's Channels, Messages and Files: the rest of desktop's roster
// global search (`apps/desktop/src/matrix/app.tsx` `MatrixAccountView`,
// `roster-global-search.ts`). People is in `HomeScreen.swift`; this file holds
// what the three new sections show and in what order.

/// One Team Space room Home search can list under Channels.
struct HomeSearchChannel: Equatable, Identifiable, Sendable {
    let roomID: String
    let name: String
    var id: String { roomID }
}

/// What Home search needs from the account's companies. Nil while the
/// Matrix session is not there (desktop: `ready: snapshot.state === 'ready'`).
struct HomeGlobalSearchActions {
    /// The joined Team Space rooms, channels and conversations, in the room
    /// list's order (desktop `snapshot.rooms` with `isTeamSpaceRoom`).
    var channels: [HomeSearchChannel]
    /// The companies Messages and Files ask. Empty: both complete at once
    /// with nothing, without asking (desktop `completeWithoutRequest`).
    var companyIDs: [String]
    /// The company rooms whose results may show right now (joined, known
    /// unencrypted, listed with the same binding). Results outside it are
    /// hidden at once: a leave, encryption or directory change removes them.
    var eligibility: CompanySearchEligibility
    /// Desktop `searchCompanies`: one tab, every company, companies in id
    /// order. A failure answers nothing.
    var search: @MainActor (String, CompanySearchTab) async -> [CompanySearchResult]
    /// Desktop `openGlobalEvent`: the message is checked again and its room
    /// opened. False when the check or the navigation fails; Home then posts
    /// the generic error.
    var open: @MainActor (CompanySearchResult) async -> Bool
}

/// Desktop `openGlobalEvent`, end to end: the result is confirmed (message
/// still there, room still eligible), then its company is activated (Home is
/// in no company, and the result may be another company's than the one
/// Workplace shows), then the route runs with that company as its selection
/// fence. `AppRoot` passes `openRoomAndRoute(_:requiringCompany:)` as `route`.
enum HomeSearchRoute {
    @MainActor
    static func open(_ result: CompanySearchResult, workspace: CompanyWorkspaceModel,
                     confirm: () async -> Bool,
                     route: (_ roomID: String, _ requiringCompany: String) async -> Bool) async -> Bool {
        guard await confirm(), workspace.activateCompany(result.companyID, owning: result.roomID) else { return false }
        return await route(result.roomID, result.companyID)
    }
}

/// The global search's sections, top to bottom (desktop
/// `data-matrix-global-search-results`), all above the roster's own matches.
enum HomeGlobalSearchSection: String, CaseIterable, Equatable {
    case people, channels, messages, files
}

enum HomeGlobalSearchPolicy {
    /// Desktop `normalizeMatrixRosterQuery`: marks folded away, lower case,
    /// đ as d, trimmed, one space for any run.
    static func normalize(_ value: String) -> String {
        let stripped = value.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: false
            default: true
            }
        }
        return String(String.UnicodeScalarView(stripped)).lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Desktop `globalChannels`: every Team Space room whose name holds the
    /// query, in the room list's order. Shown only while the query is long
    /// enough for the global search block (`HomePeopleSearchPolicy.term`).
    static func channels(_ rooms: [HomeSearchChannel], query: String) -> [HomeSearchChannel] {
        guard HomePeopleSearchPolicy.term(query) != nil else { return [] }
        let text = normalize(query)
        guard !text.isEmpty else { return [] }
        var seen = Set<String>()
        return rooms.filter { normalize($0.name).contains(text) && seen.insert($0.roomID).inserted }
    }

    /// Desktop's `companyKey`: the query and the companies asked. A new
    /// company asks again; the same ones in another order do not.
    static func companyKey(term: String?, companyIDs: [String]) -> String? {
        guard let term, !companyIDs.isEmpty else { return nil }
        return ([term] + Set(companyIDs).sorted()).joined(separator: "\u{0}")
    }

    /// Desktop shows a source's rows for the current query; the phone also
    /// keeps only rows whose room is still eligible.
    static func visible(_ results: [CompanySearchResult],
                        eligibility: CompanySearchEligibility) -> [CompanySearchResult] {
        eligibility.retained(results)
    }

    /// The sections that have something to show, in desktop's order.
    static func sections(people: Int, channels: Int, messages: Int, files: Int) -> [HomeGlobalSearchSection] {
        let counts: [HomeGlobalSearchSection: Int] = [.people: people, .channels: channels,
                                                      .messages: messages, .files: files]
        return HomeGlobalSearchSection.allCases.filter { (counts[$0] ?? 0) > 0 }
    }

    /// Desktop's "No results found": only once every source has answered and
    /// nothing at all, the roster's own matches included, is there.
    static func showsNoResults(searching: Bool, globalCount: Int, rosterCount: Int) -> Bool {
        !searching && globalCount == 0 && rosterCount == 0
    }
}

/// One query's answer from one company tab (Messages or Files). `pending`
/// covers the debounce and the request, like desktop's `status: 'pending'`.
struct HomeEventSearchState: Equatable {
    var key: String?
    var pending = false
    var results: [CompanySearchResult] = []

    static let idle = HomeEventSearchState(key: nil)
}

/// A Channels row: desktop's `Hash` and the room's name.
struct HomeSearchChannelRow: View {
    let design: LiveDesign
    let channel: HomeSearchChannel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 28
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(spacing: 12) {
            Image(atum.symbol(.hash))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(width: glyphColumn)
                .accessibilityHidden(true)
            Text(verbatim: channel.name)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: channel.name))
    }
}

/// A Messages or Files row: desktop's `Messages` / `Files` glyph, the room's
/// name above, then the file's name or the message's words (two lines).
struct HomeSearchEventRow: View {
    let design: LiveDesign
    let result: CompanySearchResult
    let section: HomeGlobalSearchSection
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 28
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(atum.symbol(section == .files ? .files : .messages))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(width: glyphColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.channelName)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(verbatim: result.text)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(result.channelName), \(result.text)"))
    }
}
