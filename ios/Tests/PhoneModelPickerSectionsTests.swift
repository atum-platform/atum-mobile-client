import AtumChat
import XCTest
@testable import AtumNativeAPI

/// The phone picker's layout rules, from T3 Code mobile's picker (owner,
/// 2026-10-24): a few defaults and favorites at the top, the rest under their
/// connection, search and the filter across all of it. The rows below are
/// synthetic where the live contract has no such row yet (no phone-visible
/// contract lists a connected catalog), and real projections where it does.
final class PhoneModelPickerSectionsTests: XCTestCase {
    typealias Row = PhoneModelPickerProjection.Row

    private func atum(_ alias: String, name: String? = nil, selected: Bool = false,
                      badges: [Row.Badge] = []) -> Row {
        Row(favoriteID: alias, source: .atum, model: alias,
            displayName: name ?? ManagedModelLineup.displayName(for: alias) ?? alias,
            selected: selected, selectable: true, badges: badges)
    }

    private func plan(_ model: String, name: String, selected: Bool = false) -> Row {
        Row(favoriteID: model, source: .chatGPTPlan, model: model, displayName: name,
            selected: selected, selectable: true)
    }

    private func key(_ provider: String, _ model: String, name: String, selected: Bool = false) -> Row {
        Row(favoriteID: provider + "/" + model, source: .ownKey(provider), model: model, displayName: name,
            selected: selected, selectable: true)
    }

    /// Atum's line-up, a ChatGPT plan with two models, and two own-key providers.
    private var catalog: [Row] {
        [
            atum(ManagedModelLineup.defaultAlias, badges: [.default]),
            atum(ManagedModelLineup.hardAlias),
            plan("gpt-6-luna", name: "GPT-6-Luna"),
            plan("gpt-6.1-sol", name: "GPT-6.1-Sol"),
            key("anthropic", "opus", name: "Claude Opus 5.5"),
            key("anthropic", "sonnet", name: "Claude Sonnet 5.5"),
            key("openrouter", "deepseek", name: "DeepSeek V4.1 Flash"),
        ]
    }

    private func make(_ rows: [Row]? = nil,
                      favorites: [String] = [],
                      query: String = "",
                      filter: PhoneModelPickerFilter = .none,
                      searchText: @escaping (Row) -> String = { _ in "" }) -> [PhoneModelPickerSection] {
        PhoneModelPickerSections.make(rows: rows ?? catalog, favorites: favorites, query: query,
                                      filter: filter, locale: Locale(identifier: "vi"),
                                      searchText: searchText)
    }

    private func models(_ section: PhoneModelPickerSection) -> [String] { section.rows.map(\.model) }

    // MARK: Section order

    func testDefaultsComeFirstThenOneSectionPerConnectionInFirstSeenOrder() {
        let sections = make()
        XCTAssertEqual(sections.map(\.id),
                       ["defaults", "connection:chatgpt_plan", "connection:own_key:anthropic",
                        "connection:own_key:openrouter"])
        XCTAssertEqual(models(sections[0]), [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias])
        XCTAssertEqual(models(sections[1]), ["gpt-6-luna", "gpt-6.1-sol"])
        XCTAssertEqual(models(sections[2]), ["opus", "sonnet"])
        XCTAssertEqual(models(sections[3]), ["deepseek"])
        XCTAssertFalse(sections[0].isCollapsible)
        XCTAssertTrue(sections.dropFirst().allSatisfy(\.isCollapsible))
    }

    func testAModelLivesInExactlyOneSection() {
        let favorites = ["anthropic/sonnet", "gpt-6.1-sol", ManagedModelLineup.hardAlias]
        let sections = make(favorites: favorites)
        let all = sections.flatMap(\.rows).map(\.stableID)
        XCTAssertEqual(all.count, Set(all).count, "no model is drawn twice")
        XCTAssertEqual(all.count, catalog.count, "no model is lost by starring")
    }

