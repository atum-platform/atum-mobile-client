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
  (`Composer.swift`) at 16 pt. The chip's `markArt` doc comment no longer says "crescent".
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

## Round 2: the Atum assistant's face

Round 1 left `AtumAvatar`'s crescent (`AtumCrescentFace`) as the main
assistant's face everywhere outside the picker. The desktop never draws a
crescent there either, so round 2 replaces it.

### Desktop (source of truth, atum-desktop `d83d6f40`)

- `apps/desktop/src/app/atum/assistant-avatar.tsx:82-103`
  `AtumAssistantAvatar` with `brand` (the master assistant, no photo): a span
  on `--atum-brand-tile` (`styles.css:14`, `#141311`, both themes) holding
  `atum-mark.svg` at `size-[70%]`, or `size-[64%]` when `inset`
  (`assistant-avatar.tsx:98`). The comment at `:94` records the owner's call
  on 2026-10-31: "The real Atum logo file: a redrawn crescent read as a moon."
- Shape: the span is `.atum-avatar` (`styles.css:3676-3682`), unlayered, so
  `border-radius: 9999px` beats any Tailwind `rounded-*` a call site adds
  (`rounded-md` at `matrix/app.tsx:8481` still renders a circle), and
  `box-shadow: none`, so no hairline. The call sites' own radius tokens are
  circles too (`--atum-r-avatar` and `--atum-r-avatar-sm`: 9999px,
  `styles.css:2215-2216`).
