# App side panel pages, official app card and app row "Info" (AS-11)

Backlog item AS-11 (P1, owner-reported; backlog of record atum-platform/atum-mobile#50;
parity audit 2026-11-10 lane 3, rows "App side panel" and "Official app card", slice L3-S13).
An app chat's side panel was an empty placeholder (`ChatPanelHost` `.appPage` drew
`EmptyView()`, and nothing pushed it). It now matches desktop as rendered, within the
limits listed at the end.

Desktop reference: atum-desktop `origin/main` **583ae946**. Platform reference read for the
route: atum-platform `origin/main` 1a2eacc0. State: committed locally on
`feat/app-side-panel-pages`; **verification pending hosted CI** (no local `swift build`,
`swift test` or `xcodebuild` was run, by instruction).

## What desktop renders, and what the phone does

All desktop paths are under `apps/desktop/`.

### The app chat's side panel (desktop `AppBotPanel`)

Desktop shows `AppBotPanel` in the side panel's launcher slot for an app chat
(`src/matrix/workbench.tsx:807-815`).

| Element | Desktop | Phone |
| --- | --- | --- |
| Data source | `bridge.menu(app_id)` (`src/matrix/app-bots/panel.tsx:172`) → main `menu()` (`electron/matrix/app-workspace.ts:990-1009`) → `GET /api/matrix/v1/apps/{slug}/manifest` with `Atum-App-Panel-Profile: atum.app-panel/1` (`electron/matrix/account.ts:2763-2796`); the `app_panel` sibling is decoded by `decodeAppPanel` (`shared/app-panel.ts:39-72`, `electron/matrix/app-workspace.ts:437`) | `NativeDomainClient.appWorkspace(slug:)` now reads the same route with the same header (`ios/Sources/AtumNativeAPI/NativeDomainClient.swift:243`). `AppWorkspaceSnapshot` keeps each route's `label` and `icon` and decodes `app_panel` into `AppPanelDeclaration` with desktop's rules (`ios/Sources/AtumNativeAPI/AppPanelPages.swift:35`); an invalid declaration is dropped, never the manifest. Read on panel open (`LiveAppModel.refreshAppPanel`, `ios/App/LiveAppModel.swift:2650`); a read within 60 s for the same version stands |
| Identity | Tile avatar, name, verified mark, subtitle (`panel.tsx:379-390`) | The panel's existing header: avatar, name with `AppSeal`, subtitle, kind line (`ChatInfoSheet.swift` `header`) |
| Pages | One centred column of Kit capsules, glyph at the start and name centred, `min(100%, 18rem)` (`panel.tsx:393-446`, `app-bots/panel.css:51-80`); declared pages in declared order with their glyphs, else the menu routes; never the chat's own `open_route_id` (`panel.tsx:216-226`) | `AppPanelPagesSection` (`ios/App/Chat/Views/AppPanelPages.swift:113`, capsule `:198`) after the header; order and filtering in `AppPanelPagesPolicy.pages` (`AppPanelPages.swift` package file `:148`) |
| Glyphs | `appSurfaceGlyph`: curated Phosphor name, else legacy alias, else `app-window` (`src/lib/atum-app-surface-icons.ts:6-37`) | `AppPanelGlyph` (`ios/App/Chat/Views/AppPanelPages.swift:84`): same alias table; drawn when the phone's Phosphor asset catalog has the symbol, else the globe |
| Not linked | One primary "Connect", back to the chat's connect card (`panel.tsx:395-404`) | `.connect` → primary "Connect" closes the panel (`AppPanelPages.swift:151`) |
| Unavailable / failed read | Notice "This app is unavailable." with Retry while the app is up (`panel.tsx:405-413`); a failed refresh keeps a menu already shown (`panel.tsx:158-162`); a menu for another app version is a failure (`panel.tsx:180-184`) | `.unavailable(retry:)` → `AtumNotice` + Retry (`AppPanelPages.swift:157`); same keep-on-failure and version rules in `AppPanelPagesPolicy.state` (package `:179`) |
| Loading | Four skeleton capsules, screen-reader "Loading apps…" (`panel.tsx:414-422`) | Four quiet capsules with the same accessibility label (`AppPanelPages.swift:172`) |
| Empty | "This app has no screens yet." (`panel.tsx:423-424`) | Same words (PENDING-COPY) (`AppPanelPages.swift:183`) |
| Page bar | Back, app tile, page name, Open in browser (`panel.tsx:330-355`) | The panel's navigation bar: system Back, page name, the panel's X (`AppPanelPageView`, `AppPanelPages.swift:222`) |
| Page content | Embedded `AtumAppView` with failed/offline presentation (`panel.tsx:361-375`) | `ChatPanelPolicy.Page.appPage(routeID:)` is pushed (raising the panel to large); the page's signed launch (`POST …/apps/{slug}/launch`, `LiveAppModel.launchAppPage`, `:2673`) opens in Safari over the panel; closing Safari pops back to the pages (desktop's Back at a page root). A failed launch shows "Couldn't open this page." (PENDING-COPY) with Retry |

