# Polish P2: grouped lists and root headers

Lane P2 of the iPhone polish wave. The owner's words: "Our current mobile
doesn't 'feel' polished." The UX audit (24 Nov 2026) found three panel screens
that drew grouped lists by hand, with 14 pt cards, custom section titles, odd
row heights and no press feedback. They sat beside the real Settings lists in
the same app (audit issue 6). It also found fixed-size controls that do not grow
with large text (issue 9). This lane moves those three screens onto the
system's inset-grouped list and fixes the fixed sizes in the files it owns.
Issue 7 (four header patterns) is handled only where it does not change what
desktop shows. The rest is recorded below as proposals for the owner.

Branch `feat/polish-p2-lists-headers`, from `main` at `9f54045` (P0 tokens, P1
system tab bar, W4-V2).

## What changed, per screen

### Chat Info (`ios/App/Chat/Views/ChatInfoSheet.swift`, `ChatInfoHome`)

- The person, group, app and Team Space panels are one system `List` with
  `.listStyle(.insetGrouped)`. The old `ScrollView`, hand-drawn
  `RoundedRectangle(cornerRadius: 14)` cards, `Divider`s and custom
  `sectionTitle` are gone. Headers and footers come from `Section`. Rows use
  `Label` (a glyph column the system aligns), `Toggle`, `Button` and
  `NavigationLink`, as `AccountSettingsDetail` does. Every action row gets the
  system press highlight.
- **Header:** the avatar, name, seal, subtitle, founder handle, topic and kind
  line are the list's first row. It is centred on the panel's ground, with no
  row background (the Settings profile-header pattern). `ChatInfoAvatar`'s
  internals are untouched: the avatar-blip lane owns them.
- **Members** ("N members") is a `NavigationLink(value: .members)` on the
  panel's own path. The system draws its chevron.
- **Team Spaces** and **Conversation** use their desktop titles as system
  section headers. The pin-limit line is the Conversation section's footer.
- **Assistant access** is one row: its titled label and its explanation,
  combined into one accessibility element, as before.
- **Report / Block / Delete chat / Leave group** and the app chat's **Delete
  chat** are list buttons with their roles (destructive in red).
- **Sections other views draw** stay as those files draw them: Shared
  (`SharedCollectionsSection`), an app's pages (`AppPanelPagesSection`) and a
  Team Space channel's details (`CompanyChannelInfoSection`). Each sits in one
  full-width row through `panelEmbeddedRow(bleed:)`:
  - It has no row background or insets, and it is widened by the list's 16 pt
    side margin, so its own 16 pt edges line up with the list's groups.
  - `.buttonStyle(.borderless)` keeps each untyped button on its own target.
    A list row otherwise runs every default-style button it holds. Borderless
    is how those buttons already looked outside a list.
- The app and Team Space chats' Pin and Mute tiles stay tiles (desktop's quick
  actions). Their corner radius is now `kit.phoneRadius(.sm)` (10), the token
  for small tiles, instead of 14.
- The list's side margin is pinned to `kit.space(.s4)` with
  `.contentMargins(.horizontal, …, for: .scrollContent)`, and the list uses
  `.listSectionSpacing(.compact)`, as the Settings index does. Row backgrounds
  keep the panel's `cell` colour, so dark mode and the sheet's ground read as
  before.

### Assistant card (`ios/App/Chat/Views/AssistantCard.swift`)

The same card is used in the chat panel and in Settings › Assistants.

- **Layout:** the card is a system inset-grouped `List`. The face, the name
  field, the title, Saved, the privacy line and Message head it as the list's
  first row, on the ground. The offline caption is that row's footer.
- **Groups:**
  - The save band (failed, changed elsewhere, persona conflict) is its own
    one-row section, and its Retry is a borderless button.
  - The bot handle is a section. The directory editor (another file) keeps its
    own 16 pt layout with zero row insets. Its untyped Cancel, Refresh and
    Retry are borderless, so each keeps its own target.
  - The persona fields are a section: what it helps with (or the hand-written
    instructions), then Personality. The grey help lines are the section
    footer: the footnote, the long-persona hint, loading and "not ready". The
    expanded Personality field is a row of its own, under its toggle row.
  - Where it lives, Model, Pet, Skills and Routines are one section. The rows
    keep their 16 pt inset and 52 pt height, to match the home row that
    `AssistantHomeCardControl` (another file) draws. They are system buttons
    now, so they highlight on press.
  - The expanded skills and "Find more skills" are rows of their own, not a
    nested stack in one row.
  - Delete {name}… is its own section, and its failure line is the footer.
    When a delete fails, the list scrolls the delete row to the middle and
    VoiceOver announces the line (see "PR #110 hosted UI shard 3" below).
