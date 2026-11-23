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

## Verification

- Package: `AssistantTurnStopTests` now covers every row above.
- UI: `TurnStopUITests` covers:
  - working → Stopping… → stopped;
  - stop_requested → Stopping… → settled after 15 s;
  - refused band → retry;
  - dark appearance;
  - AX XXXL text size;
  - no route, no Stop.
- `ask()` now taps the composer until it has keyboard focus. This fixes the
  #64 flake.
- The scheduled variant is covered by package tests only. No scripted cron
  scenario exists for UI.
