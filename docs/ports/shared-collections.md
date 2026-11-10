# Shared collections data layer (M3)

Data and actions only; SwiftUI integration belongs to the UI owner. No second
Matrix client, network index, URLSession media fetch, receipts, or message sends.
All fixtures use synthetic identities; no message content is logged.

## Desktop evidence

Read `atum-app` **origin/atum-main**, commit
`467b66d7a844805b12df6be0f7988cc4a3c074e9`, without changing that checkout.
Paths below are relative to that repository:

| Rule | Source |
| --- | --- |
| 50 events, four pages per read; requested limit clamped to 60; five links/message, 2048 UTF-16 units/URL; 8 MiB thumbnails | `apps/desktop/shared/matrix-room-shared.ts:18`; `apps/desktop/src/matrix/room-shared.ts:40` |
| Image/video → media; file/audio → files; links only from text/notice/emote | `apps/desktop/shared/matrix-room-shared.ts:192`, `:213` |
| Strip code fences/spans, trailing punctuation/unbalanced brackets, leading reply quotes; http(s), valid host, deduplicate within message; event ID plus #n link identity | `apps/desktop/shared/matrix-room-shared.ts:65`, `:113`, `:197` |
| Skip redacted, invalid identities, undecryptable, non-message and standalone replacement events; no plaintext downgrade in encrypted rooms | `apps/desktop/src/matrix/room-shared.ts:91`; `apps/desktop/shared/matrix-room-shared.ts:185` |
| Newest-first backward reads, preserve whole fetched pages, continue empty pages with a cursor | `apps/desktop/src/matrix/room-shared.ts:35`, `:121`, `:134` |
| Server filter in plain rooms; device decrypt in encrypted rooms; encrypted attachment required there | `apps/desktop/shared/matrix-room-shared.ts:154`, `:242` |
| Sender encrypted thumbnail, otherwise bounded encrypted photo; authenticated scaled plain thumbnail | `apps/desktop/src/matrix/room-shared.ts:197`, `:258` |
| Preview counts 6/3/3; See all 30; partial-empty is distinct from complete-empty; thumbnail cache 96 with four fetches | `apps/desktop/src/matrix/person-info-panel.tsx:58`, `:566`; `apps/desktop/src/matrix/person-info-model.ts:304` |

The M3 plan requires SDK-aggregated **current edited text**, rather than the
desktop reader's original-event text. This implementation follows that explicit
phone rule. Raw replacement events do not add duplicate rows. It also excludes
hidden rows and operational progress notices via the existing `ItemMapper` and
pure policy. The desktop shared reader itself has no additional bot-sender ban:
ordinary assistant/app text, notice and emote URLs count on the phone too.
Malformed backslash URL spellings are refused rather than browser-normalized;
Foundation parses accepted URLs and LinkPolicy gates every open.

## UI hand-off

On the main actor, call
`session.openSharedCollections(roomID:context:knownNames:catalogBotUserIDs:languageCode:)`.
Supply the same room context used by the transcript. This works for person,
group, assistant and app chats. Retain the returned `LiveSharedCollections`
scope until panel dismissal, then **call `close()`**. Session resource teardown
also closes every registered scope, clears models/cache and fences late results.
Dismiss viewers/share UI and release returned handles on scope disposal.
Do not reuse a closed scope after account/session replacement; create a new one.

`scope.sections[.media/.files/.links]` are observable `SharedCollectionsModel`s:

- `await loadPreview()` initially targets 6/3/3; `previewItems` stays that size.
- `await seeAll()` reveals at least 30; `await loadMore()` adds a 30-row window.
  Cached overflow is retained, so crossing a page boundary does not skip links.
- `await retry()` resumes the same section's SDK cursor. Sparse empty reads can
  still have `canLoadMore == true`; provide Load more for them. If
  `requiresReopen` is true, Retry must recreate the scope (a terminal SDK diff
  failure), rather than retry the unusable reader.
- Bind `items`, `state`, `isReading`, `canLoadMore`, `reachedStart`,
  `capacityReached`, `requiresReopen` and `failure`. States: `loading`; `partial` (including zero
  recent results with older history); `empty` (room start, zero results);
  `ready` (room start, results); `failed` (typed error, cached rows retained);
  `offline` (cached subset, possibly zero). Never label partial/offline as an
  authoritative empty room. Start reached means pagination coverage, not that
  every historical encryption key is available. `unreadableCount` is nil, not a
  fabricated zero.
- The live scope observes `SessionLifecycle` connectivity automatically; the
  model also exposes `setOffline(_:)` for synthetic sources. Offline reads attach
  to cached timeline data but never request back-pagination. Retry after recovery.
- Timeline diffs update new attachments/links, edits, redactions, removals and late
  decryption without a history re-scan. Receipt/profile-only changes leave rows
  equal and do not trigger another read. Monotonic snapshot sequences fence
  stale read completions, including rows removed while a page is in flight. URL
  spellings and opaque media sources retain exact identity through edits/cache
  lookups, including distinct Unicode encodings of otherwise identical text.