- **Keyboard bar:** Undo and Done show only while one of the card's own
  fields (name, purpose, instructions, personality) has focus. The handle
  editor's field has its own focus, Cancel, Save and return key.
- **Motion:** Personality and Skills expand with `Motion.standard`. They were
  bare `easeInOut(0.18)` curves before.
- **Tokens:** the name field's radius is `kit.phoneRadius(.sm)`. Spacing uses
  `kit.space`.

### Agent desk (`ios/App/Chat/Views/AgentDeskPage.swift`)

- **Layout:** the desk is a system inset-grouped `List`. `AgentDeskGroup` and
  `AgentDeskDivider` are deleted.
- **Sections:**
  - **Now** shows only while the agent works or waits.
  - **Files:** the sent files sit under a "Files" header. The agent's own
    files sit under "On its computer". With nothing sent, the own-files group
    takes the "Files" header, and "On its computer" moves to its footer. Both
    words stay on screen, in one header style. The audit had flagged a bold
    "Files" next to a grey footnote label.
  - **Controls:** Pause, Notifications and More. A failed control and the
    schedule's Refresh are its footer.
  - **More** opens two sections under Controls: Routines, with the system
    header in place of the old in-card label, and All settings.
- **Folders, Back, More and All settings** are system buttons with the press
  highlight. The chevron and the More rotation stay.
- **Motion:** More expands with `Motion.standard`. It was a bare `easeOut(0.2)`
  before.
- **Toggles:** they use `actionStrong`, like the Chat Info switches.

### Team Space (issue 9, files P2 owns)

- **Chat | Board** (`CompanySpaceViews.swift`, `CompanyPagesBar`): the system
  segmented control keeps its small fixed text at accessibility sizes, which
  is audit shot `15-team-space-ax-large.png`.
  - At accessibility sizes the same choice is drawn by `TeamSpaceSegments`,
    whose labels follow Dynamic Type and keep 44 pt targets. At ordinary sizes
    it is the system segmented control, as before.
  - The identifiers `company.pages` and `company.page.<tab>`, the labels and
    the selected state are the same in both forms.
  - A page change gives a `.selection` haptic.
- **Board | List** (`TeamSpaceRevampViews.swift`, `CompanyBoardControls`): the
  hand-made segments are now the shared `TeamSpaceSegments`, so there is one
  control, not two copies.
  - Its radii are `kit.phoneRadius(.sm)`, with the selected segment's corner
    10 − 2 so it stays concentric (8, as before).
  - Its spacing comes from `kit.space`. The segment's horizontal padding goes
    from 10 to 12, one grid step.
  - A view change gives a `.selection` haptic, and the selection moves with
    `Motion.quick`.
  - Mine is unchanged.
- **Fixed glyph sizes → text styles:**
  - The utility-row and search-row glyphs are now `.body` (they were 17 pt).
  - The channel row's "#" is `.title3` (it was 20 pt).
  - The empty-state briefcase is `.largeTitle` with `.imageScale(.large)` (it
    was 40 pt).
  - Each 28 pt glyph column is now an `@ScaledMetric`, so a larger glyph keeps
    its column.

### Home (`ios/App/Home/HomeScreen.swift`, issue 9 glyphs only)

- **Glyphs:**
  - The search glyph is `.callout` (it was a fixed 16 pt). That is audit shot
    `15-home-ax-large.png`.
  - The plus is `.title3`, capped at `accessibility2` so it stays inside its
    44 pt glass circle.
  - The offline glyph is `.largeTitle`, and the main-assistant star is
    `.footnote`.