    func testStarringMovesAModelUpAndUnstarringMovesItBack() {
        let none = ModelPickerPreferences()
        let starred = none.toggling("gpt-6.1-sol")
        let layout = make(favorites: starred.favorites)
        XCTAssertEqual(models(layout[0]),
                       [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias, "gpt-6.1-sol"])
        XCTAssertEqual(models(layout[1]), ["gpt-6-luna"])

        let unstarred = starred.toggling("gpt-6.1-sol")
        XCTAssertEqual(make(favorites: unstarred.favorites), make(favorites: none.favorites),
                       "unstarring restores the layout exactly, in the catalog's own order")
        XCTAssertEqual(models(make(favorites: unstarred.favorites)[1]), ["gpt-6-luna", "gpt-6.1-sol"])
    }

    func testStarsAreNewestFirstAndAnAtumStarDoesNotDuplicateTheLineUp() {
        // `ModelPickerPreferences` keeps the newest star first.
        let sections = make(favorites: ["anthropic/sonnet", ManagedModelLineup.hardAlias, "gpt-6-luna"])
        XCTAssertEqual(models(sections[0]),
                       [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias, "sonnet", "gpt-6-luna"])
    }

    func testASectionWithNothingLeftIsNotDrawn() {
        let sections = make(favorites: ["openrouter/deepseek"])
        XCTAssertFalse(sections.map(\.id).contains("connection:own_key:openrouter"),
                       "its only model moved up, so its header goes with it")
        XCTAssertTrue(models(sections[0]).contains("deepseek"))
    }

    func testAStarOnAModelTheRowsDoNotListIsSimplyNotDrawn() {
        // A signed-out connection's model is not in the rows. Its star stays in
        // the person's stored preferences (`ModelPickerPreferencesTests`) and
        // the layout neither draws it nor disturbs the stars that are listed.
        let sections = make(favorites: ["signed-out/gone", "gpt-6.1-sol"])
        XCTAssertEqual(models(sections[0]),
                       [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias, "gpt-6.1-sol"])
        XCTAssertEqual(sections.flatMap(\.rows).count, catalog.count)
    }

    func testAReadOnlyRowWithNoOpaqueIdentityCannotBePinned() {
        let external = Row(favoriteID: nil, source: .ownKey("openrouter"), model: "openai/gpt-6.1-sol",
                           displayName: "openai/gpt-6.1-sol", selected: true, selectable: false)
        let sections = make([atum(ManagedModelLineup.defaultAlias), external],
                            favorites: ["openai/gpt-6.1-sol"])
        XCTAssertEqual(sections.map(\.id), ["defaults", "connection:own_key:openrouter"])
        XCTAssertEqual(models(sections[1]), ["openai/gpt-6.1-sol"])
    }

    // MARK: The star toggle and where it is kept

    func testStarToggleMovesTheModelAndSurvivesARestartThroughTheExistingStore() throws {
        let suite = "PhoneModelPickerSectionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModelPickerPreferencesStore(defaults: defaults)
        let account = "@an:atum.test"

        var preferences = store.read(matrixAccountID: account, destinationID: "mac:mini-a")
        preferences = preferences.toggling("gpt-6.1-sol")
        store.write(preferences, matrixAccountID: account, destinationID: "mac:mini-a")

        // A new store over the same defaults is what the next launch reads.
        let relaunched = ModelPickerPreferencesStore(defaults: defaults)
            .read(matrixAccountID: account, destinationID: "mac:mini-a")
        XCTAssertEqual(models(make(favorites: relaunched.favorites)[0]).last, "gpt-6.1-sol")

        // Another Mac's picker is its own list.
        let other = ModelPickerPreferencesStore(defaults: defaults)
            .read(matrixAccountID: account, destinationID: "mac:mini-b")
        XCTAssertFalse(models(make(favorites: other.favorites)[0]).contains("gpt-6.1-sol"))

        // Starring again takes it back down.
        let unstarred = relaunched.toggling("gpt-6.1-sol")
        XCTAssertEqual(make(favorites: unstarred.favorites), make())
    }

    // MARK: Search across every section

