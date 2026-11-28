import AtumChat
import AtumNativeAPI
import Observation
import SwiftUI

/// One answer from one Home search source. `missing` means the source does
/// not exist for this account (no people directory, no company); `failed`
/// is distinct from a successful empty answer.
enum HomeSearchOutcome<Value: Sendable>: Sendable {
    case missing
    case failed
    case value(Value)

    var value: Value? {
        if case let .value(value) = self { return value }
        return nil
    }

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Every remote Home search source for one query in the plain scope.
struct HomePlainSearchResults: Sendable {
    var people: HomeSearchOutcome<[HomeGroupCandidate]> = .missing
    var companyMessages: HomeSearchOutcome<[CompanySearchResult]> = .missing
    var companyFiles: HomeSearchOutcome<[CompanySearchResult]> = .missing
    var personal: HomeSearchOutcome<PersonalMessageSearch.Page> = .missing
    /// Company rooms eligible when the company requests were dispatched.
    var companyRooms = 0
}

typealias HomeDeviceSearchResults = HomeSearchOutcome<LocalSearchSource.Page>

/// What Home's search controller may call. `HomeScreen` builds it once per
/// live session from `HomeActions`. Every closure is main-actor isolated;
/// the device closures are the only ones that ever see a device-scope term.
struct HomeSearchSources {
    typealias IsCurrent = GlobalChatSearch<HomePlainSearchResults, HomeDeviceSearchResults>.IsCurrent

    struct Device {
        var search: @MainActor (String, @escaping IsCurrent) async throws -> LocalSearchSource.Page
        var retained: @MainActor ([GlobalChatSearchHit]) -> [GlobalChatSearchHit]
        var startBackfill: @MainActor () -> Void
        var stopBackfill: @MainActor () -> Void
        var observeRedactions: @MainActor ([GlobalChatSearchHit], @escaping @MainActor @Sendable () -> Void) -> Void
        var stopObservingRedactions: @MainActor () -> Void
    }

    var people: (@MainActor (String) async -> [HomeGroupCandidate]?)?
    var company: (@MainActor (String, CompanySearchTab) async -> [CompanySearchResult])?
    /// The company rooms a company request covers right now (0: none asked).
    var companyRooms: @MainActor () -> Int = { 0 }
    /// Company hits still eligible now (joined, unencrypted, same binding).
    var companyRetained: @MainActor ([CompanySearchResult]) -> [CompanySearchResult] = { $0 }
    var personal: (@MainActor (String, @escaping IsCurrent) async throws -> PersonalMessageSearch.Page)?
    var personalRetained: @MainActor ([GlobalChatSearchHit]) -> [GlobalChatSearchHit] = { _ in [] }
    var device: Device?
    /// The company name a room's hit is labelled with; nil for a personal
    /// chat (owner decision: company-only source labels).
    var companyLabel: @MainActor (_ roomID: String, _ companyID: String?) -> String? = { _, _ in nil }
    /// A sender's room display name, never a Matrix ID.
    var senderName: (@MainActor (_ roomID: String, _ userID: String) async -> String?)?
}

/// One message hit as Home draws it, whichever source found it. Opening
/// always uses `target` (room, event and thread IDs), never the snippet.
struct HomeMessageHit: Identifiable, Equatable {
    enum Origin: Equatable {
        case personal(GlobalChatSearchHit)
        case company(CompanySearchResult)
        case device(GlobalChatSearchHit)
    }

    let origin: Origin
    let target: ChatSearchEventTarget
    /// The source's room name; the roster's name wins where it has one.
    let roomName: String?
    let senderID: String
    let senderName: String?
    let snippet: String
    /// Milliseconds since 1970.
    let timestamp: Int64
    let companyLabel: String?
    /// Found by the device-only index (M1: the small lock after the time).
    var isPrivate: Bool {
        if case .device = origin { return true }
        return false
    }

