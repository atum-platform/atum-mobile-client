# Polish P7: the time in the bubble's corner

Lane P7 of the iPhone polish wave covers UX polish audit issue 4, which the
owner approved on 28 Nov 2026. Each chat bubble had a timestamp/caption row
under it. The phone now draws the time where desktop already draws it: inside
every bubble's corner. Desktop has had this since `1b035c601` (18 Nov 2026,
`timeEligible` and `bubbleMeta` in `apps/desktop/src/matrix/app.tsx`,
`.matrix-bubble-meta` in `styles.css`). Desktop itself does not change here.
This lane brings the phone to desktop as rendered (reference: desktop `main`
`69185d92`). The meaning is the same: the same times, edit marks and delivery
marks, and every bubble's VoiceOver label still says its time.

The branch is `feat/polish-p7-timestamps`, from `main` at `f923168`, merged
with `main` at `236b918` for review r2.

## What changed

| Before | After |
| --- | --- |
| `DeliveryLine` sat under the last bubble of every run with "14:05 · đã sửa", and under every answer of my agent. | The time and "đã sửa" sit **inside the bubble's trailing corner** (`BubbleMeta`), on **every settled bubble** (desktop `timeEligible`): not sending, not failed, not undecryptable. Team-space flat runs keep the run header's time. |
| My message showed a clock under it while sending. | While sending, the corner shows **the time with a clock glyph after it** (desktop app.tsx 1273-1287). When the message settles the clock goes and the time stays, so the bubble keeps its size. |
| `DeliveryLine` held the time, the edit mark and the delivery mark. | `DeliveryLine` holds only **"Chưa gửi được" (failed) and the Seen faces**. A flat run's sending clock and "đã sửa" stay there too, since a flat run has no corner. A message that sends and settles unread draws no line at all, so its row never changes height. |
| The newest answer in an assistant or app chat had its own Copy icon (`answer.copy`, `LatestAnswerCopyRow`). | Removed. The long-press menu's "Sao chép" (`MessageMenuRules.items`) is the only Copy. |

### Projection (`ios/Sources/AtumChat/Grouping.swift`)

- `RowGrouping.showsTime` is `Grouping.showsTime(item)` on every bubble, not
  `position.endsRun`. Runs (`runGap`, `continuesRun`) still decide sender
  lines, faces and corner shapes, but not the time.
- A deleted message keeps its time, mine included, because desktop draws the
  corner after `MatrixDeletedMessage`. Undecryptable placeholders show none.
- `RowGrouping.showsEdited` (TL-5) still decides "đã sửa".
- VoiceOver: `ChatRowText.speech` is unchanged. The corner and its room are
  hidden from accessibility.

### Placement (`ios/App/Chat/Views/BubbleMeta.swift`), as desktop does it

- **The room.** Desktop ends the last text run with an invisible `::after`
  spacer as wide as the corner (`--matrix-meta-room`, styles.css 3816-3827).
  The phone does the same with `BubbleMeta.room`: an `AttributedString` of the
  corner's own characters in the corner's font, coloured clear. It is a
  breakable space, a figure space of air, the corner glued with no-break
  spaces, and three figure spaces for the sending clock. It is appended to:
  - my plain text, also when search highlights it;
  - the last block of a person's markdown, when that block is a paragraph,
    heading, list item or continuation (`NativeRichText.endsInText`);
  - an image caption;
  - a placeholder.

  If the last line has room, the corner stays beside the last word. If not,
  the spacer wraps and takes the corner to a line of its own. Every other line
  keeps the bubble's full width. The old layout narrowed every line by the
  corner's width, which caused about 70% wraps in the chat-actions
  screenshots.
- **The corner** (`BubbleCornerLayout`). `.inline` places the meta over that
  room, baseline to baseline with the content's last line. `BubbleStack` now
  reports its last part's `lastTextBaseline` through `explicitAlignment`. The
  meta sits at the trailing edge, or at the leading edge when the last
  paragraph is right to left (`BubbleMeta.endsRightToLeft`: Hebrew or Arabic
  first strong letter), because that is where an RTL last line ends.
  `.row` gives it a line of its own under the content. This matches desktop's
  `data-matrix-meta-flow='row'` and is used for a code block, table, quote or
  rule last, a fold toggle, Bot API buttons, or a file card without media.
- **Files.** A media file card puts the corner at the far end of its second
  (kind) line, as desktop's `MatrixFileCard` puts it on the size line
  (`MediaFileContent.meta`).
