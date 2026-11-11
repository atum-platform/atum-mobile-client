# Chat timeline: desktop parity for Seen, typing and the working line

The owner saw the phone chat behave differently from desktop. An earlier code-only
audit had called these "parity" because a code path existed. This pass compares what
renders. Reference: `atum-platform/atum-desktop` `origin/main` 583ae946.

## Seen faces (desktop `src/matrix/send-state.tsx`)

**Root cause.** A reader's face came from `ChatFace.reader`, which knew only the chat's
member list. `LiveAppModel` loads `conversationMembers` only for 1:1 people chats and
personal groups (`listsMembers || kind == .person`). `chatInfoPresentation` also
drops the list for Team Space chats. So in my assistant's chat, an app's chat or a
company channel, the reader was "unknown" and drew a monogram of its raw Matrix ID.
Desktop draws the agent's roster photo (`MatrixPersonAvatar` with `agent`). Thumbnail
size was not the cause: 16–18 pt asks for a 48–54 px thumbnail, and the same loader
serves the 32 pt member rows.

**Fix.**
- `Delivery.readers(of:in:context:)` (AtumChat) gives each Seen row its readers
  (`ChatRow.readers`, `ChatReader`), each with the name and Matrix avatar its own
  messages carry in the loaded timeline. My own account is dropped.
- `ChatFace.reader` resolves in this order:
  1. the member list's profile;
  2. in a 1:1 chat, the room's face, which is the reader's own (Atum's eclipse or the
     agent's photo; the app's avatar);
  3. the timeline profile;
  4. a monogram of the display name or localpart, never the raw ID.
- Readers are in desktop's `publicReaders` order: receipt time, then user ID
  (`Delivery.receiptOrder`, used by `SDKValueMapping.receiptUserIDs`). Before this,
  they were sorted by user ID.
- Drawing matches desktop: three 16 pt faces overlapping by 6 pt (no ring), then
  "+N" for the rest. Tapping shows every reader's name in a popover, the phone's
  form of desktop's tooltip. The button's accessibility label is `seen` in the
  assistant's chat, else `seenBy(N)`, with the names as its value.
- Sent follows desktop's `latest && message.sent`: only my newest message, once it
  has settled and while nobody has read it. While a newer message is still sending
  or has failed, its clock or warning is the only mark. Before, an older settled
  message kept "Đã gửi". Sent also gains desktop's check glyph.

## Typing (desktop `MatrixTypingLine`, `MatrixAgentWorking`)

Desktop shows the in-transcript working row only in my assistant's chat. Every other
chat, an app bot's included, shows one quiet "X đang soạn tin…" line above the
composer (`{!room.assistant && <MatrixTypingLine/>}`). The phone used to draw a
bubble with the name and three dots in assistant and app chats.

- `TypingNames.presentation`: `.appBot` now gets the composer line, not a row.
- `TypingRow` is desktop's atom with no line: the turning atom centred in a 28 pt
  face slot. No bubble, no name, no dots. Its accessibility label is still
  `typingOne(name)`. `TypingDots` is removed.

## Working line (desktop `typing-indicator.tsx`, `matrix-transient-lines.ts`)

- **Placement.** The agent at work is one last row: the atom, then the line. The live
  `io.atum.progress` line now takes the typing row's place instead of sitting under a
  typing bubble (`Projection.rows`). With no line yet, the typing row shows the atom
  alone.
- **Look** (`WorkingLineRow`, `AgentWorkingLayout`): the first line is the current
  step, in Kit `body` type and `ink-2`, wrapping rather than cut to one line. Later
  lines form the quiet step card (`fill-quiet`, `lg` radius, `caption` `ink-3`): a
  check for "✓"/"✔" rows and a dotted circle for "•"/"◦" rows.
  `WorkingLineText` (AtumChat) does the split.
