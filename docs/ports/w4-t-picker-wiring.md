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
- `PhoneModelPickerProjection.chip(pick:destination:offer:account:)` is the chip's one source of name and mark facts:
  - A pick still current (see "A pick yields to newer readback" below) wins. Atum's line-up keeps its product name.
  - A subscription model, picked or saved, is named by the row the conversation list draws for it
    (`subscriptions(...)`) once the account's status is loaded: the relay or connection's own catalog name
    (desktop `relayCurrentName`: catalog `displayName`, else `matrixModelDisplayName`). The chip and the
    list can't name one model two ways.
  - Without an account read, a pick keeps its own row's name, and a saved choice is named through
    `ModelDisplayName`, which is also what the list's saved row shows then.
  - Nil until something names the choice ("Model").
- Where the account comes from: the picker reports every account read it lands (`onAccount`), and the
  composer's own refresh reads it once when the saved cloud choice is a subscription (three read-only GETs,
  the picker's own read). An Atum choice costs no extra read. So a cold chip on a relayed
  `gpt-6.1-mini` reads "GPT-6.1 mini" like the list, not the derived "GPT-6.1 Mini".
- The saved/unavailable subscription row uses `ModelDisplayName`; it used to show the raw ID. Served rows
  keep the server's name unless it repeats the ID.
- A Mac's read-only external row (`PhoneModelPickerProjection.mac`) uses the desktop card's own rule for a
  saved external model, `ModelDisplayName.destinationLabel` (`matrixModelDestinationsView`
  `external.modelLabel`): split on `-`/`_`/`/`, "gpt" → "GPT", an all-lowercase ASCII word capitalised, the
  rest kept, joined by spaces. `openai/gpt-6.1-sol` → `Openai GPT 6.1 Sol` (desktop
  `model-destinations.test.ts:392`, drawn by `model-destinations-row.tsx` `destinationModels`). A catalog
  row's own label wins when one is given (desktop adds the home catalog's rows first). No Mac catalog
  reaches this projection today, so only the fallback applies here; the Lives-on sheet's catalog rows
  keep their own labels.

### A pick yields to newer readback (review r1 blocker)

- The composer holds a pick as `ChipPick` (the row, plus the destination and offer revisions it held when
  the pick landed). Every destination or offer it adopts, from its own refresh or handed over by the
  picker, runs `PhoneModelPickerProjection.reconciled`, and `chip` applies the same rule:
  - A destination readback newer than the pick drops it unless its saved cloud choice is the pick's
    source and model. With no saved cloud choice, it must be the recommended Atum model.
  - For an Atum pick, a 1.1 offer newer than the pick whose choice is another model drops it too.
  - A readback no newer than the pick never drops it. After a 1.1 Atum write the destination read may
    lag. The subscription write hands back its matching destination right after the pick.
- Blocker scenario: pick ChatGPT's `gpt-6.1-mini` in the composer, then choose Atum Nguyệt Thực in
  Assistant Info, close Info, and the composer refreshes:

  | | Chip name | Chip mark |
  | --- | --- | --- |
  | r1 (`566de11`) | `GPT-6.1 mini` (stale pick) | ChatGPT (stale) |
  | r2 | `Nguyệt Thực` | Atum crescent |

- Known edge: the 1.1 offer's choice is always an Atum alias, so it can't contradict a subscription pick.
  Only the destination readback can. If an Info Atum write moved only the 1.1 choice and never the 1.3
  destination (the scripted host keeps the two stores apart), the destination still says the plan. Then
  the chip names the plan with or without a pick, as desktop's destination-first chip would.

