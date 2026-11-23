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
  pairs, trimming).
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

Not verified locally: VoiceOver reading of the hint (desktop marks it
`role="status"`, and the phone shows it as static text), and the
`AssistantNewSheet` persona writer, which this change does not touch.
