# Report assistant and app-bot messages

App Review guidelines 1.2 and 4.7.1 require a way to report assistant output
and third-party app content. HC-2 excluded both by room kind and sender ID;
the menu also required a known non-person sender set before offering Report.

## Behavior and server path

- Long-press a server-backed text, image, or file from another sender: **Report**
  appears in person, group, assistant, and app-bot chats, including Moon/Andy.
  Reporting no longer needs the sender catalog or member classification.
- Own messages, pending/failed sends, transaction IDs, missing/invalid event IDs,
  notices, redacted/unreadable placeholders, and room-state rows remain ineligible.
- The existing `ReportSheet(subject: .message)` and `ChatActions.report` are reused.
  The live store rechecks eligibility, builds an event-only request, and calls
  `Room.reportContent(eventId:reason:)` through the existing SDK path:
  `POST /rooms/{roomId}/report/{eventId}`. No new endpoint or room-report fallback
  is used for bot content. Requests carry identifiers and the cleaned optional
  reason (default `abuse`), never message text.
- Report person and Block/Unblock eligibility are unchanged. Reporting an
  assistant/app message does not add Block to its message menu.

## Desktop parity and copy

Read fetched desktop `origin/main` at `61ba25c6` without changing its checkout.
In `apps/desktop/src/matrix/app.tsx`, `person` excludes own messages, agents,
and the assistant user ID. `reportMenu` requires `person` and an actionable
server event. App bots are not excluded by that check and can be reported;
assistant answers use the answer toolbar without `onReport`.

The phone now matches desktop app-message reporting and extends it to assistant
answers. **Desktop gap:** assistant content still has no Report action there.
Desktop person/member reporting still excludes assistants and app bots.

The vendored `ios/Vendor/AtumDesign/Localizable.xcstrings` already exports the
shared message-report wording in en, vi, ja, zh, and zh-Hant:

- `src.matrix.chat-copy.copies.report`: “Report”
- `src.matrix.chat-copy.copies.reportTitle`: “Report this message?”
- `src.matrix.chat-copy.copies.reportBody`: “The report doesn’t include the
  message text, and they aren’t blocked.”
- `src.matrix.chat-copy.copies.reportReason`: “Reason (optional)”
- `src.matrix.chat-copy.copies.reportSent`: “Report sent.”

No new copy keys or PENDING-COPY entries are needed.

## Verification

- Static checks: `git diff --check` passed; all five exported report keys
  resolve in all five locales (25 key/locale pairs).
- Swift unit tests: **0 executed; runtime validation blocked**. The focused
  package command was queued with the required lock and two jobs for over
  20 minutes behind another build/test job. It was cancelled while still
  waiting, before Swift started; no compilation or test failure was observed.
  Run `ReportPolicyTests`, `MessageMenuRulesTests`, `ThreadMenuTests`,
  `ChatMemberModerationTests`, `ChatCopyContractTests`, and `ChatExitPolicyTests`
  once the shared lock is available.
- UI tests: **0 executed** under the same resource contention. Two new tests
  use existing `chat.actions` and `bot.moon-notice` scenarios to open and cancel
  the shared report sheet. Existing assistant/app/person/group menu expectations
  now include Report; own-message expectations remain unchanged.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: passed,
  exit 0. No private paths, build numbers, secrets, or generated files added.

No simulator was started for this task. Future Swift builds/tests must use the
shared heavy build lock, two jobs, and existing build/cache directories, stopping
below 1.5 GiB free. No push, PR, CI, or Apple account action is part of this
implementation checkpoint.

## Owner device check

1. Long-press an assistant answer, Moon/Andy reply, and a bot reply in a group;
   confirm Report opens the same message sheet. Own messages offer no Report.
2. Submit one report with a reason and one without; confirm the homeserver event
   reports name the selected room/event, with the supplied reason or `abuse`.
3. Try offline submission: the existing error stays in the sheet; retry online.
4. Confirm assistants/apps gained no Block action, person Block still works,
   and VoiceOver and large text can reach the report controls in en/vi.

Scripted UI fixtures have no homeserver; the new tests target menu-to-sheet
presentation, not server acceptance. Running the unit/UI checks, live server
receipt, and physical-device checks remain with the owner.
