# Picker: Atum's real logo as its row mark

Owner report (25 Nov 2026): in "Model for this conversation", the Atum line-up
rows (Nguyệt Thực 1.3, Nhật Thực 1.1, Thái Cực) showed a plain crescent glyph
as the row mark instead of the Atum logo.

## Cause

`ProviderMark` `case .atum` drew `AtumAvatar(kind: .atum)`, which renders
`AtumCrescentFace` (`ios/App/DesignSystem/AtumAvatar.swift`), a hand-drawn
ink crescent cut by a page-colour disc. Its doc comment said "Atum is its own
crescent". That was a wrong port: the desktop picker never draws a crescent
for Atum.

## Desktop (source of truth)

- `apps/desktop/src/matrix/model-picker-list.tsx` `PickerRouteMark`: for
  `provider === 'atum'` it draws
  `<BrandMark className="size-(--mp-mark) rounded-[0.25rem]" inset />`. The
  same function draws the composer chip's mark for the current row.
- `apps/desktop/src/components/brand-mark.tsx` `BrandMark` with `inset`: the
  real mark `public/atum-mark.svg` at `size-[64%]` on a `#141311` tile, an
  inset 0.5px hairline of `--atum-line-strong`, overflow clipped to the
  rounded tile.
- `model-picker-spec.json`: `row.mark` and `trigger.mark` are both 16 px, so
  the 0.25rem corner is 4 px on a 16 px mark.
- The picker's provider rail (`model-picker-filter.tsx:87`) uses the same
  inset BrandMark at the rail icon size (20 px, `rounded-[0.3rem]`). The phone
  has no rail, so nothing to port there.

## What changed

- `ios/App/DesignSystem/ProviderMark.swift`: `.atum` now draws a new
  `AtumBrandTile`: the brand tile `#141311` (always dark, in light mode too,
  like the desktop), the mark at 64% of the side, a 0.5 pt inset hairline of
  the kit's `line-2` (the phone's equivalent of `--atum-line-strong`: white
  14% in dark matches exactly; ink 14% in light against the desktop's 12%),
  and a corner of `side × 4/16` (4 pt at 16, 5 pt at 20, growing with Dynamic
  Type as the lead column does). The lead column (`side`) and the
  `accessibilityHidden` frame are unchanged. Doc comments fixed.
- Every `ProviderMark(.atum)` call site picks this up with no edits: the
  picker's Atum rows and the "Switch back to Atum's AI" row
  (`PhoneModelPickerList.swift`) at 20 pt, and the composer chip
  (`Composer.swift`) at 16 pt.
- `ios/App/Debug/S6SystemGallery.swift` (Debug only): a row of the Atum mark
  at 16 and 20 pt beside a provider mark, so the system gallery captures it.
- `ios/AppTests/ProviderMarkTests.swift`: pins the 64% mark and the
  0.25rem-on-16 corner.

## Decision: no new image asset

The brief suggested bundling `atum-mark.svg` as an imageset. The app already
vendors that exact file: `ios/Vendor/AtumDesign/marks/eclipse.json` holds an
SVG byte-identical to desktop `public/atum-mark.svg` (checked with a string
compare on 25 Nov 2026), and `LiveEclipseMark` (`ios/App/LiveDesign.swift`)
already draws it, halo radial gradient included, on Home and the auth
screens. `AtumBrandTile` reuses `LiveEclipseMark`, so there is one copy of the
logo, it re-pins with the design export, and there is no question of whether
Xcode's SVG rasteriser handles the radial gradient. No imageset was added.

## Not changed (follow-up)

`AtumAvatar`'s crescent (`AtumCrescentFace`) is still the Atum assistant's
face in the chat title, roster and other assistant avatars. The desktop does
not draw a crescent there either: `apps/desktop/src/app/atum/assistant-avatar.tsx`
`AtumAssistantAvatar` with `brand` (the master assistant, used by
`chat-header.tsx:62`, `roster-panel.tsx:1206`, `start-chat-dialog.tsx`,
`matrix/app.tsx`, `member-avatar.tsx`, `profile-avatar.tsx` and others) draws
the same `atum-mark.svg` on the `--atum-brand-tile` (#141311) at 70%, or 64%
when `inset` (the chat list's rows). Its comment records the owner's call on
2026-10-31: "The real Atum logo file: a redrawn crescent read as a moon." So
the phone's crescent avatar is a parity gap too. This lane keeps its scope to
the picker and chip marks; replacing `AtumCrescentFace` with the brand tile
(circle frame, 70% / 64%) is the next concrete step, in its own lane.

## Verification

- Locked Debug build, AtumMobile scheme, arm64 simulator "Atum iPhone 16e"
  (CB24FAE2-75F9-4E19-A856-0F5A9F036C0B), derived data on
  `/Volumes/AtumTestFlight/dd-atum-mark`: see the lane report for the result
  and log path (`/Volumes/AtumTestFlight/atum-mark/build.log`).
- `python3 scripts/design_lint.py`: OK.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0.
- Screenshots of the system gallery's picker-mark row in light and dark,
  under `/Volumes/AtumTestFlight/atum-mark/`. UI test suites were not run
  locally; the hosted shards run them.