- **Header motion:** the header's search swap uses `Motion.quick` instead of a
  bare `easeOut(0.2)`. Under Reduce Motion it now fades over 0.15 s instead of
  not animating, which is the P0 token rule.
- **Untouched:** the header's layout, the avatar (`HomeAvatar` belongs to the
  avatar-blip lane) and the custom search field (see proposals).

## Identifiers

No accessibility identifier was removed or renamed. Where a hand-drawn container
became a list section, its identifier moved to the nearest element that still
exists:

| Identifier | Was on | Now on |
|---|---|---|
| `info.conversation` | the card's container | the section header |
| `info.team-spaces` | the card's container | each Team Space row (a container, so the name stays its own text) |
| `desk.page` | the page's stack | the list |
| `desk.files.sent`, `desk.files.own`, `desk.controls` | each card's container | the section header (the hint `sentHere` moved with it) |
| `desk.now` | the Now block | the Now block, now inside its own row |

Every row, button, switch and field keeps its own identifier, element type
(button, switch, text field) and label.

## UI test changes (hosted shards must confirm)

A system `List` is a collection view, not a scroll view, and it builds only the
rows on screen. Tests that found the panel as `scrollViews.firstMatch`, or
assumed a row below the fold already existed, were updated:

- `TranscriptUITestSupport.panelList(_:)`: the panel's collection view inside
  `info.sheet`.
- `ChatInfoUITests`:
  - The group-info test reads the list through `panelList` and reveals Assistant
    access by scrolling.
  - The app-deletion test reveals Delete chat before tapping it.
- `ChatPanelUITests`:
  - Delete chat, Low priority and Block are revealed by scrolling in
    `panelList`.
  - The AX3 review captures reveal Encryption only when it sits under the
    medium fold.
- `HomeChatsWave3UITests`: the rename test swipes the panel until Rename exists
  and is hittable, instead of waiting for it at medium first.
- `AppSidePanelUITests`: the panel is raised until the Pin tile exists before
  its position is compared with the pages.
- `AgentDeskBellUITests`:
  - The own-files check runs after the panel grows to large.
  - The routines are revealed by scrolling after More opens.

`AssistantsWave3UITests` and the card tests in `ChatInfoUITests` already scroll
with existence-and-hittable loops, and the assistant panel opens at large, so
they are unchanged.

## Parity decisions and proposals for the owner

Owner rule: parity means desktop as rendered. Where a change would alter what
desktop shows, it is left as it is and proposed here.

1. **Home title and search (issue 7).** Not changed. Desktop's roster has no
   "Chats" title, and `HomeShellUITests` asserts that the screen has no title.
   The custom `HomeSearchField` stays beside the account face, as desktop
   draws its roster search. Proposal: `.navigationTitle` "Chats" with
   `.searchable(placement: .navigationBarDrawer)`, the account face in
   `.topBarLeading`, and the bell and compose in `.topBarTrailing`. That is
   the Messages and Telegram pattern. It needs owner sign-off and a test
   change.
2. **Team Space header (issue 7, owner decision 4, pending).** Not changed:
   the company capsule row, the large title and Chat | Board stay where they
   are. Proposal (from the audit): the company switcher as `.toolbarTitleMenu`
   on the company name, and Chat | Board as one toolbar `Picker`.
3. **Board | List and Mine in a toolbar Menu (issue 7).** Not done. Desktop's
   board draws Board · List and Mine inline over the board
   (`company-board.tsx` header). Folding them into a "…" menu would hide
   controls desktop shows. They stay inline. They now scale with large text
   and share one control. Proposal: move them into a `Menu` (Drive's "…"
   pattern) once the owner accepts a phone-only placement.
4. **`.searchable` on rooted titles (issue 7).** P2's roots with a title are
   Team Space, under decision 4 above, and Home, under proposal 1 above. Drive
   and Store already use `.searchable` and toolbar items, and they belong to
   P5. No change here.
5. **Close affordance on the desk.** The desk, the panel's opening page for an
   agent, has Back (to the card) and an X (close the panel). The audit's rule
   is "never both a Back and an X on one level". Every page pushed inside the
   panel (Members, Shared, an app page) has the same pair, so dropping the X on
   the desk alone would be inconsistent. Proposal: one panel-wide rule decided
   with P5.
