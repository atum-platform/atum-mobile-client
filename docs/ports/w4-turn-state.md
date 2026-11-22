# Wave 4 chat turn state

## Adopt before build

Desktop source is atum-desktop main `eb808c46`.

| Item | Desktop native path | Existing phone equivalent |
| --- | --- | --- |
| #75 Native interims | `plugins/platforms/matrix/presentation.py:649` forwards the native send. `plugins/platforms/matrix/adapter.py:1481,3493` builds the text and reply/thread relations. `tests/plugins/matrix_presentation/test_presentation.py:51` checks immediate delivery and survival. | `AtumTurnMarkers.parse`, `ChatItem.interim` and `threadRoot`, `TransientLines.visibleItems`, `AssistantTurnSignal.read`, and `Delivery.noAnswerItemID`. |
| #63 Status codes | `apps/desktop/shared/matrix-progress-marker.ts:124,154` validates descriptors; `apps/desktop/shared/matrix-status-line-copy.ts:54,91,101,135` renders the header and checklist. | `AtumTurnMarkers.parse` already reads the enclosing progress marker. `ChatProgress` carries the phase. `Projection.rows` and the app's `WorkingLineRow` already carry and display the working footer. `PhoneApprovalPendingCopy` and its app lookup show the pending-copy pattern. |
| #22 Company status | `apps/desktop/src/matrix/message.ts:80,231,533` validates and maps company events. `apps/desktop/shared/matrix-company-presentation.ts:242,335,460` parses and admits company presentation. `apps/desktop/src/matrix/app.tsx:4592,5406` selects the footer for the channel thread and private CoS room. `apps/desktop/shared/matrix-transient-lines.ts:186` governs cleanup at this pin. | `RoomContext` distinguishes CoS and carries the selected agent, `TransientLines` hides ephemeral rows, and `TimelineProjector` recomputes the working footer. |
| #87 and #46 Stop | `apps/desktop/src/matrix/cloud-stop.ts:64,106` selects the bound agent's exact schedule, `apps/desktop/src/matrix/use-cloud-stop.ts:117` gives it priority, and `apps/desktop/electron/matrix/device/host-stop.ts:8` checks the Shell receipt. Platform #909 defines `POST /api/host/stop`. | `AssistantTurnSignal` and `AssistantTurnStop` select and latch an intent. `CloudAssistantTurnStop` and `CloudTurnStop` map receipts. `NativeDomainClient` already supplies bounded authenticated transport and refresh. |

## Findings and changes

### #75 Native interim messages

Desktop forwards the internal `_interim_send` call to the Matrix adapter immediately. The adapter emits a normal `m.text`, with an explicit `m.thread` relation and reply fallback when the caller supplied `thread_id`. The live phone SDK timeline includes threaded events. Before this port, a native threaded interim could clear both the room-level footer and Stop latch by replying to the room question, even though the phone rightly excluded threaded owner messages from Stop candidates.

The phone now scopes legacy progress clearing by sender and thread and reads the Stop and no-answer signals from room-level messages. The threaded interim is displayed immediately and stays beside the final even when the two contain the same text. `AssistantTurnSignalTests.testDesktop75NativeThreadInterimSurvivesFinalWithoutEndingTheRoomTurn` exercises the wire shape, working footer, latch input and final transcript.

An unmarked top-level interim and a top-level final can both be `m.text` with the same reply relation. Desktop's `no-reply-banner.tsx:62` also relies on the interim marker to tell them apart. The shape test records that ambiguity. A publisher-side marker on native top-level interim sends is required to fix their early settlement without delaying genuine final answers.

### #63 Structured status

`AtumTurnMarkers` checks the descriptor's version, code, phase, kind and exact argument shape. `ChatProgress` carries the typed state through the existing synthetic footer. `WorkingLineText(body:presentation:exported:)` uses the export lookup first and retains the publisher's checklist rows. A missing or invalid descriptor uses the existing body. The cases cover tool activity, heartbeat and approval wait from #63, plus the pinned desktop's additive video-consent wait.

The current export lacks these keys. The pending table has the desktop English wording for each.

