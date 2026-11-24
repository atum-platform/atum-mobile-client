# Wave 4e copy repin

The iPhone pins atum-desktop `de08405bae1f208f891eb04d5a324b150a169c5c`
(PR #116), manifest `6defd148e9c09a4cb0f840212be145d3a18d9002c8d8e048a7633d75eefd663c`.
The previous pin was `fef8286cc6606a17127778ce2786c83887dc7841`,
manifest `ae2736a1434057cbb8087ebcbfad1753172ee519c7e87be28369349a238cafc5`.
The importer updated the lock, catalog, copy contract, and manifest. The copy
inventory and phone copy map are byte-identical.

The repin is stacked on W4-E7 at `65f1b8c`. The merge of `origin/main` at
`3f4dded` had one conflict in `ScriptedHomeHost.swift`. The resolution
preserves both Team Space channel-retry state and Researcher hiring state.

## Catalog and consumers

The catalog and copy contract each grew from 4,132 to 4,134 entries,
with two additions, zero removals, and zero refreshes.
`shared.matrix-company-board-copy.copy.list` labels the List segment, and
`shared.matrix-company-board-copy.copy.mine` labels the Mine filter.
`TeamSpaceCopy` reads both directly from the pinned export.
`AtumCopyTests` checks the zero-argument contract and desktop wording in all
five locales. The labels match the W4-E7 fallback wording.

## Pending copy

The repin removes the two scanner exceptions and deletes the W4-E7 fallback
table and its Xcode project entries. The scanner found zero missing literals.
All 67 remaining pending keys are tracked in
[Wave 4d copy repin](w4-copy-repin-4.md).

## Verification

- Local import from the committed desktop checkout and importer `--verify`
  exited 0. All 44 resource hashes matched the manifest. The catalog and
  contract diff audit exited 0.
- The copy pin and Xcode project source tests exited 0 with 13 tests passed.
  The importer and native catalog tests exited 0 with 12 tests passed.
- Swift tests and the Debug simulator build ran under the shared heavy-build lock,
  with Swift scratch and Xcode derived data under
  `/Volumes/AtumTestFlight/dd-w4-d5` and package cache under
  `/Volumes/AtumTestFlight/spm`. UI suites are reserved for hosted shards.
- `swift test --filter 'AtumCopyTests|TeamSpaceRevampPolicyTests'` exited 0
  with 27 tests passed, including the new List and Mine copy test.
- Debug `build-for-testing` for `AtumMobile` exited 0. `lipo -archs`
  confirmed an arm64 simulator app executable.
- `python3 scripts/public_guard.py --base origin/main --head HEAD` checks
  the committed stack.
