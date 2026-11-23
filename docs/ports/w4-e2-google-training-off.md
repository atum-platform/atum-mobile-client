# W4-E2: ChatGPT with Google data, the training-off confirmation

Wave 4 phone catch-up, UI lane W4-E2 (tracker atum-platform/atum-mobile#47).
Base: `feat/w4-copy-repin` (PR #63). It pins the wave 4 export at atum-desktop
`46f5a518`.

## What the desktop does

Desktop PR #62 (`54fcb7a6`, merged 2026-11-16) added a one-time confirmation.
It appears when the owner picks a **ChatGPT plan** model for a cloud assistant
and the account's assistants touch Google. The owner confirms that training is
off in ChatGPT before Google data can go to OpenAI. The desktop has no
separate "connect Google" consent step. This card is the training-off step.

| Piece | Desktop reference (`origin/main` 46f5a518) |
| --- | --- |
| The card | `apps/desktop/src/matrix/chatgpt-training-confirm.tsx` |
| Words (en/vi, others read English) | `apps/desktop/src/matrix/chatgpt-training-copy.ts` |
| Gate in the picker | `apps/desktop/src/matrix/model-picker.tsx:1628-1660` (`chooseRoute`) |
| Card takes over the picker | `model-picker.tsx:2447-2460` (`takeover`) |
| Read once per open card | `model-picker.tsx:1395-1410` (`loadTraining`) |
| Shell transport | `apps/desktop/electron/matrix/chatgpt-training-confirmation.ts` |
| Shared consent transport | `apps/desktop/electron/matrix/owner-consent.ts:17,36-60` |
| `required` | `apps/desktop/electron/matrix/main.ts:18595-18610` |
| Status types and wording versions | `apps/desktop/shared/matrix-subscriptions.ts:110-140` |
| Settings › Connections row and Revoke | `apps/desktop/src/matrix/chatgpt-training-settings.tsx` |

The platform contract is in atum-platform `origin/main`:
`docs/operations/chatgpt-training-confirmation.md`,
`apps/shell/src/lib/training-confirmation.ts`,
`apps/shell/src/lib/host-owner-bearer.ts`,
`apps/shell/src/lib/matrix-authority.ts:456-466`, and
`apps/shell/src/middleware.ts:271-273`.

### The flow

1. The owner picks a ChatGPT plan model for a cloud assistant. The picker
   reads the account's confirmation:
   `GET /api/connections/openai-codex/training-confirmation`.
2. If the account needs a confirmation (`required`) and it is not `current`,
   nothing is written. The picker shows the card in its own space. It is not
   a modal and not a second picker.
3. The card shows a title, one **unticked** box with the exact v1 sentence, a
   helper line and the exact transfer sentence. Below them are "Confirm and
   use ChatGPT" (disabled until the box is ticked) and "Keep protected model".
4. Pressing Confirm sends a POST with exactly
   `{wordingVersion: "chatgpt-google-v1", connectionId, transferWordingVersion: "chatgpt-google-transfer-v1"}`
   for the relay connection the card read. Only a 200 with `current: true`
   for v1 counts. Then the pick is written.
5. A 409 means the relay connection changed. The card reads again, unticks
   the box and shows "Your ChatGPT connection changed. Tick the box again to
   confirm." Any other answer shows "Couldn't save this. Your model hasn't
   changed. Try again."
6. Keep closes the card. Nothing is written.

The platform records the confirmation itself: the owner, the time, the
language and the SHA-256 of each sentence. The checkbox and transfer
sentences are hashed per language, so they must be shown character for
character.

## What the phone does now

The step sits at the same point: the phone's ChatGPT plan pick in the model
picker. That covers the composer's model sheet (`PhoneConversationModelPicker`)
and the assistant card's Model page (`PhoneDestinationModelPicker`). These
are the only phone paths that write a `chatgpt_plan` choice. The phone has no
Google connect flow of its own. Google is connected on the desktop.

- **The same endpoint and body.** `NativeDomainClient.chatGPTTraining()` and
  `confirmChatGPTTraining(connectionID:)`
  (`ios/Sources/AtumNativeAPI/ChatGPTTraining.swift`, `NativeDomainClient.swift`)
  call the Shell route. They send the native domain bearer and
  `X-Atum-Host-Bridge-Contract: atum.s2.host-bridge/1.0.0`. The platform
  accepts the phone's bearer on this exact path. `hostOwnerBearer` admits
  `nativeDomainClients(config)`, and that includes `iosDomainClientId`. The
  domain client's URL allowlist gets one exact-path exception for this route
  on the same host. The contract header is allowed only on that path, for GET
  and POST.
- **Strict reading.** The projection is parsed as the desktop's
  `parseMatrixChatGptTraining` parses it. A wording other than v1 is not
  current. A malformed field makes the whole answer unreadable, and an
  unreadable answer is never a confirmation. Any status other than 200, 409
  or a refreshed 401 is "unavailable". A 401 refreshes the bearer once and
  never signs the phone out.
- **The gate** (`ChatGPTTrainingGate`, `ios/App/Chat/Views/ChatGPTTrainingConfirm.swift`).
  A ChatGPT pick reads the confirmation first:
  - `current`: the pick is written as before.
  - not current: the card is shown. Nothing is written.
  - read failed, or no training actions wired: nothing is written, and the
    picker's existing "couldn't save" note shows. A second tap tries again.

  OpenCode Go picks never read the confirmation. Their write path is
  unchanged.
- **The card** (`ChatGPTTrainingConfirmView`) replaces the picker's list in
  the same sheet or page, as the desktop's takeover does. It shows the title,
  the unticked box with the v1 sentence, the helper, the transfer sentence,
  and any notice. Then come Confirm (the primary button, disabled until ticked,
  reading "Saving…" while saving) and Keep (the quiet button). VoiceOver
  focus starts on the box. The box is read as the system's toggle through
  `accessibilityRepresentation`. On Confirm the pick is written against the
  snapshot the picker holds at that moment, and only after the platform has
  said `current`.
- **Words.** Every string comes from the pinned export with `design.text(key)`
  (`ChatGPTTrainingCopyKey`). Nothing is hard-coded. The en/vi checkbox and
  transfer sentences match the platform's SHA-256 table
  (`ChatGPTTrainingGateTests`).

### Deliberate difference: when the phone asks

The desktop asks only when `required` is true. It works that out on the Mac:
Google services connected there, or the owner's Google fence seen there. The
fence is a latch that stays set after Google is disconnected. The phone can't
see either. The platform's projection has no `required` field, and the fence
notice is stored on the Mac. So the phone **asks whenever the confirmation is
not current**. An account whose assistants never touch Google may see the
card once on the phone and never on the desktop. Asking once too often is
safe. Assuming consent isn't. If the platform later adds `required` to the
GET projection, the phone can read it and match the desktop exactly.

### Locale

As on the desktop, the card uses the app's language. Vietnamese gets the
Vietnamese sentences. Every other language gets the English ones, and the
export already says so for ja, zh and zh-Hant. The platform hashes against
the owner's recorded language (`owner_languages`). A phone set to a language
other than the owner's recorded language has the same gap the desktop has.

## Pending keys and follow-ups

- **No missing keys.** The card's nine keys are in the pin
  (`src.matrix.chatgpt-training-copy.COPY.{title,checkbox,helper,transfer,confirm,keep,saving,failed,stale}`).
- **Not ported in this lane:** the Settings › Connections row "ChatGPT with
  Google data" (`rowTitle`, `confirmedOn`, `notConfirmed`) and its Revoke
  (`revoke`, `revoking`, `revokePending`, `revokeFailed`, `readFailed`,
  `tryAgain`). The keys are pinned. Revoke needs an idempotency key that
  survives a restart (the desktop's `FileOwnerConsentRevokeJournal`) and the
  503 drain retry. A ChatGPT plan always needs a Mac relay, so an owner who
  can confirm can also revoke on the desktop. The helper sentence says
  "revoke this confirmation in Connections". Until the row is ported, that
  place is the desktop's Connections. Follow-up: port the row and Revoke to
  phone Settings › Connections.
- **Live check pending.** Every test here runs against synthetic data. No
  production confirmation was sent from a phone in this lane.

## Fix round: the missing ChatGPT plan rows (2026-11-23)

The r3 run failed `ChatGPTTrainingUITests` in all four combinations at
"no ChatGPT plan model". The failure hierarchy in `ui-en-light.xcresult`
showed the Subscriptions section with only the saved `gpt-6.1` row, drawn
as the saved-row fallback (model id, no display name), and never
`gpt-6.1-mini`, even with the sheet expanded and scrolled to its foot.

Cause: an app bug, not the test. The composer opens
`PhoneConversationModelPicker` with its cached 1.1 and 1.3 reads, and
`load(force:)` returned early whenever both were present. The account's
subscription status (`destinations.subscriptions.read`) is never cached, so
it was never read, and a relayed ChatGPT plan showed only its saved model.
The same applied to the assistant card's picker. `ComposerAndMenuUITests`
did not catch it because its pick step is skipped when the row is absent.

Fix: with both reads cached, `load` still reads the subscription status once
(when the picker has none yet), without re-reading 1.1 or 1.3. The training
gate is unchanged: a ChatGPT pick still asks first and writes only after
Confirm.

The branch was also rebased onto `origin/main` `6dc8859` (W4-AB #64 and its
fixes #65). The one conflict was `NativeDomainClient.isApprovedURL`; both
exact-path Shell routes (`CloudScheduleStop` and `ChatGPTTraining`) are kept.

## Review round r1 fixes (2026-11-23)

Codex review r1 held the PR on five consent findings. Four are fixed on the
phone; one, and part of another, need the platform.

1. **A model write could outlive its consent (blocking). Fixed on the phone;
   the atomic check is a platform follow-up.** The gate and the card now hand
   the write the decision they read, `ChatGPTTrainingConsent` (relay
   `connectionId` and confirmation `revision`). It travels through
   `AssistantSubscriptionActions.save` into `LiveAppModel.saveAssistantModelSubscription`,
   which refuses a ChatGPT write that has none. The shared save path
   (`ManagedModelPickerState.save`, `ios/Sources/AtumNativeAPI/ModelChoice.swift`)
   takes a `revalidate` precondition. It runs before the automatic retry
   after a revision conflict and after any refusal. `ChatGPTTrainingRecheck`
   re-reads consent with the client and scope the write was bound to. The
   decision holds only if the same connection and revision are still
   current. If it doesn't hold, nothing is retried and the result is
   `.preconditionChanged`. When the platform now says "not current", the
   picker returns to the card with the fresh status
   (`AssistantModelDestinationSaveResult.consentRequired`). An unread or
   re-confirmed status is a plain refusal, so the person picks again through
   the gate.
   **Platform follow-up:** the PUT can't carry the decision. The 1.5
   `matrix_model_destination_write` (atum-platform
   `supabase/migrations/0336_chatgpt_relay.sql` L403-447) accepts exactly
   `choice, expectedRevision, policyDigest, profile, requestId`, and it
   checks the relay but not the training confirmation. A revoke that lands
   between the phone's re-read and the PUT is therefore still accepted. The
   0538 relay admission re-checks consent before any Google data flows, so
   Google data stays protected. The saved model choice can still go stale.
   The fix belongs in the platform: an optional `trainingConfirmation:
   {connectionId, revision}` precondition on the 1.5 write, checked in the
   same transaction (`_modelChoiceError` `consent_changed`). The phone would
   send the consent it already carries. No server code changed in this lane.
2. **A malformed 200 could open the gate. Fixed.** `ChatGPTTrainingStatus`
   is `current` only when it is complete: v1 wording, a UUID `connectionId`,
   `confirmedAt` and `revision`. A `current: true` missing any of them reads
   as not confirmed. The type's initializer enforces this as well, so
   nothing can build an incomplete current record. The POST client accepts a
   confirmation only if its `connectionId` equals the UUID it sent. Any other
   answer is `.unavailable`.
3. **Closing the picker left a pending selection alive. Fixed.** This ports
   the desktop picker's selection lifetime (`beginSelection`,
   `model-picker.tsx:379-383,1527-1538`) as `ModelPickerLifetime`. Each pick
   takes a token. A newer pick or the picker's dismissal (`onDisappear` on a
   stable container, so the card replacing the list does not count) retires
   it. A stale token can't apply a consent read, can't let a card
   confirmation start a write, and can't start the PUT. The training read
   and POST closures in `LiveAppModel.assistantModelDestinationActions` are
   bound to the captured `NativeDomainClient` and the existing
   `modelPickerScope`. They no longer use whichever client is current when
   they run.
4. **Interrupted reads stalled recovery. Fixed.** Both pickers' loads take
   a load token and release it in a `defer`, so a cancelled read (the list
   giving way to the card, a closed sheet) never leaves the picker stuck
   "loading". If a 409's refresh failed and the card has no connection, the
   next press reads the status first (`ChatGPTTrainingPress`). It confirms
   only for the connection that read names, and it never sends a Confirm
   without one.
5. **Locale binding of the hashed sentence. Platform follow-up, not
   implemented.** The platform hashes against the owner's recorded language,
   not the language the card showed. Binding the POST to the shown locale
   needs a Shell contract change: for example, a `locale` field checked
   against the per-language hash table. The phone keeps showing the pinned
   sentences character for character.

Tests (package): `ChatGPTTrainingTests` checks decoder strictness and that
the type rejects incomplete records. `ChatGPTTrainingConsentTests` covers the
re-check identity, conflict → gate with no retry, conflict with the same
consent retrying once, refusal → re-check, the press's UUID match and read
before confirm, dismissal and newer-pick invalidation, and load reset.
`NativeDomainClientTests.testChatGPTTrainingUsesTheDesktopShellRouteAndExactBody`
gains the cases for a POST answered with another UUID and for an incomplete
current 200. `ChatGPTTrainingGateTests` (AppTests, on hosted shards) checks
that `.write` carries the consent.

## Verification

Each run took the shared heavy-build lock
(`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`, `-jobs 2`). DerivedData
is `/Volumes/AtumTestFlight/dd-w4-e2` and the simulator is an iPhone 17. The
script is `/Volumes/AtumTestFlight/dd-w4-e2/verify.sh`, with modes
`build` and `tests`. It was slimmed per the coordinator's 2026-11-23 lock
rule: package tests, the Debug build, the touched AppTests, and only the new
UI test in each language and appearance.

| Check | Result |
| --- | --- |
| `swift test` (package, all targets) | Pass. 0 failures across the 16/48/898/735-test suites. Includes `ChatGPTTrainingTests` (3) and `NativeDomainClientTests.testChatGPTTrainingUsesTheDesktopShellRouteAndExactBody`. The first run failed on a type error in that test's own helper; it was fixed and rerun. |
| Debug simulator `build-for-testing` (AtumMobile) | Pass, `debug-build.xcresult`. The first try hit the script's 40-minute timeout on a cold build; it passed on the incremental rerun. |
| Focused AppTests (`ChatGPTTrainingGateTests`, `PhoneModelPickerCopyTests`, `AssistantHomeDestinationTests`) | **Not run.** The queued job reached the 2 h background ceiling just as it acquired the lock (10:05:10). |
| `ChatGPTTrainingUITests` in en/vi × light/dark | **Not run**, for the same reason. |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | Exit 0 on its own. |

Rerun only the missing steps. The build is already done, and the run needs
no rebuild:
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash /Volumes/AtumTestFlight/dd-w4-e2/verify.sh tests`.
It writes `app-tests.xcresult` and `ui-{en,vi}-{light,dark}.xcresult`, with
captures under `ui-scratch/ui-evidence/`.

### Review r1 verification (2026-11-23)

The run took the shared lock with
`/Volumes/AtumTestFlight/dd-w4-e2/verify-r1.sh`, started 16:53:05 and ended
16:57:23, EXIT_MARKER 0. Per the owner's slim rule it ran only the focused
package tests and the Debug build. No UI suites ran locally; those run on
the hosted PR shards.

| Check | Result |
| --- | --- |
| `swift test --filter 'ChatGPTTraining\|ManagedModelPickerState\|ModelWriteRequests\|NativeDomainClientTests'` | Pass. 115 tests, 0 failures: `ChatGPTTrainingConsentTests` 8, `ChatGPTTrainingTests` 4, `ManagedModelPickerStateTests` 4, `ModelWriteRequestsTests` 4, `NativeDomainClientTests` 95. |
| Debug simulator `build-for-testing` (AtumMobile, compiles AppTests and UITests) | Pass, `debug-build-r1.xcresult`. No warnings in the touched files. |
| `ChatGPTTrainingGateTests` (AppTests) and `ChatGPTTrainingUITests` | Compiled, not run locally. They run on the hosted PR shards. |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | Exit 0 on its own. |
### Review r3

- Both phone pickers pass the current selection token to the confirmation
  card and the shared subscription save. If the picker closes during the
  recovery GET after a 409, the card drops the result and sends no POST.
- The shared save checks the selection alongside the account and assistant
  scope before the first PUT and the conflict retry. Dismissal while the
  destination readback or consent re-check is pending ends the save silently.
- The native client repeats the scope and selection check immediately before
  dispatch after authorization, including a replay after a 401.
- A second fence conflict or a failed destination readback re-checks consent
  before reporting a refusal. Revoked consent sends the owner back to the
  training card.

Verification ran under the shared heavy-build lock using the r3 script in
`/Volumes/AtumTestFlight/dd-w4-e2`. The first Debug build exited 65 on a
Swift closure-lifetime error in the shared save. The callback lifetime was
fixed before the rerun.

| Check | Result |
| --- | --- |
| `swift test --filter 'ChatGPTTraining\|ManagedModelPickerState\|ModelWriteRequests\|NativeDomainClientTests'` | Exit 0, 120 tests and 0 failures. Covers dismissal during the recovery GET, conflict readback and consent re-check, the refusal paths, and both sends after an authorization refresh. |
| Debug simulator `build-for-testing` (AtumMobile) | Exit 0, `debug-build-r3.xcresult`. AppTests and UITests compiled. Zero simulator tests ran locally. |
| Shared verification launcher | `EXIT_MARKER 0`. |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | Run separately on the committed revision. Output is in `guard-r3.log`. |