`await scope.thumbnail(for:pixelSide:)` returns validated JPEG/PNG/WebP/GIF bytes
or nil; retry nil when four thumbnail slots are busy. Default is 320 pixels,
clamped to 1024. The scope keeps at most 96 entries / 32 MiB total, 8 MiB each,
and validates dimensions (40 megapixels / 16384 per side). Edits/redactions cancel
and invalidate matching entries. Decrypted bytes are memory-only in this layer.

`try await scope.open(item, senderLabel: resolvedDisplayName)` returns `.link(LinkPolicy.Decision)`,
`.image(MediaViewerRequest)`, or `.file(LiveMediaFile)`. Route allowed links via
`ChatLinkRouter`; render held/refused decisions with the existing link behavior.
The UI supplies the existing sender-label policy; no raw Matrix ID is used as
a viewer label by default. Use MediaViewer for image requests; video/audio/files (and SVG) use QuickLook. Full photos accept ImageIO-supported raster codecs (including HEIC),
with the same dimension cap.
`try await scope.save(item)` returns the SDK temporary file for Share/export.
**Retain the LiveMediaFile handle** while its URL is in use. These entry points
reject stale/redacted items and recheck after SDK awaits. Supply `scope.mediaAccess(for: item)` to MediaViewer for its bounded content
and later Share fetches; it rejects substituted media sources.

## Bounds and remaining runtime evidence

Rows reverse SDK timeline order, preserving link order within an event even
when sender clocks disagree. Each action calls `paginateBackwards(50)` at most four times, stopping early on
enough rows or room start. A section retains at most 600 projected rows and 4096
compact SDK index entries. At the row cap the state remains partial; exceeding
the index cap reports a typed capacity failure with the cached subset. There is
no unbounded scan or silent index truncation. Reopen refreshes the recent
window; it cannot reach rows older than the retained cap in this version. Full files require
a known declared size <=20 MiB and an actual regular-file size <=20 MiB; one full
file fetch per scope runs at a time. Unknown-size encrypted photo fallback is
omitted; encrypted thumbnails and full files use SDK MediaSource/decryption.
No replacement crypto or opaque-source parser is introduced. Supplementary
upstream evidence: [Ruma's media-source parser prefers encrypted files](https://docs.ruma.dev/src/ruma_events/room.rs.html#73-91).

The pinned FFI does **not** expose a per-request streamed byte cap. Size checks
bound admitted results and retained data, not peak SDK allocation/network bytes
when a server lies about size. Thumbnail resize/animation flags are SDK-owned;
the pinned binding exposes only source, width and height. SDK media cache ownership/purge remains the
existing session's responsibility; this layer introduces no decrypted disk cache.
The SDK may cross multiple `/messages` requests inside one filtered pagination
call: four calls is not proof of four HTTP requests or 200 scanned raw events.
A seeded plain/E2EE-room spike must measure request counts, sparse-history time,
late decryption and in-flight cancellation. Listener FIFO checkpoint ordering and
the initial snapshot contract need that runtime proof too.
No live room, credentials, paid service or simulator UI test was used here.
The filtered timeline can omit UTD events; omit an unreadable-history count.

Synthetic policy/projection/paging tests cover desktop link shapes and limits,
native types, encrypted sources, downgrade refusal, hidden/redacted/internal
rows, current edits, late decryption, atomic diff failures, caps, ordering,
independent cursors, cached page overflow, sparse pages, retry and offline close.

## Local verification checkpoint

Public client checks passed: `npm ci --ignore-scripts && npm test` in
`scripts/public-megolm-fixture` (both vectors); `python3 scripts/import-design-exports --verify`;
`python3 -m unittest discover -s tests -p test_import_design_exports.py` (8 tests);
`python3 scripts/generate-native-push-fixtures.py --check`;
`python3 -m unittest discover -s tests -p test_native_push_projection.py` (2 tests);
`plutil -lint ios/AtumMobile.xcodeproj/project.pbxproj`; package dump/resolve.

The initial Swift/app compilations were stopped under the coordinator's machine
resource rule and do not count as passing checks. The initial locked full Swift
run passed **522 tests, zero failures**, including 18 shared-collection tests. Existing
package warnings concern an absent DerivedData exclusion and unhandled telemetry
source files. The final scoped run below passed **19 tests, zero failures**,
covering exact Unicode resource identity, strict MXC termination, MIME bounds
and terminal retry states. The compile-only arm64 app build also **passed** on
Xcode 27, including both new SDK integration files, with no warnings in those
files. Both final commands ran successfully with a 900-second timeout inside
the shared lock:

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock timeout 900 swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-m3-swift --filter SharedCollections
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock timeout 900 xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /Volumes/AtumTestFlight/dd-m3 -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES 'OTHER_SWIFT_FLAGS=$(inherited) -j2' CODE_SIGNING_ALLOWED=NO build
```

The app command compiles only; simulator boot/UI runs belong to the coordinator.
No push, PR, CI dispatch, upload, deployment, review job or paid service was used.
