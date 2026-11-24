# W4-E7: Team Space revamp pass 1 on the phone

Branch `feat/w4-e7-team-space`, based on `feat/w4-copy-repin-4` (`1bbc388`, the wave 4d copy repin,
itself on main `c12250b`). Desktop reference: atum-desktop main `fef8286c` (PR #114 at `677b746d`,
export PR #115), read only. Desktop's own record is `docs/team-space-revamp/README.md` there, with
21 after shots. Phone parity scope comes from atum-desktop
`docs/ports/mobile-export-wave4-copy.md` § "Wave 4d" › "Phone parity of #114's behaviours" and from
[Wave 4d copy repin](w4-copy-repin-4.md) § "Pending copy".

| #114 behaviour | Phone | Reason |
|---|---|---|
| Header search (the box filters the list; Enter or "Search “…”" runs company message search) | Yes | Same entry point and words. |
| Sectioned, role-aware settings (People, Workspace, AI, Billing; falls back on a role change; "Company hiring is being prepared") | Yes | Phone has People and AI today. See below. |
| Board/List and Mine | Yes, the controls | The phone has no board read, so the controls sit over the board's unavailable state, as desktop draws them over its own. |
| Channel opening, "Couldn’t open this channel." with Try again, held per company and room | Yes | State rules and words. |
| Private Chief of Staff label | Yes | Naming only. |
| One right pane | No | Each detail is already its own sheet or pushed screen on the phone. |
| Narrow sidebar truncation | No | Desktop sidebar layout. |

## Inventory (adopt first)

### Phone Team Space parts reused

All citations are at the base `1bbc388` unless marked "new".

| Part | Where | Used for |
|---|---|---|
| `TeamSpaceScreen` list, the `.searchable` header box and its `needle` filter | `ios/App/Company/CompanyWorkspaceViews.swift:547`, `:145` | Header search: the box already filtered channels and DMs. The search row and the keyboard's Search were added to it. |
| `TeamSpaceSearch.needle` / `.matches` | `ios/Sources/AtumNativeAPI/CompanySpacePolicy.swift:101` | Filtering and "No matches". |
| Channel row and its tap | `ios/App/Company/CompanyWorkspaceViews.swift:832–834` | Channel opening state and the failed line. |
| `openRoomAndRoute` and its request generation | `ios/App/AppRoot.swift:1119` | The channel open's answer. A newer generation means another open took over. |
| Company search service, eligibility and confirm-open (Home search) | `ios/App/Company/CompanySpaceReads.swift:171`, `:186`; `ios/Sources/AtumNativeAPI/CompanySearchService.swift`, `CompanyMessageSearch.swift` | Header search asks the same service, limited to the open company. |
| `HomeSearchRoute.open`, `HomeSearchEventRow` | `ios/App/Home/HomeGlobalSearch.swift:43`, `:153`; wiring `ios/App/AppRoot.swift:985` | Opening a result and drawing its row. |
| `CompanyPagesBar` (segmented `Picker`) | `ios/App/Company/CompanySpaceViews.swift:13` | The pattern for Board · List and the settings sections. |
| `CompanyBoardPage` unavailable state | `ios/App/Company/CompanySpaceViews.swift:48` | Kept under the new controls. |
| `CompanyOverviewSheet` (members, Chief of Staff, Leave) | `ios/App/Company/CompanySpaceViews.swift:113`, `:134`, `:153` | Split into People and AI. |
| Company menu "Company overview" / "Company settings" | `ios/App/Company/CompanyWorkspaceViews.swift:696`, `:708` | Which section the sheet opens on. |
| Direct messages Chief of Staff row and its search match | `ios/App/Company/ConversationViews.swift:123`, `:266` | Private Chief of Staff label. |
| Conversation title | `ios/App/LiveAppModel.swift:3629` | Private Chief of Staff header and composer placeholder (`Composer.swift:224` uses the title). |
| `TeamSpaceCopy.text` export-first reader and the pending tables | `ios/App/Company/TeamSpaceCopy.swift:18` | `list` and `mine` held back as PENDING. |
| `LiveDesign.text(_:words:)` | `ios/App/LiveDesign.swift:53` | `searchFor` / `searchMessagesFor` formatters. |
| AtumDesign tokens: `AtumVisualSystem.color` roles (`ink`, `soft`, `muted`, `ground`), `symbol`, `barIcon`; glyphs `.search`, `.close` | `ios/App/DesignSystem/AtumVisualSystem.swift:31`, `:128`, `:141` | Every new row and sheet. No new colour, size or literal. |
| Phosphor map and generator | `ios/Vendor/AtumKitIcons/phosphor-map.json`, `scripts/generate-phosphor-symbols.py` | The six missing desktop glyphs. |
| Scripted Team Space host | `ios/App/Debug/ScriptedHomeHost.swift` | The UI walk's data. |

### Native SwiftUI used

| Need | Native piece | Source |
|---|---|---|
| Header box, keyboard Search | `.searchable(text:placement:prompt:)` and `.onSubmit(of: .search)` | <https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)-co5e>, <https://developer.apple.com/documentation/swiftui/view/onsubmit(of:_:)> |
| Results pane | `.sheet(item:)` with its own `NavigationStack`, `.searchable` with `.navigationBarDrawer(displayMode: .always)` | <https://developer.apple.com/documentation/swiftui/view/sheet(item:ondismiss:content:)> |
| Settings sections, Board · List | `Picker` with `.pickerStyle(.segmented)` in a sectioned `List` | <https://developer.apple.com/documentation/swiftui/segmentedpickerstyle> |
| Mine | `Toggle` with `.toggleStyle(.button)` (a pressed-state button, desktop `aria-pressed`) | <https://developer.apple.com/documentation/swiftui/togglestyle/button> |
| Opening spinner | `ProgressView` with `.controlSize(.small)` | <https://developer.apple.com/documentation/swiftui/progressview> |
| Failed line that wraps at large type | `ViewThatFits(in: .horizontal)` | <https://developer.apple.com/documentation/swiftui/viewthatfits> |

