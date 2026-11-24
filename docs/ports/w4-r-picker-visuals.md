# W4-R: the phone model picker looks like the desktop's (#119)

Branch `feat/w4-r-picker-visuals` from main `0521e76`. UI lane: row visuals, the composer chip, provider
marks and their attribution. The parallel W4-Q lane owns the picker's data (ModelChoice,
PhoneModelPickerProjection, AccountConnections, PhoneModelPicker.swift, PhoneModelPickerCopy.swift); this
lane does not touch them.

## Desktop sources (atum-desktop main `2365efe8`, PR #119 "one model picker")

- `apps/desktop/src/matrix/model-picker-spec.json` `row`: mark 16, name, `check: "afterName"`, tagline,
  star; `trigger`: height 28, gap 6, mark 16, weight 500, capsule, `chevron: false`.
- `apps/desktop/src/matrix/model-picker-list.tsx` (~:88–197): the row, the current row's shade
  (`current && bg-(--atum-hover)`), the check beside the name (~:120), the star in `--atum-mark-amber`
  when starred (~:174); `PickerRouteMark` (~:199): Atum's eclipse for Atum, else the provider's mark.
- `apps/desktop/src/matrix/model-picker.tsx` (~:2458): the chip is the answering model's mark before its
  name, no chevron.
- `apps/desktop/src/matrix/model-picker-provider-mark.tsx` (~:42–125): `PROVIDER_ICONS` matching over
  "id label", the bundled files in `provider-marks/`, the brand colours, the initial for an unknown
  provider. `provider-marks/README.md` and `ANTIGRAVITY-LICENSE.txt`: sources and licences.
- `apps/desktop/src/app/connections/connect-sheet.tsx` (~:24): Settings' plan mark is a bare
  `ProviderMark`.
- `docs/ui-consistency-1124.md`: round 2 "Signed-out marks" (a signed-out connection keeps its full
  mark) and round 3 (the row anatomy).

## What changed on the phone

