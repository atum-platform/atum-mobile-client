# W4-E6: plan connections, the connect sheet and relay lines

Wave 4 phone catch-up, UI lane W4-E6 (tracker atum-platform/atum-mobile#47).
It used to be "Work plan rows + consent". Desktop #106 (`f1d10cf0`) moved the
plan's connection and consent out of Work into `app/connections/`. Connecting
a plan covers every assistant, scheduled turns included, and the Mac's switch
is the off switch. The old `MS.work.planRow` and `MS.work.consent.*` keys are
gone (4c); `test_the_phone_does_not_reference_retired_work_copy` keeps them out.

Base: `main` `c12250b`. Desktop reference: atum-desktop `main` `677b746d`,
which includes #106 and #111 ("retire cloud carry availability"). The words
are the wave 4, 4b and 4c export already pinned in `ios/Vendor/AtumDesign`
(`MS.connections.*`, `MS.relay.*`).

Driving or viewing Work sessions stays out. The T3 Code iPhone app does that
through T3's own pairing. This lane builds only Atum's own layer.

## Inventory

"Phone-visible" means what desktop draws for a device without Work, which is
what the phone is. `file:line` is the phone code reused.

| Desktop surface (atum-desktop) | Phone-visible? | Reused on the phone | Gap → what this lane did |
| --- | --- | --- | --- |
| Settings › Connections › Subscriptions: one row per plan (ChatGPT, Claude, Antigravity), sorted connected → needs attention → last seen → not connected; line `onMacs` / `lastSeen` / `needsAttention` / `notConnected` (`connections-section.tsx` `AccountSubscriptionsSection`, `view.ts` `accountPlanRows`) | Yes | The page: `AccountSettingsDetail.swift:575` (it showed one "Not available yet" row). The transport: `NativeDomainClient.phoneDeviceServices` (`NativeDomainClient.swift:1537`), the owner-authenticated device-services route the phone registry already uses | No registry client or model. **Built:** `atum.account-connections/1` decoder, `NativeDomainClient.accountConnections()`, `AccountConnectionsView` (a port of `view.ts`) and the rows |
| The row's Connect (not connected, needs attention) → the connect sheet | Yes | `AtumKitButtonStyle.atumSecondary` (`AtumKit.swift:427`) | **Built** |
| The row's Manage (`row.here`: plan connected on *this* Mac, opens Work there) | No, Mac only | — | Not drawn: the phone is never "here" |
| "this Mac" in the Mac names (`copy.thisMac`) | No | — | Every Mac is named by its own name |
| OpenCode Go row: "In the cloud" / "Not connected" | Yes | The registry's `opencode_go` row | **Built** (status only) |
| OpenCode Go Connect / Manage (the key dialogs, `SubscriptionConnectDialog`) | Yes | — | Not built: no phone key-entry flow yet. Follow-up below |
| Work on this Mac section, this Mac's switch (`mac.*`, `this-mac-switch.tsx`) | No, Mac only | — | — |
| Data and tools: Your chats (always) and home hubs, "Not connected" on an unconnected hub (`AccountToolsSection`, `accountToolRows`, `homeHubName`) | Yes | Glyphs `.messages`, `.home` | **Built** |
| Connect sheet on a device with Work: `sheet.title`, `sheet.line(plan)` + `sheet.consent`, Not now / Continue | No: Continue starts T3's own sign-in in Work on the Mac, and the sentence says "through this Mac" | — | Not drawn |
| Connect sheet on a device without Work: `sheet.title`, `sheet.needsMac`, Close | Yes, this is the phone's sheet | `.presentationDetents`, as `DeleteAccountRequestSheet` | **Built** |
| Progress in the Work title band: `progress.signingIn`, `done`, `failed`, `tryAgain` | `signingIn` and `failed` no: they follow a sign-in the phone never starts. `done` yes, see below | — | **Built:** `done(plan)` with a check while the sheet is open and a Mac reports the plan. `tryAgain` labels the failed-read retry |
| Picker: a plan connected nowhere gets a hollow rail mark and the Connect state, mark + `picker.use(plan)` + Connect (`AccountPlanConnectState`) | Yes (cloud assistant pickers) | `PhoneModelPickerList` (`PhoneModelPickerList.swift:14`); the picker's subscription read (`LiveAppModel.swift:2419`) now also reads the registry | **Built:** one row per such plan under the models |
| Picker: `picker.inWork` greyed rows | No | — | Not drawn. Since #106 every plan is relay-enabled (`WORK_RELAY_ENABLED_PLANS = WORK_RELAY_PLANS`), so desktop `main` never produces `in_work` |
| Picker: `picker.openWork` | No, Mac only | — | — |
| Picker: a connected Claude or Antigravity plan's models (desktop lists them from the relay view, picks with `work_selection_set`) | Yes | The phone lists plan models only from the 1.5 destinations (ChatGPT) | Not built. Follow-up below |
| Relay turn line in an Atum chat: `waiting`, `waitingForAnswer`, `invalidAnswer`, `needsOk`, `limitHeld`, `stopping`, `stopped`, `queued`, `late`, `empty`, `failed`, `fallback(model, why)` (`relay-chrome.tsx` `WorkRelayTurnLine`) | Desktop draws it only from the Mac gate's own state: room status and ledger receipts (`electron/work/surface/relay.ts`), never from the Matrix timeline. A desktop without Work draws none | — | **Honest state: no line.** **Built:** the pure mapping `RelayTurnLine` (AtumChat), tested, ready for a source. Platform follow-up below |
| Relay line's Stop / Open Work action | No: Stop goes through the Mac's gate | — | — |
| Usage line `usageUsed` / `usageLimit` / `usageUnknown` + `usageScheduled(runs)` (`useWorkRelayUsageText`) | Defined, but no desktop component draws it at `677b746d` | — | **Built:** mapping only (`RelayTurnLine.usage`), tested |
| `relay.greyed.*`, `chipGreyed.*`, `chipLimit`, `fixAllow`, `consentChatsLine`, `consentScheduled` | Still exported, no longer drawn (4c notes) | — | Not built |

## What the phone does now

- **The read.** `NativeDomainClient.accountConnections()` POSTs exactly
  `{"operation":"account_connections_read"}` to
  `/api/matrix/v1/device-services`, the desktop's own request
  (`electron/work/surface/account-connections.ts`), over the existing phone
  registry transport. Shell takes the owner from the bearer
  (`apps/shell/src/lib/work-route.ts` `account_connections_read`). The
  answer is read as strictly as the desktop's zod schema
  (`shared/account-connections.ts`): any field, value or row outside the
  contract makes the whole answer unreadable, and the credential scan in
  `NativeAPI.decode` runs over all of it.
- **Settings › Connections** (`AccountConnectionsSections`,
  `ios/App/Account/AccountConnectionsSection.swift`). Subscriptions lists the
  three plans and OpenCode Go. Data and tools lists Your chats and the home
  hubs. Then Google and Apps follow as before. The page owns the read
  (`AccountConnectionsModel`) and re-reads it whenever the app comes back,
  as the desktop re-reads on focus.
  - Loading shows a spinner row. It never shows "Not connected" before the
    read answers.
  - A failed first read shows "Couldn't check this right now." with Try
    again. A failed refresh keeps the last good read, as the desktop does.
    The desktop falls back to its own Mac's plan facts. The phone has none,
    so it says it could not check instead of claiming "Not connected".
  - Your chats is drawn before and without the read, since it is always
    there.
- **The connect sheet** (`AccountPlanConnectSheet`). Mark, "Connect
  {Plan}", "Open Atum on your Mac to connect.", Close. While it is open it
  follows the read every 3 s for up to 10 min. When any Mac reports the plan
  connected, it shows a check and "{Plan} is connected", announces it to
  VoiceOver, hands the read to the page and closes after 2.5 s. The
  intervals are the desktop's `ACCOUNT_CONNECT_POLL_MS`, `_WAIT_MS` and
  `_DONE_MS`.
  - **Deliberate difference:** a desktop without Work does not follow the
    read. The phone does, so the owner who goes to their Mac sees it land.
    It uses the exported `done(plan)` words and adds no new ones.
- **The picker** (`PhoneModelPickerList.planConnectSection`). In a cloud
  assistant's picker (the composer's sheet and the assistant card's cloud
  destination), each plan connected nowhere or signed out gets one row:
  mark, "Use your {Plan} plan", Connect. Connect opens the same sheet, which
  follows the picker's own subscription read. An unread registry offers
  nothing. The rows hide while a search or filter is active, and a Mac
  destination's picker never shows them.
