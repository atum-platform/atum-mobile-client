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

(Filled in after the locked run; see the session log below.)

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
