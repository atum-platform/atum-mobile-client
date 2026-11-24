# Wave 4f copy repin

The iPhone pins atum-desktop `a13e7275f88d12b9011b646303a05437a582d739`
(PR #122), manifest `2f1c4ea3c95f4b9612817198956306851e2951b123d3873cc851b8d59fa64dc1`.
The previous pin was `de08405bae1f208f891eb04d5a324b150a169c5c`,
manifest `6defd148e9c09a4cb0f840212be145d3a18d9002c8d8e048a7633d75eefd663c`.
The importer updated the lock, catalog, copy contract, and manifest. The copy
inventory and phone copy map are byte-identical.

## Catalog and consumers

The catalog and copy contract each grew from 4,134 to 4,138 entries,
with four additions, zero removals, and zero refreshes. The additions are
`src.matrix.model-picker-copy.COPY.efforts.{none,minimal,xhigh,max}`.
The seven existing model-picker entries covered by the desktop export change
are byte-identical in all five locales.
`AtumCopyTests` checks the zero-argument contract and desktop wording for
each new label in all five locales. W4-Q and W4-R own the adoption of these
keys in the phone picker.

## Pending copy

The Swift copy files and `tests/test_copy_keys_in_pin.py` had no pending
placeholders for the four new keys. The scanner found zero missing literals
and verified the guarded readers of the 68 existing exceptions, including
`taglineEveryday`, `taglineHard`, and `taglineFlagship` in
`tests/test_copy_keys_in_pin.py` and `ios/App/Chat/Views/PhoneModelPickerCopy.swift`.

## Verification

- Local import from the committed desktop checkout and importer `--verify`
  exited 0. All 44 resource hashes matched the manifest. The catalog and
  contract diff audit confirmed that all original entries are byte-identical.
- The copy pin and Xcode project source tests passed 13 tests. The importer
  and native catalog tests passed 12 tests.
- Swift tests and the Debug simulator build ran under the shared heavy-build
  lock, with Swift scratch and Xcode derived data under
  `/Volumes/AtumTestFlight/dd-w4-d6` and Xcode package checkouts under
  `/Volumes/AtumTestFlight/spm`.
- `swift test --filter AtumCopyTests` exited 0 with 14 tests passed, including
  the new effort-label test.
- Debug `build-for-testing` for `AtumMobile` exited 0. `lipo -archs`
  confirmed an arm64 simulator app executable. Zero UI tests ran locally.
- `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0.