    var id: ChatSearchEventTarget { target }
}

/// What the result list shows for the current query, already rechecked
/// against each source's current authority.
struct HomeSearchShown: Equatable {
    var people: [HomeGroupCandidate] = []
    var messages: [ChatSearchResultGroup<HomeMessageHit>] = []
    var files: [CompanySearchResult] = []
    /// Nil while idle or pending: coverage describes a finished search only.
    var coverage: ChatSearchCoverageLine?

    static let empty = HomeSearchShown()
}

/// Home's one search per live session (`GlobalChatSearch`). The plain scope
/// fans out to people, company messages and files, and personal messages as
/// structured children of one query. The device scope is chosen before
/// typing, clears the field, cancels and fences every remote query, and
/// sends its term only to the SDK's local index.
@MainActor
@Observable
final class HomeSearchController {
    typealias Engine = GlobalChatSearch<HomePlainSearchResults, HomeDeviceSearchResults>

    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private let sources: HomeSearchSources
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var backfilling = false
    @ObservationIgnored private var namesInFlight = Set<String>()
    /// Bumped on every engine change so SwiftUI re-reads the engine.
    private(set) var revision: UInt64 = 0
    private(set) var isClosed = false
    /// The current answer, rechecked; recomputed on engine and roster change,
    /// never on every frame (each recheck asks the SDK for current rooms).
    private(set) var shown = HomeSearchShown.empty
    /// Sender display names by room and user, filled after a page lands.
    private var senderNames = [String: String]()

    init(sources: HomeSearchSources, debounce: Duration = HomePeopleSearchPolicy.debounce) {
        self.sources = sources
        engine = Engine(debounce: debounce, plain: { term, isCurrent in
            await Self.plain(term, sources: sources, isCurrent: isCurrent)
        }, device: { term, isCurrent in
            await Self.device(term, sources: sources, isCurrent: isCurrent)
        })
        engine.onChange = { [weak self] in self?.engineChanged() }
    }

    // MARK: Reads (each registers the revision)

    var scope: GlobalChatSearchScope {
        _ = revision
        return engine.input.scope
    }

    var query: String {
        _ = revision
        return engine.query
    }

    var result: Engine.Result {
        _ = revision
        return engine.result
    }

    /// Capture with any async selection, then compare before acting.
    var generation: UUID {
        _ = revision
        return engine.generation
    }

    var offersDeviceScope: Bool { sources.device != nil }

    var isPending: Bool {
        if case .pending = result { return true }
        return false
    }

    /// The field's binding. Its setter holds the input token current when the
    /// binding was made, so a keystroke from a replaced scope is dropped.
    var text: Binding<String> {
        let input = engine.input
        return Binding(get: { [weak self] in self?.query ?? "" },
                       set: { [weak self] value in self?.engine.submit(value, for: input) })
    }

    // MARK: Lifecycle

    /// Choosing a scope clears the field and results before anything else can
    /// be typed. Choosing the current scope does nothing.
    func select(_ scope: GlobalChatSearchScope) {
        guard !isClosed, scope != engine.input.scope, scope == .plain || offersDeviceScope else { return }
        engine.reset(to: scope)
        updateBackfill()
    }

    /// Search dismissed (Cancel): back to plain, field cleared, device work stopped.
    func dismiss() {
        guard !isClosed else { return }
        engine.reset(to: .plain)
        updateBackfill()
    }

    func setForeground(_ foreground: Bool) {
        guard !isClosed, foreground != isForeground else { return }
        isForeground = foreground
        updateBackfill()
    }

    /// Roster, history, membership or ignore list changed: rerun the current
    /// query in the same scope and input, never in another.
    func refresh() {
        guard !isClosed else { return }
        engine.refresh()
    }

    /// The roster changed (a leave, a local delete, a classification): drop
    /// hits whose room is no longer eligible, without asking again.
    func revalidate() {
        guard !isClosed else { return }
        recompute()
    }

    /// The live session was replaced or signed out.
    func close() {
        guard !isClosed else { return }
        engine.reset(to: .plain)
        isClosed = true
        stopDevice()
        engine.onChange = nil
        shown = .empty
    }