- **Words.** Every word comes from the pin. The per-plan formatters are
  exported once per plan (`….plan=codex`) with a `choice` argument.
  `AtumCopy` now accepts a choice argument only for the value its key was
  exported for, and does not format it into the text. "ChatGPT", "Claude",
  "Antigravity" and "OpenCode Go" are product names, hard-coded on desktop
  too (`ACCOUNT_PLAN_NAMES`). No row shows money.
- **VoiceOver and Dynamic Type.** Each row reads as one element: name, line,
  then status. Each Connect is labelled "Connect {Plan}", so three Connect
  buttons are told apart. At accessibility sizes the action moves under the
  text. The sheet's title is a header. The marks are hidden from VoiceOver.

## Platform follow-ups

1. **Phone bearer on `account_connections_read`: verify live.** The Shell
   path is owner-only and non-browser (`matrix-authority.ts`
   device-services branch), and the phone already POSTs to this route for the
   phone registry. No production read was made from a phone in this lane.
   If the platform refuses it, the page shows its failed state, never a
   wrong "Not connected".
2. **Relay status for the phone's Atum chats.** The desktop's turn lines
   come from the Mac gate's room status and receipts. No owner-readable
   platform route serves them. The phone needs a per-room projection: open
   operation phase and hold, receipts by event, limits and scheduled usage.
   Until then the phone draws no relay line. `RelayTurnLine` maps the
   projection's states to the exported words once it exists.