| Saved cloud choice | Chip before | Chip after |
| --- | --- | --- |
| ChatGPT plan `gpt-6.1` | `gpt-6.1` | `GPT-6.1` |
| OpenCode Go `glm-5.2` | `glm-5.2` | `GLM 5.2` |
| Picked ChatGPT row "GPT-6.1 mini" | `gpt-6.1-mini` | `GPT-6.1 mini` |
| Saved relayed `gpt-6.1-mini`, cold, account read | `gpt-6.1-mini` | `GPT-6.1 mini` (catalog, as the list) |
| Saved relayed `gpt-6.1-mini`, no account read | `gpt-6.1-mini` | `GPT-6.1 Mini` (as the list's saved row) |
| Mac external `openai/gpt-6.1-sol` (row) | `openai/gpt-6.1-sol` | `Openai GPT 6.1 Sol` (desktop card) |
| Atum `nguyet-thuc` | `Nguyệt Thực` | `Nguyệt Thực` (unchanged) |

## 3. The chip's mark uses the row's connection label

- Desktop: the chip's mark is `PickerRouteMark` for the current route (`chipRoute = currentRoute ??
  saved plan provider ?? Atum`), the same component and route the row draws.
- Review r1 asked whether an own-key mark can reach the composer chip. It can't, and that matches desktop.
  The composer is the cloud conversation's picker. It lists Atum's line-up and the cloud's subscriptions,
  and neither row type carries a connection label. Own-key rows with connection labels exist only for a
  Mac home (`AgentHomeModelRows.mac`, the Lives-on sheet's picker). Desktop's composer shows an own-key
  route only when this Mac answers locally (`connectedHere`, `macAnswers`). The phone never answers
  locally. So the composer chip's mark is the current row's source mark, the same as desktop's
  `chipRoute` for a cloud assistant. r1's hand-built `Anthropic` own-key test is removed.
  `testTheChipsMarkFactsAreTheListedRowsOwn` now checks, for every row the composer really lists, that the
  chip's source and connection label equal that row's.
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

### Review r1 fixes (r2) verification

Each command ran under `TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`.

- `swift test --scratch-path /Volumes/AtumTestFlight/dd-w4-t/spm-scratch --filter 'PhoneSubscriptionModelsTests|PhoneModelPickerProjectionTests|PhoneModelPickerSectionsTests|ModelChoiceDestinationContractTests|AtumCopyTests'`:
  101 tests, 0 failures (exit 0). The first r2 run failed one new test (exit 1) because its hand-built 1.1
  offer broke the grant/eligibility invariant. That was a fixture bug, fixed, not a product change.
  New or rewritten chip tests:
  - `testANewerReadbackThatSavesSomethingElseEndsThePicksHold` (the blocker)
  - `testAnAtumPickYieldsOnlyToANewerReadbackThatSavesAnotherModel`
  - `testTheChipAndTheListNameASubscriptionModelTheSameWayOnceTheCatalogIsLoaded`
  - `testTheChipsMarkFactsAreTheListedRowsOwn` (replaces the hand-built own-key case)
  - `testASavedExternalModelIsLabelledAsTheDesktopCardLabelsIt`
  - the Mac external row test now expects `Openai GPT 6.1 Sol`
- Debug `build-for-testing` (scheme `AtumMobileStateTests`, iPhone 18 Pro simulator, derived data
  `/Volumes/AtumTestFlight/dd-w4-t/xcode`, `CODE_SIGNING_ALLOWED=NO`): TEST BUILD SUCCEEDED (exit 0).
- `python3 -m unittest discover -s tests -p test_copy_keys_in_pin.py`: 7 OK (exit 0).
- `python3 scripts/public_guard.py --base origin/main --head HEAD` runs on the commit (result in the handoff).
- No local UI suites ran.

## Follow-ups

- `ModelDisplayName.name` capitalises a word with Swift's `prefix(1).uppercased()`, the whole first
  character. Desktop's `matrixModelDisplayName` uppercases the first UTF-16 unit. They differ only for a
  non-ASCII first letter that is a multi-unit character. Current model IDs are ASCII (the 1.x pattern is
  `[A-Za-z0-9._/-]`), so nothing changes. `destinationLabel` only capitalises all-lowercase ASCII words, as
  desktop does.

- No new copy, and no missing keys: every word the chip and picker show is pinned or a product name.
- No local evidence capture of the new chip text (UI suites run on hosted shards). The
  `PhoneModelPickerVisualsUITests` chip captures will show "GPT-6.1" on the next shard run.
