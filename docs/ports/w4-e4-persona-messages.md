# Wave 4 E4: persona edits merge by field, keep headings, hint at length

Branch `feat/w4-e4-persona-messages`, base `main` `1f48fb1`. Desktop
reference: atum-platform/atum-desktop PR #95 ("Agent card: field-level merge
on save, round-trip headings, quiet length hint", merge `1ede9f94`), which is
in both the copy pin `46f5a518` and desktop `main` `635c1ae4`. The desktop
files are `apps/desktop/shared/matrix-assistant-persona.ts` and
`apps/desktop/src/matrix/assistant-card/{assistant-card,persona-fields,copy}.tsx`.

## What changed

### Field-level merge (`AssistantPersonaMerge`, AtumChat)

Before this change the card rendered every draft together (`who`, `what` and
`instructions`) on the base it held. Any revision conflict showed the generic
"changed elsewhere" band with Retry, and that retry could restore stale text
in the other field.

The phone now does what desktop does:

- A persona edit is a field delta: `before` (the field's last confirmed
  value) → `after`. It is rendered against the **latest confirmed
  definition** when it is sent (`AssistantPersonaMerge.prepare`):
  - the latest field already says `after` → nothing is written;
  - the latest field is no longer `before` (it changed elsewhere), or the
    persona changed shape (template ↔ custom) for the main field → nothing
    is written. The band shows desktop's `personaConflict` line, with no
    Retry, and that field shows the latest version;
  - otherwise only that field is rendered into the latest soul.
- A revision conflict (`.conflict(latest)`) confirms the newer definition
  and prepares again once. After a second conflict, a write that is still
  needed shows the save-failed band with Retry, as desktop's `'conflict'`
  outcome does. A conflict without a newer definition is a failure.
- When the card confirms a definition (saved, or newer after a conflict),
  the field being settled takes the latest value. Every other field takes it
  only if the person has nothing pending there and is not typing in it. A
  conflict on one field never throws away the other field's edits.
- Name saves are unchanged. A name conflict still shows `changedElsewhere`
  with Retry, which matches desktop (`band.field` is unset for the name).

### Headings round-trip (`AssistantPersonaPolicy`, AtumChat)

This is a port of desktop's `markFieldHeadings` and `fieldBody`. An `## `
heading typed inside a field, including the template's own titles, is
written behind `<!-- atum:persona-heading -->` on the line before it. Parsing
does not treat marked headings as section boundaries, and the field shows
them without the marker. In a custom persona's main field, only the template
titles are marked. The owner's other sections stay plain and stay part of the
instructions.

The parser also now follows desktop's custom rules:

- A hand-written persona's `Who you are` sections are its personality. They
  are not part of the main field.
- The template is recognised by a heading plus `What you do`, or a heading
  followed directly by `Who you are`.
- Custom renders keep every byte they do not change (`renderCustomWho`,
  `renderCustomMain`, `appendSection`).

So a custom persona now shows the same two fields as desktop's
`PersonaFields`: its text, labelled with `purposeLabel` and
`purposePlaceholder` like any other main field, and the Personality row.
`AssistantCardLayout` gives `.custom` the `.instructions` and `.personality`
rows. Before this change it gave a single Instructions field.

### Quiet length hint

`AssistantPersonaPolicy.exceedsContextBudget(soul)` checks whether the soul
is longer than Hermes' shared `defaultMaxChars` (20,000, from
`hermes_cli/data/context-file-limits.json`). It counts Unicode code points
after trimming and normalising CRLF/CR to LF, as desktop does. When it is
longer, one muted footnote-style line (`longPersona`) appears under the
card's footnote. The phone cannot read the Hermes JSON, so the constant is
mirrored in `contextFileMaxChars`. The effective limit can vary by model or
profile, and desktop uses the same default.

### Review fixes

Two Codex review rounds, on `6894b2e` (r1) and `4395675` (r2). The r2
direction from the coordinator was the simplest safe behaviour, not a more
complete parser.