3. **Claude and Antigravity plan models in the phone's picker.** The desktop
   lists them through the relay view and writes `work_selection_set`. The
   phone's picker reads plan models only from the 1.5 destinations
   (ChatGPT). A connected Claude or Antigravity plan therefore shows no rows
   on the phone yet. That needs the per-plan model list on a route the phone
   reads, plus the selection write.
4. **OpenCode Go key on the phone** (phone follow-up, not platform). The row
   shows the status. Connecting and managing the key stays on the desktop
   until a phone key sheet is ported.
5. **Decoder parity with the desktop's zod schema** (phone follow-up, from
   review r1). The phone counts a label's length in Unicode scalars; zod
   counts UTF-16 code units (`apps/desktop/shared/account-connections.ts`
   `label(max)`). The phone also refuses an integral JSON number written
   with a fraction, such as `observedAt: 1.0`; zod's `.int()` accepts it.
   So a device name made of astral characters near the bound, or a `1.0`,
   can parse on the desktop and not on the phone. The phone then shows the
   failed state, never a wrong row.

## Tests

- Package (`ios/Tests/AccountConnectionsTests.swift`):
  - the desktop's fixture decodes, and nine kinds of off-contract answer are
    refused whole;
  - the desktop's `view.test.ts` cases: rows, order, lines, the no-Mac rule,
    tools, hub names and the picker rule;
  - fresh-before-stale Mac order, needs attention, OpenCode Go;
  - every line, sheet and picker word in all five locales, with en/vi
    checked against desktop;
  - the choice-argument guard;
  - relay turn lines, usage and scheduled runs (en, vi and every locale);
  - the transport: exact POST body, path and bearer, no version header, and
    an unreadable 200 or a 503 refused.
- AppTests (`AccountConnectionsStateTests`): the picker offers Connect only
  after the registry answered; the sheet's timings; the drawn words come
  from the pin.
- UI (`AccountConnectionsUITests`, scripted `connections.mixed`,
  `connections.failed`, `connections.lands`; `AccountConnectionsPickerUITests`
  with `-AtumScriptedSubscriptions ready -AtumScriptedConnections plans`):
  - every row's words, with Connect only on the unconnected plan;
  - the sheet without the consent sentence, and Close;
  - the plan landing while the sheet is open (vi);
  - the failed read and Try again;
  - dark at AX5;
  - the picker's Connect rows and their sheet.

## Verification (2026-11-24)

Each run took the shared heavy-build lock
(`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`)
with `/Volumes/AtumTestFlight/dd-w4-e6/verify.sh`. DerivedData is
`/Volumes/AtumTestFlight/dd-w4-e6`, `-jobs 2`, one iPhone 17 simulator booted
inside the lock and `simctl shutdown all` on exit.

