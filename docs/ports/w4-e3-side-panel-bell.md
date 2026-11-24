# W4-E3: the agent's desk in the side panel, and Home's bell

Wave 4 phone catch-up, UI lane W4-E3 (tracker atum-platform/atum-mobile#47).
Branch `feat/w4-e3-side-panel-bell` from `origin/main` `1f48fb1`. It was committed
locally only: no push, PR or CI.

Desktop sources (atum-desktop, read-only checkout on `main`):

- **#51** `feat/side-panel-cloud-r2-1113`, merge `1b28c3b1`: "Side panel for cloud
  agents: browser frame, Files, and agent controls (Pause, routines)".
  Files: `src/matrix/agent-desk.tsx`, `src/matrix/agent-desk-model.ts`,
  `shared/matrix-agent-desk.ts`, `shared/matrix-agent-desk-copy.ts`,
  `electron/matrix/device/host-desk.ts`, `host-agent-control.ts`, `src/matrix/workbench.tsx`.
- **#48** `feat/titlebar-bell-roster-plus-1113`, merge `8fb1bd36`: "Roster plus
  button, short Search, notification bell in the title bar". The plus and Search
  parts were already ported (`docs/ports/roster-plus-search-bell.md`). This lane
  ports the bell: `src/matrix/attention-indicator.tsx`, `attention-copy.ts`,
  `agent-attention.ts`.

Platform routes, read at atum-platform `origin/main` `8dc33727`:
`apps/shell/src/app/api/host/{desk,agent-control}/route.ts`,
`apps/shell/src/lib/host-desk.ts`, `host-owner-bearer.ts` and `middleware.ts:266-270`.
Both routes admit a native-domain owner bearer (`nativeDomainClients`) on the
API host, which is the phone's grant.

## What desktop renders, and what the phone does

### The agent's desk (#51)

On desktop, an agent's own 1:1 chat opens its side panel (the workbench) on a
pinned tab showing the agent's face and name. The tab holds Now, Files and
Controls in one reading column. "Watch" on the chat's working line brings that tab
to the front.

| Desktop element | Desktop source | Phone (native control) |
|---|---|---|
| Entry: side panel opens on the agent's tab | `workbench.tsx` `home = deskAgent ? 'agent' : 'launcher'` | In an assistant chat the panel sheet opens on the new `ChatPanelPolicy.Page.agentDesk`, pushed on the card's `NavigationStack`, at the **medium** detent so the chat stays in view. The system Back button goes to the agent's card. Title and "…" both open it, as before. `ChatPanelHost.init`, `ChatPanelPolicy.openingPage` |
| Tab title: face and name | `workbench.tsx` tabs `id: 'agent'` | Navigation title = the chat's title. The page's accessibility label is `desk` ("Luna's desk") |
| Now: hidden while free | `NowBlock` returns null for `free` | `AgentDeskNow` draws nothing for `.free` |
| Now: "Working · 4 min" head, steer/queue hint as tooltip | `NowBlock`, `useMinuteClock` (30 s) | Atom + caption via `TimelineView(.periodic(by: 30))`. The hint becomes the accessibility hint, never on-screen text. "Since" is the latest own message before the working footer (`AgentDeskPolicy.now`) |
| Now: the line clamped with Show more / Show less; the checklist | `Clamped`, `Steps` | `AgentDeskClamped` (three lines, More/Less) and a step list (check / hollow circle) parsed by the existing `WorkingLineText` |
| Files › sent in this chat: newest 4 of the agent's own file events, with size · time and Save | `matrixAgentDeskSentFiles`, `SentFileRow` | `AgentDeskPolicy.sentFiles` (own, not local echo, with media, file or image). Save downloads through the chat's own `ChatMediaAccess.file` and opens the system export sheet (`UIDocumentPickerViewController(forExporting:asCopy:)`) |
| Files › On its computer: one folder at a time, Back, listing only | `useOwnFiles`, `OwnFiles` | Same reads and rules. A refused home reads as none, and a subfolder keeps its last listing. Folder rows are buttons, Back is a row |
| Controls › Pause switch (tooltip "Still answers you…") | `Controls`, `useAgentSchedule` | `Toggle`, shown only when the host route exists and the schedule has routines; `pauseHint` is the accessibility hint |
| Controls › Notifications (this chat's mute) | `runMatrixCommand({kind:'mute'})` | `Toggle` over the panel's existing `setMuted` (the same Matrix push rule as the card) |
| Controls › More → Routines (switch each), All settings | `Routines`, `openAssistantCard` | Disclosure row (chevron rotates). Each routine row has a `Toggle` and its line (`Next: Fri 08:00` / `Paused` / nothing when switched off on its own switch). "All settings" pops to the card |
| Optimistic switches; 409 → "Its computer is off right now."; failure → "Couldn't change that."; 429 retried once after 10.5 s; a resume that changed 0 rolls back | `useAgentSchedule` | `HostAgentDesk.optimistic` / `resolve`, and `AgentDeskPage.run` |

Wire: `NativeDomainClient.hostDeskSchedule`, `hostDeskFiles` and `hostAgentControl`
send `POST https://api.atumplatform.com/api/host/{desk,agent-control}` with the
desktop's exact bodies (`{agent, read, path?}` / `{agent, action, job?}`) and the
`X-Atum-Host-Bridge-Contract: atum.s2.host-bridge/1.0.0` header. They reuse the
client's single 401 refresh (`performAuthorized`). Replies are decoded strictly
(`HostAgentDesk`, mirroring `shared/matrix-agent-desk.ts`). A files listing must
be the folder that was asked for. The two paths and the header are added to
the client's allowlists for those paths only. The host routes are offered only
for a roster agent with `runtime: "hermes"` (`AgentsResponse.Agent.runsOnHermes`,
new and lossy), as on desktop (`hostRuntimeAgents`).

### The bell (#48)

| Desktop element | Phone |
|---|---|
| Bell in the title bar, always there while signed in; amber/red dot while something needs you | `AttentionBell` in Home's header, between the search field and the plus (on the top row at accessibility sizes). It uses the Kit `Bell` glyph in the same 44 pt glass circle as the plus, with an 8 pt badge in the Kit `warn` colour |
| Label: "Notifications"; with items "Needs you: {item}" or "Needs you: {n} things need you" | Same spoken label, built from `a11yPrefix`, the item label and `count` |
| Popover: heading, rows (dot, label, chevron) acting from themselves; "Nothing needs you right now" | `.popover` with `.presentationCompactAdaptation(.popover)`: a real popover on iPhone too, not a sheet |
| A new item is announced once, politely | `AccessibilityNotification.Announcement` on a newly added item only |
| Items (`matrixAttentionItems`, desktop order) | `AttentionBellPolicy.items`. **Sign in again** (`sign_in`) while the native domain grant needs a new sign-in, which opens the existing reauthentication. **Out of Protons** (`protons`) on a fresh wallet read with nothing spendable, which opens the existing Proton top-up sheet. No balance or rate is shown |

The domain reauthentication card under the header stays.

## Adopt-before-build inventory

What the phone already had (reused, not rebuilt):

| Need | Existing piece |
|---|---|
| Side panel container, pages, detents, scope | `ChatPanelHost` (`ios/App/Chat/Views/ChatPanelHost.swift:12`), `ChatPanelPolicy` (`ios/Sources/AtumChat/ChatPanelPolicy.swift:9`) |
| Panel actions per chat | `ChatInfoActions` (`ios/App/Chat/Views/ChatInfoSheet.swift:171`), built in `AppRoot.chatHost` (`ios/App/AppRoot.swift:800`) |
| Chat mute | `ChatInfoActions.setMuted` → `LiveAppModel.setRoomMuted` |
| Working line text and steps | `WorkingLineText` (`ios/Sources/AtumChat/WorkingLineText.swift:8`), the projection's working footer (`Projection.swift:246`) |
| Downloading a chat file | `ChatMediaAccess.file` (`ios/App/Chat/Media/ChatMediaPresentation.swift:9`) |
| Authenticated native-domain transport, 401 refresh, URL/header allowlists | `NativeDomainClient.performAuthorized`, `isApprovedURL`, `perform` (`ios/Sources/AtumNativeAPI/NativeDomainClient.swift`) |
| Strict decoding helpers | `KeyedDecodingContainer.closed/value/nullable/integer`, `NativeAPI.decode` (`NativeAPI.swift`) |
| Roster agent for a room | `LiveAppModel.agentForRoom` (private; reached through the new seam) |
| Home header slots and glass button | `HomeScreen.header` and `createButton` (`ios/App/Home/HomeScreen.swift:703`), `LiveGlass` |
| Domain reauthentication | `HomePresentation.showsDomainReauthentication`, `HomeActions.reauthenticateDomain` |
| Proton top-up | `ProtonTopUpContext` and `protonTopUpSheet` (`ios/App/Store/ProtonTopUp.swift:11`) |
| Kit glyphs and colours | `AtumGlyph.bell/clock/folder/file/slidersHorizontal/settings`, `AtumKit.ColorRole.warn` |
| Copy | the pinned export: `shared.matrix-agent-desk-copy.*` and `src.matrix.attention-copy.*` are all present |

What native SwiftUI/UIKit supplies: `NavigationStack` page push and Back, sheet
detents, `Toggle`, `.popover` with `presentationCompactAdaptation`,
`TimelineView`, `ViewThatFits`, `UIDocumentPickerViewController` export, and
`AccessibilityNotification`.

Hand-rolled (the gap only): the `HostAgentDesk` wire types and rules, three client
methods, `AgentDeskPolicy` and `AttentionBellPolicy` (pure, in `AtumChat`), the
`AgentDeskPage` view, the `AttentionBell` view, `agentDeskActions(roomID:)` (a new
`LiveAppModel` extension file), and scripted fixtures.

**LiveAppModel seam.** It is one read-only method, `agentDeskContext(roomID:)`, in
`LiveAppModel.swift` next to `agentForRoom`. Swift `private` members cannot be read
from another file, so this was the smallest possible change there. It returns the
signed-in domain client and the room's roster agent. No turn-state code was
touched. Everything else lives in `ios/App/Chat/AgentDeskLive.swift`.

## Not ported (why)

- **Watch on the working line.** It needs `WorkingLineRow` and the turn rendering,
  which belong to the queued persona and turn lanes. The desk is still one tap away
  ("…"). This is a follow-up for that lane: open the panel with `.agentDesk`.
- **Stop on the desk.** The Stop lane owns Stop. With the desk at medium, the
  composer's own Stop stays in view under it.
- **The ask and On your device.** These read an open ask and Mac reach-down. The
  panel does not receive those signals, and they are not guessed. The phone is
  cloud-only, so it has no Devices section. (Waiting is ported in fix round r2: see
  below.)
- **The model row in Controls.** W4-E2 owns the model picker. The card ("All
  settings") still has it.
- **The address bar and the browser frame.** The phone has no in-app browser tabs.
- **Bell items the phone cannot know.** Mac-only items (disk, unlock, runtime update,
  sign in again on this Mac) have no phone meaning. Confirm new device,
  unverified device, new sign-in, "{name} needs you", "connect ChatGPT" and
  "Connect your Atum account" need sources the phone does not have yet: approval
  requests in the bell, per-agent readiness on `/agents`, and sign-in notices.

## Fix round r2 (review of `3529715`)

| Finding | Fix | Test |
|---|---|---|
| 1. Folder taps hit the Shell's 10 s `files` read admission (platform migration 0471): 429 collapsed to nil, stale rows under a new Back, and re-tapping never restarted | `HostAgentDesk.FilesOutcome` keeps `busy` apart (the client throws `HostAgentDesk.ReadBusy` on 429). `AgentDeskModel` (`ios/App/Chat/AgentDeskModel.swift`) asks a busy folder again after `readRetryDelay` (10.5 s) while it is still the folder asked for. The shown path changes only when its own listing arrives. Confirmed listings are cached for Back. A refused folder clears the request, so it can be tapped again | `AgentDeskBellTests.testAFolderOpenedInsideTheReadCooldownWaitsAndShowsOnlyWhenListed`, `testARefusedFolderCanBeOpenedAgain`, `NativeDomainClientTests.testHostDeskFilesNamesTheReadAdmissionBusy` |
| 2. Overlapping switches could erase a change, and Pause/Resume could arrive out of order | One control at a time, like `RoomMutationQueue` serializes a room field (`ios/App/Home/RoomMutationQueue.swift:8`): every schedule switch is disabled while one settles (`controlPending`). `HostAgentDesk.rollBack` undoes only what that control moved, and only while it still shows that value. An ambiguous failure (`.failed`) reads the host's schedule again | `AgentDeskBellTests.testControlsReachTheHostOneAtATimeAndUndoOnlyTheirOwnChange`, `HostAgentDeskTests.testARollBackUndoesOnlyWhatItsOwnControlMoved` |
| 3. The 10.5 s retry could still send after the desk closed or the account changed | `AgentDeskModel.disappear()` cancels the control task, including its sleep. `AgentDeskActions.fenced(by:)` checks the account, the client, the agent and `runsOnHermes` before every send and again on every reply | `AgentDeskBellTests.testTheDelayedRetryIsNeverSentAfterTheDeskCloses`, `testNoHostCallIsSentOnceTheAccountOrAgentChanged` |
| 4. Now lost live status | `AgentDeskPolicy.now(rows:exported:)` reads the footer's `progress` with the transcript's own status lookup (`WorkingLineRow.swift:18`). Phase `waiting` is desktop's Waiting (`waiting` copy, a still dot, its line, no checklist), never Working. A heartbeat drops its words, as on desktop. An all-marked Hermes checklist keeps every step (desktop `matrixProgressLineParts`). Each step's done state is the `isSelected` trait on its words | `AgentDeskPolicyTests.testNowReadsTheTranscriptsStatusAndSaysWaitingDuringAKnownWait`, `testAnAllMarkedChecklistKeepsEveryStep` |
| 5. A failed Save said nothing | The Shared Collections alert (`SharedCollectionsSection.swift:771`): `errorGeneric` with `dismiss`. The scripted desk has a second file whose first download fails. The export sheet writes a debug probe line when it opens | `AgentDeskBellUITests.checkSave` (en/vi × light/dark) |
| 6. Response limits | The desk reply is capped at `HostAgentDesk.maximumDeskBytes` (64 KiB) and the control reply at `maximumControlBytes` (4 KiB). Both are passed to `performAuthorized` | `NativeDomainClientTests.testHostDeskAndControlCapTheirRepliesAtTheContractLimits` |

Reviewer's wording for 4 was "suppress Now during a known wait". The phone instead
ports desktop's Waiting block, because desktop renders it and the `waiting` key is
in the pin. Working is still never shown during a wait.

## Fix round r3 (review of `fe4a17f`)

The schedule, file listing, and control POSTs recheck the desk's account, domain
client, agent, and Hermes runtime after authorization. The main-actor check and
URLSession task start happen synchronously, including on the retry after a 401.
A stale read keeps the current desk display. A stale control clears its optimistic
change without an alert or another schedule read.

The package regression tests switch the room's agent while initial authorization
and forced refresh are suspended. They assert that an initial stale Pause sends
zero requests and a stale Resume retry sends only the original request. Both desk
read routes are also tested with stale context.

The filtered `HostAgentDeskTests`, `NativeDomainClientTests`, and
`AgentDeskPolicyTests` passed all 122 tests. The Debug simulator
`build-for-testing` also passed under the shared lock.

## UI fix: All settings below the fold

On `9e33c18`, `AgentDeskBellUITests` failed at "All settings stayed on the
desk", both on hosted UI shard 0 and locally. This was a test bug, not a product
bug. The r2 Save check added a second sent file (`bao-cao.pdf`), which pushed
All settings below the bottom edge once More is open. XCTest's built-in
scroll-to-visible worked out the button's position after the scroll, then tapped
while the page was still moving. On iOS, a tap on a moving scroll view only stops
the scroll, so the button never fired. The screen recording shows the page
reaching All settings about 2 s after the tap. In r6 the button was already on
screen, so the test never had to scroll.

A person scrolls first and then taps, so the app needed no change. The test now
does the same: it swipes the desk up, waits until All settings is hittable and
stays in the same place on two reads in a row, and then taps it. The assertions
are unchanged.

Verified under the shared lock in run `bell68b` (logs and result bundle are
`/Volumes/AtumTestFlight/dd-w4-e3/{debug-build,ui-bell}-bell68b.*`). The Debug
`build-for-testing` succeeded. `AgentDeskBellUITests/testDeskAndBellInEnglishAndVietnameseLightAndDark`
passed: 1 test, 0 failures, 592 s, with All settings reached in en and vi,
light and dark. No package source or `ChatPanelHost` changed, so no `swift test`
or `ChatPanelUITests` rerun was needed.

## Copy

Every visible string comes from the pinned export through `design.text(key)`.
Nothing is hard-coded, the vendored export and `atum-design.lock` are unchanged,
and no key is pending any more (below). Keys used:
`shared.matrix-agent-desk-copy.matrixAgentDeskCopy.{desk, working, waiting, minutes,
steerHint, queueHint, files, sentHere, save, saveShort, more, less, onItsComputer,
back, controls, notifications, moreControls, routines, paused, nextRun,
allSettings, pause, pauseHint, controlFailed, computerOff}` and
`src.matrix.attention-copy.copies.{notifications, nothing, count, a11yPrefix,
items.sign_in, items.protons}`. `AgentDeskBellTests` checks each one in every
locale.

### Pending keys

None. `pauseHint` was pending (the accessibility hint on the Pause switch, en "Still answers you. Starts nothing on its own."). The wave 4c repin (#76, desktop `899cffde`) exported it, so `AgentDeskBellTests` failed as designed on the hosted AppTests job for `b5c70da`. The hint now reads the pin directly, and `pauseHint` is checked in every locale with the other desk keys. Locally: Debug build plus `AgentDeskBellTests` 8/8 (24 Nov, under the lock).

## Verification

Runs go through the shared heavy-build lock
(`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /Volumes/AtumTestFlight/w4-e3-verify.sh <round>`).
They use the one iPhone 17 simulator, `-jobs 2`, and DerivedData at
`/Volumes/AtumTestFlight/dd-w4-e3`. After the coordinator's update, later rounds
waited behind the W4-AB fix round (pid 28475) and were slimmed. A slim round runs
only the touched packages' swift tests, the Debug build, these AppTests, and only the
new UI test. Failures were rerun as the failing test alone.

| Check | Round | Result |
|---|---|---|
| `swift test -j 2` (all package targets, including the new `HostAgentDeskTests`, `AgentDeskPolicyTests` and the host-desk transport tests in `NativeDomainClientTests`) | r1 | 741 tests, 0 failures |
| Debug simulator `build-for-testing` | r1, r2, r4–r6 | succeeded |
| AppTests `AgentDeskBellTests` | r1 → r2 | r1 failed: `pauseHint` is not exported, and `LiveDesign.text` traps on a missing key, which also crashed the r1 UI run. After it was made pending, r2: 3/3 passed |
| UI `AgentDeskBellUITests` (desk and bell, en/vi × light/dark) | r3 → r6 | r3–r5 failures were test driving: a swipe on the app closed the sheet; container identifiers hid row identifiers (fixed in the view with `.accessibilityElement(children: .contain)`); a centre tap on the Pause row lands on its label. **r6: passed** (575 s) |
| UI regressions `ChatPanelUITests` (5 passed, 1 iPad skip), `HomeShellUITests/testHeaderShortSearchAndPlusAppearances` | r1 (before slimming) | passed |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | final | exit 0 |

The r2 UI step was cut off by the session's background time limit, which counted
its time queued on the lock. It was not a test failure.

Evidence:

- Screenshots: `/Volumes/AtumTestFlight/w4-e3-verify/r6/shots/w4-e3-{desk,desk-controls,bell-badge,bell-list,bell-empty}-{en,vi}-{light,dark}.png`
- Result bundles: `/Volumes/AtumTestFlight/w4-e3-verify/r6/ui.xcresult` and `/Volumes/AtumTestFlight/w4-e3-verify/r2/app-tests.xcresult` (logs for all rounds under `/Volumes/AtumTestFlight/w4-e3-verify/`)

Not verified live: no signed-in device run against production. The host routes'
acceptance of the phone's grant was read from platform source, not exercised.
Hosted CI will run the broad UI shards on the PR.

## Follow-ups

1. Watch on the working line, opening the panel on `.agentDesk` (persona/turn lane).
2. Stop on the desk (Stop lane).
3. ~~Repin for `pauseHint`, then drop `AgentDeskCopy.pendingKeys`.~~ Done (#76 repin; pending guard removed).
4. More bell sources: approvals, per-agent readiness on `/agents`, new sign-in.
5. A live check of the host desk routes with a signed-in Hermes agent.

## Merge with main `c49c6e0` (#70 training-off), 23 Nov

- `NativeDomainClient` conflicted in three places with #70's `isCurrent` dispatch guard. Both guards are kept: `perform` refuses unless the desk's `canSend` and #70's `isCurrent` both pass, on every dispatch including the 401 replay. The two desk paths stay in `isApprovedURL`.
- The desk and #70's ChatGPT training route send the same `X-Atum-Host-Bridge-Contract` header. The desk's header rule rejected it on every non-desk path, so the training confirmation was refused (`testChatGPTTrainingUsesTheDesktopShellRouteAndExactBody`, `testRetiredChatGPTSelectionIsNotSentAfterAuthorizationRefresh`). The desk rule now governs only the desk's two paths; the header on any other path still falls through and is refused unless its own rule admits it.
- Verified under the lock: full `swift test` 772/0; Debug build-for-testing exit 0.
