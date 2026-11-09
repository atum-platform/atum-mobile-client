import XCTest
@testable import AtumNativeAPI

final class CompanyLocalPrefsTests: XCTestCase {
    private func journal(_ name: String) -> (CompanyLocalPrefsJournal, UserDefaults) {
        let defaults = UserDefaults(suiteName: "company-prefs-tests-" + name)!
        defaults.removePersistentDomain(forName: "company-prefs-tests-" + name)
        return (CompanyLocalPrefsJournal(defaults: defaults, key: "k"), defaults)
    }

    func testNotNowSurvivesARestart() {
        let (first, defaults) = journal("restart")
        var prefs = first.load()
        prefs.later("invite-1")
        prefs.activeCompanyID = "acme"
        first.save(prefs)
        let second = CompanyLocalPrefsJournal(defaults: defaults, key: "k").load()
        XCTAssertTrue(second.isLater("invite-1"))
        XCTAssertFalse(second.isLater("invite-2"))
        XCTAssertEqual(second.activeCompanyID, "acme")
    }

    func testAnInvitationThePlatformNoLongerListsIsForgotten() {
        var prefs = CompanyLocalPrefs()
        prefs.later("old")
        prefs.later("current")
        prefs.prune(keeping: ["current"])
        XCTAssertEqual(prefs.laterInvitationIDs, ["current"])
    }

    func testTheRememberedSetIsBounded() {
        var prefs = CompanyLocalPrefs()
        for index in 0..<(CompanyLocalPrefs.maximumRemembered + 5) { prefs.later("i\(index)") }
        XCTAssertEqual(prefs.laterInvitationIDs.count, CompanyLocalPrefs.maximumRemembered)
        XCTAssertFalse(prefs.isLater("i0"))
        XCTAssertTrue(prefs.isLater("i\(CompanyLocalPrefs.maximumRemembered + 4)"))
    }

    func testAnEmptyStateClearsTheKey() {
        let (store, defaults) = journal("empty")
        var prefs = CompanyLocalPrefs()
        prefs.later("x")
        store.save(prefs)
        XCTAssertNotNil(defaults.data(forKey: "k"))
        store.save(CompanyLocalPrefs())
        XCTAssertNil(defaults.data(forKey: "k"))
    }

    func testAccountKeysAreFullSHA256AndNeverCollideOnAShortPrefix() {
        let key = CompanyLocalPrefsJournal.key(forAccount: "@minh:atum.test")
        XCTAssertTrue(key.hasPrefix("atum.company-prefs.v2."))
        XCTAssertEqual(key.dropFirst("atum.company-prefs.v2.".count).count, 64)
        XCTAssertEqual(key, CompanyLocalPrefsJournal.key(forAccount: "@minh:atum.test"))
        XCTAssertNotEqual(key, CompanyLocalPrefsJournal.key(forAccount: "@anna:atum.test"))
    }

    func testTwoAccountsKeepSeparatePrefs() {
        let defaults = UserDefaults(suiteName: "company-prefs-tests-accounts")!
        defaults.removePersistentDomain(forName: "company-prefs-tests-accounts")
        let one = CompanyLocalPrefsJournal(defaults: defaults, key: CompanyLocalPrefsJournal.key(forAccount: "a"))
        let two = CompanyLocalPrefsJournal(defaults: defaults, key: CompanyLocalPrefsJournal.key(forAccount: "b"))
        var prefs = CompanyLocalPrefs()
        prefs.later("invite-1")
        one.save(prefs)
        XCTAssertTrue(one.load().isLater("invite-1"))
        XCTAssertFalse(two.load().isLater("invite-1"))
    }

