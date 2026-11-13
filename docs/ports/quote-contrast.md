# Reply-quote contrast (owner ruling, 2026-11-13)

## Question

`ChatKindsUITests/testAccessibilityAuditKinds` (quarantined) and the local
`TranscriptUITests/testAccessibilityAuditAssistantChat` stop at a contrast
finding on reply-quote preview text (`QuoteView`). The owner accepted a darker
quote ink if that fixes it, using exported tokens only and matching desktop as
rendered.

## Desktop as rendered

`atum-desktop` `origin/main`, `apps/desktop/src/matrix/app.tsx`
(`MatrixReplyQuote`): the quote is `text-sm` in `--atum-ink-soft` with a 2 px
`--atum-line` rule, in every bubble.

| Where | Desktop ink on ground | Ratio |
| --- | --- | --- |
| Others' bubble / answer, light | `#3B3F47` on the light bubble | ~10:1 |
| Others' bubble / answer, dark | `#D9DBE0` on the dark bubble | ~12:1 |
| Own bubble, light (`--ak-bubble-own` `#1B1D22`) | `#3B3F47` on `#1B1D22` | **~1.6:1, fails** |
| Own bubble, dark (`#3D3F47`) | `#D9DBE0` on `#3D3F47` | ~7.6:1 |

The own bubble doesn't re-scope `--atum-ink-soft` (only look-pack bubbles
do, `look/look.css`), so desktop's quote in your own bubble in light mode is
dark ink on the ink bubble. **That's a desktop follow-up.** The phone doesn't
copy it.

## Phone tokens

`QuoteView.quiet`:

- others' bubbles and answers: `theme.quiet` = legacy `soft` = Kit `ink-2`
  (`#3B3F47` light, `#C9CCD2` dark). This is desktop's `--atum-ink-soft` in light;
  in dark it's the Kit's `ink-2`, a step below desktop's root `#D9DBE0`
  (`colors.json` `ink.soft`). Both pass with a wide margin.
- your own bubble: `on-bubble-own` at 0.72 (≈ `#BFC0C1` on `#1B1D22` light,
  9.3:1; ≈ `#C1C2C6` on `#3D3F47` dark, 5.9:1).

Every pairing clears WCAG AA (4.5:1) by token math, and the screenshots show
the glyphs drawn at exactly those colours (sampled: `#C9CCD2` on `#1F2025` in
Lan's bubble, dark).

## What the audit actually reports

The run used one build with a temporary launch switch (not committed) that
tried variants, plus a contrast-only audit scoped to the two quotes
(iPhone 17 simulator, iOS 27, Xcode 27, light and dark):

| Variant | Quote preview flagged? |
| --- | --- |
| Current (`ink-2` / own 0.72) | yes, light and dark |
| Darkest exported ink (`ink`, ~16:1; own `on-bubble-own` at 1.0) | **yes**, identical findings |
| No `Button` wrapper (plain combined element) | yes |
| `.subheadline` instead of `.footnote` | preview passes; the semibold footnote sender name ("Bạn") is flagged instead |

In the same contrast-only pass, Xcode flags plainly legible text outside the
quotes: body text ("Mình tới muộn mười phút."), sender names, timestamps, and
avatar monograms. The finding follows **text size**, not ink. So it isn't the
quote token, opacity, the rule or a nested element, and no exported ink fixes
it. As instructed, **the quote's look is unchanged.** The only change that
silenced it, a larger quote font, would change the look away from desktop.
It's left for the owner to decide.

## Test

`ChatKindsUITests.testQuotesInBothBubblesMeetContrast` replies to Lan in
`chat.kinds`, so one screen holds a quote in someone else's bubble and one in
your own. It then measures each quote's drawn ink against its bubble from the
screenshot (WCAG relative luminance, ground = the region's most common colour,
ink = the pixel furthest from it) and requires ≥ 4.5:1. It runs in the
simulator's current appearance; the local verification runs it in light and in
dark.

## Verification (2026-11-13, iPhone 17 simulator, under the heavy-build lock)

| Run | Appearance | Result | Measured (mine / theirs) |
| --- | --- | --- | --- |
| run 3 | dark | PASS | 5.90 / 10.10 |
| run 4 | light | PASS | 9.27 / 10.56 |
| run 5 (final code) | light | PASS | 9.27 / 10.56 |
| run 4, run 5 | dark | FAIL before measuring: "Neither element nor any descendant has keyboard focus" typing the reply, right after the local runner switches the simulator to dark | — |

The measured ratios match the token math above. The dark typing failure is in
the test's reply step, not the measurement; hosted CI runs light only. If it
repeats, give the test a scripted own reply instead of typing one.

## Quarantines

None lifted:

- `ChatKindsUITests/testAccessibilityAuditKinds` still fails first on the
  avatar monogram's Dynamic Type ("Dynamic Type font sizes are partially
  unsupported", `avatar.monogram`, the known wave-2 debt). In one light run it
  also flagged a timestamp ("7:47") for contrast. It stays quarantined in
  `ui-tests.yml`.
- `TranscriptUITests/testAccessibilityAuditAssistantChat` (LOCAL_ONLY) still
  fails on the quote preview in light ("Cảm ơn! Còn phần kết luận?") and, in
  dark, on a markdown list bullet ("•") just inside the top edge.

## Follow-ups

- Desktop: own-bubble quote ink in light (~1.6:1).
- Owner: whether quote text should move from `.footnote` to `.subheadline`
  (closer to desktop's 14 px `text-sm`). That clears the audit's finding on
  the preview line, but not on the semibold name.
- The audit harness: consider a reviewed exception for footnote-size quote
  text, backed by this test's measured ratio.