- **Lifecycle** is unchanged and matches desktop: the line is edited in place and
  hidden once its turn ends (settled marker, or the agent's later answer or outcome).
  `TransientLines.retiredWaitLines` gains desktop's `matrixStatusLineCopy`
  waiting/waited sentences, which desktop also treats as working text.
- **Wording** comes from the publisher (the Mac, `matrix-progress-line.ts` /
  `matrixToolActivityCopy`, e.g. "Đang chạy tác vụ…"). The phone renders the event
  body and adds no strings.

## Run times and "đã sửa" (TL-4, TL-5; coordinator decision 2026-11-11)

Desktop puts the clock in the quiet line under a bubble, not in a centred label:
- under the last bubble of each run (`runEnd`, `src/matrix/app.tsx:1672`/`:1676`);
- for my messages, sharing the line with Sent or Seen (`send-state.tsx:85`);
- under every answer of my agent, in the answer toolbar before Copy (`app.tsx:1748`).

The phone drew a centred label only after a 60-minute gap. Now:

- `Grouping` (AtumChat) sets `RowGrouping.showsTime`:
  - on a bubble that ends its run, or on any answer in my assistant's chat
    (`Grouping.isAnswer`, which needs the room's agent; live groups list none);
  - never on a message still sending, failed or undecryptable, on my own deleted
    message, or on notices (desktop `timeEligible`).
- `RowGrouping.timeLabel`, `Grouping.timeLabelGap` and `TimeLabelRow` are removed.
  Day dividers keep desktop's line and pill.
- `RowGrouping.showsEdited` (desktop `personEdited`): people's edits, mine included.
  An agent's or app bot's edit (a streamed answer) no longer says "đã sửa".
- `DeliveryLine` draws one line: "14:05 · đã sửa · ✓ Đã gửi" (or the Seen faces). For
  the newest answer it draws "14:05" then Copy, which moved here from its own row.
  "đã sửa" left the bubble. In team space flat runs the line carries no clock,
  because the run header already shows it.

## Failed send (TL-6): not done, copy missing

Desktop's line is "Not sent. Sending when you're back online." with an inline "Try
now" (`message-actions.tsx:487`). Neither string is in the pinned export, so the
phone keeps "Chưa gửi được" and its sheet. Needed keys:
`src.matrix.chat-copy.copies.notSentOffline` and `src.matrix.chat-copy.copies.tryNow`.

## Day divider (desktop `TeamSpaceDayDivider`, `.atum-divider`)

`DayDividerRow` now draws desktop's hairline across the column, with the day in a
pill (ground fill, `line` border, `soft` semibold caption). The labels are unchanged
(see remaining differences).

## Scripted capture

- New Debug scenario `chat.timeline-parity` (assistant chat): Atum's receipt on my
  message at open, Atum typing at 3 s, a working line at 6 s, and at 8 s the line
  edited in place with a two-step checklist. There is no answer.
- `-AtumScriptedPhotos` gives Atum's room face and the scripted group's members a
  generated Matrix "photo", served by a scripted thumbnail loader, so captures show
  photos where live chats have them. Release builds compile none of it.

## Remaining differences (not changed here)

| Behaviour | Desktop | Phone |
| --- | --- | --- |
| Answer toolbar: desktop has copy, 👍 good answer, 👎 bad answer and retry; the phone has copy only. Keys `goodAnswer` and `badAnswer` are not in the pin | `app.tsx:1759` | `App/Chat/Views/AnswerActionsRow.swift:10` |
| Seen accessibility words: desktop says `seenBy(N)` in every chat but the assistant's; the phone's row label says it only in groups | `send-state.tsx:52` | `App/Chat/Views/ChatRowView.swift:178` (shared lane) |
| "đã sửa" time tooltip (`editedAt` is not in the pin). When the edited message does not end its run, desktop puts "đã sửa" on its own line apart from Seen/Sent; the phone keeps one line | `app.tsx:1507`, `:1663` | `App/Chat/Views/DeliveryLine.swift` |
| Failed send line (TL-6, copy missing, see above) | `src/matrix/message-actions.tsx:487` | `App/Chat/Views/DeliveryLine.swift` (`.failed`) |
| My agent answering in a group: desktop gives every answer its time and hides its "đã sửa"; live phone groups carry no agent IDs, so these get run-end times and still say "đã sửa" | `app.tsx:1115`, `:1153` | `App/LiveAppModel.swift:3316` |
| Day labels: desktop uses Today/Yesterday, else the long weekday and date; the phone uses the weekday alone for 2–6 days ago | `src/matrix/message-time.ts` `matrixDayLabel` | `Sources/AtumChat/DayLabel.swift:31` |

Seen faces keep the phone's Kit shapes (people are circles, apps squircles). That is
ruling 2 (TL-8), and it is decided, not a gap.

Copy keys missing from the pinned export (`atum-design.lock`), all under
`src.matrix.chat-copy.copies.`: `goodAnswer`, `badAnswer`, `notSentOffline`,
`tryNow`, `editedAt`.

## Verification

- `swift test --filter AtumChatTests` (`-j 2`, under the heavy-build lock): 655 tests,
  0 failures, on the tree rebased onto main 161a732 (621 before the rebase). New: `TimelineParityTests`. Updated or extended: `DeliveryS1Tests`,
  `TransientLinesTests`, `TypingTests`, `GroupingTests`, `BubbleGroupingTests`,
  `ProjectionS1Tests`.
- `xcodebuild` Debug, iOS Simulator (arm64), AtumMobile scheme: build succeeded,
  before and after the rebase.
- Scripted captures (vi, light and dark) of `chat.timeline-parity` and `chat.kinds`
  with `-AtumScriptedPhotos`. "Before" is main 77ab08f plus only the Debug scenario and
  host patch. Files are in `.scratch/timeline-parity/` (local only, not committed).
- Launch note: a cold launch of the Debug app on the simulator can take over 15 s
  before the chat appears. One sample caught the main thread waiting in the Swift
  conformance lookup behind an AttributeGraph worker. Captures therefore start the
  scripted clock 30 s after launch (`-AtumScriptedStartAt`). Build the simulator app
  with `-destination id=<sim> ARCHS=arm64`, because the Matrix SDK library is
  arm64-only and a generic simulator build fails to link x86_64.
- Not run: UI tests (the XCUITest suites). `S1MatrixUITests.testBotRoom` and
  `ComposerAndMenuUITests` already check the composer typing line. The answer Copy
  button keeps its `answer.copy` identifier.

## Review follow-up (cross-family review of #38)

- Seen faces read one sender-profile index per projection (`Delivery.senderProfiles(items)`, built on the first Seen row), not a backwards timeline scan per Seen row.
- A reader's profile is taken whole from their newest message whose profile is known (a name or an avatar), so a photo they removed doesn't come back from an older message. A message with neither is an unavailable profile and is skipped. Regression test: `DeliveryS1Tests.testANewerProfileWithoutAPhotoWinsOverAnOlderPhoto`.
- Verified by `swiftc -parse` locally and the hosted `swift` check; the build lock was busy.
- CI (UI shard 2, `ChatKindsUITests.testContextMenuPreventsReadReceiptUntilDismissed`) caught that the delivery line's `accessibilityIdentifier` was stamped onto its children. The inline Copy button lost `answer.copy`, so the menu's "Sao chép" query also matched it and the menu looked like it never closed. The line now uses `.accessibilityElement(children: .contain)`, so the Copy button and Seen faces keep their own identifiers.

## Search-scan stall investigation (hosted UI shard 1, run before the 11 Nov main update)

- `HomeChatsWave3UITests.testSearchBarAtAccessibilitySizePassesTheAudit` saw "Searching 71 of 2200 messages…" after 15 s. The 2200 is `ChatHistorySearch.eventBound`; the `chat.search` scenario holds only 140 messages in 20-event pages, so the walk is a handful of passes, not a 2200-row scan.
- The #38 projection work is linear: Seen readers use one sender-profile index per pass, run times and edit marks are per-row lookups on a `Set`, `Delivery.marks` is one pass. Added `TimelineScanPerformanceTests` (2200 messages, 3 receipts on every message of mine, projected page by page as search does) to keep it that way.
- Same run, same build: `testSearchWithNoMatchSaysNoResultsInVietnamese` (walks all 140 messages) and `testSearchFindsAWordThreePagesBackAndCloses` passed. Only the AX-XXXL test failed, and every `chat.search.count` accessibility query in it took 2-4 s, so the runner was slow to answer snapshots (three shards plus other branches' runs were live at once). Treat the failure as runner load at the largest text size unless it repeats on a re-run.
- Measured (`swift test -j 2 --filter AtumChat`, debug): the page-by-page walk, 44 passes and 49,500 projected rows, takes 0.71 s; one 2200-row projection takes 0.03 s. All 658 AtumChat tests pass. The test bounds (20 s, 2 s) are deliberately far above that.

## Seen faces hit region (local `TranscriptUITests` audit, 12 Nov)

- `TranscriptUITests.testAccessibilityAuditAssistantChat` (LOCAL_ONLY, so hosted CI never runs it) failed with "Hit area is too small" on `delivery.seen`: the button was 16 x 20 pt.
- The button's label now pads the faces out to at least 44 x 44 pt (`ReaderAvatarMarks.hitSlop`, `minHit`), and negative padding outside the button hands the slop back. The line keeps its 20 pt row and the faces don't move. The before/after captures of `chat.actions` show the same layout; only the clock differs. The extra hit region reaches 12 pt above and below the line and 14 pt to each side, into empty space, not into another control.
- With the hit region fixed, the same audit flagged the faces' fixed-size monogram initials ("Dynamic Type font sizes are partially unsupported"). The button now gives assistive tech a plain button (`accessibilityRepresentation`), with its existing label, value and `delivery.seen` identifier. The faces are drawing.
- The audit test now asserts the Seen frame is at least 44 x 44 pt. The new `testSeenFacesAnswerATapOutsideTheDrawnFace` taps near the region's corner and expects the names popover (`delivery.seen.names`).
- Still open, not in #38's diff: with those two fixed, both `testAccessibilityAuditAssistantChat` and `ChatKindsUITests.testAccessibilityAuditKinds` stop at a contrast finding on quote-preview text (`QuoteView`, muted on the bubble). `continueAfterFailure = false` had hidden it behind the first finding.
- Verified locally (iPhone 17 simulator, under the heavy-build lock). Pass: `testSeenFacesAnswerATapOutsideTheDrawnFace`, `ChatKindsUITests.testEveryKindShows`, `ChatKindsUITests.testContextMenuPreventsReadReceiptUntilDismissed`, `ComposerUITests.testU4SendIsInstantLiteralAndKeepsTheKeyboard`. The Seen frame went from 16 x 20 to 44 x 44 pt. The two audits now fail only on the quote contrast above.
- `ComposerUITests.testTheModelSheetListsTheAccountSubscriptions` fails with "no Subscriptions section" both on this branch and on origin/main d37e008, so the cause is not in #38.
