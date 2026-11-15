# Report assistant and app-bot messages

App Review guidelines 1.2 and 4.7.1 require a way to report assistant output
and third-party app content. HC-2 excluded both by room kind and sender ID;
the menu also required a known non-person sender set before offering Report.

## Behavior and server path

- Long-press a server-backed text, image, or file from another sender (also a
  notice in an app-bot chat): **Report**
  appears in person, group, assistant, and app-bot chats, including Moon/Andy.
  Reporting no longer needs the sender catalog or member classification.
- Own messages, pending/failed sends, transaction IDs, missing/invalid event IDs,
  notices outside app-bot chats, redacted/unreadable placeholders, and room-state
  rows remain ineligible. Incoming server notices in app-bot chats offer Copy,
  Select text, and Report, as their text messages do.
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

## Original PR verification

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
below 2 GiB free. No push, PR, CI, or Apple account action is part of this
implementation checkpoint.

## Owner device check

1. Long-press an assistant answer, Moon/Andy reply, and a bot reply in a group;
   confirm Report opens the same message sheet. Own messages offer no Report.
2. Submit one report with a reason and one without; confirm the homeserver event
   reports name the selected room/event, with the supplied reason or `abuse`.
3. Try offline submission: the existing error stays in the sheet; retry online.
4. Confirm assistants/apps gained no Block action, person Block still works,
   and VoiceOver and large text can reach the report controls in en/vi.

Scripted UI fixtures have no homeserver. The original tests target menu-to-sheet
presentation. The follow-up below adds submission and routed-request assertions;
live server receipt and physical-device checks remain with the owner.

## Review follow-ups

The `bot.moon-notice` name covered two different event types: `.0001` is a
regular text greeting, while `.0003` is an actual `.notice` setup message with
`io.atum.app_bot` metadata. The earlier menu/sheet UI checks pressed the greeting.
`bot.moon-notices` and its edited/spoofed variants also publish actual notices,
including the shared Andy notice codes. `ItemMapper` preserves the SDK's notice
kind and captures catalog-bot notice metadata; `Projection` keeps non-transient
notices as notice rows. The catalog-bot path is shared by Moon and Andy; this is
fixture/mapping evidence, not a live homeserver observation.

B17's blanket no-action notice rule stranded that app content. `MessageMenuRules`
and `ReportPolicy` now accept incoming, settled server notices in `.appBot` rooms,
and `ChatRowView` installs the existing menu on `NoticeRow`. The menu matches app
text messages: Copy, Select text, Report, without reactions or Block. Notice text,
setup/terms buttons, and app metadata authentication are unchanged. No sender
catalog or metadata requirement is added to content reporting. Notice menus in
other room kinds retain B17's behavior; assistant transient-line projection and
person/member reporting are unchanged. Own, local-echo, pending/failed,
transaction-only, missing/invalid event, redacted, unreadable, and state rows
cannot be reported. This uses the documented desktop app-content report path;
it does not add a new endpoint or person-report rule.

The Debug scripted host now replaces only the final report transport on its
room-less `LiveConversationStore`. Report sheet submission still calls
`ChatActions.report`, resolves the selected row again, constructs the real
`ReportPolicy.Request`, and reaches the store's send path. The host records only
room ID, event ID, and cleaned reason in the existing timestamped UI probe;
no SDK/network report is attempted. Two UI tests assert exactly one routed call:
Moon's actual notice with a supplied reason, and an assistant answer with the
default `abuse`. They also check successful sheet dismissal. Unit tests check
notice eligibility/exclusions and fixture projection. The thread test asserts
that another person's, assistant's, or app bot's reply is reportable and targets
its own event ID, rather than the thread root or quoted event; an own reply is
excluded.

### Follow-up verification

- Focused Swift package tests: **83 passed, 0 failed** (80 chat-core tests plus 3 copy-contract tests). Suites:
  `ReportPolicyTests`, `MessageMenuRulesTests`, `ThreadMenuTests`, `ScriptedTests`,
  `ChatMemberModerationTests`, `ChatCopyContractTests`, `ChatExitPolicyTests`,
  `WorkingLineParityTests`.
- Simulator app/test build: passed. Focused UI tests on `Atum iPhone 16e`:
  **5 passed, 0 failed**: `testAppBotNoticeMenuSubmitsReportWithReason`,
  `testAssistantReportSubmissionUsesDefaultReason`,
  `testAssistantAnswerOpensMessageReportSheet`,
  `testAppBotMessageOpensMessageReportSheet`,
  `testBotRoomMenuOffersCopySelectAndReport`.
- Xcode returned exit 0 (`TEST SUCCEEDED`). Its automatic post-test
  `simctl diagnose` child was stopped after the five tests passed; the test/build
  process itself completed normally. The locked runner then shut down simulators.
  Final build-volume free space: 7.1 GiB. The result bundle reports five
  `Invalid frame dimension (negative or non-finite)` runtime warnings across
  the five menu tests; no test failed. Their layout source remains uninvestigated.
- `git diff --check`: passed.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: passed,
  exit 0, including the implementation commit.

All Swift/Xcode verification uses the shared heavy-build lock, two build jobs,
and the prescribed temporary/cache directories. The Xcode run uses dedicated
`dd-report-followups` derived data and the shared `spm` cache. A monitor stops
verification below 2 GiB free, and the same locked command shuts down all
simulators before releasing the lock. This checkpoint is local-only; the
coordinator owns integration, review, pushing, PRs, and CI.

The verification batch held `lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`
with `TMPDIR=/Volumes/AtumTestFlight/tmp` throughout both commands below (working
directory `ios`). Its disk monitor enforced the 2 GiB floor, and its finalizer
ran `xcrun simctl shutdown all` before releasing the lock.

```sh
swift test --scratch-path /Volumes/AtumTestFlight/swiftbuild-fold-reader -j 2 --filter 'ReportPolicyTests|MessageMenuRulesTests|ThreadMenuTests|ScriptedTests|ChatMemberModerationTests|ChatCopyContractTests|ChatExitPolicyTests|WorkingLineParityTests'

xcodebuild -project AtumMobile.xcodeproj -scheme AtumMobile -configuration Debug \
  -destination 'platform=iOS Simulator,id=CB24FAE2-75F9-4E19-A856-0F5A9F036C0B' \
  -derivedDataPath /Volumes/AtumTestFlight/dd-report-followups \
  -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm -jobs 2 \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -resultBundlePath /Volumes/AtumTestFlight/report-followups-verify/ui.xcresult test \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testAppBotNoticeMenuSubmitsReportWithReason \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testAssistantReportSubmissionUsesDefaultReason \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testAssistantAnswerOpensMessageReportSheet \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testAppBotMessageOpensMessageReportSheet \
  -only-testing:AtumMobileUITests/MessageMenuUITests/testBotRoomMenuOffersCopySelectAndReport
```
