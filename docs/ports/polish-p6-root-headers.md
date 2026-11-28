# Polish P6: one root header, Back vs X, system sheet backgrounds

Lane P6 of the iPhone polish wave. It closes UX audit issue 7 ("four tabs, four
header patterns") and the P2 proposals 1, 2, 3 and 5
(`polish-p2-lists-headers.md`). The owner approved the recommendations on
28 Nov 2026 ("go with your recommendations"), including owner decision 4 (Team
Space header) and decision 6 (the bell moves into the account face, as on
desktop).

Branch `feat/polish-p6-root-headers`, stacked on `feat/chat-parity-phone`,
because that branch's ML3 lane rebuilt Home search in the same files. ML3's
search engine and results (`HomeSearchController`, `HomeGlobalSearch`,
`HomeSearchResultsView`) are untouched: P6 only replaces the field that feeds
them.

## The rules

### Root header (every tab root)

1. **Title:** the root's exported title through `.navigationTitle`. Home,
   Drive and Store use a large title. Team Space with a company open uses the
   company name inline, because its title is the company switcher
   (`.toolbarTitleMenu`). With no company it keeps the large "Team space".
2. **Search:** the system `.searchable` in the bar's drawer
   (`.navigationBarDrawer`). No hand-built search fields.
3. **Leading:** only Home has a leading item, the account face. Account and
   Settings live behind it (desktop's rail account).
4. **Trailing:** system bar items only, no hand-drawn glass:
   - status first, and only while it says something (Store's connection glyph
     is not drawn as an empty item);
   - then the root's own controls;
   - the root's primary action or its "…" menu comes last.
   Groups that do different jobs are split with `ToolbarSpacer(.fixed)`.

| Root | Leading | Title | Trailing |
|---|---|---|---|
| Home | account face (carries the attention dot) | large "Chats" | compose (+) |
| Team Space | — | company name, title menu = switcher | view menu · Activity, "…" |
| Drive | — | large "Drive" | "…" view options |
| Store | — | large "Store" | connection glyph (only while offline) · balance |

### Back vs X (sheets and panels)

- **X only on a sheet's root page**, at `.cancellationAction`, for sheets that
  show content (the chat panel, Store item, Companies).
- **Back (the system chevron) on every page pushed inside a sheet**, with no
  X beside it. The sheet still closes by dragging it down, and on an iPad
  keyboard Escape still closes the chat panel from any page (the host keeps
  the `.cancelAction` shortcut while a page is pushed).
- Sheets that edit and save keep Cancel / Done text (the audit's rule), for
  example the assistant card's model, destinations and routines pickers.
- Never both Back and X on one level.

Applied in the chat panel (`ChatPanelHost`): the root page (`ChatInfoHome`,
which also hosts the assistant card) keeps its X. Members, Shared "See all",
an app's page, Pinned messages and the agent desk now show only Back. Before
P6 those pages had Back and an X; Pinned messages put its X at the leading
edge, where the Back belongs. The assistant card already followed the rule:
it sits on the panel's root, and in Settings › Assistants it is pushed with
Back. Its edit sub-sheets use Done.

### Sheet background

A sheet uses the system sheet background: no `.background(ground)` fill and no
`.scrollContentBackground(.hidden)` at its root, so a grouped list draws the
system grouped background and a plain one the sheet's own. Bottom action bars
inside a sheet use the system `.bar` material instead of a ground strip.

## What changed, with what it replaces

### Home (`ios/App/Home/HomeScreen.swift`, `HomeAccountFace.swift`)

- **Replaced:**
  - the hidden bar (`.toolbar(.hidden, for: .navigationBar)`, the audit's
    `HomeScreen.swift:542`);
  - the hand-built top row (`header`: avatar, search capsule, bell, glass plus,
    with its own accessibility-size layout, audit `:712-764`);
  - `HomeSearchField`, a vertical-axis `TextField` that stripped newlines to
    imitate the Search key (audit `:1354-1404`).
- **Now:**
  - `.navigationTitle` with the exported `desktop.atum.roster.title` ("Chats" /
    "Trò chuyện") and a large title;
  - `.searchable(placement: .navigationBarDrawer(displayMode: .always))`,
    bound to ML3's `HomeSearchController.text` with the same prompts (plain,
    or the device-only placeholder);
  - `.searchFocused` for focus, and `.onSubmit(of: .search)` ends typing and
    keeps the query (the old Return behaviour);
  - the system Cancel ends search: `HomeSearchActivity` reads `isSearching`,
    and when it turns false Home calls `HomeSearchController.dismiss()`, which
    is what the old Cancel did;
  - the account face is `.topBarLeading`, drawn without the bar's shared glass
    (`.sharedBackgroundVisibility(.hidden)`), so it reads as a profile picture;
  - compose is a system bar button (`.topBarTrailing`, `barIcon(.plus)`) in
    place of the hand-made `LiveGlass` circle. Same action, label and
    identifier (`home.create`).
- The S2 scope chips and the S16 filter chips, and the domain sign-in card,
  sit in a `.safeAreaInset(edge: .top)` over the content's own scroll view.
  The large title still collapses with the roster.
- **Bell into the face (owner decision 6).** `AttentionBell` becomes
  `HomeAccountFace` (file renamed). Desktop removed its bell on 24 Nov 2026:
  what waits sits at the top of the rail's account face, which wears a red
  dot (`rail-account.tsx`, `attention-indicator.tsx`). On the phone:
  - nothing waits: the face opens Settings, as before;
  - something waits: the face wears a red (`danger`) dot. A tap opens the old
    bell's list, the same rows and actions, with Settings as its last row.
    That is desktop's menu order: attention first, then the account;
  - VoiceOver: the label is "Settings, Needs you: Sign in again" (several
    items: "Settings, Needs you: 2 things need you", from the exported `count`
    key). The value is the count. A new item is still announced once.
  - identifiers: `home.account` (the face), `home.account.badge`,
    `home.account.attention.<kind>`, `home.account.settings`. `home.bell*`
    are gone.

### Team Space (`CompanyWorkspaceViews.swift`, `CompanySpaceViews.swift`, `TeamSpaceRevampViews.swift`)

- **Replaced (owner decision 4):** three header rows became one.
  - The leading company capsule (`header`, `CompanyHeaderLabel`, audit
    `CompanyWorkspaceViews.swift:815-835`) is gone.
  - So is the large "Team space" title under it.
  - `CompanyPagesBar`, Chat | Board as a segmented control with an
    accessibility-size fallback (audit `CompanySpaceViews.swift:13-33`), is
    gone.
  - `CompanyBoardControls` and `TeamSpaceSegments`, Board | List and Mine
    over the board (audit `TeamSpaceRevampViews.swift:228-256`), are gone.
- **Now:**
  - the company name is the inline title. Its `.toolbarTitleMenu` lists every
    company (the open one checked, each with its mark in words) and then
    Companies, which opens the existing switcher sheet with its invitations
    and Create company;
  - one trailing view `Menu` (`company.pages`). It is labelled with the
    current page's name and holds inline `Picker`s for Chat · Board (·
    Marketplace) and, on the Board, Board · List, plus the Mine `Toggle`. Its
    VoiceOver value says the choice ("Board, List, Mine");
  - the `.selection` haptic on a page or view change is kept;
  - Activity and the company "…" follow as their own group.
- **Dynamic Type:** the system menu's rows follow Dynamic Type and keep
  44 pt targets. The bar item gets the system large-content viewer at
  accessibility sizes, as bar items do. The AX-XXXL UI test checks the List
  and Mine rows.

### Drive and Store

- Both keep their large titles and `.searchable`.
- Drive is already on the rule: its one trailing item is "…" (view options).
- Store drew `ConnectionGlyph` as its own toolbar item even when it was
  hidden, so iOS 26 could keep an empty glass slot. Now the item, and a
  fixed spacer after it, exist only while the glyph shows. The balance stays
  the root's own control.

### Chat panel (Back vs X)

- `ChatMembersPage`, `SharedCollectionPage`, `AppPanelPageView`,
  `RoomPinnedMessagesPage` and `AgentDeskPage` no longer add
  `ChatPanelCloseButton`.
- `ChatPanelHost` keeps a hidden `.cancelAction` button while a page is
  pushed, so Escape still closes the panel.
- `ChatInfoHome` keeps the X.

### Sheet backgrounds

The ground fill and `scrollContentBackground(.hidden)` are removed from:

- Home's Start chat, Add friend, New group and the founder draft;
- Team Space's switcher, Company overview, Activity, Saved, Threads, Invite,
  Join with a link, New channel and message search.

Start chat's and New group's bottom action bars use `.background(.bar)`.

Not changed (outside the four roots' sheets):
- `AppOnboardingSheet` and `ConversationPickerSheet` keep their fills;
- `SelectTextSheet` and `FailedSendSheet` are short sheets with
  `glassOpaque`;
- `MessageMenu`'s clear overlay.

## Deviations from desktop

- **Search's spoken name.** Desktop's roster search has the aria-label
  "Search everything". The system search field speaks its prompt ("Search"),
  and SwiftUI offers no separate label for it, so that one assertion was
  dropped from `HomeShellUITests`.
- **The face's dot is red** (desktop's `danger` face badge).
  `AttentionBellPolicy.tone` still says `.warn` for both phone causes. The
  old bell drew amber. The policy and its tests were left as they are; the
  face follows desktop as rendered.
- **The face opens Settings directly when nothing waits.** Desktop always
  opens its account menu. The phone's Settings sheet is that menu's content
  (status, Settings, phone, Protons, feedback, sign out), so the extra step is
  skipped while there is no attention row to show.
- **Team Space title.** The company's logo, and the mark saying another
  company has something waiting, are no longer drawn in the bar. A system
  title is text only. Each company's mark is in the title menu, and the Team
  Space tab badge still counts every company.
- **Board · List and Mine** are behind the view menu, not inline over the
  board as on desktop. The owner accepted this phone-only placement
  (decision 4).
- **Escape on pushed panel pages** works through a hidden shortcut button,
  not a visible X.

## Missing copy

None. Every word is an existing exported key:
- `desktop.atum.roster.title` (Chats);
- `desktop.atum.settings.title`;
- the `src.matrix.attention-copy.copies.*` keys;
- `CompanyCopy.companiesTitle`;
- the `TeamSpaceCopy` page, board-view and Mine keys.

## Verification

- `python3 scripts/design_lint.py`: exit 0. The baseline was lowered for P6's
  four files only: `CompanySpaceViews`, `CompanyWorkspaceViews`,
  `TeamSpaceRevampViews` and `HomeScreen`.
- `python3 -m unittest tests.test_design_lint`: OK.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0,
  by its own exit code.
- No Swift package code changed (`ios/Sources` untouched), so no
  `swift test` was needed.
- **Locked run: queued, not yet run.** It was queued at 15:09 (+07),
  28 Nov 2026, behind the shared heavy-build lock. At 16:41 it still had
  not started.
  - Script: `/Volumes/AtumTestFlight/polish-p6/locked-run.sh`.
  - It does a Debug `build-for-testing` with the temporary capture class
    `polish-p6/harness/PolishP6CaptureUITests.swift`. The class is copied
    in, and the project is restored after the build.
  - Then the UI tests: `HomeShellUITests`, `AgentDeskBellUITests`,
    `HomeSearchM1CaptureUITests`, `TeamSpaceRevampUITests`,
    `TeamSpaceDailyUITests`, `ChatPanelUITests` and
    `KitBoardSettingsCaptureUITests/testTeamSpaceHeaderAndSwitcher`.
  - Then the captures: `p6-{home,team-space,drive,store}-{light,dark,ax-large}`,
    plus the face's badge and list, the active search, and Team Space's title
    menu and view menu.
  - Then `xcrun simctl shutdown all`.
  - Results go to `polish-p6/logs/`: `run.txt`, `build.log`, `ui.log`,
    `ui.summary.txt`, `ui.xcresult`, `capture.*`. Shots go to
    `polish-p6/screens/`.
- **Not verified yet:** none of the changed SwiftUI has been compiled. The
  updated UI tests have not run. The test helpers that find the system
  search's Cancel and the company title menu are written against the
  system's accessibility names, and the run must confirm them.

## Locked run 1 (28 Nov 13:0x UTC)

Debug build failed (exit 65): `7e2212c` removed `exitText(_:delete:leave:)` along with the old header, while the exit confirmation dialog still calls it (plus a cascading type-check timeout in `body`). Coordinator restored the helper unchanged; locked run re-queued.

## Locked run 2 and fix round 1 (28–29 Nov)

Locked run 2: the Debug build passed and 52 UI tests ran locally, with 16
failures (`polish-p6/logs/ui.log`, `ui.xcresult`). The hosted re-run of the
same classes (run 46167083209) never reached the tests. All four shards
failed to build: `HomeScreen.swift:637`, "the compiler is unable to
type-check this expression in reasonable time". The hosted runner is slower
than the build Mac, and the error is real.

Triage method: the result bundle's per-test screen recordings were cut into
frame sheets with ffmpeg, and the failure hierarchies were read. That shows
what was on screen at each failure. No UI test or screenshot was run
locally in this round.

### Classification

Categories:
- **a**: P6 changed the UI on purpose; the test was updated to the accepted
  design.
- **b**: P6 broke something; the code was fixed.
- **c**: pre-existing, or a load flake; left as is and recorded.

| Failure | Cat. | What the evidence shows / what changed |
|---|---|---|
| Hosted build (all shards) | b | `homeBody` was one modifier chain, and P6 added the title, toolbar, `.searchable`, `.searchFocused`, `.onSubmit` and the inset to it. It is now five `some View` stages: `homeContent` → `homeHeader` → `homeSheets` → `homeLifecycle` → `homeBody`. The `.searchable` text and prompt are typed properties (`searchText`, `searchPrompt`). Behaviour is unchanged. |
| TeamSpaceDaily ×4, KitBoardSettings `testTeamSpaceHeaderAndSwitcher` | a | The recordings show the title menu open with "✓ Anka", "Studio · Có tin nhắn mới" and "Công ty của bạn". The system menu drops SwiftUI identifiers from its rows, so `company.header` never matched. New helper `companiesMenuItem`: the identifier, else the exported name ("Your companies" / "Công ty của bạn"). `openCompanyTitleMenu` waits for it. Studio already fell back to its name. |
| TeamSpaceRevamp `testBoardControlsHave44PointTargetsAtAccessibilityTextSize` | a | At AX XXXL the view menu is taller than the screen and scrolls. List was hittable; Mine, the last row, was below the fold. The test now checks List, then scrolls the menu's own list until Mine is hittable, then checks it. |
| View menu showing "✓ Bảng" twice (seen in the same recording) | b | On the Board page, the page picker's Board and the board-view picker's Board were two untitled, checked "Bảng" rows. Each group is now a titled `Section`, using the exported "Company pages" / "Trang công ty" and "Board views" / "Chế độ xem bảng". The two Bindings moved to `boardViewSelection` and `mineSelection`. |
| TeamSpaceRevamp `testRevampWalkInEnglishAndVietnameseLightAndDark` | a | With the one-row header the channel list is shorter. #design's failed line and Try again come to rest on the floating tab bar's top edge (kept screenshot `w4-e7-channel-failed-en-light`). XCUITest called Try again hittable, but the tap landed on the bar. New helper `clearOfTabBar`: the frame must end 8 pt above the tab buttons, the audit's bound. The walk scrolls until both rows are clear. |
| HomeShell `testRosterAccessibilityAudit`, `testHomeSearchChannelsMessagesFilesAccessibilityAudit` | a | The only finding is contrast on `UISearchBarTextField`, the system `.searchable` field P6 adopted. Its placeholder and glyph colours are the system's. The audit handler now excuses contrast findings on that one system class, with a `MEASURE` line, like its other recorded exceptions. The second test is also quarantined on main (atum-mobile#50). |
| HomeShell `testPlusOpensStartChatWithRealRowsAndAvailableCreationActions` | c (hardened) | Local-only on main for timing. Start chat opened with real rows. The picked row was half under the sheet's search drawer, so the tap hit the bar and the list scrolled to the top. The pick now needs the row to sit wholly below the sheet's bar. |
| HomeShell `testHomeSearchHidesResultsOfARoomLeftWhileShown` | c | Base branch, not P6. ML3's `HomeSearchController` rechecks results only when Home's roster changes (`revalidate()` from `.onChange(of: presentation.rows…)`). The scripted leave is a company room that never changes Home's roster, so the row stays. P6 did not touch this path. ML3's own UI tests were never run (`chat-parity-phone-search.md`, lock timeouts). Follow-up for the ML3 owner. |
| HomeSearchM1Capture `testResultsPrivateScopeAndFiltersLightAndDark` | c | Base branch's capture, never run before. The recording shows the system search focused, the device-scope chips and the results. The coverage line sits at the foot of the results, below the open keyboard, so the List never builds it. P6's field does not change that. Follow-up for the ML3 owner. |
| HomeShell `testSwipeActionsMutateRowsOnce`, `testInvitationMenuDeclinesOnce` | c | The recordings show the swipe and the long press arriving as plain taps (Luna's chat pushed, and the invitation joined), right after launch on a heavily loaded Mac (tests took 40–400 s each). The invitation test has this exact flake on record (`roster-plus-search-bell.md`). The same run's long-press tests that scroll first (`testPinLimitMenu…`, `testDeletingAppRoom…`) passed. P6 did not change the rows, their swipe actions or their menus. To be confirmed by the hosted run. |
| HomeShell `testHomeSearchChannelsMessagesFilesAppearances` | c (hardened) | en light, en dark and vi light passed. In the vi-dark pass the check at line 879 (`home.messages.$launch-review` `.exists`, read the moment People stopped searching) ran before the company messages answer landed; the recording shows the Messages section a moment later. The check now waits up to 15 s. Open risk: the same recording shows the system field at "la", with the keyboard down for about 2 s, mid-`typeText`, before "launch" landed. Watch for this in the hosted run. |
| AgentDeskBell `testDeskAndBellInEnglishAndVietnameseLightAndDark` | c | It failed in the desk half, before the bell: the swipe on `desk.page` never grew the panel to large (the recording shows it resting at medium). P6 only removed that pushed page's X. The same gesture-as-tap symptom as the Home flakes. The bell half (P6's face) was not reached locally; the hosted run covers it. |

### Decisions taken without the owner (native first)

- The view menu's groups carry section titles (existing exported keys). This
  is presentation only: the owner's decision 4 placement is unchanged.
- Audit exception for the system search field's contrast. The alternative
  was a global `UISearchTextField` appearance override, which reaches into
  UIKit around SwiftUI and changes every search field in the app. It was
  rejected.

### Verification (fix round 1)

- `python3 scripts/design_lint.py`: OK. `git diff --check`: clean.
- No Swift package changed, so there is no `swift test`.
- Locked run: one Debug `build-for-testing` (generic iOS Simulator,
  `CODE_SIGNING_ALLOWED=NO`), with `-warn-long-expression-type-checking=300`
  to flag what a slower runner times out on. Script
  `polish-p6/fix1/locked-build.sh`, launchd label `io.atum.lock.p6fix1`.
  It was queued behind P7, W4-Y2, W4-AC2 and a `swift test` lane.
  - Attempt 1 (`generic/platform=iOS Simulator`) failed at link. That
    destination also builds x86_64, and MatrixRustSDK has no x86_64 slice.
    This was the script's setup, not the code.
  - Attempt 2 (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`), head `c766050`, 29 Nov
    01:17–01:28 (+07): `** TEST BUILD SUCCEEDED **`, exit 0. No warning or
    error in any file this round touched.
  - The only app expression over 300 ms is `AtumMobileApp.swift:63`
    (about 2.1 s), which predates P6. The split `HomeScreen` body no
    longer shows up.
  - Logs: `polish-p6/fix1/build.log`, `slow-expressions.txt`.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0,
  by its own exit code.
- UI classes for the hosted run: `HomeShellUITests`, `AgentDeskBellUITests`,
  `HomeSearchM1CaptureUITests`, `TeamSpaceRevampUITests`,
  `TeamSpaceDailyUITests` and `ChatPanelUITests`. Also the classes over
  P6's other touched views: `SharedCollectionsUITests` and
  `AppSidePanelUITests` (pushed panel pages, Back only),
  `StoreCommerceUITests` (Store's connection glyph) and
  `TeamSpaceInviteUITests` (sheet background). `KitBoardCaptureUITests`
  (`KitBoardSettingsCaptureUITests`) is local-only in CI.
