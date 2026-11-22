# Wave 4 copy repin

The Wave 4 repin is blocked by an upstream manifest mismatch. The phone still
pins atum-desktop `4f193a16e135869e2bf5d6d2dc69429b160762ba`.

## Import blocker

The importer rejected both the atum-desktop#101 merge commit
`c2d71828f42fa3b60bef57087887cfb4ee2a4073` and its export commit
`c34e651ec7fdf1c347dbec64b4d7b9cd99f471ca`. Both carry manifest
`2ea06dd33d1da9aa28ca41ec80693b3cb531df05ba95b6ee82d50c046acaaff1`.
Comparing the committed archive against the manifest found one mismatch.
Desktop `57bdc29f` restored an Atum-owned image at
`app-icon/atum-app-icon-1024.png`. The committed bytes hash to
`cf67ad54eb5dcc9e4a860e0532fa48b2882c192b55c3e83b287f80e5747248eb`.
The manifest still expects the prior image's hash,
`8b5b59a60ca7f1cfd8065fb059d8df1a60064723532766e9ddbf4d24d8cc23f4`.
The phone needs a published desktop revision whose manifest agrees with its
committed export. The existing importer can then install the full export by
revision and verify it before replacing the phone's pin.

## Consumer audit

Compared with the current phone pin, Wave 4 adds 199 catalog entries (184 keys
plus 15 branches), removes two, and refreshes one across all five locales.
The phone copy map is byte-identical. Neither removed key appears in the
prototype catalog fixture.

- `DriveCopy.allFiles` feeds the destination picker in `DriveScreen`. Use the
  `browser.drive` export already read by `DriveCopy.driveName`. Update the
  destination labels in `DriveRevampUITests` to “Atum Drive” in English and
  Vietnamese and the Drive places assertion in `AccountSettingsStateTests`
  to use the new pin.
- `PhoneModelPickerCopy.unavailable(.notReady)` reads
  `COPY.chatgptCloudNotReady`. Move it and `PhoneModelPickerCopyTests` to
  `COPY.chatgptInWork`. `PhoneModelPickerProjection` mentions the old key in
  a comment only.
- `HomeScreen.searchPrompt` reads `desktop.atum.roster.searchPlaceholder`
  through `HomeSearchPromptCopy`. Read the same key directly once the pin
  carries the short value and remove the fallback. In
  `HomeGlobalSearchPolicyTests`, check all five short values against the pin
  directly and keep the spoken-label check on `desktop.atum.roster.search`.
  `HomeShellUITests` already expects the short visible label.

The retired-literal scan of `ios/AppTests` and `ios/UITests` found the Drive
assertions and the Home fallback tests above. All 44 Drive fallback entries
that Wave 4 promotes match the exported values in the five locales. The removed
and refreshed keys all take zero arguments. No retained key changes its argument
contract. None of the 52 new argument-bearing entries (including exact-value
and absent-value branches) has a phone caller on the baseline branch. The five
new exact-value selectors use numeric argument slots. The parallel turn branch
adds a heartbeat descriptor whose value is an integer. Its rendering call must
pass that value as `.number`, matching the new contract.

`test_copy_keys_in_pin.py` reports 75 missing literal occurrences (72 distinct
keys) on the baseline. Comparing its scanner to the Wave 4 catalog and contract
with the planned rekey gives the same 75 occurrences and zero newly missing.
All four entries in `PENDING` are still absent from the export.

## Verification

- `scripts/import-design-exports --verify` passes on the current pin.
- `test_import_design_exports` passed 8 tests and `test_native_catalog` passed 4.
- `test_copy_keys_in_pin` ran 3 tests with the 1 existing missing-key failure.
- Locked `swift test -j 2` passed 735 tests, including 3 prototype catalog tests.
- The locked Debug `AtumMobile` simulator build succeeded on the current pin.
  The first build stalled during app compilation and was cancelled. The
  single-job retry succeeded under `/Volumes/AtumTestFlight/dd-w4-copy-repin`,
  and `lipo` confirmed `arm64`.
