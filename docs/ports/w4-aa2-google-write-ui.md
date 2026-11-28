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
| `pending` | open, actions as `canDecide` and the approval restrictions below | question, fields, `approve` where supported, `decline` |
| `deciding(.approve)` | open, both disabled, spinner on Approve | `approving` ("Approving…") |
| `deciding(.decline)` | open, both disabled | `declining` ("Declining…") |
| `reconciling` | open, both disabled, no busy word | (nothing is known to be in flight) |
| `failedRetryable` | open, actions as `canDecide` | `retry` under the actions |
| `approved` / `declined` / `superseded` / `changed` | one line: summary + state | assistant `approved`…`changed`; Work `work.approved`…`work.changed` |
| `closed` / `expired` | one line | assistant `closed`; Work `work.expired` (desktop folds the two the same way) |
| `outcomeUnknown` | one line | pinned `Unknown` when a Work proposal disappears after an ambiguous decision |
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
3. **Work Gmail mailbox actions and draft replacement are Decline-only.** The
   card uses the pinned "Needs your OK on your Mac" line. The store also
   rejects an attempted phone approval before calling Shell.
4. **Explicit Calendar clears get removal rows.** An omitted field has no
   row. A cleared location shows "Location" and "Clear". A cleared description
   uses the closest pinned field label, "Details", and keeps the proposal
   Decline-only until a precise description key is available. The same store
   restriction applies in chat and Work.
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
- Vietnamese uses the pinned vi strings for all 53 keys the card speaks.
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

- A Shell status contract is needed to recover the actual result after a lost
  receipt. When a successful list omits a Work proposal after an ambiguous
  decision, including a disappearance seen while the receipt was in flight,
  the phone settles it as `outcomeUnknown`. An explicit matching receipt still
  settles as approved or declined.
- A pinned "From Work on your Mac" line (decision 2).
- Desktop's delivered acknowledgement and typed approval (W4-AA1 open
  questions) are not on the phone.

## Review r1 consent fixes and W4-C9 handoff

- Calendar PATCH sends an explicit empty `location` or `description` and
  leaves omitted fields out of the body. See Shell `api-executor.ts:537–553`
  at platform `fd831c390`. The phone retains those differences in the existing
  card grid as typed removal values. The reused `desktop.common.clear` supplies
  the operation. The reused `desktop.atum.workspace.tabDetails` is a broader
  label than Calendar's description, so its removal stays Decline-only.
- Shell `work-proposals.ts:24–35` digests the mailbox request itself. Its
  permitted keys are the action, source, operation, target ID and optional
  labels (`matrix-google-tool-request.ts:125,372–392`). `gmail-mail.ts:453–480`
  operates on that exact message or thread ID. Desktop #134 at `583cd334`
  shows only the scope and optional labels (`google-write-card.tsx:226–234`).
  Phone approval requires a human-readable target summary bound to the
  proposal digest, such as subject with sender or snippet. The handoff copy
  directs the owner to the Mac, whose existing card has the same preview gap.
- Shell compares the regenerated outgoing draft preview with the confirmed
  payload (`api-executor.ts:508–535`). It carries the destination `draftId`.
  `gmail-compose.ts:715–719,757–781` replaces all MIME content with a Gmail
  `PUT`. Re-enabling phone approval requires a digest-bound revision of the
  existing Gmail draft that Shell verifies as a precondition to replacement.

Proposed desktop export keys for W4-C9, with English source text:

| Key | Proposed English | Current phone copy |
| --- | --- | --- |
| `shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.description` | Description | Details, Decline-only |
| `src.matrix.google-write-card-copy.copies.labels.cleared` | Will be removed | Clear |
| `src.matrix.google-write-card-copy.copies.work.approvalOnMac` | Open Atum on your Mac to review this request. | Needs your OK on your Mac |
| `src.matrix.google-write-card-copy.copies.work.outcomeUnknown` | We couldn’t confirm what happened to this request. | Unknown |

## Verification

### Review r1 fixes

- The locked package test filter covers `GoogleWriteCardPresentationTests`,
  `GoogleWriteProposalDecoderTests`, `GoogleWriteProposalStoreTests` and
  `AtumCopyTests`, followed by a Debug arm64 build for the iPhone simulator.
  Local evidence is under `/Volumes/AtumTestFlight/w4-aa2-r2/`.
- The focused regressions cover omission versus explicit removal, the
  Decline-only presentation and dispatch path, and an ambiguous Work outcome
  when the proposal disappears before or after the receipt is lost.
- Design lint passed with 601 baseline findings, all 10 lint tests passed,
  the desktop export pin verified, all 13 copy and project-source checks
  passed, and `git diff --check` passed.

### Original port

- Focused package tests: `GoogleWriteCardPresentationTests` (8 cases) cover
  the email and event blocks, busy, reconciling and retry phases, the settled
  lines for each source, summaries, unsupported proposals, all 49 card keys in
  en and vi with zero arguments, and time and size formatting.
- Light checks, unlocked: `tests.test_copy_keys_in_pin` and
  `tests.test_ios_project_sources` (13 tests) pass. The design lint reports no
  new findings (601 baseline findings in 46 files). `git diff --check` is
  clean. `python3 scripts/public_guard.py --base origin/main --head HEAD`
  exits 0.
- Locked run 1 (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock
  /Volumes/AtumTestFlight/w4-aa2-locked.sh`, scratch and DerivedData under
  `/Volumes/AtumTestFlight/dd-w4-aa2`, packages under
  `/Volumes/AtumTestFlight/spm`): `swift test` exited 0, with 1,979 XCTest
  cases passed and 0 failed. The Debug `build-for-testing` failed in the
  gallery: it called `GoogleWriteAttachment`'s memberwise init, which is not
  public. The gallery now decodes the attachment from wire JSON.
- Locked run 2: `build-for-testing` exited 0, producing an arm64 simulator
  app. The 48 screenshots showed the cards correct in place. In the assistant
  chat the card sits above the composer and scrolls within its bound. On Home
  the Work card renders at AX5. Some captures were launch frames. The
  default-size Home capture had no Work card, because Home read the store
  inside its List closure and missed a list that arrived after the first
  frame. Home now reads the store in its own body.
- Locked run 3 (package unchanged, so `SKIP_SWIFT=1`), at `ac6c226`:
  `build-for-testing` exited 0, producing an arm64 simulator app. All 48
  screenshots drew content, with longer waits and retakes of blank frames. Home
  now shows Work's card at the default size in both schemes. Shots are
  in `/Volumes/AtumTestFlight/w4-aa2-shots/`: `gallery-{open,busy,settled,work}`,
  `chat` and `home`, in `{en,vi}` × `{light,dark}`, plus `ax5-` variants.
  No UI test was added. The scripted hosts and the gallery serve the
  screenshots, and the hosted shards stay the UI evidence.
