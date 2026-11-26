# Waves 4g and 4h copy repin

The iPhone pins atum-desktop `ec9e90041e4f5dbacfe4be72d00bd330ab508bbf`
(PR #135 head), manifest `e9136dc388da23f8c88fddfff22d9b63db60abd53023182d8ee6e450bc874c39`.
The previous pin was `a13e7275f88d12b9011b646303a05437a582d739`,
manifest `2f1c4ea3c95f4b9612817198956306851e2951b123d3873cc851b8d59fa64dc1`.
The importer read the committed export from the local desktop Git repository
while its checkout stayed on `main`. It updated the lock, catalog, copy
contract, copy inventory, and manifest. The phone copy map is byte-identical.
After desktop PR #135 merges, the coordinator will update the revision in the
lock and pin test to the merge commit after confirming the manifest matches.

## Catalog and consumers

The catalog and copy contract each grew from 4,138 to 4,187 entries,
with 52 additions, three removals, and zero refreshes. All 4,135 retained
entries are byte-identical in both files. Every addition takes zero arguments.

- Wave 4g adds `desktop.surfaces.{comingSoon,comingSoonHelp}` for the beta
  gate from desktop PR #132. Both keys have desktop wording in all five locales.
- Wave 4h adds 36 keys from desktop PR #134 under
  `src.matrix.google-write-card-copy.copies.`.
  Their suffixes are `approve`, `approved`, `approving`, `changed`, `closed`,
  `decline`, `declined`, `declining`, `retry`, `superseded`,
  `labels.{appliesTo,conversation,labels,name,oneEmail,quote,truncated}`,
  `mailbox.{add_labels,archive,mark_read,mark_unread,remove_labels,star,trash,unarchive,unstar,untrash}`,
  `question.{create_draft,create_label,update_draft}`, and
  `work.{approved,changed,declined,expired,source,superseded}`. Desktop writes
  these in English and Vietnamese and uses English for Japanese, Simplified
  Chinese, and Traditional Chinese.
- Wave 4h also adds 14 keys under
  `shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.`. Their suffixes
  are `labels.{attachments,bcc,cc,end,forwarded,inReplyTo,location,start,subject,title,to}`
  and `message.{create-event,send-email,update-event}`. Desktop supplies all
  five locales for these keys.

The copy inventory adds the `surfaces` scope to each locale, records the
English fallback for Google write cards, and lists the desktop rail-badge
source.

Desktop's disk-alert retirement (`e8ce4357`) removed three keys.

- `src.matrix.attention-copy.copies.items.disk_critical`
- `src.matrix.attention-copy.copies.items.disk_low`
- `src.matrix.attention-copy.copies.snooze`

The phone has no readers for those keys. The attention bell builds item keys
only for `sign_in` and `protons`. The retired-copy scan now checks the three
removals alongside the earlier retired keys.

`AtumCopyTests` checks the zero-argument contract and desktop wording for
both gate keys and three Google write keys in all five locales. The gate
and Work UI lanes own adoption.

## Pending copy

The scanner checked 1,089 Swift copy literals and found zero missing keys.
All 68 existing exceptions remain pending and have guarded readers.

## Verification

- The importer and importer `--verify` exited 0. All 44 resource hashes
  matched the expected manifest. The catalog and contract matched the
  committed desktop export byte for byte. All 36 card keys matched the
  English fallback in Japanese, Simplified Chinese, and Traditional Chinese.
- The copy pin and Xcode project source tests passed 13 tests. The importer
  and native catalog tests passed 12 tests.
- Swift tests and the Debug simulator build ran under the shared heavy-build
  lock, with Swift scratch and Xcode derived data under
  `/Volumes/AtumTestFlight/dd-w4-d7` and Xcode package checkouts under
  `/Volumes/AtumTestFlight/spm`.
- `swift test --filter AtumCopyTests` exited 0 with 15 tests passed, including
  the new five-locale case.
- Debug `build-for-testing` for `AtumMobile` exited 0. `lipo -archs`
  confirmed an arm64 iPhone 18 Pro simulator app executable. Zero UI tests ran.
- The pre-push check is `python3 scripts/public_guard.py --base origin/main --head HEAD`
  on the committed repin.