### Hand-rolled (the gap)

- `TeamSpaceRevampPolicy.swift` (new, `ios/Sources/AtumNativeAPI/`): desktop's rules as pure types,
  `TeamSpaceHeaderSearch`, `CompanySettingsSections`, `CompanyBoardPreference` and
  `CompanyChannelOpenState`.
- `TeamSpaceRevampViews.swift` (new, `ios/App/Company/`): the "Search “…”" row, the results sheet, the
  failed channel row, and the Board · List and Mine bar.
- `TeamSpaceRevampPendingCopy.swift` (new): the two pending labels.

## What changed

| Area | Phone now | Desktop source (`fef8286c`) |
|---|---|---|
| Header search | Once the box holds two characters (code points, after trimming), a "Search “launch”" row sits at the top of the list. VoiceOver reads it as "Search messages for “launch”". The row, or the keyboard's Search, opens a **Search** sheet. That sheet asks company message search for this company only and shows the Messages results. Its own field refines the query, and a result opens its message through Home's confirm-and-route. When the box filters out every channel and Direct message, the list says "No matches". Settings never offered search on the phone, so nothing was removed there. | `company-workspace.tsx:2983–3005` (box, Enter, row), `:3632` (pane), `team-space/company-search.tsx` |
| Sectioned settings | The overview sheet draws a segmented People · AI picker (`settingsSections`). It shows one section at a time and only draws the picker when there is a choice. People holds Members and Leave company, as desktop's members panel does. AI holds the Chief of Staff state and "Company hiring is being prepared", because the phone has no Marketplace page. Company settings opens on Workspace, and the overview opens on People. A section the viewer no longer has falls back to the first one there. Without a member snapshot, Leave company stays reachable. | `company-workspace.tsx:2842–2856` (sections, fallback), `:3331` (People), `:3377–3382` (AI) |
| Board · List and Mine | The Board page has a segmented Board · List control (`boardViews`) and, once the viewer's own member is known, a Mine button toggle. Mine sets the owner filter to the viewer, and both work in either view. Choices are kept per company for the session, like the page. Below the controls is the board's existing "Board is unavailable." state. | `company-board.tsx:2029–2056` |
| Channel opening | A tap shows a small spinner on the row while the room opens. A failed open adds "Couldn’t open this channel." with **Try again** under that row. The failure is held with its company and room and shown only in that company. It is cleared when the next open starts, on a success, and when another company comes on screen. Only the latest open may land. An open replaced by another, or one the person left Team Space during, is not a failure. | `company-workspace.tsx:410`, `:2549` |
| Private Chief of Staff | The Direct messages row, its search match, and the private chat's header and composer placeholder say "Private Chief of Staff" (vi "Chief of Staff riêng"). The overview's AI section and Activity/Saved labels keep the shared "Chief of Staff". | `team-space/conversation-sections.tsx:138,245`, `app.tsx:2370,8799` |