| Check | Result |
| --- | --- |
| `swift test -j 2 --filter 'AccountConnections\|AtumCopyTests\|SidePanelCopyTests\|NativeDomainClientTests\|PhoneRegistry'` | Exit 0, 140 tests, 0 failures (run 1) |
| Debug `build-for-testing` (AtumMobile, `CODE_SIGNING_ALLOWED=NO`) | Exit 0 (runs 1 and 2) |
| AppTests `AccountConnectionsStateTests`, `AccountSettingsStateTests`, `PhoneModelPickerCopyTests` | Exit 0, 36 tests (runs 1 and 2) |
| UI `AccountConnectionsUITests` (4) and `AccountConnectionsPickerUITests` (1) | Run 1: exit 65, all five failed on two test-side causes. The helper `row(app, id)` was shadowed by the base class's `row` (`row.` prefix). The sheet container's accessibility identifier overrode its children's. Both fixed. Run 2: exit 0, 5 passed |
| `tests/test_copy_keys_in_pin.py`, `tests/test_ios_project_sources.py` | OK |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | Exit 0 on its own |

Captures: `/Volumes/AtumTestFlight/dd-w4-e6/ui-scratch/ui-evidence/`
(`connections-rows-en-light.png`, `connections-sheet-en-light.png`,
`connections-sheet-done-vi-light.png`, `connections-rows-en-dark-ax5.png`,
`AccountConnectionsPickerUITests.picker-connect-en.png`).

## Review r1 fixes (r2, 2026-11-24)

Codex review r1 held the lane on one account-access finding and two
should-fixes.

1. **The connect sheet could start token rotation in the background
   (blocking). Fixed.** The sheet's follow-up reads are now polls that
   never rotate the grant.
   - `NativeDomainClient.accountConnections(.poll)` sends only a stored
     bearer that stays valid for 60 s
     (`OIDCGrantRefresh.storedAccessTokenWithoutRefresh`). It never
     refreshes an expired one, never replays a 401 and reports no
     authentication failure. When a refresh would be needed it fails
     without a request, and the next foreground read renews the token.
   - The sheet follows only while the scene is active
     (`.task(id: scenePhase == .active)`). Leaving the scene cancels the
     loop, and the 10-minute limit counts across pauses.
   - The poll is made once, when the sheet first follows, by
     `LiveAppModel.accountConnectionsPoller()`. It is bound to the client
     current at that moment and answers nothing once that session is
     replaced.
2. **The picker kept offering Connect after a plan landed. Fixed.** The
   sheet's registry now replaces the picker's
   (`PhoneModelPickerList.account(_:with:)`), keeping the subscription
   statuses already read. The poll is a dedicated registry read
   (`AssistantSubscriptionActions.makeConnectionsPoll`). It no longer
   repeats the relay and provider-connection reads.
3. **A late Settings refresh could undo a landing. Fixed.** Each
   `AccountConnectionsModel.reload` takes a generation. `landed` takes a
   new one, so an older read in flight is dropped when it finishes.
4. **Small fixes.**
   - At accessibility sizes the picker's Connect row stacks the button
     under the words, as Settings does.
   - The home hub's trailing "Not connected" is hidden from VoiceOver,
     since the row's label already says it.

Tests added:
- `AccountConnectionsTransportTests.testAPollNeverRefreshesOrReplaysA401`
  (package): a valid stored bearer sends one request; a 401 is final after
  one request; no stored bearer sends none; the grant is never asked and
  no failure is reported. The foreground read is the control and still
  refreshes once.
- `OIDCTests.testStoredTokenWithoutRefreshNeverSpends` (package).
- `AccountConnectionsStateTests` (AppTests):
  `testALateRefreshNeverUndoesALanding` and
  `testThePickerDropsConnectOnceThePlanLands`.

r2 verification ran under the shared lock with
`/Volumes/AtumTestFlight/dd-w4-e6/verify-r2.sh`. Per the slim lane rule, no
UI tests ran locally; the hosted PR shards run them.

| Check | Result |
| --- | --- |
| `swift test -j 2 --filter 'AccountConnections\|OIDCTests\|AtumCopyTests\|NativeDomainClientTests\|PhoneRegistry'` | Exit 0, 153 tests, 0 failures |
| Debug `build-for-testing` | Exit 0 |
| AppTests `AccountConnectionsStateTests`, `AccountSettingsStateTests`, `PhoneModelPickerCopyTests`, `ChatGPTTrainingGateTests` | Exit 0, 42 tests |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | Exit 0 on its own |