    func testSearchFiltersEverySectionAtOnce() {
        // "1" is in "Nguyệt Thực 1.3", "Nhật Thực 1.1", "GPT-6.1-Sol" and
        // "DeepSeek V4.1 Flash": one live query, three sections, nothing else.
        let sections = make(query: "1")
        XCTAssertEqual(sections.map(\.id),
                       ["defaults", "connection:chatgpt_plan", "connection:own_key:openrouter"])
        XCTAssertEqual(models(sections[0]), [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias])
        XCTAssertEqual(models(sections[1]), ["gpt-6.1-sol"])
        XCTAssertEqual(models(sections[2]), ["deepseek"])
    }

    func testSearchIgnoresCaseAndDiacriticsAndNeedsEveryWord() {
        XCTAssertEqual(make(query: "THUC").flatMap(\.rows).map(\.model),
                       [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias])
        XCTAssertEqual(make(query: "claude 5.5").flatMap(\.rows).map(\.model), ["opus", "sonnet"])
        XCTAssertEqual(make(query: "claude opus").flatMap(\.rows).map(\.model), ["opus"])
        XCTAssertEqual(make(query: "opus claude").flatMap(\.rows).map(\.model), ["opus"],
                       "words match in any order")
        XCTAssertEqual(make(query: "claude gpt"), [])
    }

    func testSearchAlsoMatchesTheConnectionWordsTheViewSupplies() {
        let words: (Row) -> String = { row in
            switch row.source {
            case .atum: "Atum"
            case .chatGPTPlan: "ChatGPT plan"
            case .opencodeGo: "OpenCode Go plan"
            case let .ownKey(provider): provider + " API key"
            }
        }
        XCTAssertEqual(make(query: "chatgpt", searchText: words).flatMap(\.rows).map(\.model),
                       ["gpt-6-luna", "gpt-6.1-sol"])
        XCTAssertEqual(make(query: "openrouter key", searchText: words).flatMap(\.rows).map(\.model),
                       ["deepseek"])
        XCTAssertEqual(make(query: "atum", searchText: words).flatMap(\.rows).map(\.model),
                       [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias])
        XCTAssertEqual(make(query: "chatgpt").count, 0, "without the words, only names answer")
    }

    func testBlankSearchListsEverythingAndNoMatchListsNothing() {
        XCTAssertEqual(make(query: "   "), make())
        XCTAssertEqual(make(query: "zzz-no-such-model"), [])
    }

    func testSearchFindsAStarredModelInTheDefaultsSection() {
        let sections = make(favorites: ["anthropic/sonnet"], query: "sonnet")
        XCTAssertEqual(sections.map(\.id), ["defaults"])
        XCTAssertEqual(models(sections[0]), ["sonnet"])
    }

    // MARK: The filter

    func testFilterFavoritesOnlyKeepsStarredRowsEverywhere() {
        let sections = make(favorites: ["anthropic/sonnet", ManagedModelLineup.hardAlias],
                            filter: PhoneModelPickerFilter(favoritesOnly: true))
        XCTAssertEqual(sections.map(\.id), ["defaults"])
        XCTAssertEqual(models(sections[0]), [ManagedModelLineup.hardAlias, "sonnet"])
        XCTAssertEqual(make(filter: PhoneModelPickerFilter(favoritesOnly: true)), [],
                       "nothing starred, nothing listed")
    }

    func testFilterByOneConnection() {
        let plan = make(favorites: ["anthropic/sonnet"], filter: PhoneModelPickerFilter(connection: "chatgpt_plan"))
        XCTAssertEqual(plan.map(\.id), ["connection:chatgpt_plan"],
                       "Atum's line-up and other connections' stars are hidden")
        XCTAssertEqual(models(plan[0]), ["gpt-6-luna", "gpt-6.1-sol"])

        let atumOnly = make(favorites: ["gpt-6.1-sol"], filter: PhoneModelPickerFilter(connection: "atum"))
        XCTAssertEqual(atumOnly.map(\.id), ["defaults"])
        XCTAssertEqual(models(atumOnly[0]), [ManagedModelLineup.defaultAlias, ManagedModelLineup.hardAlias])

        let starredOfOne = make(favorites: ["anthropic/sonnet"],
                                filter: PhoneModelPickerFilter(connection: "own_key:anthropic"))
        XCTAssertEqual(starredOfOne.map(\.id), ["defaults", "connection:own_key:anthropic"])
        XCTAssertEqual(models(starredOfOne[0]), ["sonnet"])
        XCTAssertEqual(models(starredOfOne[1]), ["opus"])
    }

