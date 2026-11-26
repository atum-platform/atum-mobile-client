# W4-AA2 Google write cards

Atum for iPhone draws the owner's Google write proposals as native cards, for
parity with desktop #134 (`apps/desktop/src/matrix/google-write-card.tsx`,
`google-write-card-copy.ts`, and their tests at atum-desktop `583cd334`). The
cards read the W4-AA1 store (`docs/ports/w4-aa-google-proposals.md`), which
owns the list, each decision's lifecycle, reconciliation of ambiguous results,
and when the actions are disabled. The words come from the wave 4h pin
(`docs/ports/w4-copy-repin-7.md`).

## What the owner sees

**In an assistant's chat**, the room's cards sit above the composer, in the
same column as desktop's. They scroll within at most 45% of the chat's height,
so a long draft at AX5 never pushes the composer off screen. They are drawn
only in an assistant chat with a composer (`store.kind == .assistant` and no
read-only banner). Search replaces the composer, so it hides the cards too.

**For Work**, the cards sit at the top of Home, above Assistants. The phone has
no Work page (decision 1). They give way to search results while a search is
open.

An open card shows its kind's mark and question, then the field grid, then the
reply note, the body and the quoted original. Approve is the kit's primary
capsule and Decline is the plain one. Drafts are shown with
`Text(verbatim:)`, so line breaks are kept and markdown is never parsed.
Identifiers (`sourceId`, `eventId`, `draftId`, `threadId`, `messageId`) are not
shown, as on desktop.

| Store state | Card | Words |
| --- | --- | --- |
| `pending` | open, actions as `canDecide` | question, fields, `approve`, `decline` |
| `deciding(.approve)` | open, both disabled, spinner on Approve | `approving` ("Approving…") |
| `deciding(.decline)` | open, both disabled | `declining` ("Declining…") |
| `reconciling` | open, both disabled, no busy word | (nothing is known to be in flight) |
| `failedRetryable` | open, actions as `canDecide` | `retry` under the actions |
| `approved` / `declined` / `superseded` / `changed` | one line: summary + state | assistant `approved`…`changed`; Work `work.approved`…`work.changed` |
| `closed` / `expired` | one line | assistant `closed`; Work `work.expired` (desktop folds the two the same way) |
| `unsupported`, or an unsupported source or kind | nothing | desktop's strict reader drops these |

The settled summary follows desktop `summary`: a message's subject, an event's
title, a label's name, a mailbox change's labels, or the mailbox question
without its question mark.

The pure mapping is `GoogleWriteCardPresentation`
(`ios/Sources/AtumNativeAPI/GoogleWriteCardPresentation.swift`). The SwiftUI
card and the surface binding are in `ios/App/Chat/Views/GoogleWriteCard.swift`.
Each surface registers with `setVisible(_:for:session:)`, using the session
captured when it appeared. It registers again when the store's session changes.
The chat passes its newest event ID to `hintAssistantMessage`. A decision sends
the card ID captured from the projection the owner tapped.

## Decisions

1. **Work placement: top of Home.** Desktop draws Work's card above the Work
   view. The phone has no Work page. Home is the root the owner returns to, and
   its bell is already the place the app asks the person to act. The cards sit
   in Home's list, so they scroll away with it.
2. **Provenance line omitted.** Desktop's `work.source` says "From Work on this
   Mac" ("Từ Work trên máy Mac này"). That is false on a phone. No pinned key
   says "From Work on your Mac". The closest pinned line,
   `model-picker-copy.COPY.chatgptInWork` ("Your plan works in Work on your
   Mac"), names a plan, not where a request came from. So the phone omits the
   line and invents no copy. On Home a Work card is still distinguishable: it
   speaks Work's own settled lines, and Work alone asks for draft, label and
   mailbox changes. Gap: desktop should export a phone line for "From Work on
   your Mac" (en and vi); the phone can then draw it under the question.
3. **No Mac hand-off.** A Work approval is carried out by Shell, and its outcome
   goes back to Work. Desktop's card says only "Approved." and offers nothing to
   continue on the Mac, so the phone offers nothing either. "Open Atum → Work on
   your Mac to continue" is not pinned. It would be needed only if a later wave
   adds a Work step that has to finish on the Mac.
4. **A cleared Calendar location or description draws nothing**, as on desktop
   (`draft.location && …`). The W4-AA1 store types it as `cleared`, but no
   pinned key says "will be removed". Gap: once desktop shows it, the phone
   should show it with the same words.
5. **Reconciling shows no words.** Desktop has no such state: its unavailable
   answer returns to pending with "Couldn't reach Atum. Try again." The phone
   store holds an ambiguous decision disabled until a read proves the outcome.
   Showing "Try again" over disabled buttons would mislead the owner, so the card
   stays open and quiet. `failedRetryable` shows the retry line with the actions
   live.
6. **Time and size formatting.** Start and end use the app language's locale,
   medium date and short time, in the device time zone. That zone is the one
   the phone reports as the owner's. A value that is not RFC 3339 shows as
   written. Attachment sizes use decimal units with at most one decimal, as on
   desktop. Foundation's byte unit word can differ slightly from `Intl`'s.
7. **Glyphs.** Desktop's `Calendar`, `Inbox` and `Tag` map to the phone's
   existing Phosphor aliases `StoreCalendarBlank`, `StoreTrayArrowDown` and
   `StoreTag`, added as `AtumGlyph.calendar`, `.inbox` and `.tag`. Mail and
   draft use `.mail` and `.pencil`. No assets were added.

## Accessibility and appearance

- Dynamic Type: at accessibility sizes each label stacks over its value, the
  actions stack vertically, and the settled summary wraps instead of
  truncating.
- VoiceOver: each card is a container named by its question (desktop's
  `aria-label`), with the question as a header. A busy card's value is
  "Approving…" or "Declining…". Each grid row reads as one element. A settled
  line or the retry line is announced when it appears (desktop's
  `role="status"`). Marks are hidden.
- Colors are kit roles only: an open card is `surface` with elevation one, a
  settled card is `sunk`, labels are `ink-3` and the quote rule is `line`. Both
  schemes come from the token export. The design lint has no new findings.
- Vietnamese uses the pinned vi strings for all 49 keys the card speaks.
  Japanese and Chinese fall back to English for the card keys, as desktop
  does.

## Debug seams

- `-AtumScripted google-write.gallery -AtumGoogleWritePage open|busy|settled|work`
  draws every state from synthetic projections (desktop's
  `work-google-write-gallery`). It is Debug only (`ScriptedGoogleWriteGallery.swift`,
  excluded from Release by `Scripted*.swift`).
- `-AtumScriptedGoogleWrite` binds the real `GoogleWriteProposalStore` to a
  synthetic feed. The feed holds one assistant email for the scripted chat
  (`-AtumScripted chat.long`) and one Work mailbox change for Home
  (`-AtumScripted home.roster`). Their digests were computed with the
  platform's canonical JSON, checked against the W4-AA1 test digests, so they
  verify as pending. A decision is accepted after one second and leaves the
  list.

## Follow-ups (not in this slice)

- From review r2 of W4-AA1: a lost Calendar create receipt can show as
  "expired". If the create succeeded but its receipt was lost, Shell removes
  the proposal, and the next list settles the card as expired for Work (closed
  for an assistant). A Shell status contract is needed to tell those outcomes
  apart.
- A pinned "From Work on your Mac" line (decision 2) and pinned words for
  cleared Calendar fields (decision 4).
- Desktop's delivered acknowledgement and typed approval (W4-AA1 open
  questions) are not on the phone.

## Verification

See the session status at the end of this file.
