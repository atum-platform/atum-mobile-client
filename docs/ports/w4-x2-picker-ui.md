# W4-X2 picker settled reads UI

UI lane over [W4-X1](w4-x-picker-settle.md). Both picker entry points (the composer's
`PhoneConversationModelPicker` and the assistant card's `PhoneModelDestinationsPicker`) now draw the
settled read states that W4-X1 publishes. Desktop reference: atum-desktop #126 `a55f1f3f`
("settle agent plan catalogs and offer native consent"). It covers `model-picker.tsx`
`relayReadReason`, `catalogState`, the account-plan routes and the consent check before a plan
selection, and `connections/connect-sheet.tsx` on a device without Work.

## What each state looks like

| Source / state | Phone treatment | Copy key |
| --- | --- | --- |
| Destination `loading` | A line at the top of the list: spinner (a still clock under Reduce Motion) and the loading words | `src.matrix.model-picker-copy.COPY.modelsLoading` |
| Destination `failed` | Its own line at the top, alert glyph, words, **Try again**. Atum's line-up and every loaded catalog stay listed, read-only and unchecked (r2: `destinationReady` in the projection; no row is selectable or current without a ready destination) | `…COPY.switchProblem.unavailable`, `…COPY.modelsRetry` |
| Destination `ready` / `unavailable` | No line | — |
| ChatGPT / OpenCode Go `loading` | A line under the models: provider mark, "{Plan} plan", spinner and loading words | `…COPY.planAccount`, `…COPY.modelsLoading` |
| ChatGPT / OpenCode Go `failed` | Same line with the failed words and **Try again**. When a saved plan row already shows that reason under its name, the line keeps only the plan name and Try again (r2) | `…COPY.modelsFailed`, `…COPY.modelsRetry` |
| Account Connections `loading` | Link glyph, "Subscriptions", loading words | `src.matrix.mobile-copy.mobileScreensCopy.connections.subscriptions`, `…COPY.modelsLoading` |
| Account Connections `failed` | Same line with the unreachable-connections words and **Try again** | `…COPY.modelsUnavailable`, `…COPY.modelsRetry` |
| Any account source `ready` / `unavailable` | No line. The existing treatments remain: catalog rows, a saved row's reason (`Row.unavailable`), Connect entries | — |
| Work plan reported on a Mac (`workPlanHandoffs`) | A read-only group per plan: header with the plan mark and "{Plan} plan", one greyed row per model, then a hand-off row with the reason. Tapping it opens the existing connect sheet in hand-off mode: plan mark, "Connect {Plan}", "Open Atum on your Mac to connect." and Close, with no registry follow | `…COPY.planAccount`, `…connections.picker.inWork`, `…connections.sheet.title.plan=*`, `…connections.sheet.needsMac`, `…connections.sheet.close` |

Status and hand-off rows are hidden while a search or filter is active, as the Connect entries are.
While the ChatGPT line shows (loading or failed), no ChatGPT hand-off group is drawn (r2).
VoiceOver announces a line once when it first reads failed: "{source}, {words}" at high priority (r2).
The destination line is always shown. At accessibility text sizes, Try again moves under the words.
Every status row is one VoiceOver element reading "{source}, {words}". Each Try again reads
"Try again: {source}". A hand-off row reads "{Plan} plan, Works in Work for now", with the needs-Mac
line as its hint. Each hand-off model reads "{model}, Works in Work for now". Colours, spacing and
control heights come from the design tokens (`atum.color`, `kit.space`, `kit.phoneControlHeight`).

## Decisions

- **No line for `unavailable`.** Desktop's quiet unavailable copy appears only where the account
  has a plan with nothing to show. On the phone, those cases already have a treatment: a saved row's
  reason, a Connect entry or a Work hand-off. Another line would repeat it for every account without
  a relay.
- **One Retry path.** W4-X1's account model reloads its three sources together. A per-source Retry
  would change W4-X1's state logic, so each account Try again re-reads all three under a fresh
  budget. Desktop also re-reads its whole relay. Since W4-X1 `172fa3f`, every picker load refreshes the
  destination, offer and account sources together. In both pickers, every Try again reruns `load()`,
  bounded by `PhoneModelPickerRead`.
- **Destination failure copy.** No pinned string names a failed destination readback. `modelsFailed`
  names "this connection" and `modelsUnavailable` names the connections registry, so the phone uses
  the pinned `switchProblem.unavailable`. That string describes the result: the assistant's choice
  can't change right now. It is recorded as a copy gap below.
- **Hand-off, not consent.** Desktop #126 checks native consent before a plan selection. Missing
  consent opens the Allow sheet; expired consent opens the Renew sheet. On a device without Work, that
  sheet shows "Connect {Plan}", "Open Atum on your Mac to connect." and Close. The phone reuses its
  port of that sheet (`AccountPlanConnectSheet`) with `AccountPlanConnectRequest.handoff`, which
  turns off the registry poll so a connected plan isn't announced as just connected. The phone never
  grants or renews consent.
- **Training stays separate.** The ChatGPT training confirmation (`ChatGPTTrainingConfirmView`) is
  unchanged and still guards the cloud ChatGPT pick only. Hand-off groups never reach it.
- **W4-X1 logic unchanged.** The UI reads `chatGPTState`, `openCodeGoState`,
  `accountConnectionsState`, the pickers' `destinationReadState` and `workPlanHandoffs`. The pure
  mapping is `PhoneModelPickerStatus` in `AtumNativeAPI` and is unit-tested. No W4-X1 bug fix was
  needed.
- **ChatGPT hand-off hidden behind its line (r2).** When the ChatGPT relay read fails,
  `workPlanHandoffs` no longer treats ChatGPT as supplied by the cloud relay, so W4-X1 also lists
  a ChatGPT plan that Work reports on a Mac. Desktop never offers that hand-off on a device that reaches
  the relay (`model-picker.tsx:894`, `:1089`). The list therefore hides the `.codex` hand-off group
  while the ChatGPT line shows (loading or failed). This is a UI filter only (`shownHandoffs`). W4-X1 is unchanged.
- **Read-only means unchecked too (r2).** With a destination read, Atum rows are selectable and
  current only when that read is `ready`. While it loads or after it fails, neither the 1.1 offer
  nor a cached 1.3 snapshot stands in. `choose` and `chooseEffort` write nothing, the line-up has no
  check and no Default word, and no thinking control shows. A destination read the server does not
  offer (`unavailable`) leaves the 1.1 offer as the authority, as before W4-X2, so a legacy server
  keeps a working picker. The card applies the same gate to a snapshot kept from an earlier read.

## Gaps

Copy, for the desktop export lane:
- No string for a failed destination readback over read-only catalogs. `switchProblem.unavailable`
  stands in for it.
- Desktop's Renew title (`connections/copy.ts` `renewal`, "Keep your assistants on this Mac") and the
  Work relay fix labels (`relay-copy` `fix.allow` / `fix.renew`) are not in the pin.

Behaviour, deferred from r1 review:
- One merged loading note, and no destination line over a cached snapshot (review follow-up 5).
  The phone draws a line per loading source, and draws the destination line even over a cached snapshot.
- Retry reloads the whole picker. There is no per-source retry.
- Desktop #129 removed Renew, so no Renew variant is planned.

Data:
- The phone has no native consent read (desktop `work.readPlanConsent`: state, agents, named Macs,
  `nativeRenewal`). It can't tell missing consent from expired consent, or from a plan that would
  already work. Every Work plan therefore gets the same hand-off, and no Allow or Renew variant is
  built.
- Hand-off models aren't searchable (review gap 4) and have no favorites. They come from the registry, not a
  model-choice contract, so they have no write identity.

## Verification

Verification runs once under the heavy-build lock, using `/Volumes/AtumTestFlight/w4-x2/verify.sh`.
Results are recorded below once the run finishes.

- r1 (`88aa1d3`): Swift tests passed (exit 0) and `build-for-testing` succeeded. The destination-failure UI
  test passed in all five runs. The ChatGPT test failed at the hand-off step in each run: it looked up
  `phone.model.handoff.claude.open`, but the view uses the plan's picker ID (`claude-plan`). The UI
  hierarchy shows both hand-off groups rendered as designed. This was a test fix only.

- r2 (`3256176`, after merging W4-X1 `3f9bc7c`): Swift tests passed (107, exit 0). The build failed
  (exit 65) because the merge removed `load(force:)`, so the composer's Retry called a signature that no
  longer existed. The fix is to call `load()`, which is now always a full refresh.
- r3 (`bb58abf`): Swift tests were skipped because the package code is identical to r2, where they passed
  (107, 0 failures). `build-for-testing` succeeded (exit 0) for arm64 Debug on the iPhone 18 Pro simulator.
  `PhoneModelPickerSettledReadsUITests` passed both tests in each of light-en, light-vi, dark-en,
  dark-vi and light-en at AccessibilityXL, 10 of 10 (exit 0). The simulators were shut down afterwards.
  The locked run's exit code was 0. Logs are in `/Volumes/AtumTestFlight/w4-x2/logs-r3/` and result
  bundles in `ui-*.xcresult`. Captures are in `/Volumes/AtumTestFlight/w4-x2/ui-scratch/ui-evidence/`:
  `chatgpt-failed`, `work-handoff`, `work-handoff-sheet`, `destination-failed` and
  `destination-failed-catalog`, each tagged `w4x2-{en,vi}-{light,dark}` plus `-en-light-ax`.
- Unlocked checks: `python3 scripts/design_lint.py` reported OK with no new findings (exit 0). The copy-key
  pin test passed (7 OK). `python3 scripts/public_guard.py --base origin/main --head HEAD` passed (exit 0).

## Fix round r2 (review r1, Opus: HOLD)

Findings, then fixes:

1. **Blocker: the composer's failed destination was not read-only.** `conversation(offer:destination:)`
   took `selectable` from the 1.1 offer and the check from the 1.1 choice or the cached 1.3 snapshot,
   and `choose()` wrote through the 1.1 path. Fix: `PhoneModelPickerProjection.conversation` and
   `.destination` take `destinationReady`. When it is false, every row becomes `Row.readOnly()`:
   unchecked, not selectable, no Default word and no subscription effort. The composer passes
   `atumWritable`, which is true only when it has no destination read, or its read is `ready` or
   `unavailable`. `choose()` and `chooseEffort()` also guard on `atumWritable`.
2. **Should-fix: the card kept a stale snapshot after a later failure.** The card passes
   `destinationReadState == .ready` to `.destination`, so old rows draw greyed and unchecked.
3. **Should-fix: ChatGPT hand-off next to its failed line.** `PhoneModelPickerList.shownHandoffs`
   drops the `.codex` group while a ChatGPT status line exists. The change is UI-only.
4. **Should-fix: failed words shown twice.** `PhoneModelPickerStatus.isShownOnRow(in:)` is true when a
   saved plan row of that source carries the same reason (`failed`/`loading`). The line then draws the
   plan name and Try again without the words. The VoiceOver label is the plan name, and the failed row
   still speaks the reason.
5. **Follow-up: failure announcement.** The list posts `AccessibilityNotification.Announcement`
   (high priority) when a line first reads failed, including a line that is already failed when the
   list appears. A source that loads again and fails again is announced again.

Tests: `PhoneModelPickerProjectionTests` adds the composer and card read-only cases.
`PhoneModelPickerStatusTests` adds the row-reason case. In `PhoneModelPickerSettledReadsUITests`, the
destination test asserts that Nguyệt Thực and Nhật Thực are disabled, unselected and have no
current value. The ChatGPT test asserts that the saved GPT-6.1 row carries the failed words, the line
does not repeat them, and no `openai-codex` hand-off exists.

Test fixes found in the first locked run (`85d96f7`):
- Once the ChatGPT hand-off was gone, the list was shorter. Claude's "Works in Work for now" row then
  sat under the bottom search bar. XCUITest still calls that row hittable, but in dark-en the tap
  landed on the bar. At AccessibilityXL, the Atum rows sat below the lazily drawn area. `reveal` now
  scrolls until the target exists, is hittable and ends above the bar (86% of the window), and the
  destination test uses it for the Atum rows.
- `PhoneModelPickerVisualsUITests` (W4-R) still looked up `phone.model.plan.claude`. The view has
  used the plan's picker ID, `claude-plan`, since `AccountPlan.pickerID`, and main has the same stale
  ID. Both of its tests failed for that reason alone, so the IDs are corrected here. The change is test-only.

- In the rerun (`acdcbad`), AccessibilityXL left the ChatGPT line above the bar, but its Try again (under
  the words at that size) stayed under it. The tap focused search, which hides the lines. The test now
  reveals Try again itself before tapping.

Verification (fix round r2): pending the locked rerun `/Volumes/AtumTestFlight/w4-x2/verify-fix-r2c.sh`.

