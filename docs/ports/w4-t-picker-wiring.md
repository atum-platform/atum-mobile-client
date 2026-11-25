# W4-T: model picker chip wiring

Branch `feat/w4-t-picker-wiring` from `origin/feat/w4-q-picker-data` `294ef44` (W4-Q data parity and the
wave 4f copy repin; W4-R visuals already merged). Desktop reference: atum-desktop main `4353d358b416`,
read only. This lane closes three follow-ups from `w4-q-picker-data.md` and `w4-r-picker-visuals.md`.

## 1. Thinking levels read the pinned `COPY.efforts.*`

- The wave 4f pin (`w4-copy-repin-6.md`) carries `src.matrix.model-picker-copy.COPY.efforts.{none,minimal,xhigh,max}`
  beside low/medium/high. `PhoneModelPickerCopy.effortName` now reads all seven levels from the pin through
  one key (`PhoneModelPickerCopy.effortKey`). The four pending cases and their five-locale table rows are
  gone from `ios/App/Chat/Views/PhoneModelPickerCopy.swift`, and the four keys are out of `PENDING` in
  `tests/test_copy_keys_in_pin.py`.
- No wording changed: the pinned values equal the retired pending values in en, vi, ja, zh and zh-Hant
  ("Off", "Instant", "Extra thorough", "Maximum"; "Tắt", "Tức thì", "Rất kỹ", "Tối đa"; …).
- Every Thinking label in the app goes through `effortName` (the picker's level menu,
  `PhoneModelPickerList.swift`). There's no other hard-coded or raw level word.

## 2. The chip names the model, never its raw ID

- Desktop: the chip shows the saved plan's `displayName` (`model-picker.tsx` `cloudSubscriptionName`,
  `shownPlanName`, `chipLabel`). Atum's line-up shows its product name without a version (`atumChipName`).
  Any ID-only entry goes through `matrixModelDisplayName` (`apps/desktop/shared/matrix-model-display-name.ts`).
  Rows use it too (`model-picker-list.tsx:59`).
- Phone: `ios/Sources/AtumNativeAPI/ModelDisplayName.swift` ports `matrixModelDisplayName` case for case
  (same brand table and `GPT-` version hyphen). These are product names, not translated copy.
- `PhoneModelPickerProjection.chip(picked:destination:offer:)` is the chip's one source of name and mark facts:
  - A row a pick just wrote wins, with its own `displayName` (the server's name, as the list drew it).
  - Atum's line-up keeps its product name.
  - A saved connection choice the phone has no row for yet is named through `ModelDisplayName`.
  - Nil until something names the choice ("Model").
- The phone's 1.3–1.5 saved choice carries no display name, unlike desktop's cloud choice. Before the
  picker opens, the chip derives the name from the ID. For the relay's current models this matches the
  list ("gpt-6.1" → "GPT-6.1"). If a server name ever differs from the derived one, the chip shows the
  server's name after any pick but the derived one on a cold start. Platform owns adding `displayName` to
  the saved choice if that ever matters.
- The saved/unavailable subscription row and a Mac's read-only external row also use `ModelDisplayName`.
  They used to show the raw ID. Served rows keep the server's name unless it repeats the ID.

| Saved cloud choice | Chip before | Chip after |
| --- | --- | --- |
| ChatGPT plan `gpt-6.1` | `gpt-6.1` | `GPT-6.1` |
| OpenCode Go `glm-5.2` | `glm-5.2` | `GLM 5.2` |
| Picked ChatGPT row "GPT-6.1 mini" | `gpt-6.1-mini` | `GPT-6.1 mini` |
| Atum `nguyet-thuc` | `Nguyệt Thực` | `Nguyệt Thực` (unchanged) |

## 3. The chip's mark uses the row's connection label

- Desktop: the chip's mark is `PickerRouteMark` for the current route (`chipRoute = currentRoute ?? …`),
  the same component and route the row draws.
- Phone: `ProviderMark.art(source:connectionLabel:)` / `art(for: Row)` (`ios/App/DesignSystem/ProviderMark.swift`)
  is now the single row-mark rule. `PhoneModelPickerList.markArt` and the composer chip both call it. The
  picker's `onPick` hands the chip the written `Row` (Atum picks pass the line-up row the list checks;
  subscription picks pass the row itself). The chip's mark is matched from that row's `connectionLabel`, not
  the provider ID. This also removes the W4-R "brief no-mark flash" after a subscription pick: the chip
  no longer waits for the destination readback to name the source.
- The list's own marks are unchanged: its fallback labels ("ChatGPT", "OpenCode Go", the provider ID)
  match the same table entries as before.

## Verification

- `swift test --filter 'PhoneSubscriptionModelsTests|PhoneModelPickerProjectionTests|PhoneModelPickerSectionsTests|ModelChoiceDestinationContractTests|AtumCopyTests'`
  and the Debug simulator build, each under `TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`,
  scratch and derived data under `/Volumes/AtumTestFlight/dd-w4-t`, Xcode packages under `/Volumes/AtumTestFlight/spm`.
  - Swift: 97 tests, 0 failures (exit 0).
  - Debug `build-for-testing` (iPhone 18 Pro simulator, `CODE_SIGNING_ALLOWED=NO`): the first run failed (exit 65)
    because the new AppTest called the `@MainActor` copy struct's `effortKey` from a nonisolated test.
    After `effortKey` was made `nonisolated`, the build succeeded (exit 0). `lipo -archs` reports arm64.
- New package tests (`PhoneSubscriptionModelsTests`): the saved-plan chip name, picked-row name and
  connection label, Atum's product name and the empty state, and `ModelDisplayName` against the desktop's cases.
  `PhoneModelPickerProjectionTests` now expects the Mac external row's derived name.
- New AppTest `PhoneModelPickerCopyTests.testEveryThinkingLevelIsNamedByThePin` runs on the hosted
  shards with the other AppTests; no UI suites ran locally.
- `python3 -m unittest discover -s tests -p test_copy_keys_in_pin.py`: 7 OK.
- No design-drift lint exists on this base (PR #95 is not in it), so none ran.
- `python3 scripts/public_guard.py --base origin/feat/w4-q-picker-data --head HEAD` ran on the commit (result in the handoff).

## Follow-ups

- No new copy, and no missing keys: every word the chip and picker show is pinned or a product name.
- No local evidence capture of the new chip text (UI suites run on hosted shards). The
  `PhoneModelPickerVisualsUITests` chip captures will show "GPT-6.1" on the next shard run.