- `shared.matrix-status-line-copy.matrixToolActivityCopy.web`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.read`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.write`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.run`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.delegate`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.look`
- `shared.matrix-status-line-copy.matrixToolActivityCopy.draw`
- `shared.matrix-status-line-copy.matrixProgressCopy.heartbeat`
- `shared.matrix-status-line-copy.matrixApprovalWaitCopy`
- `shared.matrix-status-line-copy.matrixVideoConsentWaitCopy`

`AtumTurnMarkersTests` checks the descriptor allowlist, argument types and bounds, and the export-first rendering path.

### #22 Company progress

`CompanyTurnMarker` checks the closed 1.6 scope, audience, identity, revision and exact non-fallback thread relation. The projector admits those facts only from the agent in the supplied room binding. Channel progress goes in the selected thread footer and private CoS progress goes in its bound room. An unbound or mismatched marker remains an ordinary message. Interim remarks stay in the transcript.

The current desktop pin fences the full identity on a settled marker or a seen line's redaction. An unrelated agent answer leaves that identity active. The phone projector remembers settled turns and accepted revisions for the open timeline, and reuses the existing projection wake time for the 540-second presentation expiry. `CompanyTurnProjectionTests` covers channel and private CoS, rejected markers, edit identity, settlement and expiry. Desktop keeps terminal memory across room visits and can choose among all replacement events. The phone retains memory for the current projector and can validate the original and latest edit exposed by the SDK.

### #87 and #46 Scheduled Stop

The selected cloud agent's live, confirmed cron progress carries the exact job and execution IDs. A live cron line missing the tuple keeps Stop visible but disabled and suppresses fallback to a room question. An edited line keeps the tuple only when it agrees with the original. Progress for one execution survives a different execution's answer.

The existing Stop callback submits `{agent,requestId,source:{kind:"schedule",job,execution}}` through authenticated Shell transport. The stable UUIDv8 matches desktop and repeats across room reopening and bearer refresh. Execution identity preserves the exact identifier bytes. The server verifies the owned Hermes runtime and the exact execution. A correlated `interrupted` receipt requires both flags. `finished` finishes without a Stop claim. `pending` and `unknown` keep the pending phase. Refusal or transport failure uses the existing retryable failure phase and leaves the manual Stop route available. Turn-only readers continue to receive the original event ID as a string, including the scripted composer probe. The phone roster DTO does not expose the desktop's runtime field, so the current entry point relies on Shell's runtime check.

`AtumTurnMarkersTests`, `AssistantTurnSignalTests` and `AssistantTurnStopTests` cover the selection, stale edits and receipts, retries, and pending state. `CloudTurnStopTests` and `NativeDomainClientTests` cover exact JSON, request IDs, receipt flags, the Shell route and bearer refresh using synthetic responses.

## App integration hooks

- In `ItemMapper`, pass `originalJSON: event.lazyProvider.debugInfo().originalJson` to `AtumTurnMarkers.parse` and apply the complete value with `markers.apply(to: &item)`. The existing sender filter reads `context.transientAgentUserIDs`, which now includes the proven company agent when a binding is installed.
- In company room classification, assign `context.companyTurnScope = .privateCos(binding: verifiedBinding)` for a ready CoS pair or `context.companyTurnScope = .channel(threadRoot: nil, binding: nil)` for a channel timeline. The thread's store construction supplies `.channel(threadRoot: rootID, binding: verifiedBinding)` in its copied room context. Supply only a fresh company-agent read and joined membership for channels, and the ready pair bound to the current joined room and members for CoS. The existing phone workspace exposes the ready private pair and channel directory. The desktop's fresh company-agent status read still needs an app integration for channel bindings.
- In the existing footer, call `WorkingLineText(body: row.item.body, presentation: row.item.progress?.presentation, exported: lookup)` using the existing `AtumCopy` lookup and a numeric argument for heartbeat. Select `WorkingLineRow` for a present descriptor even when the agent body is empty.
- The existing composer dispatches exact schedule intents through its standard Stop callback. To re-offer Stop on desktop's pending timeout, call `turn.stop.retryPendingSchedule(for: intent)` after `AssistantTurnStop.scheduledRetryDelay` on a pending schedule result. The method checks the current selection and request before changing it.

Live company binding, localized footer rendering and pending timeout are app integration points. The package tests use synthetic bindings and receipts.

## Verification

The batch held `/Volumes/AtumTestFlight/.heavy-build.lock`, used two jobs, and kept Swift scratch and Xcode derived data under `/Volumes/AtumTestFlight/dd-w4-turn-state`. Xcode used package clones in `/Volumes/AtumTestFlight/spm`.

- Baseline `b9cab0d` reproduced the #75 regression with two assertions in one test. The footer vanished and `AssistantTurnSignal` reported idle while the room-level turn was working. See `/Volumes/AtumTestFlight/tmp/w4-turn-state/native-interim-baseline.log`.
- The port passed 1,704 package tests. AtumChat ran 747, AtumDesign and Native API ran 894, AtumDrive ran 47, and AtumTelemetry ran 16. See `/Volumes/AtumTestFlight/tmp/w4-turn-state/swift-test.log`.
