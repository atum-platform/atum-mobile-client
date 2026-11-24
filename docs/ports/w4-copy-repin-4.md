# Wave 4d copy repin

The iPhone pins atum-desktop `fef8286cc6606a17127778ce2786c83887dc7841`
(PR #115, Team Space revamp #114), manifest
`ae2736a1434057cbb8087ebcbfad1753172ee519c7e87be28369349a238cafc5`.
The previous pin was `899cffdee306e87c4a14bf1344a7db4f545af6b4`,
manifest `dbc8e64ab0a62c2057106b5e609e2f4b348aee301139b43f947a1e43826052f3`.
The importer updated the lock, catalog, copy contract, copy inventory, and
manifest. The inventory adds the desktop Team Space revamp copy table.

## Catalog and consumers

The catalog grew from 4,110 to 4,132 entries, with 23 additions, one removal,
and zero refreshes. Desktop draws the additions from
`src.matrix.team-space.revamp-copy.copy`. `AtumCopyTests` checks the wording
and argument types in English, Vietnamese, Japanese, Simplified Chinese,
and Traditional Chinese.

- Header search uses `search`, `noMatches`, and the query formatters
  `searchFor` and `searchMessagesFor`. Both formatters take one string.
- Sectioned settings uses `settingsSections`, `people`, `workspace`, `ai`,
  `billing`, `hiringPreparing`, `companyWallet`, and `openWallet`.
- The task board uses `boardViews` for the view selector, `suggested` and
  `suggestedHint` for the Suggested lane, and `showAllActivity` and
  `showLessActivity` for task details. `showAllActivity` takes a count
  with exact branches for zero and one.
- The channel pane uses `preparingChannel`, `channelFailed` (“Couldn’t
  open this channel.”), and `tryAgain`. The export removed
  `shared.matrix-company-copy.copy.channelOpenFailed`. The phone Swift
  sources and UI tests had no references to that key or its old wording.
  The scanner now flags references to it, including a bare Swift suffix.
- `privateChiefOfStaff` names the private row, header, and composer in the
  revamp. `shared.matrix-company-board-copy.copy.chiefOfStaff` serves
  the shared Chief of Staff in channels.

## Pending copy

The Team Space UI lane will wire the new keys. The Board view selector's group
label is pinned as `boardViews`. The desktop Board/List and Mine controls
also use `shared.matrix-company-board-copy.copy.list` and
`shared.matrix-company-board-copy.copy.mine`. Both labels still need a
desktop export before the phone can use them. The same UI lane should follow
up on phone glyph mappings for `Checks`, `Forward`, `LayoutGallery`,
`LayoutGroups`, `PenNib`, and `Laptop`.

All 67 scanner `PENDING` entries remain absent. The earlier 75 missing
literal occurrences were recorded at `2c9c007` in
[Wave 4 copy pin gaps](w4-copy-pin-gaps.md). The scanner reports zero missing
literal occurrences at this repin and at its base, `c12250b`.

The scanner requires all 18 Connections branches for `claude`,
`antigravity`, and `codex` in both the catalog and contract, including
`sheet.title.plan=claude`. It also requires the absence of Work's
`planRow` and `consent` family and the retired channel key from both
resources. The Connections plan formatters retain the desktop
`choice` contract. Rendering them through `AtumCopy.text` requires
support for that argument kind when a consumer is wired.

## Verification

- Local import, importer `--verify`, and the catalog and contract diff audit
  exited 0. All 44 resource hashes matched the manifest.
- Importer tests passed 8/8, native catalog tests 4/4, Xcode project source
  tests 6/6, and `test_copy_keys_in_pin` 6/6. The baseline scanner passed 4/4.
- Swift tests and the Debug simulator build ran under the shared heavy-build lock,
  with Swift scratch and Xcode derived data under
  `/Volumes/AtumTestFlight/dd-w4-d4` and package cache under
  `/Volumes/AtumTestFlight/spm`. UI suites are reserved for hosted shards.
- `swift test --filter AtumDesignTests` exited 0 with 954 tests passed,
  including the three new Team Space copy tests.
- The Debug simulator build exited 0. `lipo -archs` confirmed the app
  executable is arm64.
- `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0
  against the committed branch.