6. **Cards drawn by other files.** `CompanyChannelInfoSection`
   (`CompanyChannelChrome.swift`), `SharedCollectionsSection` and
   `AssistantHandleEditor` still draw their own 14 pt cards and section
   titles inside the new lists. They are not P2's files, so they are hosted
   full-width, aligned and unchanged. Proposal for P5 (or a follow-up lane):
   give each a `Section`-based form so the panel is all system groups.

## Haptics

- A `.selection` haptic fires on Chat | Board and Board | List changes, the
  audit's rule for segmented controls.
- System `Toggle`s keep their own feedback.
- No other haptics were added.

## Verification

Every heavy step ran under the shared heavy-build lock, with derived data in
`dd-polish-p2` on the build volume, on the arm64 simulator
`CB24FAE2-75F9-4E19-A856-0F5A9F036C0B` (iPhone 16e, iOS 27.0). No Swift package
and no tested logic changed, so no `swift test` and no new AppTests ran.

| Run | Result | Log (build volume) |
|---|---|---|
| Debug `build-for-testing` (app, AppTests, UITests) | `TEST BUILD SUCCEEDED`. No new warnings in touched code: the only ones in touched files are the pre-existing `AssistantCard` `PhotosPicker` label isolation warnings. | `polish-p2/logs/build-120528.log` |
| Capture 1: build with the temporary capture class, then 4 capture tests | Build 0. Card, Chat Info, desk, Team Space and Home: 3 of 4 passed. The card test's first launch on the cold simulator timed out with no process ID: an infrastructure failure, with no app frame drawn. The shots found the `Label` glyph regression (session log). | `polish-p2/logs/capture-build.log`, `capture-test.log` |
| Capture 2: rebuild with the glyph fix, then the card and Chat Info tests only | Build 0. 2 of 2 passed. | `polish-p2/logs/capture2-build.log`, `capture2-test.log` |

- The temporary class `PolishP2CaptureUITests`
  (`/Volumes/AtumTestFlight/polish-p2/harness/`) was copied in for each build
  and removed. The project was restored by the script, so it was never
  committed. The scripts are `polish-p2/locked-build.sh`,
  `locked-capture.sh` and `locked-capture2.sh`.
- **Before** shots are the UX audit's, in `/Volumes/AtumTestFlight/ux-audit/shots/`:
  - `08-assistant-card-*-light.png`
  - `08-group-info-*-light.png`
  - `13-desk-*-light.png`
  - `14-desk-dark.png`
  - `09-team-space-board*-light.png`
  - `15-team-space-ax-large.png`
  - `15-home-ax-large.png`
- **After** shots are in `/Volumes/AtumTestFlight/polish-p2/shots/`:
  - `p2-assistant-card-*`
  - `p2-group-info-*`, `p2-person-info-*`, `p2-app-info-*` (medium, large,
    scrolled and bottom, light and dark, plus the group at AX-Large)
  - `p2-desk-*` (medium, large, More open, light and dark)
  - `p2-team-space-{root,board,board-list}-{light,ax-large}`
  - `p2-home-{light,ax-large}`
- `python3 scripts/design_lint.py`: exit 0. The baseline was lowered for P2's
  seven files only, through `--update` then keeping every other lane's entry
  as it is at HEAD. The kept entries include `Composer.swift`, whose count is
  already lower on main and belongs to P3. P2's files went from 339 findings
  to 185.
- `python3 -m unittest tests.test_design_lint`: OK.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0, by
  its own exit code.
- **Not run locally (lane rule):** the UI suites. The hosted UI shards must
  run, at least, `ChatInfoUITests`, `ChatPanelUITests`, `AgentDeskBellUITests`,
  `AppSidePanelUITests`, `HomeChatsWave3UITests`, `SharedCollectionsUITests`,
  `AssistantsWave3UITests` and `TeamSpaceRevampUITests`.

## PR #110 hosted UI shard 3

Hosted UI shard 3 (run `45566872605`, head `c7223dd`)
failed two `AssistantsWave3UITests` cases on the card. The cause came from the
shard's `ui-3` xcresult: the failure hierarchy, screenshots and recording.

