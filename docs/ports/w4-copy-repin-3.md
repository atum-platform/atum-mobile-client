# Wave 4c copy repin

The iPhone pins atum-desktop `899cffdee306e87c4a14bf1344a7db4f545af6b4`
(PR #109), manifest `dbc8e64ab0a62c2057106b5e609e2f4b348aee301139b43f947a1e43826052f3`.
The previous pin was `a6f70c63570337827741f91f502dc9838f1dc6d7`,
manifest `22bd2a54647383135b10b53ac17ddd2b8649719284bf728d63e7d0b5a83b78e4`.
The importer updated the lock, catalog, copy contract, and manifest. The copy
inventory, phone copy map, and other export resources are byte-identical.

## Catalog and consumers

The catalog grew from 4,086 to 4,110 entries, with 38 additions, 14 removals,
and zero refreshes. Desktop #106 moved plan setup from Work to Connections.

- `shared.matrix-agent-desk-copy.matrixAgentDeskCopy.pauseHint` takes no
  arguments and has desktop wording in all five locales. `AtumCopyTests` reads
  the pinned key and checks each translation.
- `src.matrix.mobile-copy.mobileScreensCopy.connections` adds 37 entries
  across 25 keys. Vietnamese and English come from desktop. Japanese,
  Simplified Chinese, and Traditional Chinese use the exported English text.
  `onMacs` and `lastSeen` take a string of Mac names. `AtumCopyTests` checks
  interpolation and fallback wording in all five locales.
- Desktop removed `mobileScreensCopy.work.planRow` and the
  `mobileScreensCopy.work.consent` family, including two `otherMac` index
  branches. The phone has zero Swift references to the 14 retired entries.
  The pin scanner now checks those retired Work references explicitly. The
  UI test matches for shared words such as “Save” point to other surfaces.

## Pending copy

The older Drive, dictation, model picker, and video consent fallback findings
still apply. The four scanner `PENDING` entries remain absent. The scanner
reports the same 75 missing literal occurrences across 72 keys as `origin/main`,
verified by comparing the full lists.

The six Connections plan formatters preserve the desktop `choice` contract,
with 18 branches over `codex`, `claude`, and `antigravity`. No phone callers
use those formatters yet. Rendering them through `AtumCopy.text` requires
support for the `choice` argument kind when a consumer is wired.

## Verification

Swift tests and the Debug build ran in sequence under the shared heavy-build
lock. Swift scratch and Xcode derived data were under
`/Volumes/AtumTestFlight/dd-w4-d3`, with package cache
`/Volumes/AtumTestFlight/spm`. UI suites are reserved for hosted shards.

- Local import, importer `--verify`, and the catalog and contract diff audit
  exited 0. All 44 resource hashes matched the manifest.
- Importer tests passed 8/8, native catalog tests passed 4/4, and Xcode project
  source tests passed 6/6. Each suite exited 0.
- `test_copy_keys_in_pin` passed 3/4 and exited 1 on the existing missing-key
  assertion. The baseline comparison and the isolated retired Work test
  both exited 0.
- The private-source `generate-native-catalog.py --check` exited 1 because
  `docs/design/screen-catalog.json` is absent from the public checkout.
- `swift test --filter AtumDesignTests` passed 911/911 and exited 0,
  including the new Pause and Connections tests.
- The Debug simulator build exited 0, and `lipo` confirmed an arm64 app
  executable.
- `python3 scripts/public_guard.py --base origin/main --head HEAD` runs
  separately against the committed branch.