    func testFilterAndSearchNarrowTogether() {
        let sections = make(favorites: ["anthropic/sonnet", "gpt-6.1-sol"], query: "5.5",
                            filter: PhoneModelPickerFilter(favoritesOnly: true))
        XCTAssertEqual(sections.flatMap(\.rows).map(\.model), ["sonnet"])
    }

    func testFilterIsActiveOnlyWhenItNarrowsAnything() {
        XCTAssertFalse(PhoneModelPickerFilter.none.isActive)
        XCTAssertTrue(PhoneModelPickerFilter(favoritesOnly: true).isActive)
        XCTAssertTrue(PhoneModelPickerFilter(connection: "atum").isActive)
    }

    func testTheFilterListsAtumFirstThenEachConnectionOnce() {
        let external = Row(favoriteID: nil, source: .ownKey("openrouter"), model: "m", displayName: "m",
                           selected: true, selectable: false)
        // A Mac's rows start with its saved external choice, then Atum's line-up.
        XCTAssertEqual(PhoneModelPickerSections.connections(in: [external, atum("nguyet-thuc"), atum("nhat-thuc")]),
                       ["atum", "own_key:openrouter"])
        XCTAssertEqual(PhoneModelPickerSections.connections(in: catalog),
                       ["atum", "chatgpt_plan", "own_key:anthropic", "own_key:openrouter"])
        XCTAssertEqual(PhoneModelPickerSections.connections(in: []), [])
    }

    // MARK: The current selection

    func testTheSectionHoldingTheCurrentSelectionIsFlagged() {
        var rows = catalog
        rows[4] = key("anthropic", "opus", name: "Claude Opus 5.5", selected: true)
        let sections = make(rows)
        XCTAssertEqual(sections.filter(\.containsCurrent).map(\.id), ["connection:own_key:anthropic"])
        XCTAssertEqual(sections.flatMap(\.rows).filter(\.selected).map(\.model), ["opus"])
    }

    func testAStarredCurrentModelIsFoundAtTheTopAndNotInItsConnection() {
        var rows = catalog
        rows[4] = key("anthropic", "opus", name: "Claude Opus 5.5", selected: true)
        let sections = make(rows, favorites: ["anthropic/opus"])
        XCTAssertEqual(sections.filter(\.containsCurrent).map(\.id), ["defaults"])
        XCTAssertEqual(models(sections.first { $0.id == "connection:own_key:anthropic" }!), ["sonnet"])
    }

    func testTheCurrentSelectionStaysVisibleWhenSearchFindsIt() {
        var rows = catalog
        rows[3] = plan("gpt-6.1-sol", name: "GPT-6.1-Sol", selected: true)
        let sections = make(rows, query: "sol")
        XCTAssertEqual(sections.flatMap(\.rows).map(\.model), ["gpt-6.1-sol"])
        XCTAssertTrue(sections[0].containsCurrent)
    }

    // MARK: Real projections

