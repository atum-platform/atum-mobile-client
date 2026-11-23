# Wave 4b copy repin

The iPhone now pins atum-desktop `a6f70c63570337827741f91f502dc9838f1dc6d7`
(PR #105), manifest `22bd2a54647383135b10b53ac17ddd2b8649719284bf728d63e7d0b5a83b78e4`.
The previous pin was `46f5a5181666e1b9ecaf508f70e26ab3896f957e`,
manifest `be38f8aa7e060582161990d1a5de60b6291993fd3bfeb71a015673cddb32dead`.
The importer updated the lock, catalog, copy contract, and manifest. The copy
inventory and all other export resources are byte-identical. Desktop PRs #89,
#90, #103, and #104 introduced no export changes between the pins.

## Catalog and consumers

The catalog grew from 4,081 to 4,086 entries, with five additions, zero
refreshes, and zero removals. All five are under
`src.matrix.mobile-copy.mobileScreensCopy.relay`.

- `waitingForAnswer` and `invalidAnswer` take no arguments.
- `usageScheduled` takes a required number and has exact-value branches for
  `runs=0` and `runs=1`. It uses Vietnamese in `vi` and English in `en`, `ja`,
  `zh`, and `zh-Hant`, including the desktop wording “1 scheduled runs”.

`AtumCopyTests` exercises zero, one, and three runs in all five locales. The
Work plan rows and consent UI will consume the new keys in the follow-up lane.

## Pending copy

The previous Drive, dictation, model picker, and video consent fallback findings
still apply. The four scanner `PENDING` entries remain absent. The copy-key
scanner reports the same 75 missing occurrences across 72 keys as the base.
