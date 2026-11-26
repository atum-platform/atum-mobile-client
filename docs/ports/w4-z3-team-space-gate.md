# W4-Z3 Team Space beta gate

Desktop #132 gates Team Space behind the account's native `/me`
`betaFeatures` answer (W4-Z1, `LiveAppModel.betaFeatures`). The iPhone now
matches it for accounts where the flag is false. Beta accounts see no change.
The gate controls presentation only. The platform still authorizes each
company action.

Desktop reference (`atum-desktop`):

- `apps/desktop/src/app/atum/shell-surface.tsx:235`: the rail item is greyed
  (`--atum-ink-ghost`), labelled `Team space · Coming soon`, and has no badge.
- `apps/desktop/src/matrix/workspace.tsx:356`: the Team Space page is an
  empty state with `surfaces.comingSoon` over `surfaces.comingSoonHelp`
  (`data-team-space-coming-soon`).
- `apps/desktop/src/matrix/app.test.tsx:3523`: room links, notifications and
  selected company rooms all land on that page. None of them shows a
  workspace, transcript or composer. Assistant pages opened from Settings
  still work.

## Phone behaviour

The decision lives in `AtumChat.TeamSpaceBetaGate`
(`ios/Sources/AtumChat/TeamSpaceBetaGate.swift`), built from
`model.betaFeatures` on every render of the shell. Because the flag is
observable, sign-out, sign-in and account switches update the gate live.

- **Tab** (`RootTabs`): the system tab bar keeps the Team Space tab. When
  gated, its briefcase glyph is drawn in the Kit's `ink-4` (the phone's
  ghost ink) in both selected and unselected states. The accessibility
  label combines the pinned title and status: `teamSpaceTitle · Coming soon`
  (`desktop.surfaces.comingSoon`). The tab shows no mention badge and no
  value.
- **Page** (`TeamSpaceComingSoonView`, applied by `.teamSpaceComingSoon`):
  a system `ContentUnavailableView` with the briefcase glyph, the title
  `desktop.surfaces.comingSoon` and the description
  `desktop.surfaces.comingSoonHelp`, under the large `Team space` navigation
  title. All copy comes from pinned keys. The page replaces
  `TeamSpaceScreen` and its room `navigationDestination`, so the workspace,
  the join-by-link sheet and the company chat host are not in the view
  hierarchy at all.
- **Routing** (`AppRoot.routeRoom`): when the requested or authoritative
  destination is Team Space and the gate is closed, the route calls
  `landOnTeamSpaceComingSoon()`. That function invalidates in-flight opens,
  drops any pending thread route and shows the Team Space root, which is the
  Coming soon page. It never calls `model.openRoom`, so it opens no Matrix
  timeline and no composer. This route covers foreground and cold
  notifications (`onValidatedRoom` and `onValidatedColdRoom`), Home search
  channel and message results, retained Team Space rooms on a tab re-tap,
  and any `requestRoomOpen`. The route reports `opened` because it has
  landed where desktop lands, so Home search shows no error. If the gate
  closes while an open is in flight, the authoritative check closes the
  conversation that just opened.
- **Board links** (`onOpenCompanyBoard`): a gated account goes straight to
  the Coming soon page. No `boardLinkRequest` is recorded that a later
  account might pick up.
- **Flag flips** (`.onChange(of: model.betaFeatures)`): if the flag turns off
  while a company room is open in Team Space, the room is closed and the
  Team Space stack pops to its root. If the flag turns on, the next render
  restores `TeamSpaceScreen`.
- **Personal chats** keep their routing. Settings › Assistants lives in the
  Account sheet and never routes through Team Space, so the desktop's
  `initialPage` exception has no phone counterpart to preserve.

The tab doc comment previously said an unavailable tab is never dimmed. It
now records this gate as the single exception, because desktop #132 greys
the rail item.

## Debug and captures

`ScriptedHomeHost` reads `-AtumScriptedBetaFeatures NO`, the same flag W4-Z2's
Store gate reads, and applies the gate to its tab and Team Space page. Without
that flag, every existing scripted walk is unchanged. When this lane and W4-Z2
are assembled, the coordinator may move this static onto Z2's
`AtumDebugLaunch.scriptedBetaFeatures` state.

Captures: `/Volumes/AtumTestFlight/w4-z3/` on the build volume, local only.
They cover non-beta and beta accounts, the Team Space and Home tabs, light
and dark, and AX5. The beta captures double as "before" captures, because
before this change every account rendered the way beta accounts do now.

## Verification

- `TeamSpaceBetaGateTests` (AtumChat): flag → gate, combined label, badge
  suppression, routing landing (Team Space only, personal unaffected, beta
  unaffected), and closing an open room on a flip.
- `TeamSpaceDailyUITests.testWithoutBetaFeaturesTeamSpaceIsComingSoon` is
  left to the hosted UI shards. It checks the Coming soon page and copy, the
  absence of the workspace, the combined tab label, the absence of a mark,
  and that a tab round trip still lands on Coming soon.
- The locked run (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`)
  covers `swift test --filter
  'TeamSpaceBetaGateTests|PhoneTabAvailabilityTests|AccountBetaFeaturesTests'`,
  the Debug `build-for-testing` for `AtumMobile` (generic iOS Simulator,
  arm64) and the captures.
- The design lint, `git diff --check` and `python3 scripts/public_guard.py
  --base origin/main --head HEAD` run unlocked.

Results are recorded in the session-log section below.

## Open questions

- Desktop opens a popover on the rail and keeps the current place. The phone
  has no popover on a system tab, so a tap selects the tab and shows the
  same Coming soon content as its page. Desktop also shows that page for
  routed company rooms.
- Home search still lists Team Space channels and messages for a gated
  account, and opening one lands on Coming soon. This matches the desktop
  code: `globalChannels` in `matrix/app.tsx` does not read beta features, and
  selecting a channel lands on the gated page. It has not been compared
  against a running desktop.
- The notification service extension still renders company notifications
  with their Team Space names and logos. Only the tap is gated.

## Session log (2026-11-26)

- Locked run (`/Volumes/AtumTestFlight/dd-w4-z3/run.sh`, iPhone 17 simulator
  939B69F8): `swift test --filter` ran 8 tests (5 `TeamSpaceBetaGateTests` and
  3 `PhoneTabAvailabilityTests`) with 0 failures. Debug `build-for-testing`
  for `AtumMobile`, including the UI test target, ended with
  `** TEST BUILD SUCCEEDED **`.
- Captures: on the first pass, 8 of 10 frames caught the launch screen
  because the 8 s wait was too short. No crash report was written. A second
  locked pass, captures only (`captures.sh`: one warm-up launch, then 25 s
  waits), rendered all 10.
  - Non-beta: the tab shows a grey briefcase with no badge. The page has the
    large `Team space` title over "Coming soon" and "This place is not ready
    yet." The layout holds in light, dark and AX5.
  - Beta: the workspace, the channel list and the 7 badge are unchanged.
- Unlocked checks: design lint OK (baseline unchanged), `git diff --check`
  clean, and `public_guard.py --base origin/main --head HEAD` exit 0.
- The UI test was not run locally. Per the lane rules, the hosted UI shards
  run it.
- Deferred: the gate is not enforced in the notification service extension's
  presentation, so a company notification still renders. Only opening it is
  gated.