    func testAPendingCreateSurvivesARestartAndOldStoredPrefsStillDecode() throws {
        let (first, defaults) = journal("pending-create")
        var prefs = CompanyLocalPrefs()
        prefs.pendingCreate = CompanyCreateTracker.Attempt(displayName: "Studio", requestID: "r-1")
        first.save(prefs)
        let second = CompanyLocalPrefsJournal(defaults: defaults, key: "k").load()
        XCTAssertEqual(second.pendingCreate, CompanyCreateTracker.Attempt(displayName: "Studio", requestID: "r-1"))
        // Clearing the attempt from an otherwise empty store clears the key.
        first.save(CompanyLocalPrefs())
        XCTAssertNil(defaults.data(forKey: "k"))

        // Prefs stored before this field existed.
        defaults.set(Data(#"{"laterInvitationIDs":["i"],"activeCompanyID":"acme"}"#.utf8), forKey: "k")
        let old = CompanyLocalPrefsJournal(defaults: defaults, key: "k").load()
        XCTAssertTrue(old.isLater("i"))
        XCTAssertEqual(old.activeCompanyID, "acme")
        XCTAssertNil(old.pendingCreate)
    }

    // MARK: Last-used company

    /// Candidates named after their ids, every default channel reachable.
    private func candidates(_ ids: [String], unreachable: Set<String> = []) -> [CompanyCandidate] {
        ids.map { CompanyCandidate(id: $0, name: $0, hasReachableDefaultChannel: !unreachable.contains($0)) }
    }

    private func resolved(_ prefs: CompanyLocalPrefs, _ ids: [String]) -> String? {
        prefs.resolvedCompanyID(candidates: candidates(ids), locale: Locale(identifier: "en"))
    }

    func testTheCompanyInUseWinsWhileItIsStillListed() {
        var prefs = CompanyLocalPrefs()
        prefs.use(company: "a")
        prefs.use(company: "b")
        XCTAssertEqual(resolved(prefs, ["a", "b", "c"]), "b")
        XCTAssertEqual(resolved(prefs, ["c", "b", "a"]), "b", "by id, not list position")
    }

    func testAGoneCompanyFallsBackToTheMostRecentlyUsedOneStillListed() {
        var prefs = CompanyLocalPrefs()
        prefs.use(company: "a")
        prefs.use(company: "b")
        prefs.use(company: "c")
        XCTAssertEqual(resolved(prefs, ["a", "b"]), "b", "c left: b was used last")
        XCTAssertEqual(resolved(prefs, ["z", "a"]), "a", "c and b left: a")
        // Re-using an older company makes it the newest again.
        prefs.use(company: "a")
        XCTAssertEqual(resolved(prefs, ["b", "c"]), "c")
    }

    func testOnlyWhenNothingRememberedIsListedDoesItTakeTheFirst() {
        var prefs = CompanyLocalPrefs()
        XCTAssertEqual(resolved(prefs, ["x", "y"]), "x", "nothing chosen yet")
        prefs.use(company: "gone")
        XCTAssertEqual(resolved(prefs, ["x", "y"]), "x")
        XCTAssertNil(resolved(prefs, []))
    }

    func testPrefsSavedBeforeTheRecentsListStillDecode() throws {
        let old = Data(#"{"laterInvitationIDs":["i"],"activeCompanyID":"a"}"#.utf8)
        let prefs = try JSONDecoder().decode(CompanyLocalPrefs.self, from: old)
        XCTAssertEqual(prefs.activeCompanyID, "a")
        XCTAssertTrue(prefs.isLater("i"))
        XCTAssertEqual(resolved(prefs, ["b", "a"]), "a")
        XCTAssertEqual(resolved(prefs, ["b"]), "b")
    }

    func testTheRecentsSurviveARestartAndAreBounded() {
        let (store, defaults) = journal("recents")
        var prefs = CompanyLocalPrefs()
        for index in 0..<(CompanyLocalPrefs.maximumRecentCompanies + 3) { prefs.use(company: "c\(index)") }
        XCTAssertEqual(prefs.recentCompanyIDs.count, CompanyLocalPrefs.maximumRecentCompanies)
        store.save(prefs)
        let loaded = CompanyLocalPrefsJournal(defaults: defaults, key: "k").load()
        XCTAssertEqual(loaded.recentCompanyIDs.first, "c\(CompanyLocalPrefs.maximumRecentCompanies + 2)")
        XCTAssertEqual(loaded, prefs)
    }

    // MARK: Fallback order

    func testWithNothingRememberedItIsTheFirstByNameNotTheFirstInTheList() {
        let prefs = CompanyLocalPrefs()
        let list = [
            CompanyCandidate(id: "1", name: "Zeta", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "2", name: "alpha", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "3", name: "Mid", hasReachableDefaultChannel: true),
        ]
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: list, locale: Locale(identifier: "en")), "2",
                       "alpha, whatever the list order; case does not matter")
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: list.reversed(), locale: Locale(identifier: "en")), "2")
    }

    func testNamesSortByTheLocaleNotByRawCodePoints() {
        let prefs = CompanyLocalPrefs()
        let list = [
            CompanyCandidate(id: "1", name: "Zoo", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "2", name: "Édith", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "3", name: "Eve", hasReachableDefaultChannel: true),
        ]
        // Diacritics are ignored: Édith sorts with E, ahead of Eve.
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: list, locale: Locale(identifier: "vi")), "2")
        // Vietnamese: A, Ă, Â, B ... so "Ân" sorts after "An" and before "Bình".
        let vi = [
            CompanyCandidate(id: "1", name: "Bình", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "2", name: "Ân", hasReachableDefaultChannel: true),
        ]
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: vi, locale: Locale(identifier: "vi")), "2")
    }

    func testACompanyStillBeingProvisionedIsSkippedWhileAnotherIsReachable() {
        let prefs = CompanyLocalPrefs()
        let list = [
            CompanyCandidate(id: "1", name: "Alpha", hasReachableDefaultChannel: false),
            CompanyCandidate(id: "2", name: "Beta", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "3", name: "Gamma", hasReachableDefaultChannel: true),
        ]
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: list, locale: Locale(identifier: "en")), "2")
        // Nothing reachable: still the first by name rather than nothing.
        let none = list.map { CompanyCandidate(id: $0.id, name: $0.name, hasReachableDefaultChannel: false) }
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: none, locale: Locale(identifier: "en")), "1")
    }

    func testRememberedCompaniesBeatTheNameOrderEvenWhenNotYetReachable() {
        var prefs = CompanyLocalPrefs()
        prefs.use(company: "3")
        let list = [
            CompanyCandidate(id: "1", name: "Alpha", hasReachableDefaultChannel: true),
            CompanyCandidate(id: "3", name: "Gamma", hasReachableDefaultChannel: false),
        ]
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: list, locale: Locale(identifier: "en")), "3",
                       "the stored company wins")
        // It left; the next most recent still listed wins over the alphabet.
        prefs.use(company: "2")
        prefs.use(company: "3")
        let afterLeaving = list.filter { $0.id != "3" } + [
            CompanyCandidate(id: "2", name: "Zulu", hasReachableDefaultChannel: false),
        ]
        XCTAssertEqual(prefs.resolvedCompanyID(candidates: afterLeaving, locale: Locale(identifier: "en")), "2")
    }

    func testReachabilityMeansAnActiveDefaultChannelWithAReadyRoom() throws {
        func directory(state: String, room: String, system: String?) throws -> CompanyChannelDirectory {
            var channel: [String: Any] = [
                "id": "00000000-0000-4000-8000-20f46db16790",
                "companyId": "00000000-0000-4000-8000-91320823a72f",
                "displayName": "general", "visibility": "company", "state": state,
                "projectId": NSNull(), "authorityGeneration": 1, "channelGeneration": 1,
            ]
            if let system { channel["systemKey"] = system }
            return try NativeAPI.decode(CompanyChannelDirectory.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "channels": [[
                    "schemaVersion": 2,
                    "channel": channel,
                    "memberCount": 1,
                    "room": room == "ready" ? ["state": "ready", "roomId": "!a:atum.test"]
                        : ["state": room, "roomId": NSNull()],
                ]],
            ]))
        }
        XCTAssertTrue(CompanyCandidate.reachable(try directory(state: "active", room: "ready", system: "default")))
        XCTAssertFalse(CompanyCandidate.reachable(try directory(state: "provisioning", room: "ready", system: "default")))
        XCTAssertFalse(CompanyCandidate.reachable(try directory(state: "active", room: "provisioning", system: "default")))
        XCTAssertFalse(CompanyCandidate.reachable(try directory(state: "active", room: "failed", system: "default")))
        XCTAssertFalse(CompanyCandidate.reachable(try directory(state: "active", room: "ready", system: nil)),
                       "a ready non-default channel is not the default channel")
        XCTAssertFalse(CompanyCandidate.reachable(nil), "not read yet")
    }
}