- **Photos** without a caption: `ink` on a `glass` capsule in the corner.
- **Layout cost.** Neither layout narrows or re-measures content for the
  corner. Both `BubbleCornerLayout` and `BubbleStack` cache their frame by
  the offered width and by the resulting width, because SwiftUI re-offers a
  bubble its own width. They place with the frame worked out while sizing.
  The old single-width `BubbleStack` cache thrashed between the two widths.
  The transcript is an eager `ScrollView` + `VStack` (`TranscriptView`), so
  this runs for every row.
- **Type and spacing.** `.caption2` with tabular digits (desktop 11 px), 3 pt
  between parts (desktop `gap: 0.1875rem`), no "·" separator. The corner is
  inset `s3` from the side; on its own row, `s2` from the bottom.
- **Colours.**
  - On my bubble: `on-bubble-own` at 0.66, desktop's own-bubble opacity.
    Against `bubble-own` that is about 7.9:1 in light and 5.2:1 in dark.
    Desktop's own-bubble inks are changing on its `feat/dark-own-bubble`
    branch; recheck when that lands.
  - On a person's bubble: Kit `ink-4` (#8A8F98 / #6E737C), the closest token to
    desktop's `--atum-ink-faint` (#9096A0 / #666B74). That is about 3.2:1 in
    light and 3.4:1 in dark, slightly above desktop's 3.0:1.

### Deferred / differences kept

- If a message both failed and was edited, the corner shows "đã sửa" alone.
  Desktop shows that "edited" outside the bubble. The phone has no separate
  edited line for bubbles.
- Desktop gives a bot's text or a Chief of Staff answer card the `row` flow.
  The phone keys `row` on Bot API buttons and on non-text last blocks only.
- The RTL check uses the last paragraph's first strong letter, which is the
  base direction SwiftUI's text uses. Mixed-direction paragraphs follow that
  rule.

## Tests

- `GroupingTests`:
  - `testEverySettledBubbleCarriesItsOwnClockMineIncluded`
  - `testMyAgentsAnswersAndAnAppsMessagesCarryTheirTimeLikeAnyone`
  - `testADeletedMessageKeepsItsTimeMineIncluded`
  - `testNoClockWhileSendingFailedOrUndecryptableAndNeverOnNotices`
    (unchanged)
- `BubbleGroupingTests`: every bubble's `showsTime` is true.
- `ProjectionS1Tests`: every bubble's `showsTime` is true.
- `S6PresentationTests`:
  - `DeliveryLine.shows` drops a bubble's sending clock and keeps a flat
    run's.
  - `BubbleMeta.shows` while sending, also inside a run, and not when failed.
  - `BubbleMeta.endsRightToLeft`.
- UI tests:
  - `ScriptedSendReceipt.assertUnread` now asserts that a settled unread
    bubble has no `delivery.line.<id>` at all. It used to look inside a line
    that no longer exists, so it passed vacuously.
  - The dead `answer.copy` exclusions are gone from `S1MatrixUITests`,
    `ChatKindsUITests` and `ComposerAndMenuUITests`.
- New scripted scenario `chat.corners`, a 1:1 with Huy. It has, in order:
  - a photo without a caption;
  - my photo with a caption;
  - a file card;
  - a deleted message;
  - "Ok", then a wrapped Vietnamese message;
  - Arabic, then Chinese;
  - my edited message, then my Hebrew message;
  - a failed message, then one still sending.

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
- 2026-11-28 review r1 (Opus) findings fixed in r2:
  1. Every settled bubble carries its time (desktop `timeEligible`).
  2. The sending clock is in the corner.
  3. The desktop-style room replaces the narrowed lines, which also fixes
     RTL placement (finding 9).
  4/5. Caches by offered and resulting width, and placement from the sizing
     frame.
  6. `ink-4` / 0.66 inks.
  7. The `chat.corners` scenario.
  8. The "·" is gone.
  10. The unread assertion is no longer vacuous, and the `answer.copy`
     exclusions are removed.

  Verification:
  - `swift test` (all 822) exit 0.
  - `design_lint.py` exit 0.
  - `swiftc -parse` of every changed Swift file exit 0.
  - `git diff --check` clean.
  - The app could not be type-checked outside the heavy-build lock, which
    was held. The r2 locked run (`locked-run.sh`, launchd
    `io.atum.lock.p7r2`, log `logs/run-r2.log`, screenshots in `screens/r2/`)
    covers the Debug build, `S6PresentationTests` and light/dark/AX-L shots
    of `chat.people`, `chat.bubbles-group`, `chat.actions` and
    `chat.corners`.