### Phone differences, recorded

- **No right pane.** The results are a sheet, and the failed line sits under the row that was
  tapped, because the phone's list is where the open was asked for. A pushed screen that only
  says it failed would add a step.
- **Preparing.** `preparingChannel` is not drawn. A channel without its room is already disabled
  in the list with its "Preparing" state, so the phone never selects an unbound channel.
- **Search failures.** The phone's company search service answers a failure with no results,
  as Home search does. The sheet then says "No matching messages…". Desktop shows its error
  text. The Files tab, file types, coverage, operators help and load-more are not drawn:
  `searchMessagesTab`, `searchFilesTab` and `searchNoFiles` are not in the pin.
- **Workspace and Billing.** The phone has no workspace settings (logo, policy, projects) or
  wallet, so neither section is offered. `companyWallet`, `openWallet` and `billing` are wired
  through `TeamSpaceCopy.settingsSection` for when they land.
- **"My tasks" migration.** The phone never had the third view or a remembered board view, so
  desktop's one-time `my_tasks` → List + Mine migration has nothing to act on.
- **Board content, compact cards, the Suggested lane, task details (`suggested`,
  `suggestedHint`, `showAllActivity`, `showLessActivity`).** These need the board read, which the
  phone does not have (`board-*` native routes; [Team Space structure](team-space-structure.md)).

## PENDING-COPY

`shared.matrix-company-board-copy.copy.list` and `…copy.mine` are not in the pin. Desktop export
W4-C5 adds them. `TeamSpaceCopy.boardView(.list)` and `.mine` read the export first, through the
`design.copy.contains` guard in `TeamSpaceCopy.text`. Until the export has them, they read
`ios/App/Company/TeamSpaceRevampPendingCopy.swift`. That table was generated verbatim with Bun from
`apps/desktop/shared/matrix-company-board-copy.ts` at `fef8286c`, through
`matrixCompanyBoardCopy(locale)` for en, vi, ja, zh and zh-hant.

| Key | en | vi |
|---|---|---|
| `shared.matrix-company-board-copy.copy.list` | List | Danh sách |
| `shared.matrix-company-board-copy.copy.mine` | Mine | Của tôi |

`tests/test_copy_keys_in_pin.py` gained both keys in `PENDING` and the new table in
`PENDING_TABLE_READERS`, the scanner's own mechanism for guarded fallback tables. Remove all three
entries and the table at the repin that carries W4-C5. The test file belongs to the copy-pin lane
(W4-D4). This lane's change there is these three lines only. No vendored pin file changed.

## Glyph mappings