- **One parser, plus a guard.** The card shows and edits desktop's parse
  (`parsePersona`, which splits on any unmarked `## ` line). A second,
  fence-aware parse of the same text is used only to check it.
  - *Read.* `AssistantPersona.isAmbiguous` is set when the two parses
    disagree about any field, when a `Who you are` or `What you do` title
    repeats, or when a code fence is never closed (`fences`). Examples are a
    template title inside a code fence and two `Who you are` sections. An
    ambiguous persona is shown, but its fields are read-only. No exported
    copy key says why, so there is no message (see Copy below).
  - *Write.* `AssistantPersonaMerge.prepare` returns `.unsafe` and writes
    nothing in three cases: the latest persona is ambiguous, the assembled
    text is ambiguous, or either field would not read back exactly as
    intended. The draft stays and the band shows save-failed with Retry.
  - So a phone save never writes text that desktop reads differently. This
    covers an open fence typed into Personality swallowing Purpose, and
    clearing the first of two personalities promoting the hidden one. No
    desktop change is needed for this. Fenced template titles that someone
    types *into* a field still save: desktop's `markFieldHeadings` marks
    them, and both parses keep them inside the field. That is desktop's
    PR #95 marker unchanged, not a phone-only addition. The r1 fence-aware
    structure was replaced by this guard.
- **A newer draft survives an earlier save.** Each persona save remembers
  the draft it sent. On success, or when the latest already says it,
  `AssistantCardEdit.settle(_:submitted:)` moves the baseline forward,
  even while the field is focused. A draft typed after the send is kept for
  the next write.
- **A same-field conflict keeps a newer draft.** Say the phone sends A→B,
  the person types C, and the server already says D. If the field still
  holds what was sent, it shows D with desktop's conflict line, as before.
  If the person typed past it, C stays, the conflict line appears with
  Retry, and the field is *held* (`AssistantCardSaveBand.isHeld`): leaving
  it again writes nothing. Retry rebases C on D and writes it. Undo shows D.
- **Failures stay with their field.** `AssistantCardSaveBand` ties each
  failure to its field until that field is retried, settles, or is
  discarded. A save of another field does not clear it. A refused rename
  (too long, taken, reserved) shows under the name field
  (`assistant.card.name-refused`), not in the band, so it never hides
  another field's Retry.
- **Byte fidelity.** Renders keep every untouched slice exactly: CRLF,
  trailing spaces, and the text's final newline. A replaced field keeps the
  separator after it. A new boundary gets only the separator it needs, in
  the text's own line ending. The primary keeps its head and last section
  as written. Before this fix it rebuilt the head and trimmed the end.
- **BOM.** The length hint drops a leading U+FEFF before counting, as
  Hermes reads `SOUL.md` as `utf-8-sig` (`agent/prompt_builder.py`).

### Desktop follow-up

Desktop's `parsePersona` treats a template title inside a code fence, or
after an unclosed fence, as a section boundary. It also shows only the
first of two `Who you are` sections and drops the second on a Personality
edit. The phone avoids both by making such personas read-only. Desktop
should get the same guard, or fence-aware parsing, in its own change.

### Known gap (matches desktop)

The persona shape guard in `AssistantPersonaMerge.prepare` only checks the
main field's id: an edit to `what` or `instructions` is a conflict when the
latest persona's main field is the other one. A Personality (`who`) edit is
rendered into whatever shape the latest persona has. This is the same as
desktop's guard and is left that way on purpose.

## Copy

Both keys are in the vendored wave 4 export (`ios/Vendor/AtumDesign`, pin
`46f5a518`), and the card reads them through `AtumCopy`. Neither needs a
pending fallback.

| Key | en |
| --- | --- |
| `src.matrix.assistant-card.copy.assistantCardCopies.personaConflict` | This field changed while you were editing. Showing the latest version. |
| `src.matrix.assistant-card.copy.assistantCardCopies.longPersona` | Your agent may only load part of these instructions. |

Both take no arguments. An AppTest checks their values in all five locales
against desktop `copy.ts`.

Missing key: there is no exported line for "this persona can't be edited
here" (the closest, `routineReadOnly` "View only", belongs to routines). An
ambiguous persona is read-only without a message until the export adds one.

## Not ported (phone has no equivalent surface)

- Desktop's per-field "Saved · Undo" note and its kind-aware undo
  (`PersonaUndo`, `inheritedSoul`). The phone card shows one header "Saved"
  label and has no persona Undo. This predates the change.
- Desktop's expanded editor and its Esc semantics. The phone keeps its
  keyboard Undo/Done toolbar.
