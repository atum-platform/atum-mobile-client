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
