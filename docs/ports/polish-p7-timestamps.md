# Polish P7: the time in the bubble's corner

Lane P7 of the iPhone polish wave covers UX polish audit issue 4, which the
owner approved on 28 Nov 2026. Each chat bubble had a timestamp/caption row
under it. This change is phone-only and changes only where things are drawn.
Desktop is unchanged. The meaning is the same: the same times, edit marks and
delivery marks, and every bubble's VoiceOver label still says its time.

The branch is `feat/polish-p7-timestamps`, from `main` at `f923168`.

## What changed

| Before | After |
| --- | --- |
| `DeliveryLine` sat under the last bubble of every run with "14:05 · đã sửa", and under every answer of my agent. | The time and "đã sửa" sit **inside the bubble's trailing corner**, Telegram-style (`BubbleMeta`). |
| My agent's answers each carried a time (desktop's answer toolbar). | One clock per run for everyone, my agent included. The clock shows on the **last bubble of a sender's run**, so it reappears after a change of sender or a gap of more than 5 minutes. |
| `DeliveryLine` held the time, the edit mark and the delivery mark. | `DeliveryLine` holds only the **sending clock, "Chưa gửi được" (failed) and the Seen faces**. A settled message nobody has read draws no line. |
| The newest answer in an assistant or app chat had its own Copy icon (`answer.copy`, `LatestAnswerCopyRow`). | Removed. The long-press menu's "Sao chép" (`MessageMenuRules.items`, which already offered Copy on every text message) is the only Copy. |

### Reused, not rewritten

- The runs come from `Grouping.layout` (`ios/Sources/AtumChat/Grouping.swift`).
  `runGap` (5 minutes, desktop `MESSAGE_RUN_MS`) is at :88 and `continuesRun`
  (same sender, same day, at most 5 minutes apart) is at :178. `RunPosition.endsRun`
  is at :18. The only projection change is that `showsTime` is now
  `position.endsRun` alone (:152); the "every answer of my agent" exception is
  gone. The unused `Grouping.isAnswer` went with it. The menu's own
  `MessageMenuRules.isAnswer` is untouched.
- `RowGrouping.showsEdited` (TL-5) still decides "đã sửa". It shows on every
  edited bubble, not only at the end of a run.
- VoiceOver: `ChatRowText.speech` already gave every bubble's label its sender,
  time, edit and delivery. It is unchanged, and the corner meta is
  `accessibilityHidden`.

### Placement (`ios/App/Chat/Views/BubbleMeta.swift`)

- `BubbleMetaLayout` takes the bubble's content and the meta.
  - If the content keeps its line count with the meta's width taken off the
    right, the meta sits on the last line, baseline to baseline, and the bubble
    widens by the meta. This only applies to plain text, or a caption, with
    nothing under it.
  - Otherwise the meta takes its own row under the content, at the trailing
    edge. The content is always measured with room taken out for the meta, so
    the meta never covers a word, at any text size, AX sizes included.
  - This approximates Telegram: when a multi-line message's last line is short
    but an earlier line is near full width, the meta drops to its own row
    rather than sharing the last line.
- Spacing comes from Kit tokens: a gap of `s2` before the meta, an inset of `s3`
  from the trailing edge, and `s2` from the bottom on its own row. The font is
  `.caption2` with `monospacedDigit`.
- Colours:
  - On my bubble, `on-bubble-own` at 70% (8.8:1 light, 5.7:1 dark against
    `bubble-own`).
  - On a person's bubble, the chat's quiet `soft` (`ink-2`, about 10:1).
  - On a photo with no caption, `ink` on a `glass` capsule over the system
    thin material.
- Kinds:
  - Text and quoted text: inline or own row.
  - Placeholders (deleted, can't decrypt): inline or own row, inside the
    stroke.
  - Image captions: inline or own row.
  - Photos and image boxes: a capsule in the corner.
  - File cards: own row inside the card. The card's fill moved out to the
    layout, so the time is inside the card.
  - Team-space flat runs (no bubble): unchanged. The time is in the run
    header, and "đã sửa" stays in the line under the run.
- Bubbles with a fold toggle or Bot API buttons put the meta on its own row
  under them.
- While my newest message sends, its clock's place in the corner is kept but
  empty (`BubbleMeta.keepsTimeSlot`). The bubble does not grow when the message
  settles, and the clock fades in (`Motion.quick`).

### Known trade-off

The line under my message now appears and disappears with its state:
clock → nothing → Seen faces. Before, it was always there with the time in it.
The bubble itself keeps its size, but the row is a line's height shorter while
the message is sent and unread. The alternative was to draw the sending clock
in the bubble's corner, Telegram-style. It was left out because the brief keeps
sending in `DeliveryLine`.

## Tests

- `GroupingTests.testMyAgentsAnswersCarryTheirTimeOnlyAtRunEndLikeAnyone`
  replaces the every-answer test. It covers one clock per run and the clock
  returning after a gap of more than 5 minutes.
- `BubbleGroupingTests.testAnAppsChatLaysOutExactlyLikeAPersonsAndMyAssistants`:
  the assistant chat now lays out exactly like an app's.
- `S6PresentationTests`: `DeliveryLine.shows` holds only the delivery mark
  (plus a flat run's "đã sửa"), `BubbleMeta.shows`, and the kept clock slot.
- UI tests are not changed. They only excluded `answer.copy` from menu
  queries, so the exclusion is now a no-op.

## Verification

See the session log at the end of this file.

## Session log

- 2026-11-28: implemented. Design lint OK (baseline locked in: the removed copy
  row took one padding and one font size with it).
- 2026-11-28: self-review fix. An image caption now spans the card, so its
  corner time sits in the card's corner and not right after a short caption.
- 2026-11-28: self-review fix. `BubbleStack` is a custom `Layout` and reports
  no text baseline. When the content reports none, the inline meta's bottom
  now meets the last line's box instead of the bubble's bottom edge.
- 2026-11-28 verification:
  - Design lint OK.
  - `swiftc -parse` of every changed Swift file OK.
  - `public_guard.py --base origin/main --head HEAD` exit 0.
  - `git diff --check` clean.
- The one locked run (`/Volumes/AtumTestFlight/polish-p7/locked-run.sh`:
  AtumChatTests, Debug simulator build, `S6PresentationTests`, and light/dark/
  AX-L screenshots of `chat.people`, `chat.bubbles-group` and `chat.actions`)
  was queued at 15:18 +07. At 16:44 +07 it was still waiting on the heavy-build
  lock. Its results will land in `/Volumes/AtumTestFlight/polish-p7/logs/`
  (`run.log` ends with an `EXIT swift=… build=… apptests=… shots=…/9` line) and
  `/Volumes/AtumTestFlight/polish-p7/screens/`. Not run yet: compile, unit
  tests, screenshots. UI tests are left to the hosted shards.