### Official app card (desktop `AppCard`)

| Element | Desktop (`src/matrix/assistant-card/app-card.tsx`) | Phone (`ios/App/Home/AppCardSheet.swift`) |
| --- | --- | --- |
| Done | Top-left "Done" (`:35-37`) | Leading toolbar "Done" |
| Face | Catalog tile avatar (`:41-46`) | `ChatInfoAvatar` app squircle from the row's art (`:122`) |
| Name + verified | Name, `CheckCircle2` labelled "Verified" when `app.verified` (`:47-52`) | Same (`:130`) |
| Caption | "An Atum app" (`:53-55`) | Same |
| Open pill | "Open {app}" with ArrowUpRight, only when `availability === 'available'`; opens the app's chat (`:56-63`, `index.tsx:88-91`) | Same; opens the row (`HomeActions.openRoom`) (`:141`) |
| About | `description` else `subtitle`, in a settings group (`:30`, `:65-71`) | `AppCardPresentation.about` via `LiveRosterRows.appDescriptionOrSubtitle` (`:92`) |

### "Info" on an app row (desktop `RosterAppMenu`)

Desktop wraps app bot rows and not-yet-started catalog app rows in `RosterAppMenu`
(`src/matrix/roster-conversations.tsx:492`, `:1287`), whose single item "Info" opens the
card (`src/matrix/roster-context-menu.tsx:578-597`; `src/matrix/app.tsx:8036-8039`).
Coming-soon placeholders have no menu. Phone: the Home row's long-press menu leads with
"Info" for app rows (`HomeRowActionPolicy.offersAppInfo`, `ios/App/Home/HomeScreen.swift:2464`;
menu `:2684`; awaiting-start rows `:2551`), with an accessibility action, and presents
`AppCardSheet` (`HomeScreen.swift:499`); data from `LiveAppModel.appCardPresentation(rowID:)`
(`ios/App/LiveAppModel.swift:2696`).

## Copy

Exported keys used: `src.matrix.assistant-card.copy.assistantCardCopies.{done,appCaption,openApp,verified,menuInfo}`,
`src.matrix.app-copy.matrixAppCopy.{connect,unavailable,retry,loading}`.

PENDING-COPY (desktop's hard-coded `panelCopy`, `src/matrix/app-bots/panel.tsx:41-92`, not in
the pinned export; values copied verbatim for five locales in `AppPanelPendingCopy`, read
only when the export lacks the key):

- `src.matrix.app-bots.panel.panelCopy.openIn` ("Open in {0}", the pages section's label)
- `src.matrix.app-bots.panel.panelCopy.noScreens`
- `src.matrix.app-bots.panel.panelCopy.failed`

Not needed by the phone's adaptation: `back`, `openInBrowser`, `linkLabel`, `linkMessage`, `offline`.

## Behaviour change outside the panel

The phone previously read the workspace at `GET /api/matrix/v1/apps/{slug}`. atum-platform
main serves no such route (`apps/shell/src/app/api/matrix/v1/apps/[slug]/` has `manifest`,
not a bare route, and `middleware.ts:61` admits only the suffixed paths), so that read
always failed and `appWorkspaces` stayed empty live. Moving it to `/manifest` also brings
Moon's composer "readings" action (`AppBotPresentation.composerAction`) and
`openAppRoute` to life on the phone; both keep their existing gates.

## Remaining differences (desktop ↔ phone)

1. **Commerce pages stay closed.** Owner decision (11 Nov): every declared page
   opens, as on desktop (`panel.tsx:236-240`, `:426-443`), except pages that sell or
   price digital goods (the app's own `purchase_route_id`, and `top-up`, `purchase`, `pricing`, … in
   `AppOnboardingPolicy.commerceRouteIDs`), which App Store guideline 3.1.1 keeps on
   In-App Purchase. The platform needed no change: its launch already refuses a route
   the app version doesn't declare (`target_route_id = any(endpoint.session_route_ids)`,
   migrations 0400/0403/0411, `app_launch_route_unknown`) and has no iOS-specific limit.
   Follow-up: `atum.mobile-native-api/1.3` still says `routes-unchanged`
   (`spec/mobile-native-api/v1.3/contract.json:52-55`); record this as a v1.4 text
   amendment in atum-platform.