- **One shared mark view**, `ios/App/DesignSystem/ProviderMark.swift`. It carries the desktop's
  `PROVIDER_ICONS` table (same order, same match strings, same colours: Claude `#D97757`, DeepSeek
  `#5786FE`, Gemini `#8E75B2`, MiniMax `#E73562`, Qwen `#6950EF`; the rest in the theme's ink), Atum as
  `LiveEclipseMark` (`ios/App/LiveDesign.swift:138`), Antigravity as its full-colour image, and the
  initial in the shared `AtumAvatar` squircle (`ios/App/DesignSystem/AtumAvatar.swift:27`) for anything
  else, as the desktop's `BrandTile`. Marks scale with Dynamic Type up to 2×. Signed-out connections
  are never dimmed.
- **Real artwork**, `ios/App/Assets.xcassets/ProviderMarks/` (template SVG image sets, vector preserved,
  like the existing `Phosphor/` symbol sets): the desktop's own files, byte-identical except
  `openai.svg`/`grok.svg` (`fill="currentColor"` → `#000000`; the app tints them).
- **Rows**, `ios/App/Chat/Views/PhoneModelPickerList.swift` `modelRow`: the provider's mark (20 pt), the
  name with the check beside it (moved from the trailing edge), Atum's tagline under the name in every
  section (it was only shown among the defaults), the current row shaded with the Kit's `fill-hover`
  over the cell (`AtumVisualSystem.kitColor`), a starred model's star in the mark amber
  (`AssistantMarkPalette.amber`, `AtumAvatar.swift:535`, = desktop `#ffa100`). Section headers and
  "Back to Atum" use the same marks; the private monogram `PhoneModelConnectionMark` is gone.
- **Composer chip**, `ios/App/Chat/Views/Composer.swift` `ComposerModelChoiceButton`: the current
  model's mark (16 pt) and its name, weight medium, gap 6, no chevron. The mark comes from the same
  facts as the name (Atum's line-up → the eclipse; a subscription or own key → its provider); while
  nothing names the choice yet it shows the name only.
- **Settings › Connections**, `ios/App/Account/AccountConnectionsSection.swift`: `AccountPlanMark` is the
  real mark (ChatGPT → OpenAI, Claude, Antigravity), as is OpenCode Go's row; 22 pt in a 28 pt lead
  column that keeps titles aligned with the tool glyphs, 44 pt on the connect sheet.

## Deviations for iOS

- Atum's tagline stays on a second line under the name; the desktop trails it on the same line. An
  iPhone row is too narrow to keep both legible, and iOS list rows put a subtitle underneath.
- An unstarred star is always drawn (soft ink): the desktop shows it only on hover, and a phone has none.
- Mark sizes are 20 pt in rows and headers (desktop 16 px at 13 px type; the phone's body type is 17 pt),
  16 pt in the chip, all scaled with Dynamic Type. Row height stays at the 44 pt+ tap target (52 pt).
- The chip keeps its 30 pt height (desktop 28 px) for the tap target.
- The desktop's package-drawn marks (Google, OpenRouter, Mistral, Ollama, Hugging Face, NVIDIA, GitHub,
  Meta, from `@icons-pack/react-simple-icons`) are not bundled: the phone ships only the desktop's own
  files. Those providers show their initial, as any unknown provider does on the desktop. Follow-up if
  own-key rows for them become common on the phone: copy the pinned Simple Icons paths (CC0) the same
  way.
- No ⌘1–⌘9 hints (no keyboard shortcuts on the phone picker).

## Licences and attribution

- `ios/App/Resources/ThirdPartyNotices/ProviderMarks-NOTICE.txt`: per-file sources, pinned commits, the
  OpenAI brand note, and the full MIT texts for Lobe Icons (Copyright (c) 2023 LobeHub) and T3 Code
  (Copyright (c) 2026 T3 Tools Inc., the Antigravity mark).
- `ios/App/Resources/ThirdPartyNotices/ProviderMarks-SimpleIcons-CC0-1.0.txt`: CC0-1.0 text (from the
  desktop's `apps/desktop/third-party/licenses/texts/CC0-1.0.txt`).
- Both are in the licences screen (`scripts/generate-ios-licences.py` → `ThirdPartyLicences.json`), the
  app's Resources build phase, `THIRD-PARTY.json` (`notices`, new `bundledArtwork`), `ios/App/Resources/NOTICE`
  and `DESIGN-PROVENANCE.md`. No AGPL or proprietary art is copied; nothing is hand-drawn.

| File | Source | SHA-256 (bundled) |
| --- | --- | --- |
| `claude.svg` | Simple Icons `icons/claude.svg` | `029b69f0…049ecc` |
| `deepseek.svg` | Simple Icons `icons/deepseek.svg` | `a7a1ebbb…f9084` |
| `gemini.svg` | Simple Icons `icons/googlegemini.svg` | `ad591037…659e` |
| `github-copilot.svg` | Simple Icons `icons/githubcopilot.svg` | `d2b82be0…085f` |
| `minimax.svg` | Simple Icons `icons/minimax.svg` | `d835d615…c09` |
| `opencode.svg` | Simple Icons `icons/opencode.svg` | `71850d1f…4a6f` |
| `qwen.svg` | Simple Icons `icons/qwen.svg` | `180d5019…fdbb0` |
| `openai.svg` | Lobe Icons `packages/static-svg/icons/openai.svg` (fill modified) | `4bcce3c0…109e` |
| `grok.svg` | Lobe Icons `packages/static-svg/icons/grok.svg` (fill modified) | `dca4c50a…767d45` |
| `antigravity.png` | T3 Code `apps/web/src/components/Icons.tsx` via desktop | `e534b8db…ff248` |

## Tests

- `ios/AppTests/ProviderMarkTests.swift`: the desktop table's matches, every named asset is in the
  catalog, only the desktop's coloured marks carry a colour, the initial fallback.
- `ios/UITests/ComposerAndMenuUITests.swift` `PhoneModelPickerVisualsUITests`: chip, sheet and the plans'
  Connect rows in en and vi, light and dark, and one AX5 pass where Connect stays reachable; captures to
  `ATUM_UI_SCRATCH/ui-evidence`.
- `python3 -m unittest tests.test_ios_project_sources`: OK (licence screen holds every bundled text).

## Verification

See the session's locked run below (filled after the run).
