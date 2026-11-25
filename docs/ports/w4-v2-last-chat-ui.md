# W4-V2 · Chats reopens the last conversation (shell)

Desktop PR #121: Chat reopens the last conversation and never flashes an
empty state. W4-V1 (`docs/ports/w4-v1-last-chat.md`) added the restore
engine, `LiveAppModel.restorePersonalChat(for:intentID:hasExplicitRoute:stillCurrent:)`.
This lane calls it from the app shell. It also fixes client issue #101
(Store's Purchased survived a shelf link).

## What the person sees

| Moment | Before | After |
| --- | --- | --- |
| Launch or a new sign-in, with a restorable chat | Chats roster | The boot screen stays up until the restore decides, then the transcript appears with no push animation and no roster frame |
| Launch, nothing to restore | Chats roster | Chats roster, as soon as the inputs the policy reads have settled (at most 3 s behind the boot screen) |
| Tap Chats from another tab, Chats at its root | Chats roster | The last chat, else the primary assistant's chat. While the per-intent claim read runs, Chats' root shows the plain ground (at most 1 s). Then the transcript or the roster |
| Tap Chats while a chat is open in Chats | That chat | Unchanged (the retained chat reopens) |
| Re-tap Chats at its root | Scroll to top | Unchanged. A re-tap never restores, so the roster stays reachable |
| Back from a restored chat | n/a | The roster, the same as Back from a tapped chat |
| Notification or deep link at launch | Opens that room | Unchanged. It wins over any pending restore |

The lane adds no new copy. The launch hold reuses `S6BootWait`. The
Chats-tap hold is the `ground` token.

## Shell ownership

`Router` owns the restore intent and the navigation generation:

- `navigationGeneration` advances on every navigation Router performs:
  room, Team Space and app opens, root resets, cold staging, holding a
  notification, Store shelf and Purchased routes, every `select(tab:)`, Back
  via `popHomeToRoot`/`popTeamSpaceToRoot`, Account presentation and account
  scope resets. Each advance ends the pending intent (`claimNavigation`).
- `beginChatRestore(_:)` creates a `ChatRestoreIntent` with a new UUID under
  the current generation. `AppRoot` applies each account scope through
  `applyAccountScope(replacesAccount:)`, which begins `.launch` unless a
  notification already owns the route. It begins `.chatsTap` from
  `onUserSelectedTab(.home)` when Chats has no retained room.
- `applyAccountScope(replacesAccount:)` resets routes only when the new scope
  replaces a signed-in account (`AppRoot` tracks the applied scope's account,
  `LiveAppModel.accountScopeID`). The first account after none (a cold
  launch, a fresh sign-in) is initial setup: a notification tapped while
  booting stays held and is validated against the resumed account, and no
  launch restore starts. Before r2 the first scope's reset dropped that
  notification and the launch restore could open the remembered room.
- `receivePushIntent(roomID:)` claims navigation synchronously when the relay
  delivers. A restore retry queued before the shell's observer holds the
  room therefore cannot open the remembered room or clear its delivered
  notifications.
- `chatRestoreIsCurrent(_:)` is the `stillCurrent` closure. It requires the
  same intent and generation, Chats selected at its root, no presentation,
  no Account sheet and no held notification.
- `attemptChatRestore(hasExplicitRoute:_:)` calls the model with the
  intent's entry and ID. Every retry reuses that ID. It passes
  `hasExplicitRoute` as true for a held notification or deep link (and, from
  `AppRoot`, a ready onboarding room). A returned room ID is published to
  `homePath` in the same turn inside a no-animation transaction, and the
  intent ends.

`AppRoot` retries a pending intent when the roster snapshot, room
classification, the model's claim revision, the agent roster,
`personalChatRestoreIsWaiting`, Matrix readiness
(`personalChatRestoreMatrixReady`, initial sync included) or the Matrix room
publication (`personalChatRestoreRoomPublication`) changes. The last two
were added in r2: on a v1 account a remembered group's row can arrive before
initial sync while `/agents` is still loading, so neither the roster nor the
aggregate waiting flag changes when the room becomes eligible. That model flag is new in this lane.
It is true while the first room publication, the agent roster, workspace
classification or a claim read is still arriving. A `nil` attempt with
nothing still arriving ends the intent and shows the roster. A bounded hold
(`Router.chatRestoreHold`, 3 s for launch and 1 s for a Chats tap) also ends
it. A late restore therefore never replaces a roster the person is already
reading. On success the shell clears that room's delivered notifications,
as a tapped open does.

### Cold notifications behind the boot screen (fix round 3)

The r2 targeted review (Sol r2) closed r1's three findings and found two
blockers caused by carrying a cold notification through the first account
scope. While a cold notification is pending, `AppRoot` shows only
`S6BootWait` and the shell is unmounted, so nothing that ran inside the
shell could help validate it.

1. **Stranded boot screen.** An ordinary joined group starts `.unknown`, so
   validation stayed `.pending`. The task that registers rooms with the
   company workspace (`reconcileMatrixRooms`, which marks groups Personal
   once the directory is complete) lived inside the unmounted shell, and no
   timer covered the cold cover. The app stayed on the boot screen.
2. **Team Space check bypassed.** A two-person company DM is `.people` to
   the room list. Its conversation-type claim was registered by the same
   shell task, so before mount the room read `.unknown` and
   `RoomRootDestination.authoritative(.people, .unknown)` gave `.personal`.
   The transcript could open under Chats before its directory record
   arrived.

The r3 fix:

- The classification task (`RoomClassificationInput`: room IDs, type
  claims, classification revision) moved from `product(_:)` to `AppRoot`'s
  body, together with the classification-revision re-validation. It runs
  whenever an account is signed in, mounted or not. It is the same
  registration (`reconcileMatrixRooms`), not a second classifier.
- `validatePendingPush()` registers the current rooms and claims before
  it decides (`reconcileRoomClassification()`, idempotent). A notification
  that validates in the same turn as the room list arrives therefore never
  reads a company DM without its claim.
- `RoomPushDecision.decide(canOpen:destination:awaitsDirectory:)` holds a
  room that claims the conversation type while the directory that could
  vouch for it has not settled
  (`CompanyWorkspaceModel.awaitsConversationDirectory`: quarantined,
  classification incomplete, phase neither `.hidden` nor `.unavailable`).
  Once the record arrives the room is `.conversation` and routes to Team
  Space. A settled directory without the record denies it and the list
  shows. It never opens under Chats.
- The cold cover is bounded. `S6BootWait`'s cold branch runs a task that
  sleeps `Router.coldDeepLinkHold` (the launch restore's 3 s) and then calls
  `Router.releaseColdDeepLinkHold()`. A conclusive denial already cleared
  the cold flag. Either way the shell mounts at Chats' roster.

Decision (r3): on expiry the notification stays held as a foreground one
instead of being dropped. The mounted shell's normal validation then opens
it once it is conclusively allowed, the way a foreground notification
opens (animated push, no cold staging), or drops it on a denial. This is
the warm path's existing behaviour, so no new routing code was needed.
Releasing the hold does not advance the navigation generation: nothing
moved.

## #101: Purchased on `storePath`

Purchased was a `navigationDestination(isPresented:)` on a local Boolean.
`openStore(shelf:)` reset `storePath` but could leave Purchased showing.
`StoreScreen` now takes `onOpenPurchased`. The shell (and the scripted
host) passes `Router.openStorePurchased()`, which appends
`Router.StoreDestination.purchased` to `storePath`. A shelf link and a Store
re-tap both reset the path, Purchased included. Hosts without a Router path
(Settings' Store, the scripted commerce host) keep the local destination.

## Tests

New in `AtumMobileTests/S2StateTests` (shell route precedence, deferred from
W4-V1):

- `testChatRestoreNotificationBeatsPendingLaunchRestore`: a launch retry
  waits for a claim read; a notification arrives; the captured
  `stillCurrent` turns false; a later claim-revision retry does not call the
  model; the notification's room keeps ownership.
- `testChatRestorePassesHeldNotificationAsExplicitRoute`
- `testChatRestoreNewerNavigationBeatsLateRestore`: a manual open beats a
  pending Chats tap. A model reply that lands after a tab change is
  discarded.
- `testChatRestoreReusesIntentIDAndLandsLikeATappedChat`: retries share one
  ID; a success publishes one path entry; Back returns to the roster; a new
  tap gets a new ID; a stale `endChatRestore` leaves the newer intent alone.
- `testStoreShelfLinkLeavesPurchased` (#101).

Added in fix round 2:

- `testChatRestorePushReceiptClaimsNavigationBeforeHold`: precedence driven
  through `receivePushIntent`. The captured `stillCurrent` turns false at
  receipt, before `holdDeepLink`; a queued retry does not call the model.
- `testChatRestoreColdNotificationSurvivesInitialAccountScope`: a cold
  notification held (or only received) while booting survives the first
  account scope and validates; no launch restore starts. A real account
  change discards it and starts a restore.
- `testChatRestoreCoversYieldToTabSwitchRetapAndExpiry`: switching away
  during a Chats-tap hold ends it and the other tab is selected; returning
  makes a new intent; a re-tap at Chats' root never restores (scroll to top);
  a claim reply after the hold expires is discarded and the roster stays
  reachable. Back from a restored chat is covered by
  `testChatRestoreReusesIntentIDAndLandsLikeATappedChat`.

Added in fix round 3:

- `S2StateTests.testChatRestoreColdNotificationWithUnknownClassificationHoldsBoundedThenShowsTheList`:
  a cold group notification carried through the first scope stays pending
  while the directory is delayed. The hold equals the launch hold (at most
  3 s). Releasing it mounts the roster with nothing pushed, no restore and
  no navigation. The notification stays held, then routes the foreground
  way once the directory lands. A denial during the hold clears the cold
  flag at once.
- `ConversationTests.testAColdNotificationForACompanyTypedDMWaitsForTheDirectoryAndNeverOpensUnderChats`:
  without the claim a `.people` DM would read `.personal` (the failure
  mode). With the claim registered and the directory loading it is held,
  never denied and never under Chats, before and after the hold is
  released. When the directory lands it routes to Team Space (foreground)
  or stages there (still cold). A directory without the record denies it,
  and neither tab opens.

## Known limits and follow-ups

- r3: after the cold hold expires, a still-pending notification stays held
  and can open its room later, once validation is conclusive. A held
  notification also keeps `chatRestoreIsCurrent` false, so a Chats tap does
  not restore until it resolves. Both are the warm path's existing
  behaviour.
- r3: a type-claiming room is now held, not denied, while its directory is
  incomplete. That includes a conversation read that failed while the
  company list stayed `.ready`, which stays held until the next refresh.
  It fails closed (it never opens under Chats). For a cold launch it is
  bounded by the hold.
- r3, pre-existing and out of scope: on a v1 (`.hidden`) workspace an
  ordinary group never classifies (`classificationComplete` stays false),
  so its notification stays pending. Before r3 that stranded a cold launch.
  Now the hold bounds it and the roster shows. Only the restore engine
  treats `.hidden` + `.unknown` as Personal.
- r3: the cold-hold task and the moved classification task are `AppRoot`
  wiring with no XCTest, for the same reason as the other `AppRoot` covers.
  The Router and workspace seams they call are tested.

- The hold bounds are product judgment, not desktop values. Desktop has no
  full-screen roster to flash. A launch whose sync takes longer than 3 s
  shows the roster and does not restore.
- The Chats-tap hold exists because the engine re-reads the CoS claim for
  every new intent. A per-session claim cache in the engine would remove it.
- `AppRoot` wiring (retry signals, hold task, covers) has no XCTest. The
  live path needs a signed-in Matrix session. The scripted UI host does not
  use `AppRoot`, so a UI test of the live covers is not practical in this
  lane (r2 decision). The cover rules are exercised at the Router seam the
  shell reads (`coversChatsRootForRestore`, `chatRestoreIsCurrent`). A live
  manual pass remains: switch away and back during a Chats-tap hold, re-tap
  Chats at its root, a claim reply after the hold expires, Back from a
  restored chat.
- The Matrix readiness retry (r2 finding 3) has no unit test: the signals
  read a live `LiveMatrixSession`. It is a pure addition to the retry key.
- A cold notification that validation denies leaves the launch without a
  restore; the roster shows. Notifications always win, so this is accepted.

## Verification

- Debug `build-for-testing` for `AtumMobile` under the shared heavy-build
  lock exited 0 (`/Volumes/AtumTestFlight/w4-v2/r1-build.log`, derived data
  `/Volumes/AtumTestFlight/dd-w4-v2`). No new warnings in the touched files.
- 24 focused `AtumMobileTests/S2StateTests` methods passed, 0 failures
  (`r1-tests.log`, `r1-tests.xcresult`): the 16 W4-V1 restore methods, 3
  existing Router methods and the 5 new methods above.
- No Swift package source changed, so no `swift test` run applied. UI suites
  run on the hosted shards.
- `python3 scripts/design_lint.py` exited 0.
  `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0.

### Fix round 2 (review r1: HOLD)

- Debug `build-for-testing` under the heavy-build lock exited 0
  (`/Volumes/AtumTestFlight/w4-v2/r2-build.log`, derived data
  `/Volumes/AtumTestFlight/dd-w4-v2`, sim "Atum iPhone 16e"). No new
  warnings in the touched lines.
- The whole `AtumMobileTests/S2StateTests` class ran: 103 tests, 0 failures
  (`r2-tests.log`, `r2-tests.xcresult`). That includes the 3 new methods.
- No Swift package source changed, so no `swift test` run applied. UI
  suites run on the hosted shards.
- `python3 scripts/design_lint.py` exited 0.
  `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0.

### Fix round 3 (review Sol r2: two blockers)

- Debug `build-for-testing` under the heavy-build lock exited 0
  (`/Volumes/AtumTestFlight/w4-v2/r3-build.log`, derived data
  `/Volumes/AtumTestFlight/dd-w4-v2`, sim "Atum iPhone 16e"
  `CB24FAE2-75F9-4E19-A856-0F5A9F036C0B`). The touched lines add no new
  warnings. The `S2StateTests` actor-isolation warnings at 1611, 1632, 2063
  and 2105 were there before.
- `AtumMobileTests/S2StateTests` (104 tests) and
  `AtumMobileTests/ConversationTests` (38 tests) ran in full: 142 tests,
  0 failures (`r3-tests.log`, `r3-tests.xcresult`). That includes the 2 new
  methods.
- No Swift package source changed, so no `swift test` run applied. UI
  suites run on the hosted shards.
- `python3 scripts/design_lint.py` exited 0.
  `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0
  on the r3 commit.
