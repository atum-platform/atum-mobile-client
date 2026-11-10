# Chat: message actions overlay and the composer's working state

Two high-severity findings of the phone design review (A1 message actions, C1
composer Stop), fixed against the Atum style bible (`packages/atum-kit/STYLE.md`
§10–§11) and the desktop chat.

## A1: the long-press overlay

The overlay ghosted (the pressed bubble stayed visible under its lifted copy, so
the text showed twice), its reaction capsule covered the bubble above, and the
26% light scrim did not separate the layers.

- **Decision:** keep the custom overlay. The system `contextMenu(menuItems:preview:)`
  was weighed first: its preview is not interactive, so it cannot carry the
  reaction capsule, and SwiftUI has no reaction-accessory API.
- **The pressed row is hidden** while its menu is open (`opacity(0)` and
  `accessibilityHidden`, keyed by the request's item ID), as the system menu
  does. Only the lifted copy shows.
- **Material dim:** `.regularMaterial` with the Kit `scrim` over it. It works in
  light and dark, and turns opaque under Reduce Transparency.
- **Placement** is a pure rule, `AtumChat.MessageMenuLayout`, with unit tests:
  - the copy stays where it was pressed;
  - the capsule and the menu sit on opposite sides of it (capsule above, menu
    below), and they flip for a message low on the screen;
  - when neither fits, the stack moves only as far as it must to stay in the
    safe area;
  - a copy taller than the remaining room is cut inside its bubble.
  Nothing overlaps or leaves the screen at any position (exhaustive test).
- Reactions are 44 pt targets. The emoji and menu width scale with Dynamic Type
  (`@ScaledMetric`, capped so six reactions stay on one line). Menu glyphs use
  the body text style.
- Unchanged: every action and its behaviour (react, reply, copy, select text,
  edit, delete with confirmation), the VoiceOver actions, the UI-test labels, and
  the B13 read rule (`MessageActionsPresenter.covers` includes the overlay, so
  `bottomVisible` stays false). Reduce Motion keeps the linear fade with no
  scale. New identifiers for tests: `menu.reactions`, `menu.preview`,
  `menu.items`, `menu.backdrop`.

## C1: working state and Stop

**Authority.** This is the same route the desktop uses for a cloud turn
(atum-app `apps/desktop/src/matrix/app.tsx` `stopCloud`,
`electron/matrix/device/cloud-stop.ts`):

- The route is `POST /api/matrix/v1/cloud/stop` with
  `{requestId, agentPrincipal, target: {kind: "turn", roomId, eventId}}`
  (`atum.cloud-execution/1` §3.5, `atum.agent-turns/1` rule 5).
- It is idempotent on `(owner, requestId)`.
- It answers `stopped`, `stop_requested` or `completed`.
- On the platform it sits behind the cloud gate (`ATUM_MATRIX_CLOUD_ENABLED` and
  the owner allowlist) and reaches only cloud-answering agents. The desktop's
  other Stop, `cancelHermes`, is a local IPC to the Mac that runs the turn, and a
  phone cannot use it.

**Built here:**

- `AtumChat.AssistantTurnSignal`: which turn is in progress. It is the desktop's
  `matrixCloudStopTarget` fallback: my newest top-level sent question with no
  agent reply or status line naming it, while the agent types or shows a live
  `io.atum.progress` line. Interim remarks and working lines never end a turn.
  An uncorrelated agent message hides Stop, which is the safe direction.
- `AtumChat.AssistantTurnStop`: the state machine, with unit tests.
  - It goes `working → stopping → stopped`.
  - `stop_requested` stays "stopping" until the room ends the turn, and is never
    shown as stopped.
  - `completed` becomes `finishing`: no Stop and no claim.
  - A failure returns to Stop with the same `requestId`, so a retry is
    idempotent.
  - A second tap while a request is out sends nothing.
  - It latches on the question, so Stop survives typing lapsing.
  - A late reply for an earlier turn is ignored.
- `AtumNativeAPI.CloudTurnStop`: the exact request body, and a strict reply check
  (it must echo the agent and the target, refuses executor fields and accepts
  only the three states). Tested with the cloud-execution pack's synthetic values.
- In the composer:
  - VoiceOver reads the pill as "Working on this task" while a turn is in
    progress.
  - In a host that supplies `AssistantTurnStopActions` (`ChatInfoActions.assistantTurnStop`),
    the empty send circle becomes Stop: the same 36 pt ink circle with the
    `StopFilled` glyph, a 44 pt target, and no change to the row's height.
  - It then shows "Stop requested. Waiting for confirmation." or "Task stopped".
  - A light haptic plays on Stop and a warning haptic on failure.
  - With a draft, send shows instead, so the person can add to the request.
  - Only assistant chats get the action.
- The scripted host supplies a fake route only with `-AtumScriptedTurnStop
  <stopped|stop_requested|completed|failed|failed-then-stopped>`. The scenario is
  `chat.turn-stop` (Atum keeps working and never answers).

**Not live yet: no host supplies the action, so live builds draw no Stop.** What
is missing:

1. `NativeDomainClient` has no call for `/cloud/stop`. Its URL allowlist
   (`isApprovedURL`) refuses the path, and its transport is private. Adding a
   second bearer-carrying transport outside the reviewed client was rejected.
   The owner of that file adds `cloudStop(_ request: CloudTurnStop.Request)`,
   which allows exactly that path for POST, decodes with
   `CloudTurnStop.response(_:for:)`, and maps any throw to `.failed`.
2. `AppRoot.chatHost` builds `ChatInfoActions`. It passes
   `assistantTurnStop: model.assistantTurnStopActions(roomID:)`, which
   `LiveAppModel` returns only when the room's agent has `answering == .cloud`.
   It uses `agent.principal`, the room ID and a fresh lowercase UUID per turn,
   and the state machine keeps that UUID for retries.
3. Copy: no exported key yet for a failed stop (desktop `cloud.stopRefused`,
   "Couldn't stop this reply. It may have already finished.") or for STYLE §11's
   working placeholder (desktop `copy.ts` `addToRequest`, "Add to your
   request…"). Until they ship, a failure is the warning haptic and Stop coming
   back, and the placeholder is unchanged.
4. Platform reach: Stop only works for owners inside the cloud gate. M1 turns run
   by a Mac from its own records are out of reach (contract rule 5). Owner
   decision O4 is still open.

## Verification (2026-11-10, local, under the shared build lock)

- `swift test --package-path ios -j 2`: 526 tests, 0 failures, 25 of them new
  (turn signal, stop machine, menu layout, `/cloud/stop` shapes).
- Public client checks: design import verify plus 8 importer tests, push
  fixtures plus 2 projection tests, and `plutil -lint` of the project all
  pass. The npm Megolm check was not run; this change does not touch it.
- App `xcodebuild build-for-testing` (iPhone simulator): succeeded.
- UI, light mode, iPhone 18 Pro, scripted:
  - Passed: `testAnswerMenuInMyAssistantChatAndSelectText`,
    `testPeopleChatMenuAndEdit`, `testReactionsToggleFromThePaletteAndTheChips`
    and all four `TurnStopUITests` (stopped; stop requested; failure, then a
    retry with the same request ID; no route means no Stop).
  - `testTheLiftedMessageShowsOnceAndNothingCoversIt`: the text-once,
    on-screen and no-overlap checks passed. Its close tap at the top of the
    screen failed, because the capsule now sits there. The test now closes at
    the left edge; that fix has not been re-run.
  - Not run: dark mode, and `testGroupChatMenu`, whose close tap was moved
    off the capsule the same way.
- Captures showed the lifted bubble growing to its height cap (empty space
  under short text). Fixed by capping inside `HugWidth`; that fix is built but
  not re-captured.
- `xcodebuild test-without-building` twice failed to exit after its tests
  finished: about 21 minutes idle, then `timeout 900` (exit 124), with a
  partial result bundle. It is not tied to a particular test.
