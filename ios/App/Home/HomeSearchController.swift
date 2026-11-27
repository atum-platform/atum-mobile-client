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

/// What Home's search controller may call. Built once per live session in
/// `HomeScreen` from `HomeActions`. Every closure is main-actor isolated;
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
    var personal: (@MainActor (String, @escaping IsCurrent) async throws -> PersonalMessageSearch.Page)?
    var personalRetained: @MainActor ([GlobalChatSearchHit]) -> [GlobalChatSearchHit] = { _ in [] }
    var device: Device?
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
    /// Bumped on every engine change so SwiftUI re-reads the engine.
    private(set) var revision: UInt64 = 0
    private(set) var isClosed = false

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

    /// The live session was replaced or signed out.
    func close() {
        guard !isClosed else { return }
        engine.reset(to: .plain)
        isClosed = true
        stopDevice()
        engine.onChange = nil
    }

    /// The hits still eligible now, for each source's current authority.
    func retainedPersonal(_ hits: [GlobalChatSearchHit]) -> [GlobalChatSearchHit] {
        sources.personalRetained(hits)
    }

    func retainedDevice(_ hits: [GlobalChatSearchHit]) -> [GlobalChatSearchHit] {
        sources.device?.retained(hits) ?? []
    }

    /// True while `generation` still names the query on screen.
    func isCurrent(_ generation: UUID) -> Bool {
        !isClosed && engine.generation == generation
    }

    // MARK: Engine

    private func engineChanged() {
        revision &+= 1
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

    /// Each remote child checks `isCurrent` immediately before dispatch and
    /// again before its answer is used.
    private static func plain(_ term: String, sources: HomeSearchSources,
                              isCurrent: @escaping HomeSearchSources.IsCurrent) async -> HomePlainSearchResults {
        let companyRooms = sources.company == nil ? 0 : sources.companyRooms()
        async let people = people(term, sources: sources, isCurrent: isCurrent)
        async let messages = company(term, tab: .messages, sources: sources, rooms: companyRooms,
                                     isCurrent: isCurrent)
        async let files = company(term, tab: .files, sources: sources, rooms: companyRooms, isCurrent: isCurrent)
        async let personal = personal(term, sources: sources, isCurrent: isCurrent)
        return await HomePlainSearchResults(people: people, companyMessages: messages, companyFiles: files,
                                            personal: personal, companyRooms: companyRooms)
    }

    private static func people(_ term: String, sources: HomeSearchSources,
                               isCurrent: @escaping HomeSearchSources.IsCurrent)
        async -> HomeSearchOutcome<[HomeGroupCandidate]> {
        guard let search = sources.people else { return .missing }
        guard isCurrent() else { return .failed }
        guard let found = await search(term), isCurrent() else { return .failed }
        return .value(found)
    }

    private static func personal(_ term: String, sources: HomeSearchSources,
                                 isCurrent: @escaping HomeSearchSources.IsCurrent)
        async -> HomeSearchOutcome<PersonalMessageSearch.Page> {
        guard let search = sources.personal else { return .missing }
        guard isCurrent() else { return .failed }
        do {
            let page = try await search(term, isCurrent)
            return isCurrent() ? .value(page) : .failed
        } catch {
            return .failed
        }
    }

    private static func company(_ term: String, tab: CompanySearchTab, sources: HomeSearchSources, rooms: Int,
                                isCurrent: @escaping HomeSearchSources.IsCurrent)
        async -> HomeSearchOutcome<[CompanySearchResult]> {
        guard let search = sources.company, rooms > 0 else { return .missing }
        guard isCurrent() else { return .failed }
        let found = await search(term, tab)
        return isCurrent() ? .value(found) : .failed
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