Desktop draws six Phosphor icons that the phone's map lacked (`apps/desktop/src/lib/icons.ts`).
Each now maps to the nearest icon already vendored in
`ios/Vendor/AtumKitIcons/phosphor-icons.json`, so no asset was added.
`generate-phosphor-symbols.py --check` passes with 120 symbols.

| Alias | Desktop Phosphor | Phone | Why |
|---|---|---|---|
| `Checks` | `checks` (`icons.ts:50`) | `check` | Same tick, single. |
| `Forward` | `share-fat` (`icons.ts:114`) | `share-network` | Same Phosphor share family; the phone has no forward arrow vendored. |
| `LayoutGallery` | `slideshow` (`icons.ts:141`) | `image` | A gallery of pictures; `Photo` already uses it. |
| `LayoutGroups` | `rows` (`icons.ts:143`) | `files` | Stacked rows of items. |
| `PenNib` | `pen-nib` (`icons.ts:236`) | `pen-nib` | Exact; already vendored for `StorePenNib`. |
| `Laptop` | `laptop` (`icons.ts:235`) | `desktop` | Nearest computer; `StoreDesktop` already uses it. |

`glyphs.json` (the pin) still lacks these aliases, so no typed `AtumGlyph` case was added. The map
is ready when the export splices them.

## Files

- New: `ios/Sources/AtumNativeAPI/TeamSpaceRevampPolicy.swift`,
  `ios/App/Company/TeamSpaceRevampViews.swift`, `ios/App/Company/TeamSpaceRevampPendingCopy.swift`,
  `ios/Tests/TeamSpaceRevampPolicyTests.swift`, `ios/UITests/TeamSpaceRevampUITests.swift`.
- Changed: `CompanyWorkspaceViews.swift` (search row, No matches, channel open, board state),
  `CompanySpaceViews.swift` (board controls, settings sections), `TeamSpaceCopy.swift`,
  `ConversationCopy.swift`, `ConversationViews.swift`, `CompanySpaceReads.swift`
  (`teamSpaceCompanySearch`), `AppRoot.swift` (`openTeamSpaceChannel`, search wiring),
  `LiveAppModel.swift` (private chat title), `ScriptedHomeHost.swift` (scripted search, a
  channel that fails once, the viewer's member), `phosphor-map.json`, `PhosphorSymbols.swift`,
  `AtumMobile.xcodeproj` (three file entries added by hand, without a full XcodeGen
  regenerate), `tests/test_copy_keys_in_pin.py` (PENDING only).
- Not touched: Connections/plan rows (W4-E6), the agent desk and bell (W4-K), Stop (W4-I),
  read-signal UI tests (W4-J), and the vendored copy pin (W4-D4).

## Verification

See the session's final report for the locked run's exit codes. Its sections are:
`swift test --filter 'TeamSpaceRevampPolicyTests|CompanySpacePolicyTests|CompanyMessageSearchTests|StoreShelvesTests|AtumCopyTests'`,
the Debug simulator `build-for-testing`, and one local UI test,
`TeamSpaceRevampUITests/testRevampWalkInEnglishAndVietnameseLightAndDark`. That test walks
channel retry, Board · List · Mine and header search in en and vi, light and dark. All of it ran
under `lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`, with derived data in
`/Volumes/AtumTestFlight/dd-w4-e7` and packages in `/Volumes/AtumTestFlight/spm`.

## Commits

1. State rules (`TeamSpaceRevampPolicy.swift`) with their tests, and this document.
2. The six glyph mappings (`phosphor-map.json`, regenerated `PhosphorSymbols.swift`).
3. The Team Space UI: header search, channel retry, Board · List and Mine, settings sections,
   the Private Chief of Staff label, the pending table, scripted data and the UI walk.
4. UI walk imports `AtumChat` for its scripted scenarios (caught by the first locked build).
5. UI walk scrolls the failed line on screen (the row under #design is lazily made on a 6.1" screen), and finds the page and view segments by identifier.