- **`testAFailedDeleteChangesNothingAndSaysSo` (line 190):**
  - Cause: at large, the card's list ends with Delete {name}… on the bottom
    edge. That row counts as hittable, so the test's scroll loop never swiped
    and the list never moved. The failure line is the delete group's footer,
    and a `List` builds only what is on screen. The footer was added below the
    fold, so it never existed for the test, and a person never saw it either.
    The old `ScrollView` built every line, whether it was seen or not.
  - Fix (app): the card's `List` sits in a `ScrollViewReader`. The delete row
    has an `id`. When `retireFailed` turns true, the list scrolls that row to
    the centre with `Motion.standard`, which brings its footer on screen.
    VoiceOver announces the same line.
- **`testChoosingABotHandleChecksConfirmsAndClaims` (line 229):**
  - Cause: Save did become enabled. Line 229 is the wait for the confirmation
    alert, which never opened. The card's keyboard bar (`ToolbarItemGroup`,
    `.keyboard`) drew Done for every field in the card, including the handle
    editor's field. On iOS 26 that bar floats above the keyboard, and in the
    list layout its Done (`{{307, 494}, {62, 36}}`) sat over the editor's Save
    (`{{305, 491}, {53, 36}}`). The tap landed on Done. For this field Done
    also did nothing: it cleared the card's own focus, but the handle field
    has its own `@FocusState`.
  - Fix (app): the card's keyboard bar shows Undo and Done only while one of
    the card's own fields has focus. The handle field keeps its Cancel, Save
    and return key, and Save is no longer covered.
- No test changed. Neither test relied on a layout detail that P2 changed
  legitimately: both found real defects in the list layout.
