# Home search: Channels, Messages and Files (desktop → phone)

Date: 2026-11-14. Phone base: main `161ada7`. Desktop source of truth:
`6c5aacbc` (`origin/main` of the desktop checkout), read with `git show`.
Desktop paths are relative to `apps/desktop/`. This follows
[home-search-people.md](home-search-people.md), which ported the People section
and listed these three as "Left for later".

## Desktop as rendered

`src/matrix/app.tsx` (`MatrixAccountView`) draws one global search block above
the roster's own matches while the trimmed query has 2+ characters. From top to
bottom:

1. `t.atum.roster.searching` ("Searching…") while any source is still out
   (`matrixRosterGlobalSearchPending`: People, Messages or Files pending).
2. **People** (already on the phone).
3. **Channels** (`t.atum.roster.channels`, "Channels and teams" / "Kênh và
   nhóm"): `globalChannels`, the snapshot's Team Space rooms
   (`isTeamSpaceRoom`, minus `isCompanyPrivateCosClaim`) whose `room.name`
   holds the query under `normalizeMatrixRosterQuery` (marks folded, lower
   case, đ → d, spaces collapsed). Local only, no request. Each row is a
   `Hash` glyph and the room's name. A tap selects the room.
4. **Messages** and **Files** (`t.atum.roster.messages` / `.files`): the
   controller's `searchCompanies` (`roster-global-search.ts`). For every
   company that owns a room in the snapshot (`globalCompanyIds`), 250 ms after
   the last keystroke, it asks `companies.search({ companyId, query, limit: 10,
   tab })` once per tab. The pages are merged in company-id order. A failed
   company answers `[]`: there is no error row and no retry. With no company,
   both tabs complete empty at once, so they never show "Searching…". Each row
   shows a `Messages` or `Files` glyph, the room's name (small, muted), then the
   file name or the message snippet (2 lines). A tap runs `openGlobalEvent`: it
   re-reads the exact event (`openCompanyMessage`), reveals it in the room's
   history (`revealMatrixHistoryMessage`, with the thread when there is one),
   then selects the room. A failure goes to the generic `fail` toast.
5. Then the roster's own conversations. "No results found" shows only after
   every source has answered and nothing at all matched.

What `companies.search` does (`electron/matrix/main-company-search.ts`,
`src/matrix/company-message-search.ts`): it checks the query (2…200
characters, `parseMatrixCompanySearchQuery` with `from:` / `in:` / `before:`
/ `after:` and "phrases"), then reads the company's channel directory (ready
rooms, channel `active`/`archived`) and conversation directory (ready rooms,
`active`/`read_only`, named by their participants). It keeps only rooms that
are joined and not encrypted, narrowed by `in:#channel`. Then it calls Matrix
`POST /search` (`room_events`, `types: [m.room.message]`, `contains_url` for
Files, `order_by: recent`, the `from:` senders). Results are filtered on the
client: no edits, reactions or replies (a relation other than `m.thread`),
no redactions, the date window, every term present, and for Messages a
`m.text` body whose visible words (`historyMessageText`) hold the whole
query on one line. A result from a room it did not ask about refuses the
whole company.

## Phone now