    /// True while `generation` still names the query on screen.
    func isCurrent(_ generation: UUID) -> Bool {
        !isClosed && engine.generation == generation
    }

    // MARK: Engine

    private func engineChanged() {
        revision &+= 1
        recompute()
        guard !isClosed, let device = sources.device else { return }
        if case let .device(.value(page)) = engine.result, !page.results.isEmpty {
            let input = engine.input
            device.observeRedactions(page.results) { [weak self] in
                // Only the page shown for this field binding is refreshed.
                guard let self, !self.isClosed, self.engine.input == input else { return }
                self.engine.refresh()
            }
        } else {
            device.stopObservingRedactions()
        }
    }

    private func recompute() {
        guard !isClosed else {
            shown = .empty
            return
        }
        var next = HomeSearchShown()
        var hits = [HomeMessageHit]()
        switch engine.result {
        case .idle, .pending:
            break
        case let .plain(plain):
            next.people = plain.people.value ?? []
            for hit in sources.personalRetained(plain.personal.value?.results ?? []) {
                hits.append(message(hit, origin: .personal(hit), companyID: nil))
            }
            for result in sources.companyRetained(plain.companyMessages.value ?? []) {
                hits.append(HomeMessageHit(
                    origin: .company(result),
                    target: ChatSearchEventTarget(roomID: result.roomID, eventID: result.eventID,
                                                  threadRootID: result.threadRootID),
                    roomName: result.channelName, senderID: result.sender,
                    senderName: senderNames[Self.nameKey(result.roomID, result.sender)],
                    snippet: result.snippet, timestamp: result.at,
                    companyLabel: sources.companyLabel(result.roomID, result.companyID)))
            }
            next.files = sources.companyRetained(plain.companyFiles.value ?? [])
            let personal = plain.personal.value?.coverage
            next.coverage = .plain(
                personalSearched: personal?.searchedRooms, personalEncrypted: personal?.encryptedRooms ?? 0,
                personalTruncated: personal?.truncated ?? false, companyRooms: plain.companyRooms,
                // People is a directory, not a chat: its failure stays silent
                // as on desktop (`.catch(() => [])`).
                failed: plain.personal.failed || plain.companyMessages.failed || plain.companyFiles.failed)
        case let .device(outcome):
            switch outcome {
            case .missing, .failed:
                next.coverage = .deviceUnavailable
            case let .value(page):
                for hit in sources.device?.retained(page.results) ?? [] {
                    hits.append(message(hit, origin: .device(hit), companyID: nil))
                }
                next.coverage = .device(privateChats: page.eligibleRooms, earliestMatch: page.oldestMatchTimestamp,
                                        partial: page.truncated)
            }
        }
        next.messages = ChatSearchResultGrouping.groups(hits, roomID: \.target.roomID, eventID: \.target.eventID,
                                                        timestamp: \.timestamp)
        shown = next
        resolveSenderNames(hits)
    }

    private func message(_ hit: GlobalChatSearchHit, origin: HomeMessageHit.Origin,
                         companyID: String?) -> HomeMessageHit {
        HomeMessageHit(origin: origin, target: hit.id, roomName: hit.roomName, senderID: hit.senderID,
                       senderName: hit.senderName ?? senderNames[Self.nameKey(hit.id.roomID, hit.senderID)],
                       snippet: hit.snippet, timestamp: hit.timestamp,
                       companyLabel: sources.companyLabel(hit.id.roomID, companyID))
    }

