# Wave 4 one read signal

Port of desktop #89, "one read signal — drop the check marks, keep the seen
avatar" (atum-desktop merge `9259f675`). Owner rule (2026-11-19): the readers'
faces and the ticks said the same thing twice, so a bubble says "read" only
through its readers' faces. A message nobody has read yet shows just its time,
as in any messaging app.

## Adopt before build

This is a removal inside existing phone code; nothing new was built.

| Desktop | Phone |
| --- | --- |
| `send-state.tsx`: `matrixReceiptTick` and `MatrixReceiptTick` (Sent check with sr-only "Sent", double tick once read) removed | `DeliveryMark.sent` removed from `ios/Sources/AtumChat/Delivery.swift`; `Delivery.marks` no longer marks my newest settled message |
| `app.tsx`: the bubble corner keeps the time, "edited" and the sending clock only | `ios/App/Chat/Views/DeliveryLine.swift` drops the `.sent` case (check + "Đã gửi"); the line keeps time, "đã sửa", clock, failed mark, Seen faces and Copy |
| The read state stays announced through the faces' `aria-label` ("Seen"/"Seen by N") | `ChatRowText.delivery` no longer speaks "Đã gửi"; the bubble label and the `delivery.seen` button still say "Đã xem"/"Đã xem · N" |
| `chat-copy.ts`: `sent` kept for the forward dialog's button, commented as never a receipt | `ChatCopyKey.sent` kept with the same comment; the phone has no forward dialog using it yet. No copy repin |

`ChatDelivery.sent(eventID:)` (the item's server state) is unchanged: it still
settles a send, ends the clock and carries the event ID.

The separator logic needed no change: `DeliveryLine.shows` and the "·" joins
only count drawn parts, so a settled unread message in a flat team-space run
draws no line, and in a bubble run draws just its time.

## Tests

- `DeliveryS1Tests`: no `.sent` mark after settle in assistant, bot, person and
  group rooms; Seen faces where a receipt sits; clock while sending; failed
  mark unchanged.
- `ConversationCoreTests`: a retried send that the server accepts ends with no
  mark.
- `S6PresentationTests.testABubbleSaysReadOnlyThroughItsReadersFaces` (AppTests):
  the row's spoken delivery and `DeliveryLine.shows` for settled, sending,
  failed and seen rows.
- `ComposerAndMenuUITests` U4/U4b and U5: settle is detected by the clock and
  failure leaving, never by "Đã gửi"; Seen arrives with the `delivery.seen`
  faces.
- `S1MatrixUITests.testSendThenSeen`: sending, unread and seen screenshots per
  cell, asserting no "Đã gửi"/"Sent" in the bubble label.

## Known difference

Desktop draws the time inside the bubble's corner (#82); the phone keeps it on
the quiet line under the bubble. That predates #89 and is out of this scope;
the read signal itself (faces only, no ticks) now matches.

## Verification

- Run 1: `swift test --package-path ios` passed 748/748. Debug
  `build-for-testing` failed: in U4 a local `settled` flag shadowed the
  `settled(_:_:)` helper. Renamed the flag; run 2 reruns the build and tests.
- Run 2: Debug `build-for-testing` passed. AppTests `S6PresentationTests`
  passed 8/8. The S1 matrix (`testSendThenSeen`, `testFailedSendSheet`) passed
  in vi-light, en-light and en-dark. In vi-dark `testSendThenSeen` failed "no
  Seen": the wait was scoped to `row.latest`, and on the slow run Atum's answer
  (about 7.6 s after the send) became the newest row first. The test now finds
  my message by its unique text in the transcript. The composer UI tests ran
  0 tests because the verify script named the wrong class (`ComposerUITests`).
  Run 3 reruns both.
- Run 3 (after a Mac restart): build passed. U5 retry and parked-retry
  passed; U4 failed "Seen once Atum's receipt lands" for the same
  `row.latest` race (the Seen wait began about 9 s after the send). U4b now
  scopes to the sent bubble in the transcript. The matrix passed in vi-light
  and en-light. Both dark cells failed at the existing 3 s keyboard wait,
  before the send. That wait is now 10 s.
- Lane rule from 2026-11-23: no UI tests locally. The hosted PR shards run U4
  and the S1 matrix. Run 4 is the slim lane only: `swift test --filter
  "AtumChatTests|ChatCopyContractTests"` and Debug `build-for-testing`.