    private func fixture() throws -> ManagedModelDestinationSnapshot {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "destination.snapshot", withExtension: "json",
                                                  subdirectory: "model-choice-v1.3"))
        return try NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: Data(contentsOf: url))
    }

    func testAMacWithASavedExternalChoiceShowsItsConnectionAndKeepsAtumReachable() throws {
        let snapshot = try fixture()
        let destination = try ManagedModelDestinationID("mac:book-a")
        let rows = PhoneModelPickerProjection.destination(snapshot, destination: destination,
                                                          cloudEligibleAliases: [])
        let sections = PhoneModelPickerSections.make(rows: rows, favorites: [], query: "", filter: .none)

        XCTAssertEqual(sections.map(\.id), ["defaults", "connection:own_key:openrouter"])
        XCTAssertEqual(models(sections[0]),
                       ManagedModelLineup.servedAliases + [ManagedModelLineup.announcedAlias],
                       "the way back to Atum's models is the first thing in the list")
        XCTAssertTrue(sections[0].rows.filter { !$0.announced }.allSatisfy(\.selectable))
        XCTAssertEqual(sections[1].rows.map(\.model), ["openai/gpt-6.1-sol"])
        XCTAssertEqual(sections.filter(\.containsCurrent).map(\.id), ["connection:own_key:openrouter"],
                       "the external saved choice is current and its section is the one that opens")
        XCTAssertFalse(sections[1].rows[0].selectable, "read-only: no opaque route exists to select")
    }

    func testAMacOnAtumHasOnlyTheLineUpAndItsCurrentRow() throws {
        let snapshot = try fixture()
        let destination = try ManagedModelDestinationID("mac:mini-b")
        let rows = PhoneModelPickerProjection.destination(snapshot, destination: destination,
                                                          cloudEligibleAliases: [])
        let sections = PhoneModelPickerSections.make(rows: rows, favorites: [], query: "", filter: .none)
        XCTAssertEqual(sections.map(\.id), ["defaults"])
        XCTAssertEqual(sections[0].rows.filter(\.selected).map(\.model), [ManagedModelLineup.hardAlias])
        XCTAssertEqual(sections[0].rows.filter { $0.badges.contains(.default) }.map(\.model),
                       [snapshot.recommended.model],
                       "Default names the recommendation, not the current choice")
    }

    // MARK: Disclosure

    func testTheDefaultsSectionIsAlwaysOpenAndCannotBeToggled() {
        var disclosure = PhoneModelPickerDisclosure()
        let defaults = make()[0]
        XCTAssertTrue(disclosure.isOpen(defaults, browsing: false))
        disclosure.toggle(defaults, browsing: false)
        XCTAssertTrue(disclosure.isOpen(defaults, browsing: false))
    }

    func testOnlyTheSectionWithTheCurrentSelectionStartsOpen() {
        var rows = catalog
        rows[5] = key("anthropic", "sonnet", name: "Claude Sonnet 5.5", selected: true)
        let sections = make(rows)
        let disclosure = PhoneModelPickerDisclosure()
        XCTAssertEqual(sections.dropFirst().map { disclosure.isOpen($0, browsing: false) },
                       [false, true, false])
    }

    func testSearchAndFilterOpenEverySectionTheyLookAt() {
        // A hit inside a closed section would be invisible, so a search opens it.
        let sections = make(query: "1")
        XCTAssertEqual(sections.count, 3)
        let disclosure = PhoneModelPickerDisclosure()
        XCTAssertEqual(sections.dropFirst().map { disclosure.isOpen($0, browsing: false) }, [false, false])
        XCTAssertEqual(sections.map { disclosure.isOpen($0, browsing: true) }, [true, true, true])
    }

    func testAPersonsOpenAndCloseSurvivesUntilTheViewChanges() {
        let sections = make()
        let plan = sections[1]
        var disclosure = PhoneModelPickerDisclosure()
        disclosure.show(view: "|")

        XCTAssertFalse(disclosure.isOpen(plan, browsing: false))
        disclosure.toggle(plan, browsing: false)
        XCTAssertTrue(disclosure.isOpen(plan, browsing: false))
        disclosure.show(view: "|")
        XCTAssertTrue(disclosure.isOpen(plan, browsing: false), "the same view keeps their choice")

        disclosure.show(view: "sol|")
        XCTAssertFalse(disclosure.isOpen(plan, browsing: false), "a new view starts from the rules again")
        XCTAssertTrue(disclosure.isOpen(plan, browsing: true))

        disclosure.toggle(plan, browsing: true)
        XCTAssertFalse(disclosure.isOpen(plan, browsing: true), "while browsing, a person can still close one")
    }

    func testASectionThatHeldTheCurrentSelectionStaysOpenAfterAPick() {
        var before = catalog
        before[2] = plan("gpt-6-luna", name: "GPT-6-Luna", selected: true)
        var disclosure = PhoneModelPickerDisclosure()
        let beforeSections = make(before)
        disclosure.settle(beforeSections)
        XCTAssertTrue(disclosure.isOpen(beforeSections[1], browsing: false))

        // The person picks a model in another section; the current moves there.
        var after = catalog
        after[4] = key("anthropic", "opus", name: "Claude Opus 5.5", selected: true)
        let afterSections = make(after)
        disclosure.settle(afterSections)
        XCTAssertTrue(disclosure.isOpen(afterSections[1], browsing: false), "the one they were in is not folded")
        XCTAssertTrue(disclosure.isOpen(afterSections[2], browsing: false))
        XCTAssertFalse(disclosure.isOpen(afterSections[3], browsing: false))
    }

    // MARK: Identity

    func testTheSameModelNameOnTwoConnectionsIsTwoRows() {
        let one = key("openrouter", "gpt-6", name: "GPT-6")
        let two = plan("gpt-6", name: "GPT-6")
        XCTAssertNotEqual(one.stableID, two.stableID)
        XCTAssertEqual(one.connectionID, "own_key:openrouter")
        XCTAssertEqual(two.connectionID, "chatgpt_plan")
        XCTAssertEqual(atum("nguyet-thuc").connectionID, "atum")
        XCTAssertEqual(
            Row(favoriteID: nil, source: .opencodeGo, model: "glm-5.2", displayName: "glm-5.2",
                selected: true, selectable: false, isSubscription: true).connectionID,
            "opencode_go")
    }

    // MARK: The line-up and the connected subscriptions

    private func announced() -> Row {
        Row(favoriteID: nil, source: .atum, model: ManagedModelLineup.announcedAlias,
            displayName: "Thái Cực", selected: false, selectable: false,
            tagline: .flagship, announced: true)
    }

    private func subscription(_ model: String) -> Row {
        Row(favoriteID: nil, source: .opencodeGo, model: model, displayName: model,
            selected: true, selectable: false, isSubscription: true)
    }

    func testSubscriptionsComeAfterTheLineUpAndBeforeEveryConnection() {
        let rows = [
            atum(ManagedModelLineup.defaultAlias, badges: [.default]),
            atum(ManagedModelLineup.hardAlias),
            announced(),
            subscription("glm-5.2"),
            plan("gpt-6-luna", name: "GPT-6-Luna"),
        ]
        let sections = make(rows)
        XCTAssertEqual(sections.map(\.id), ["defaults", "subscriptions", "connection:chatgpt_plan"])
        XCTAssertEqual(models(sections[0]), [ManagedModelLineup.defaultAlias,
                                             ManagedModelLineup.hardAlias,
                                             ManagedModelLineup.announcedAlias])
        XCTAssertEqual(models(sections[1]), ["glm-5.2"])
        XCTAssertEqual(models(sections[2]), ["gpt-6-luna"])
        XCTAssertTrue(sections[1].containsCurrent)
        XCTAssertFalse(sections[1].isCollapsible)
        XCTAssertEqual(sections[0].rows.last?.announced, true)
        XCTAssertEqual(sections[0].rows.last?.selectable, false)
    }

    func testSubscriptionsObeySearchAndFavoritesOnly() {
        let rows = [
            atum(ManagedModelLineup.defaultAlias),
            subscription("glm-5.2"),
            subscription("gpt-6-luna"),
        ]
        XCTAssertEqual(make(rows, query: "glm").map(\.id), ["subscriptions"],
                       "a search lists only the group that holds the match")
        XCTAssertEqual(make(rows, query: "glm")[0].rows.map(\.model), ["glm-5.2"])
        XCTAssertEqual(make(rows, favorites: [ManagedModelLineup.defaultAlias],
                            filter: PhoneModelPickerFilter(favoritesOnly: true)).map(\.id),
                       ["defaults"], "a subscription is read-only and has no star")
        XCTAssertEqual(make(rows, filter: PhoneModelPickerFilter(connection: "opencode_go"))
            .flatMap(\.rows).filter(\.isSubscription).map(\.model),
                       ["glm-5.2", "gpt-6-luna"])
    }
}
