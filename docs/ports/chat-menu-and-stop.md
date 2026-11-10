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

**Live wiring (2026-11-10):**

- `NativeDomainClient.cloudStop` adds exactly `/api/matrix/v1/cloud/stop` to
  the URL allowlist and sends POST through its existing MAS domain bearer
  transport. There is no second transport. It retains the native 4,096-byte
  write and 262,144-byte reply budgets, 15-second request / 30-second resource
  timeouts, no cookies/cache/URL credentials, redirect refusal, cancellation,
  closed native error envelope and single 401 refresh. Success is only a
  correlated 200 decoded by `CloudTurnStop.response`.
- `CloudAssistantTurnStop` is the tested bridge between the pure chat state
  machine and the native client. `AtumNativeAPI` depends on the SDK-free
  `AtumChat` core for the existing intent/result types; the chat core still has
  no SDK, SwiftUI, UIKit or native transport dependency.
- `AppRoot.chatHost` passes `LiveAppModel.assistantTurnStopActions(roomID:)`.
  It returns nil unless this is the currently open assistant chat, the Matrix
  session is ready, the roster is fresh, an active room-matched agent has a
  Matrix identity and explicitly says `answering: cloud`, and the domain client
  exists. Local, missing, malformed and unknown answering facts do not offer
  Stop. Typing, default-agent identity, model choice and a cloud-creation
  capability are never used to guess where the selected agent answers.
- Desktop source checked at `origin/atum-main` revision
  `ad7ce42dbf5230bb58c3c42829c019bb31ce9eae`:
  `apps/desktop/src/matrix/cloud-status.tsx:15` (`cloudRoomAgent`) requires the
  selected assistant's `answering === 'cloud'` and `macRole !== 'answering'`.
  `apps/desktop/src/matrix/app.tsx:3710` requires joined membership and the
  cloud bridge; its composer at `:4019` selects `stopCloud`, otherwise the
  running local turn uses `cancelHermes`. The phone has no Mac executor or
  `macRole`: its positive routing fact is the selected roster agent's
  `answering`, and `local` is never sent to the cloud stop route.
- The action rechecks client identity, account/session generation, open room
  and cloud routing before sending and after awaiting a reply. A replaced
  account/session or changed route cannot publish an old stop confirmation.
- Forbidden/not-admitted (native `matrix_403`), missing route (`matrix_404`)
  and unavailable/cloud-gate-off (`matrix_503`) resolve to the existing failed
  state and warning haptic. They also withdraw this agent's action until a
  successful product roster refresh, so a known unavailable route draws no
  Stop. The refusal cache is cleared on client replacement. There is no
  separate Stop-capability discovery endpoint in the current contract; the
  first refusal remains authoritative, never assumed to mean stopped.
- Transport loss, cancellation, malformed/noncorrelated replies and other
  failures also resolve to `.failed`. Retryable failures keep Stop and reuse
  the state machine's UUID. The composer already creates one lowercase UUID
  per turn; the live bridge forwards it unchanged, including a 401 retry.
  `stop_requested` stays stopping until the transcript ends the turn;
  `completed` claims nothing was stopped. No UI/layout or copy changes.

**Remaining platform/product limits:**

- No production call was made. Live admission of `/cloud/stop` for this account
  is unverified; the platform still controls the cloud gate and owner allowlist.
  Turns run by a Mac from its own records remain out of reach (contract rule 5).
- No exported key yet for a failed stop (desktop `cloud.stopRefused`,
  "Couldn't stop this reply. It may have already finished.") or for STYLE §11's
  working placeholder (desktop `copy.ts` `addToRequest`, "Add to your
  request…"). The existing warning haptic/failure state is retained. No new
  text was invented.

## Live Stop verification (2026-11-10)

The local Stop checkpoint was rebased onto merged PR #10 before final
verification. Purchase methods and tests were retained; the Stop transport diff
remains one new method and one exact allowlist entry.

Seven new native-client tests cover the exact POST/body/MAS bearer/no-cookie
request, identical request across the sole 401 refresh, request/reply byte
boundaries, strict replies and closed errors, cloud/local/unknown/missing route
policy, and the real live bridge driving the existing state machine through
stopped, stop_requested, completed and failure/idempotent retry. No simulator
was launched and no production endpoint was called.

Commands (serialized under the shared lock, each build/test capped):

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock timeout 900 swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-stop-swift
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock timeout 1500 xcodebuild build -jobs 2 -project ios/AtumMobile.xcodeproj -scheme AtumMobile -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -derivedDataPath /Volumes/AtumTestFlight/dd-stop -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm
PATH=$HOME/.local/bin:$PATH python3 scripts/public_guard.py --base $(git rev-parse origin/main) --head HEAD
```

- First Swift run: one new fixture error (missing nullable `matrixUser` key).
  Corrected the fixture to explicit null. The new transport and state-machine
  integration cases passed that run; final verification follows the correction.
- Final Swift run (after rebasing onto PR #10): exit 0; 1,193 tests, zero
  failures (626 native/design, 535 chat, 16 Drive and 16 telemetry). All seven
  new Stop tests pass.
- Xcode app build: exit 0; `** BUILD SUCCEEDED **` for the generic arm64
  iOS Simulator destination. No simulator boot or UI test execution.
- Public outbound guard: exit 0;
  `PASS: 1 new commits; raw paths/modes, ancestry, identifiers, secrets and metadata`.

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