2. **Page content** opens in Safari, not inside the panel; there is no in-panel bar with
   the app tile or "Open in browser" (Safari has its own). Desktop's in-page navigation
   bridge (`panelCommand`, `focus-chat`, `⌘1-9`, `⌘R`) has no phone equivalent.
3. **Launch profile.** The phone sends no `Atum-App-Launch-Profile` and keeps
   `atum.app-launch/1`; an app whose manifest only offers v2 launch reads as not
   launchable.
4. **Glyphs** the phone's asset catalog lacks (e.g. `books`, `heart`, `cards`) draw the
   globe; adding them needs `scripts/generate-phosphor-symbols.py` assets.
5. **Phone-only controls.** The app panel keeps the phone's pin/mute tiles, assistant
   access line and "Delete chat" below the pages (desktop has them in the roster menu).
   The Home row menu keeps pin/mute/unread/delete after "Info".
6. **Look packs.** Desktop tints the panel with the app's look pack
   (`resolveAppPanelLook`, `panel.tsx:120`, `:302-325`); the phone does not.
7. **Bot API panel link** (`panel-link`, `electron/matrix/app-workspace.ts:1050-1060`) is
   not read; the phone's pages need no account link for Bot API apps (the policy treats
   them as linked, as desktop does), but their launch gate is unchanged.
8. Desktop's 15-second "no answer" timeout (`panel.tsx:164-170`) is the phone's ordinary
   request timeout.

## Changed files

- Wire and policy: `ios/Sources/AtumNativeAPI/AppOnboarding.swift` (route label/icon,
  `app_panel`, typed init), `AppPanelPages.swift` (new), `NativeDomainClient.swift`
  (manifest route + header, `manifest` added to both app path allowlists).
- App: `ios/App/Chat/Views/AppPanelPages.swift` (new), `ios/App/Home/AppCardSheet.swift`
  (new), `ios/App/Chat/Views/ChatPanelHost.swift` (`.appPage` destination),
  `ios/App/Home/HomeScreen.swift` (Info item, card sheet), `ios/App/LiveAppModel.swift`,
  `ios/App/AppRoot.swift`.
- Shared files owned by another lane, minimal edits: `ios/App/Chat/Views/ChatInfoSheet.swift`
  (one optional `ChatInfoActions.appPanel` field; one `AppPanelPagesSection` insert after the
  app panel's header), `ios/App/Chat/Views/ScriptedChatHost.swift` (one `appPanel:` argument).
  `AssistantCard.swift` untouched.
- Scripted fixture: `ios/App/Debug/ScriptedAppPanel.swift` (new) behind
  `-AtumScriptedAppPanel <pages|empty|failed|connect>` (`ios/Sources/AtumChat/LaunchArguments.swift`);
  scripted Home `appInfo` in `ios/App/Debug/ScriptedHomeHost.swift`.
- Tests: `ios/Tests/AppPanelPagesTests.swift` (new), `ios/Tests/NativeDomainClientTests.swift`
  (manifest route), `ios/AppTests/AppSidePanelStateTests.swift` (new),
  `ios/UITests/AppSidePanelUITests.swift` (new).
- `ios/AtumMobile.xcodeproj/project.pbxproj`: five file references added by hand (sibling
  entries mirrored; no `xcodegen generate`).

## Verification

Local (Mac mini, no build), all passed: `swiftc -parse` on all 18 changed Swift files;
`plutil -lint ios/AtumMobile.xcodeproj/project.pbxproj`;
`python3 -m unittest discover -s tests -p test_ios_project_sources.py` (2 tests);
`bash scripts/pre-push-public origin/main HEAD` (PASS: paths, ancestry, identifiers,
secrets, metadata).

Pending hosted CI: `swift test` (package tests above), AppTests, the UI test class
`AppSidePanelUITests` (iPhone only), and the native build. Nothing here was compiled.

CI fix (11 Nov, run 43019137755): `perform(...)` now admits `Atum-App-Panel-Profile` only as
`atum.app-panel/1` on a GET of `/apps/{slug}/manifest`; the AppTests card fixture no longer
feeds a blank localized phrase (`AppLocalizedCopy` refuses it, as desktop's catalog parser does),
and asserts the refusal instead.

UI fix (11 Nov, run 43049204470, shard 0): `testAppPanelReadFailureOffersRetry` could not find
`info.app.unavailable`. The section's own container id (`info.app.pages`) replaced the notice's id
on its text, so the notice is now its own accessibility container in both retry and no-retry forms.
Not compiled locally (build lock busy); hosted UI shard 0 is the verdict.