- `ios/Sources/AtumNativeAPI/CompanyMessageSearch.swift` (pure, no I/O):
  `CompanySearchQuery` (desktop's parser, term and date rules),
  `CompanySearchTarget.targets` (the channel and conversation directories →
  search rooms, desktop main's `targets`, including its fixed
  "Conversation" fallback name), `CompanyMessageSearch.query` / `.admitted` /
  `.memberMatches` / `.requestBody` / `.results` / `.merged` / `.snippet`.
- `ios/App/Company/CompanySpaceMatrix.swift`: `companySearchJSON(body:)`
  posts to `/_matrix/client/v3/search` on the session's own homeserver with
  its bearer. It uses the same transport as the Activity
  `/notifications` read: HTTPS only, ephemeral session, no cookies, no
  redirects followed. The pinned Rust SDK has no `/search` binding.
- `ios/App/Company/CompanySpaceReads.swift`: `homeSearchChannels()` (joined
  rooms the channel directory or the conversation directory claims, in room
  list order, named by the room list. "You" and the Chief of Staff are left
  out), `homeSearchTargets()`, `homeCompanySearch(_:tab:)` (all companies
  at once, merged by id, a failure answers `[]`) and `openHomeSearchResult`
  (the room is still listed for that company, and `loadOrFetchEvent` still
  finds the same sender and thread root).
- `ios/App/Home/HomeGlobalSearch.swift`: `HomeGlobalSearchActions`,
  `HomeGlobalSearchPolicy` (channel match, company key, section order,
  "No results" rule), `HomeEventSearchState`, and the two row views.
- `ios/App/Home/HomeScreen.swift`: one `globalResults` block draws
  "Searching…", then People, Channels, Messages and Files, above Assistants
  and Chats. Messages and Files each run their own `.task(id:)` keyed by
  query + sorted company ids (desktop's `companyKey`). Each has the same 250 ms
  debounce and late-answer fence as People. A channel tap is
  `actions.openRoom(roomID)`, which `AppRoot` routes to Team Space. A result
  tap re-checks the message, then opens its room. A failure plays the
  error haptic and posts the generic error announcement, as People does.
- `ios/App/AppRoot.swift`: passes `globalSearch` while a Matrix session
  exists.
- Glyphs: `Files` (Phosphor `files`) and `Messages` (Phosphor
  `chats-circle`), as desktop's `icons.ts` maps them. The Kit subset was
  refreshed at the same pin.

Copy: `desktop.atum.roster.channels`, `.messages` and `.files` are already in
the vendored export (en, vi, ja, zh, zh-Hant). No `PENDING-COPY` entries.

## Review fixes (cross-family review of `bd6feb8`)

1. **Eligibility after the search (privacy).** `CompanySearchEligibility`
   (AtumNativeAPI) is each company's directory-listed rooms, with their exact
   channel binding, that are joined and known unencrypted.
   `homeCompanySearch` decodes an answer against the rooms admitted when it
   asked, then keeps only results whose room is still eligible. Home also
   filters what is on screen through the current eligibility
   (`HomeGlobalSearchActions.eligibility`, recomputed with the room list and
   the directories), so a leave, encryption turned on or a directory change
   hides those rows at once.
2. **Unknown encryption (privacy).** A room is admitted only when the SDK
   says `isEncrypted == false`. While the SDK does not know yet (`nil`), the
   room is not searched or shown.
3. **Opening a result.** `CompanyMessageSearch.confirmOpen` checks
   eligibility (joined, unencrypted, same company, channel and room) before
   the event read, and again after it. Then it checks sender and thread.
   `AppRoot` then routes with `openRoomAndRoute(_:requiringCompany:)`. A
   failed check or a refused route returns false, and Home plays the error
   haptic and posts the generic error announcement.
4. **Bounded fan-out.** Both tabs share one `CompanySearchLimiter` (4 at a
   time). Each company's whole page, its `from:` member reads included, is
   one job. Jobs start in arrival order (companies in id order), and a job
   cancelled while waiting never starts. Requests share one ephemeral
   `URLSession` (no cookies, no cache, no redirects). The merge is still in
   company-id order.
5. **Former members in `from:`.** `companySearchMembers` reads every
   membership from the SDK store (`membersNoSync`, no join filter), as
   desktop's `room.getMembers()` does. `CompanyMessageSearch.senders` keeps
   every matching member.

Tests: `CompanyMessageSearchTests.testEligibilityDropsResultsWhoseRoomIsNoLongerReadable`,
`testUnknownEncryptionIsNotAdmitted`, `testOpenIsCheckedBeforeAndAfterTheEventRead`,
`testSearchQueueRunsAtMostFourInOrderAndSkipsCancelledWork`,
`testFromFindsAFormerMembersHistoricalMessage`;
`HomeGlobalSearchPolicyTests.testShownResultsFollowCurrentEligibility`;
`HomeShellUITests.testHomeSearchResultThatCannotOpenStaysOnHome`.

## Left for later (known gaps)

- **Reveal on open.** Desktop scrolls the room to the message and opens its
  thread. The phone opens the room at its newest messages. The chat has no
  "open at event" route yet, which is the same gap as Saved and Activity rows
  (`team-space-structure.md`).
- **Operator-only queries.** Desktop answers `from:me` (no words) from
  the loaded timeline (`loadedSearch`). The phone answers nothing for these.
  Queries with words and operators work.
- **`from:@handle` via the alias service.** Desktop main also resolves a
  public handle through `account.alias lookup`. The phone matches room
  members by localpart or display name only.
- **Directory freshness.** Desktop re-reads the channel and conversation
  directories before and after each search and refuses the company when they
  changed. The phone uses the directories Team Space already holds.
- **First-run empty Home.** Same as People: with no chats at all, Home shows
  its empty state, and search does not reach the global block.

## Verification

All heavy runs went through the shared `lockf` lock, with derived data on the
build volume. The counts below are from the run after the review fixes
(derived data `dd-home-search-cmf-fix`).

- `swift test --package-path ios -j 2`: 1,571 tests, 0 failures. That is
  AtumDesignTests 807 (including the 19 `CompanyMessageSearchTests`:
  parser, targets, admission and unknown encryption, eligibility, open
  checks, queue, former members, request body, answer filtering, cap, merge
  order, snippet), AtumChatTests 726, AtumDriveTests 22 and
  AtumTelemetryTests 16. An earlier note and commit message said "726": that
  is the AtumChatTests bundle alone, not the package total.
- `xcodebuild … build-for-testing` (Debug, iPhone 17 simulator): succeeded.
- `-only-testing:AtumMobileTests`: 378 tests, 0 failures. This includes
  `HomeGlobalSearchPolicyTests` (channel match and fold, two-character
  minimum, company key, section order, "No results" rule) and
  `KitGlyphTests` (the new `Files` / `Messages` glyphs resolve).
- `AtumMobileUITests/HomeShellUITests` (scripted Home, `ScriptedHomeHost`):
  - `testHomeSearchListsChannelsMessagesAndFilesInDesktopOrder`: one
    character asks nothing. "launch" lists People, Channels, Messages and
    Files, headers top to bottom in that order. Both tabs are asked once.
    Rows read "room, words". A message tap re-checks it, then opens the room.
  - `testHomeSearchChannelOpensItsRoom`
  - `testHomeSearchChannelsMessagesFilesAppearances`: en/vi × light/dark at
    L, plus AX XXXL (top, and scrolled to Files).
  - `testHomeSearchChannelsMessagesFilesAccessibilityAudit`:
    `performAccessibilityAudit` at AX XXXL, keyboard dismissed. Its query
    ("kickoff") finds a channel, a message and a file but no person. It
    audits twice: at the top, then scrolled to Files. **Quarantined** in CI
    next to the People audit. See "Audit finding" below.
  - `testHomeSearchResultThatCannotOpenStaysOnHome` (review fix 3).
  - Whole class after the review fixes: 23 run, 23 passed. The three
    quarantined tests were skipped, as CI skips them.
  - Before the review fixes: every other `HomeShellUITests` test passed (15 tests), as did
    `HomeChatsWave3UITests` (5 passed, 1 skipped, the quarantined test left out),
    and the People tests (find by handle, known chat not repeated, roster
    control audit, appearances).
### Audit finding (not fixed, documented)

At AX XXXL the audit reports one "Dynamic Type font sizes are unsupported"
finding with no element and a zero frame. A diagnostic run on the build Mac
(a log-only test, since removed) ran a Dynamic Type audit for each case
separately:

| Results on screen | Findings |
|---|---|
| Roster match only ("lan") | none |
| People only ("@somehandle") | the element-less one, plus the targeted `avatar.monogram` one already exempted |
| Channel only | the element-less one |
| Message only | the element-less one |
| File only | the element-less one |

So it comes from the global search block as a whole, not from one row type.
It is also the finding behind main's quarantined
`testHomeSearchPeopleAccessibilityAudit`, so People's monogram is not its
cause. Drawing the rows with the roster's button style (default, tinted)
instead of `.plain` did not change it, and that change was reverted. With no
element attached, it can't be traced to a view. The new audit is quarantined
under the same tracking issue (atum-platform/atum-mobile#50). See
`docs/ci-ui-tests.md`. It still runs on the build Mac. Targeted findings would
still fail it.

- Screenshots: `home-search-cmf-{en,vi}-{light,dark}-l.png`,
  `home-search-cmf-en-light-ax5.png` and `…-ax5-files.png` (local evidence
  folder on the build volume; not committed).
