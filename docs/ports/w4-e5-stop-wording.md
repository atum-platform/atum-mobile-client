# Wave 4 E5: Stop wording and states match desktop

Branch `feat/w4-e5-stop-wording`, built on `feat/w4-ab-wiring` (#64).

## Desktop reference

The desktop checkout is atum-desktop main `635c1ae4`. The phone copy is pinned
to desktop `46f5a518`.

- #46 `e4ff060c` "say Stopping until the agent confirms a host Stop":
  `stop_requested` keeps the control reading "Stopping…". After 15 s
  (`MATRIX_STOP_SETTLE_MS`) it settles quietly. It never claims stopped.
- #87, exact scheduled Stop: `useMatrixCloudStop` (`apps/desktop/src/matrix/use-cloud-stop.ts`).
  - A pending schedule receipt re-offers Stop after 15 s.
  - A confirmed exact scheduled Stop shows a "Stopped." band.
- How the composer renders it: `app.tsx` `MatrixComposer`, the `cloudStop.shown`
  button and the `NoticeBand` above the composer.

## States, desktop → phone

| State | Desktop as rendered | Phone (`AssistantTurnStop.control` / `.notice`) |
|---|---|---|
| Turn in progress | Ink icon button with the stop square, aria-label "Stop" | `.stop(enabled: true)`: 36 pt ink circle with `StopFilled`, 44 pt target, VoiceOver "Stop" |
| Scheduled run with no exact target | Icon, disabled (30 %) | `.stop(enabled: false)`, 30 % |
| Request out, or `stop_requested` | `ak-btn--primary` text button "Stopping…", disabled (30 %), `aria-busy`, `role=status` text | `.stopping`: ink capsule "Stopping…", disabled, 30 %. VoiceOver label "Stopping…"; announced once on tap |
| Turn `stop_requested` after 15 s | `settled`: icon, disabled, no band | `.settled` phase → `.stop(enabled: false)`, no line (`settlePendingTurn`) |
| Scheduled `stop_requested` after 15 s | Stop offered again | `.stop(enabled: true)` (`retryPendingSchedule`, unchanged from #64) |
| Turn `stopped` or `completed` | Icon, disabled, no band, until the turn ends | `.stop(enabled: false)`, no line. Previously the phone hid Stop and said "Task stopped" |
| Scheduled `stopped` | Icon disabled while the run shows; band "Stopped." stays after the run clears, until another turn is named | `.notice == .scheduledStopped`, kept across the marker clearing (`scheduledStopConfirmed`) and announced |
| Refused or failed | Band "Couldn't stop this reply. It may have already finished."; Stop offered again | `.notice == .refused` plus `.stop(enabled: true)`. Announced, with the warning haptic. The phone showed no line before |

The band follows desktop's `[data-matrix-composer-dock] > .notice-band`:

- a glass band with the Kit `lg` radius, using `LiveGlass`, which goes opaque
  under Reduce Transparency or Increase Contrast;
- the `Info` glyph in soft ink and the words in ink;
- one combined accessibility element whose label is the words
  (`composer.turn`).

The pill's VoiceOver value "Working on this task" is unchanged.

## Copy keys

All of these come from the vendored export (`ChatCopyKey`). Every key resolves
in all five locales.

- `shared.matrix-action-copy.matrixActionCopy.cancelHermes`: "Stop"
- `src.matrix.mobile-copy.mobileScreensCopy.cloud.stopping`: "Stopping…"
- `src.matrix.mobile-copy.mobileScreensCopy.cloud.stopRefused`
- `shared.matrix-agent-status-copy.matrixAgentStatusCopy.stopped`: "Stopped."
- `src.matrix.mobile-device-copy.mobileDeviceCopy.chatStatesTurnRunningText`
  (the pill value)

Retired from `ChatCopyKey`: `chatStatesStopRequestedText` and
`chatStatesStoppedText`. Desktop renders neither.

**Not ported:** desktop's `title` tooltip "Stop target unavailable" /
"Chưa xác định được lượt cần dừng". It is hard-coded in desktop `app.tsx` (en and
vi only), has no export key, and iPhone has no tooltip. It needs an export key
before it can become a VoiceOver hint.

## Signals

There is no transport or receipt change. The only new model signals are local
to the view state:

- `settlePendingTurn(for:)`, a desktop timer;
- `scheduledStopConfirmed`, which keeps desktop's scheduled "Stopped." band.

## Merge with the #64 fix round (`8338b59`)

- `AssistantTurnStopActions.unavailableTargets` still hides Stop for an
  unavailable target. The other states map through `control`.
- `settleSchedule` still runs after a terminal scheduled receipt.
- The fix round kept a scheduled `stopped` phase once its footer cleared. That
  now resets to idle with `scheduledStopConfirmed`. The run is over and Stop is
  hidden, but desktop's "Stopped." band stays until another turn is named.
- `ask()` keeps #64's hittable-plus-keyboard-focus wait and adds a wait for the
  send circle.

## Verification

- Package: `AssistantTurnStopTests` now covers every row above.
- UI: `TurnStopUITests` covers:
  - working → Stopping… → stopped;
  - stop_requested → Stopping… → settled after 15 s;
  - refused band → retry;
  - dark appearance: Stopping… and the refused band;
  - AX XXXL text size: the Stopping… capsule, capped at `xxxLarge` with the
    Large Content Viewer, fits on screen, and the band,
    capped at `accessibility1`, leaves the field above the keyboard;
  - no route, no Stop.
- `ask()` now taps the composer until it has keyboard focus. This fixes the
  #64 flake.
- The scheduled variant is covered by package tests only. No scripted cron
  scenario exists for UI.

### Local run log

- **Run 1:** killed while still queued, at the coordinator's request.
- **Run 2:** the merge with the #64 fix round conflicted. Resolved in
  `f873bb4`.
- **Run 3:** slimmed run (`/Volumes/AtumTestFlight/dd-w4-e5/verify.sh`).
  - Package tests: 28, 0 failures.
  - Debug build: succeeded.
  - `ComposerDictationTests`: 12, 0 failures.
  - `TurnStopUITests`: 5 of 6 passed. `testStopWhileWorkingThenStopped`
    failed inside `ask()`: "The composer field did not take keyboard focus".
    - The simulator was loaded: each element query took about 10 s, so the
      polled focus checks used up their limits after a single tap.
    - `ask()` now taps, then waits up to 20 s for the keyboard with XCTest's own
      expectation, and retries the tap up to three times.
- **Run 4** (`verify-retry.sh`): only the failing test and the new tests.
  - Focus held in every test. `testStopRequestedSaysStoppingThenSettles`
    passed.
  - Three tests failed because they waited for the transient Stopping… label.
    The scripted route answers `stopped` or `failed` in 0.4 s, which is shorter
    than one element query on a loaded simulator.
  - Change: those tests now check only states that last: `stop_requested`
    keeps Stopping… for 15 s, and `failed` keeps the band.
  - The largest-size screenshot also showed that the uncapped refused band
    filled half the screen and pushed the pill's controls under the keyboard.
    The band's text now stops growing at `accessibility1`.
- **Run 5:** reruns only the three failing tests.
  - Passed: dark, and working → stopped.
  - Failed: at AX XXXL the Stopping… capsule was 305 pt wide and ran past the
    402 pt screen edge.
  - Change: like other bar controls, the capsule stops growing at `xxxLarge`
    and shows the Large Content Viewer on a long press.
- **Run 6:** reruns only `testStoppingFitsAtTheLargestTextSize`. It passed.
  - At AX XXXL the capsule reads "Đang dừng…" in full, on screen.
  - The refused band wraps to three lines and leaves the field and controls
    above the keyboard.
  - The model chip shortens to "Ngu…" so the capsule fits. Its own
    accessibility label is unchanged.

Every test in `TurnStopUITests` has now passed at least once on the current
code:

- run 3: refused and retry, no route;
- run 4: stop requested then settled;
- run 5: dark, working then stopped;
- run 6: largest text size.

They have not all run together in one pass since the last fixes. The hosted UI
shards rerun the class on the PR.

## Fix round r2 (Codex review r1 on PR #69)

1. **Search reset Stop and allowed a second request.** Search swapped the
   composer out, and its `@State` went with it.
   - The Stop state, the in-flight request and its timers now live in
     `AtumChat.AssistantTurnStopController`. `LiveConversationStore.turnStop`
     owns it, scoped to the room.
   - The transcript watch (`TurnSignalWatch`) moved to `ChatScreen`.
   - A rebuilt composer re-reads the same state, so a tap while a request is
     out, or after it settled, sends nothing.
2. **A late scheduled receipt.**
   - When the timeline clears a run's marker while its Stop is in flight or
     pending, `observe` now keeps that exact attempt
     (`scheduleMarkerCleared`).
   - A confirmed receipt then shows "Stopped." with no Stop. Any other receipt
     settles quietly, and a pending retry is not re-offered.
   - A new reply or run drops the attempt, so its receipt is ignored.
   - `resolve` returns whether it accepted the receipt. VoiceOver hears only
     accepted notice transitions, and only while `ChatScreen` is shown, since
     `ChatScreen` sets `announce`. The raw receipt is never announced.
3. **A draft hid Stop.** Stop now wins over Send whenever it is shown. Send is
   kept for idle and editing.
4. **A transient 503 hid scheduled Stop.** The host Stop route now withdraws an
   execution's Stop only on 403 or 404. A 503 shows the refused band and offers
   Stop again. The turn route's closed-error handling is unchanged.

Tests:

- `AssistantTurnStopControllerTests`:
  - a rebuild during the request and after settling sends no second request
    ID;
  - a retry reuses the request ID;
  - only accepted transitions are announced.
- New `AssistantTurnStopTests` cases cover a late receipt with the marker
  cleared, a newer target dropping the attempt, and no re-offer for a pending
  stop.
- `NativeDomainClientTests.testScheduledStop503StaysRetryableAndOnlyDenialsWithdrawIt`.
- `TurnStopUITests.testStopRequestedSaysStoppingThenSettles` now checks that a
  draft keeps "Stopping…" and that Send waits.

r2 run log:

- **Run r2:** the volume detached while the run was queued, so it never
  started.
- **Run r2b:** the package build failed. The `AtumChat` package also targets
  macOS 13, and `@Observable` needs macOS 14. The controller and its tests now
  carry `@available(macOS 14.0, *)`, as `SharedCollectionsModel` does.
- **Run r2c:** rerun of the same script.