- Desktop's `inherited` cards (persona inherited from Atum). The phone's
  definition read has no inherited flag, so a missing definition stays
  read-only, as before.

## Tests

- `ios/Tests/AtumChat/AssistantPersonaMergeTests.swift`: desktop's custom
  fixtures (Sample Agent with and without personality, a changed
  personality, an added personality that survives replacing the main field),
  the three heading round-trip cases from PR #95, the marker shape, the four
  merge outcomes, and the length boundary (code points, CRLF, surrogate
  pairs, trimming, a leading BOM). The review fixes add a fenced-example
  round trip, CommonMark fence ranges, repeated `Who you are` sections
  (custom and template), the newer-draft settle, and the per-field band.
- `AssistantCardPolicyTests`: a custom persona gets `.instructions` and
  `.personality` on both roles.
- `AssistantRoutineStateTests` (AppTests): both keys are in the pin with
  desktop's words in en, vi, ja, zh and zh-Hant.
- `ChatInfoUITests` uses two scripted-host switches.
  `-AtumScriptedPersonaElsewhere` makes the first write meet a newer
  definition whose "What you do" changed. `-AtumScriptedPersonaLong` seeds a
  soul over the budget.
  - `testAPurposeChangedElsewhereShowsTheLatestAndDesktopsLine` (en, light,
    L): the conflict line appears with no Retry, the field shows the other
    device's text, and nothing is written.
  - `testAPersonalityEditKeepsTheOtherDevicesPurposeInDarkAtAX5` (vi, dark,
    AX5): the personality saves on the newer definition and keeps the other
    device's purpose. The length hint is reachable.

## Verification

All builds and tests ran under the shared heavy-build lock, one run at a
time. The script is `/Volumes/AtumTestFlight/w4-e4-verify.sh`, with derived
data and the SwiftPM clone under `/Volumes/AtumTestFlight/dd-w4-e4`. The
simulator was an iPhone 17 on iOS 27, and every run shut it down at the end.
At the coordinator's request the local runs were slimmed to the touched
package, the Debug build, the touched AppTests and the two new UI tests.
Broader regression suites are left to the hosted UI shards on the PR. Logs
are under `/Volumes/AtumTestFlight/w4-e4-verify/<round>/`.

- r2: `swift test -j 2 --filter AtumChatTests` passed 747/747. The Debug
  `build-for-testing` succeeded. `simctl bootstatus` then hung until the
  background limit, so no tests ran. The script now caps the boot wait at
  5 minutes.
- r3: the conflict UI test passed in English, light, at size L. The merge
  UI test (Vietnamese, dark, AX5) made exactly one save. That save kept the
  other device's purpose and added the personality text, but one assertion
  failed because it assumed where the caret lands on tap. The assertion now
  reads the saved section and does not depend on order. The AppTests filter
  had named the wrong class.
- r4: `AssistantCardCopyTests` passed 6/6, including the five-locale check
  of both strings. The merge UI test lost keyboard focus at AX5 before
  typing. The test now scrolls the field into view and retries the tap until
  the keyboard appears.
- r5: the merge UI test passed (rebuild plus that test only).
- `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0.
- r6 (review fixes, `2115a0e`, `SKIP_APPTESTS=1`): `swift test --filter
  AtumChatTests` passed 770/770. The Debug `build-for-testing` succeeded.
  Both persona UI tests passed. The first two r6 attempts were lost when the
  shared build volume detached and reattached; neither had reached a test.
- r7 (review r2 fixes, `ea991aa`): `swift test --filter AtumChatTests`
  passed 776/776. The Debug build failed: the band's `retry` flag shadowed
  the new `retry()` method. Fixed by calling `self.retry()`. The first r7
  attempt was lost to another build-volume detach.
- r9 (`30bda8e`, slim lane rule of 23 Nov: package tests and the Debug
  build only; the hosted PR shards run the persona UI tests):
  `swift test --filter AtumChatTests` passed 776/776 and the Debug
  `build-for-testing` succeeded. Volume detaches killed r8 and the first
  r9 attempt before either ran.

Not verified locally: VoiceOver reading of the hint (desktop marks it
`role="status"`, and the phone shows it as static text), and the
`AssistantNewSheet` persona writer, which this change does not touch.
