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