- `inset` is passed by one surface only: the chat list's rows,
  `matrix/roster-conversations.tsx:1166-1171` (`MatrixProfileAvatar ... inset`).
  Every other `brand` face is 70%: `chat-header.tsx:60-63` (chat title),
  `roster-panel.tsx:1206`, `start-chat-dialog.tsx:93`, `matrix/start-chat.tsx:175`,
  `member-avatar.tsx:68` (message and member faces), `greeting.tsx:39` (the
  empty chat's large face), `settings-revamp.tsx:276`, `workplace.tsx:336`,
  `group-picker.tsx:274`, `first-run-card.tsx:63`.

### What changed

- `ios/App/DesignSystem/ProviderMark.swift` `AtumBrandTile`: a `Cut`
  (`.pickerMark`, `.avatar`, `.avatarInset`). `.pickerMark` is round 1
  unchanged (64%, 0.5 pt `line-2` hairline, corner side×4/16). `.avatar` is a
  circle, no hairline, the mark at 70%; `.avatarInset` the same at 64%. Same
  `#141311` tile and the same `LiveEclipseMark`, so the logo still has one
  copy (`marks/eclipse.json`).
- `ios/App/DesignSystem/AtumAvatar.swift`: the `.atum` kind's treatment is now
  `.brand` (was `.crescent`) and draws `AtumBrandTile` at the face's size,
  inside `AtumAvatar`'s own circle mask; `.avatarInset` when the new
  environment value `\.atumAvatarBrandInset` is set. `AtumCrescentFace` is
  deleted (no other user). Only the rendering case changed: art loading,
  caching and the `ChatFaceView` / title-capsule state are untouched, so this
  merges cleanly with the `fix/chat-open-avatar-blip` lane.
- `ios/App/Home/HomeScreen.swift` `HomeRowView` (compact and accessibility
  layouts): sets `\.atumAvatarBrandInset` on the row's 52 pt `HomeAvatar`, as
  the desktop's chat-list rows pass `inset`. The `HomeAvatar` loader itself is
  untouched.
- Surfaces that pick this up with no edits, because they all draw
  `AtumAvatar(kind: .atum)`: the chat title capsule and the empty chat's
  greeting face (`ChatFaces.swift` `ChatFaceView`, `ChatScreen.swift`
  `greetingFace`), message rows' sender face and the Seen marks
  (`MessageBubbleRow.swift:509`, `ChatFaceView`), the info sheet
  (`ChatInfoSheet.swift` `ChatInfoAvatar`, `.eclipse` → `.atum`), the
  start-chat sheet (`HomeScreen.swift` 36 pt list), Settings > Assistants
  (`AccountSettingsDetail.swift:782`), the assistant card
  (`AssistantCard.swift:375`) and the notification face bitmap
  (`NotificationRoomPublisher.swift:123`, rendered with `ImageRenderer`). All
  at 70% except Home's chat-list rows (64%), as on desktop.
- Comments that said "crescent" (`HomeScreen.swift`, `ChatScreen.swift`,
  `PhoneModelPickerList.swift`) now say "logo".
- `ios/App/Debug/S6SystemGallery.swift` (Debug only): an inset Atum row under
  the avatar grid (whose Atum row now shows the 70% face), id
  `system.gallery.atum-inset`.
- Tests: `AvatarArtTests.testAvatarTreatmentFollowsDesktopOrder` expects
  `.brand`; `ProviderMarkTests` adds
  `testAtumAssistantFaceWearsTheDesktopsBrandAvatar` (70% / 64%, circle, no
  hairline; the picker cut unchanged) and
  `testRenderedAtumFaceIsTheDarkBrandCircle` (pixels: `#141311` above the mark
  in light mode, and clear at 12% in from a corner, so a circle).

### Decisions

- Tile colour: the desktop's `#141311`, not the phone export's `eclipseTile`
  role (`#0E0F11` light / `#1B1D22` dark), which no view used. Parity with
  the desktop as rendered wins; `eclipseTile` stays exported and unused.
- No phone surface keeps the crescent, including ones whose FlowPhone spec
  drew it (Home rows, the title capsule): owner rule, parity is the desktop as
  rendered.
- The inset is an environment value, not an `AtumAvatar` parameter, so no
  call site in the loader code (owned by the parallel avatar lane) changes.

## Verification

- Locked Debug build (`lockf` on the heavy-build lock), AtumMobile scheme,
  arm64 simulator "Atum iPhone 16e" (CB24FAE2-75F9-4E19-A856-0F5A9F036C0B),
  derived data on `/Volumes/AtumTestFlight/dd-atum-mark`: BUILD SUCCEEDED.
- `python3 scripts/design_lint.py`: OK.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0.
- Screenshots: the scripted `chat.empty` chat (`-AtumScripted chat.empty`)
  in light and dark. The composer chip shows "Nguyệt Thực" with the logo on
  its dark tile; the eclipse ring and halo render (Canvas radial gradient),
  and in dark the tile keeps its edge on the dark composer. The system
  gallery's picker-mark row sits below the first screen, and scrolling needs
  UI automation, so it was not captured locally; the hosted
  `S6SystemUITests` gallery captures (`-bottom`) will include it. The picker
  sheet itself needs a tap, so it was not captured locally either: its rows
  use the same `ProviderMark(.atum)` at 20 pt. UI test suites were not run
  locally; the hosted shards run them.
- `ProviderMarkTests.testAtumWearsTheDesktopsInsetBrandMark` was not run
  locally (the lane builds only); it runs on hosted CI.

### Round 2 verification (25 Nov 2026)

- Locked run (`lockf` on the heavy-build lock, script
  `/Volumes/AtumTestFlight/atum-mark/r2-verify.sh`), simulator
  CB24FAE2-75F9-4E19-A856-0F5A9F036C0B, derived data
  `/Volumes/AtumTestFlight/dd-atum-mark`: AtumMobile Debug build succeeded
  (`r2-build.log`); `AtumMobileStateTests` with
  `-only-testing:` `ProviderMarkTests` and `AvatarArtTests`: 22 tests, 0
  failures (`r2-tests.log`), including both new tests.
- After that run, `@MainActor` was added to the two `ProviderMarkTests`
  methods that call `AtumAvatar` / `AtumBrandTile` statics, to clear Swift 6
  actor-isolation warnings. That is an annotation only and was not rebuilt
  locally; hosted CI covers it.
- `python3 scripts/design_lint.py`: OK. `public_guard.py --base origin/main
  --head HEAD`: exit 0.
- Screenshots (scripted host, `/Volumes/AtumTestFlight/atum-mark/`):
  `r2-roster-{light,dark}.png` (`home.roster`: Atum's row, inset logo on the
  dark circle), `r2-chat-messages-{light,dark}.png` (`chat.long`: title
  capsule face and composer chip), `r2-chat-title-dark.png` and
  `r2-chat-greeting-dark.png` (`chat.empty`: title capsule, the 64 pt
  greeting face, chip). The light `chat.empty` launch came up blank twice
  (`blank-*.png`, a launch that had not settled), so the light greeting face
  is not captured; it is the same `AtumAvatar(.atum)` 70% face as the dark
  capture. `stale-*.png` are a capture pass made after another lane installed
  its own build on the shared simulator (they show the old crescent); they
  are not evidence for this change. The capture script now reinstalls this
  lane's build before shooting.
- Not captured locally: the info sheet, Seen marks and message sender faces
  need taps or specific scenarios; they draw the same `AtumAvatar(.atum)`.
