# Wave 4 copy repin

The iPhone pins atum-desktop `46f5a5181666e1b9ecaf508f70e26ab3896f957e`
(PR #102), manifest `be38f8aa7e060582161990d1a5de60b6291993fd3bfeb71a015673cddb32dead`.
The importer now accepts the restored app icon's bytes and the matching
manifest hash. The previous pin was `4f193a16e135869e2bf5d6d2dc69429b160762ba`.
The importer updated the lock, catalog, contract, inventory, manifest, and app
icon. The phone copy map and prototype catalog fixture are byte-identical.

## Catalog and consumers

The catalog grew from 3,884 to 4,081 entries. It adds 184 keys and 15 branches,
removes two keys, and refreshes one key across all five locales.

- Drive's root destination now uses `src.matrix.drive-copy.matrixDriveCopy.browser.drive`
  through `DriveCopy.driveName`. The old `browser.allFiles` key was removed.
  Recents reads the pinned `browser.recents` directly. AppTests read both
  destinations from the pin, and the Drive UI tests select “Atum Drive” in
  English and Vietnamese.
- The model picker uses `src.matrix.model-picker-copy.COPY.chatgptInWork`
  for `.notReady`. The old `COPY.chatgptCloudNotReady` key was removed.
- Home reads the refreshed `desktop.atum.roster.searchPlaceholder` directly.
  The AppTest checks the five short values and the separate spoken label from
  `desktop.atum.roster.search`.
- The 44 newly exported `DrivePendingCopy` entries already read the pin
  first and match the previous fallback values in all five locales.

## Pending copy

- Drive still falls back for `matrixDriveCopy.gridView`, `listView`,
  `viewMode`, `search`, `searchEmpty`, `preview.error`, `preview.loading`,
  and `preview.unavailable`, plus `mobilePhoneCopy.drive.searchFolderOnly`.
- The four entries in the scanner's `PENDING` set are still absent.
  These are `mobileDeviceCopy.dictationListening` and the model picker's
  `COPY.taglineEveryday`, `COPY.taglineHard`, and `COPY.taglineFlagship`.
- `shared.matrix-status-line-copy.matrixVideoConsentWaitCopy` is named in
  the copy inventory. The pinned desktop source declares five locales, and
  the generated catalog and contract omit the key. The turn-state branch
  retains its existing English fallback.

## Argument contracts

No retained entry changed its parameter contract. Both removed keys and
the refreshed key take zero arguments. The 44 newly pinned Drive fallback
entries take zero arguments. The 52 newly added argument-bearing entries
comprise 37 keys and 15 branches. The audit found no phone callers for them
on this branch, including calls through composed key prefixes. All five
new exact-value selector groups target numeric arguments.

The turn-state branch carries heartbeat minutes as an integer. When its
footer lookup is wired during assembly, pass `.number(Int64(minutes))` for
`shared.matrix-status-line-copy.matrixProgressCopy.heartbeat`. Its seven
tool activity keys and approval wait are also available through the lookup.

## Verification

The verification commands ran one at a time under the shared heavy-build lock.
Swift scratch and Xcode derived data were under
`/Volumes/AtumTestFlight/dd-w4-copy-repin`.

- Importer `--verify` accepted the pin. Importer tests passed 8/8 and native
  catalog tests passed 4/4.
- `test_copy_keys_in_pin` still reports 75 missing literal occurrences
  across 72 keys, exactly matching the baseline by key and occurrence count.
  The misses come from Team Space (67 occurrences), App Panel (6), Drive's
  guarded folder-search scope (1), and Home's guarded main-agent label (1).
- `swift test -j 2` passed 735/735, including all three prototype catalog tests.