    /// Server search carries no profiles. Names are read once per room and
    /// sender from the SDK's member cache, then the list redraws in place.
    private func resolveSenderNames(_ hits: [HomeMessageHit]) {
        guard let senderName = sources.senderName else { return }
        let missing = Set(hits.filter { $0.senderName == nil }.map { Self.nameKey($0.target.roomID, $0.senderID) })
            .subtracting(namesInFlight).subtracting(senderNames.keys)
        guard !missing.isEmpty else { return }
        namesInFlight.formUnion(missing)
        let pairs = hits.filter { missing.contains(Self.nameKey($0.target.roomID, $0.senderID)) }
            .map { ($0.target.roomID, $0.senderID) }
        Task { [weak self] in
            var found = [String: String]()
            for (room, user) in pairs where found[Self.nameKey(room, user)] == nil {
                if let name = await senderName(room, user) { found[Self.nameKey(room, user)] = name }
            }
            guard let self, !self.isClosed else { return }
            self.namesInFlight.subtract(missing)
            guard !found.isEmpty else { return }
            self.senderNames.merge(found) { _, new in new }
            self.recompute()
        }
    }

    private static func nameKey(_ roomID: String, _ userID: String) -> String { roomID + "\u{0}" + userID }

    private func updateBackfill() {
        let wants = !isClosed && isForeground && engine.input.scope == .deviceOnly
        if wants, !backfilling {
            backfilling = true
            sources.device?.startBackfill()
        } else if !wants {
            stopDevice()
        }
    }

    private func stopDevice() {
        if backfilling { sources.device?.stopBackfill() }
        backfilling = false
        sources.device?.stopObservingRedactions()
    }

    // MARK: Sources

    /// One plain query's sources and fence, main-actor isolated (so the
    /// structured children below can share it without sending closures).
    @MainActor
    private final class PlainQuery {
        let term: String
        let sources: HomeSearchSources
        let isCurrent: HomeSearchSources.IsCurrent

        init(term: String, sources: HomeSearchSources, isCurrent: @escaping HomeSearchSources.IsCurrent) {
            self.term = term
            self.sources = sources
            self.isCurrent = isCurrent
        }
    }

    /// Each remote child checks `isCurrent` immediately before dispatch and
    /// again before its answer is used.
    private static func plain(_ term: String, sources: HomeSearchSources,
                              isCurrent: @escaping HomeSearchSources.IsCurrent) async -> HomePlainSearchResults {
        let companyRooms = sources.company == nil ? 0 : sources.companyRooms()
        let query = PlainQuery(term: term, sources: sources, isCurrent: isCurrent)
        async let people = people(query)
        async let messages = company(query, tab: .messages, rooms: companyRooms)
        async let files = company(query, tab: .files, rooms: companyRooms)
        async let personal = personal(query)
        return await HomePlainSearchResults(people: people, companyMessages: messages, companyFiles: files,
                                            personal: personal, companyRooms: companyRooms)
    }

    private static func people(_ query: PlainQuery) async -> HomeSearchOutcome<[HomeGroupCandidate]> {
        guard let search = query.sources.people else { return .missing }
        guard query.isCurrent() else { return .failed }
        guard let found = await search(query.term), query.isCurrent() else { return .failed }
        return .value(found)
    }

    private static func personal(_ query: PlainQuery) async -> HomeSearchOutcome<PersonalMessageSearch.Page> {
        guard let search = query.sources.personal else { return .missing }
        guard query.isCurrent() else { return .failed }
        do {
            let page = try await search(query.term, query.isCurrent)
            return query.isCurrent() ? .value(page) : .failed
        } catch {
            return .failed
        }
    }

    private static func company(_ query: PlainQuery, tab: CompanySearchTab, rooms: Int)
        async -> HomeSearchOutcome<[CompanySearchResult]> {
        guard let search = query.sources.company, rooms > 0 else { return .missing }
        guard query.isCurrent() else { return .failed }
        let found = await search(query.term, tab)
        return query.isCurrent() ? .value(found) : .failed
    }

    private static func device(_ term: String, sources: HomeSearchSources,
                               isCurrent: @escaping HomeSearchSources.IsCurrent) async -> HomeDeviceSearchResults {
        guard let device = sources.device else { return .missing }
        do {
            return .value(try await device.search(term, isCurrent))
        } catch {
            return .failed
        }
    }
}