- **Verification:**
  - Script: `polish-p2/ci110-run.sh`, run under the heavy-build lock with
    derived data in `dd-polish-p2`, on simulator `CB24FAE2-…` (iPhone 16e).
    Logs: `polish-p2/logs/ci110*.log`, and result bundles
    `ci110-run{1,2}.xcresult`.
  - Debug `build-for-testing`: exit 0. The only warnings in
    `AssistantCard.swift` are the existing `PhotosPicker` label isolation
    ones.
  - Each run had 7 tests, and the run was done twice: both runs exit 0, 7 of
    7 passed. The tests were:
    - from `AssistantsWave3UITests`: `testAFailedDeleteChangesNothingAndSaysSo`,
      `testChoosingABotHandleChecksConfirmsAndClaims`,
      `testThePrimaryCardHasNoDeleteRow`,
      `testDeletingAnAssistantAsksWithDesktopsWordsThenLeaves` and
      `testTheCardWithDeleteFitsAtTheLargestTextSize`;
    - from `ChatInfoUITests`, the two that use the card's keyboard Done:
      `testAssistantPurposeSavesWhenLeavingTheField` and
      `testAssistantPersonalityExpandsAndSavesInTheCard`.
  - `python3 scripts/design_lint.py`: exit 0.
  - `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0,
    by its own exit code, after the commit.
  - The hosted shards still have to confirm.

## PR #110 hosted UI shards 1 and 2 (run 45609426502, head e5d867e)

- **Shard 1, `ChatInfoUITests.testAPersonalityEditKeepsTheOtherDevicesPurposeInDarkAtAX5`:**
  a real P2 defect. The shard's xcresult (hierarchy plus screen recording)
  shows that at AX5, with the long scripted persona, the "What you do" row was
  840 pt tall. That is taller than the 797 pt list. Its vertical `TextField`
  (`lineLimit(3...10)`, about 68 pt a line) filled the viewport with its own
  scrolling text. Every swipe from the screen centre scrolled the field's text,
  never the list. The list stopped at 51 %, so the Personality row below was
  never built.
  - Product fix (`AssistantCard.swift`, `fieldLines`): at the accessibility
    text sizes, the purpose, instructions and personality fields stop growing
    at four lines and scroll their own text, so a row stays shorter than the
    list. Non-accessibility sizes are unchanged.
  - Test fix (`ChatInfoUITests.scrollCardList`): the AX5 test scrolls the
    card's list by dragging its side margin, which belongs to the list alone,
    instead of swiping the screen centre. A centre swipe can still start on a
    field that scrolls its own text. The assumption that "the screen centre
    scrolls the card" dates from the old `ScrollView`. No assertion changed.
- **Shard 2, `AppSidePanelUITests.testUnlinkedAppPanelConnectReturnsToTheChat`:**
  the recording shows the `chat.title` tap highlight the title, and then no
  sheet presentation starts at all, not even partly. The app's hierarchy has
  no sheet. The presentation path (`ChatScreen` `.sheet(isPresented:)`,
  `ChatPanelHost`, `AppPanelPages.swift`) has no P2 change. The sibling tests
  that use the same launch passed on the same runner. No code changed for it.
  It is judged by the local repeat runs below.
- **Second AX5 defect, found locally:** once Personality was reachable, the
  test's `assistant.card.saved` check failed 3 of 3. "Saved" sits in the
  card's header, and the list releases the header once it is scrolled off. On
  the old `ScrollView` it existed off screen. The product is correct: the line
  is where desktop has it.
  - The test now drags back until the header and the handle row are both
    built, then checks Saved. It also checks that the conflict band, which
    sits between them, is absent. A band check made while the header is off
    screen would pass vacuously.
- **Verification:** `polish-p2/ci110b-run.sh`, run under the heavy-build lock
  on the iPhone 16e simulator, with derived data in `dd-polish-p2`. Logs are in
  `polish-p2/logs/ci110b*` and `ci110c*`.
  - **ci110b, at `606615e`:** Debug `build-for-testing` exit 0.
    - `testUnlinkedAppPanelConnectReturnsToTheChat`: passed 3 of 3.
    - The AX5 test: failed 3 of 3. The failure is at the Saved check, past
      the original line-129 failure.
    - The other 17 `ChatInfoUITests` and `AppSidePanelUITests` cases: 17 of
      17 passed.
  - **ci110c, with the Saved-check change:** build exit 0. The AX5 test
    passed 3 of 3.
  - `python3 scripts/design_lint.py`: exit 0.
- **Verdict on shard 2:** it does not reproduce locally (3 of 3), and the P2
  diff has no part in its path. It is treated as a hosted flake. The tap
  landed while the scripted Moon reply was arriving, and no sheet
  presentation began. If it recurs, look at `ChatScreen`'s sheet presentation
  under a transcript update (P3 owns `ChatScreen`), not at the panel list.

## PR #110 hosted UI shard 1, again (run 45658840730, head 5ba6ad8)

- **Failure:** the AX5 test failed again on hosted shard 1. It failed at the
  Saved check (`XCTAssertTrue(saved.waitForExistence(timeout: 5))`) after
  97 s. It was the shard's only failure.
- **Evidence:** the shard's xcresult (activity log, screen recording, final
  hierarchy).
  - **The app was right.** The recording shows "Đã lưu" (Saved) in the card
    header after the edit, and no conflict band. The save fired.
  - **The test closed the sheet.** On the first back-drag, the list reached
    its top partway through the drag. The rows above Personality had not been
    built, and they came in shorter than their estimates. The rest of the
    320 pt drag (0.4 of the list) then pulled the sheet itself down. The
    sheet settled at its medium detent, with the list's top at y 393.6 instead
    of 47. The handle row was then off screen, so the loop kept going. Its
    next drags started at y 206, above the sheet, on the chat behind it. Once
    XCTest saw the new frame, a drag closed the sheet. The loop then fell
    back to `app.swipeDown()`. Saved was left only as a stale node with an
    infinite frame.
  - **Locally the same test passed.** The repro run at `5ba6ad8` on the iPhone
    16e passed 2 of 2. There the first two drags stopped short of the top,
    so nothing overshot. On hosted, the jump to the top came within one drag.
- **Proof of the mechanism (temporary probe tests, not committed):** the card
  opens at AX5 with the list at its top. One back-drag from the list margin:
  - 0.4 of the list: the list's top moved from 47 to 393.6 (the hosted
    frame), and the handle row was gone. 2 of 2.
  - 0.18 of the list: the list's top stayed at 47, and the handle row stayed
    built. 2 of 2.
- **Fix (test only; the app's behaviour is desktop's):** in
  `ChatInfoUITests.scrollCardList`, a back-drag travels 0.18 of the list
  (about 143 pt), not 0.4. An overshoot at the top then snaps back to the
  large detent. The AX5 test allows up to 16 back-drags, up from 8, and the
  loop exits as soon as Saved and the handle row are both on screen. Its Saved
  assertion now reports the list's frame, so a dropped sheet shows in the
  failure message.
- **Nothing weakened:** the test still checks the following.
  - Exactly one `persona-save.txt` line.
  - The personality holds both "Calm." and "Vui vẻ.".
  - The other device's purpose is kept, and the stale one is not written.
  - No conflict band.
  - Saved is in the header.
  - The length hint can be reached.
- **Verification:** `/Volumes/AtumTestFlight/p2-chatinfo-ax5.sh`, run under
  the heavy-build lock on the iPhone 16e (390 x 844, the hosted size), with
  derived data in `dd-polish-p2`. Logs are in `dd-polish-p2/logs/*-{repro16e,fix3x,fixall,probe}.log`.
  - **fix3x:** build exit 0. The AX5 test passed 3 of 3 (88, 54 and 54 s).
  - **fixall:** build exit 0. All 14 `ChatInfoUITests` and 5
    `AppSidePanelUITests` cases passed, 19 of 19.
  - `python3 scripts/design_lint.py`: exit 0.

## Known gaps

- **Lazy rows in the UI tests:** the test changes above were reasoned from
  the code and the captures, not run. A hosted run may still find a row that
  a test reads before scrolling to it.
- **Large sheet:** the panel's rows keep the `cell` colour on the sheet's own
  ground. At the large detent in light mode, both are white, so groups read by
  spacing and separators only. That was already the case before this lane
  (audit shot `08-group-info-scrolled-light.png`). Proposal: give the panel
  the Settings ground (`ground` behind `cell`), which would replace the
  medium detent's glass look. That is a design call for the owner.
- **Section headers:** iOS 26 draws inset-grouped section headers in a bolder
  style than the old grey footnote titles, the same as Settings.

## Session log

- **25 Nov 2026, P2 UI sub-agent (Opus):**
  - Branch `feat/polish-p2-lists-headers` from `9f54045`. Local commits only:
    no push, PR or CI.
  - First capture run: in these list rows `Label` drew its title only, so
    Chat Info and the desk lost their row glyphs. Rows now draw an explicit
    glyph-and-text `HStack`, the column they had before.
  - Stayed out of P3's files (Composer, MessageMenu, MessageBubbleRow,
    DeliveryLine, ChatRowView, EmptyChatGreeting, ChatScreen), the avatar views
    (`ChatInfoAvatar`, `HomeAvatar`), `AtumAvatar.swift` and `RootTabs.swift`.
- **25 Nov 2026, PR #110 CI-fix sub-agent (Opus):**
  - Hosted UI shard 3 failed two card tests. The cause came from the shard's
    xcresult, not from guessing. It was not a lost identifier.
  - In one test the delete-failure footer was below the fold. In the other,
    the keyboard bar's Done covered Save.
  - Both were fixed in `AssistantCard.swift`, and no test changed. The fixes
    were verified locally twice (above).
  - Local commit only: no push, no CI rerun.
- **25 Nov 2026, PR #110 shards 1 and 2 CI-fix sub-agent (Opus):**
  - Root causes came from the shards' xcresults: hierarchies and screen
    recordings.
  - AX5 card: the persona row was taller than the list. It is now capped at
    four lines at accessibility sizes. The test drags the list's margin and
    reads Saved where the list builds it.
  - The unlinked app panel test passed 3 of 3 locally, and no P2 code is in
    its path.
  - Local commits only: no push, PR or CI rerun.
- **26 Nov 2026, PR #110 shard 1 re-fail, test sub-agent (Opus):**
  - The cause came from the hosted xcresult and was proven by probe tests.
    The test's 0.4 back-drag overshot the list's top and dropped the sheet to
    its medium detent. The app saved and showed Saved correctly.
  - The fix is test-only: back-drags are now 0.18 of the list, with up to 16
    of them.
  - Local results: the AX5 test passed 3 of 3, and ChatInfo + AppSidePanel
    passed 19 of 19.
  - Local commit only: no push, PR edit or CI rerun.
