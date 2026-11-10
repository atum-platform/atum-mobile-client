# Shared photos, files and links: phone UI (M3)

The SwiftUI layer on the shared-collections data layer
([`shared-collections.md`](shared-collections.md)). Desktop reference: `atum-app`
**origin/atum-main** `apps/desktop/src/matrix/person-info-panel.tsx` (previews 6/3/3,
"See all" pages of 30), placed in the phone side panel (`ChatPanelHost`, PR #7)
where the desktop shows it: after the Conversation group, before the chat's actions.

## Where it lives

| Piece | File |
| --- | --- |
| Scope protocol (`LiveSharedCollections` conforms), opener type, scope owner | `ios/App/Chat/SharedCollections/SharedCollectionsScope.swift` |
| Preview section, See all page, tiles/rows, viewers, Save/Share | `ios/App/Chat/SharedCollections/SharedCollectionsSection.swift` |
| Copy (pending desktop keys + exported stand-ins) | `ios/App/Chat/SharedCollections/SharedCollectionsCopy.swift` |
| State rules shared by views and tests | `ios/Sources/AtumChat/SharedCollectionsDisplay.swift` |
| Synthetic rows/source (DEBUG) | `ios/Sources/AtumChat/Scripted/ScriptedSharedCollections.swift`, `ios/App/Debug/ScriptedSharedCollectionsScope.swift` |
| Live wiring | `LiveAppModel.sharedCollectionsOpener(roomID:)` → `ChatInfoActions.sharedCollections` (`AppRoot.chatHost`) |
| Panel wiring | `ChatPanelHost` owns the `SharedCollectionsController` and builds `SharedCollectionPage` for `ChatPanelPolicy.Page.shared(_)`; `ChatInfoHome` takes the controller and shows `SharedCollectionsSection` after `conversationSection` |

`ChatInfoSheet.swift` changed by one optional `ChatInfoActions.sharedCollections`
field, one optional `ChatInfoHome.sharedCollections` property and the section
line. The section renders only for person and group chats that are not company
channels, and only when the host supplies an opener.

## Behaviour

- **Lifetime.** `SharedCollectionsController` is `ChatPanelHost` state. It opens one
  scope when the section first appears and closes it in its isolated `deinit`,
  when the panel closes (a new room or account closes the panel, per
  `ChatPanelPolicy.staysOpen`). It does not use `onDisappear`, because See all
  pushes over the home on the panel's path. A scope closed under it (session teardown) dismisses its
  viewers, releases handles and opens a new scope once. A failed open, or a
  section with `requiresReopen`, retries by opening a new scope.
- **Previews.** Three concurrent `loadPreview()` reads. Photos/videos are a
  3-column grid with thumbnails (`scope.thumbnail`, retried while the four slots
  are busy, then a kind glyph). Files and links use the panel's grouped card rows.
  "See all" appears above rows. A preview with nothing recent but older history
  shows Load more inline instead, so two "more" controls never sit together.
- **See all.** `ChatPanelPolicy.Page.shared(section)` pushed on the panel's path
  (its height is kept, per `ChatPanelPolicy.height(afterPushing:)`), with the
  panel's close button. It calls `seeAll()` on appear, then
  "Load more" (`loadMore()`) while `canLoadMore` holds. Media uses an adaptive grid.
- **Open.** Photos open `MediaViewer` (zoom from the tile, its own Share). Videos,
  audio and files open in QuickLook, retaining the `LiveMediaFile` while shown.
  Links route the data layer's `LinkPolicy.Decision`: allowed → in-app
  `SafariView`, held → the existing held-link alert, refused → nothing.
- **Save and share.** Media tiles have a context menu and VoiceOver actions:
  Save (add-only Photos request; `NSPhotoLibraryAddUsageDescription` already in
  `Info.plist`) and Share. File rows have a 44 pt Share button. Both go through
  `scope.save(item)`. A failure shows the generic error alert.
- **States** (`SharedCollectionsDisplay`): loading (grid placeholders / "Loading…"),
  rows, empty (only at room start), partial with nothing recent (desktop
  `noneRecent` once exported + Load more, never the empty line), failed (the
  whole line retries), offline (cached rows plus "Offline — showing saved
  content"; with nothing cached, no empty claim). Rows stay visible under a
  failure or a read in progress. No counts are shown, and `unreadableCount` stays nil.
- **Accessibility.** Headers are headers. Each tile is one element: kind, name,
  date and sender (from the panel's member names, never a Matrix ID), with an
  open hint and Save/Share actions. File rows read name, kind, date and sender;
  links read "Open <url>". Targets are at least 44 pt. At accessibility text
  sizes, the header stacks See all under the title. Colours are Atum roles, so dark
  mode follows the tokens. The fade-in is dropped under Reduce Motion.
- **File sizes are not shown.** The desktop panel shows them, but `ChatMedia`
  says byte size is never presentation copy on the phone. Rows show kind · date.

## Copy: missing keys

Copy comes only from the pinned export. The re-pin to desktop `63e122d3a2`
(PR #7) carries part of the desktop table (`person-info-copy.ts`), and the section
uses its `loading`, `failed` and `tryAgain` keys directly. Its shared-section keys
are **still not exported**. They are read behind `design.copy.contains` (PENDING in
`tests/test_copy_keys_in_pin.py`), with the stand-ins below until they are exported:

| Pending key (`src.matrix.person-info-copy.copy.`…) | Shown today |
| --- | --- |
| `media` | `src.matrix.mobile-copy.mobileChatCopy.photo` ("Photo") |
| `files` | `desktop.atum.workspace.tabFiles` ("Files") |
| `links` | `shared.matrix-debug-share-copy.matrixDebugShareCopy.open` ("Open link"), weak |
| `seeAll` | `desktop.atum.agents.more` ("More") |
| `seeAllMedia` / `seeAllFiles` / `seeAllLinks` | VoiceOver: the See all label, hinted by the section title |
| `loadMore` | `desktop.atum.agents.more` ("More") |
| `noMedia` / `noFiles` / `noLinks` | `src.matrix.mobile-device-copy.mobileDeviceCopy.rosterStatesEmptyText` ("Nothing here yet") |
| `noneRecent` | nothing (Load more still offers older history) |

Also missing from the pin and not needed for now, because an exact equivalent is
used: `video` → `mobileChatCopy.media.kind.video`; `openLink(url)` →
`desktop.dm.resource.openAria`; `mediaLabel(name, date)` → parts joined as in
`MediaViewer`; `unreadable(count)` → not shown, since `unreadableCount` is nil.

Phone-only lines that have **no key anywhere** yet:
- A partial-state note ("showing what's loaded so far"). Not shown; Load more carries it.
- "Save to Photos" / "Saved to Photos". Stand-ins: `src.matrix.chat-copy.copies.save`
  ("Save") and `assistantCardCopies.saved` ("Saved") for the announcement.
- File too large / size unknown (`SharedCollectionFailure.tooLarge`, `.sizeUnavailable`).
  Stand-in: `chat-copy.copies.errorGeneric`.
- Photo library access denied. Stand-in: `errorGeneric`.

When the export lands: re-pin, remove the PENDING entries, and the stand-ins stop
showing automatically.

## Data-layer touch

`LiveSharedCollections.closed` changed from `private` to `private(set)`, so the UI can
see a scope that session teardown closed. The data layer's logic is unchanged.

## Tests

- `ios/Tests/AtumChat/SharedCollectionsDisplayTests.swift` (in the `SharedCollections`
  filter): the real `SharedCollectionsModel` on the synthetic source. Covers loading,
  6/3/3 previews with See all, 30 then Load more to room start, empty only at start,
  partial-nothing-recent, failed → retry, failure below cached rows (reopen),
  offline cached / nothing cached, reading-more, and the synthetic identity and link rules.
- `ios/UITests/SharedCollectionsUITests.swift` (panel opened from the chat title) on `-AtumScriptedShared <mode>`
  (`chat.people` person, `chat.media` group): preview counts, See all, Load more,
  photo viewer, empty, partial, failed → retry, offline.

## Verification (2026-11-10, Mac mini, Xcode 27 / Swift 6.4, on `origin/main` 98b15ed)

All Swift and Xcode commands ran one at a time inside the shared lock:
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock timeout 900 …`.

- `swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-m3ui-swift --filter SharedCollections`:
  **29 tests, 0 failures** (19 data-layer and 10 display/state tests), after the final change.
- `xcodebuild … -derivedDataPath /Volumes/AtumTestFlight/dd-m3ui -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing`:
  **TEST BUILD SUCCEEDED**, with no warnings in the changed files, after the final change.
- One scoped UI run (`-only-testing:AtumMobileUITests/SharedCollectionsUITests test-without-building`,
  iPhone 17 / iOS 27, `xcrun simctl shutdown all` afterwards): **3 passed, 2 failed**.
  Empty, partial and offline passed. Two tests failed on their helper, not on the product:
  - `testPersonPreviewSeeAllAndPhotoViewer`: the helper only scrolled down the panel, so it never
    returned to the media "See all" it had passed. The screenshot shows the button.
  - `testFailedReadRetriesIntoRows`: the Try again button was tapped at the very bottom edge of the
    screen, and the rows did not appear within 5 s.

  The helper now scrolls both ways and keeps targets clear of the edges. The changed tests compiled
  (build above) but were **not run again**: the brief allows one UI run. After the tests finished,
  `xcodebuild` hit the 900 s cap while finalizing the result bundle (exit 124); it did not stall
  inside a test. Screenshots are kept outside the repository, in `/Volumes/AtumTestFlight/m3ui-screens/`.
- Public client checks: Megolm fixture `npm ci --ignore-scripts && npm test` (both vectors);
  `import-design-exports --verify` (63e122d3a2); importer 8 tests; push fixture check;
  push projection 2 tests; `test_copy_keys_in_pin.py` 3 tests; `plutil -lint`; `swift package dump-package`.

Not verified:
- **Through the UI:** opening a photo in the viewer from See all; Load more to the room start;
  Retry after a failed read (this path is covered by the package tests).
- **Not exercised:** Save to Photos, Share and QuickLook, on simulator or device.
- **Dark mode:** setting `XCUIDevice.appearance` to dark did not change the app (it sets its own
  window style), so the offline screenshot is light. Dark mode relies on the colour tokens.
- **Not run:** VoiceOver, Dynamic Type at accessibility sizes, Reduce Motion, iPad.
- **No live data:** no live homeserver or encrypted room was used.

### Coordinator verification (2026-11-10)

- Rebased onto main `30ec84d`; the two conflicts (`ChatInfoSheet.swift`, `ScriptedChatHost.swift`) were additive, and both `assistantTurnStop` and `sharedCollections` are kept.
- Test helper `reveal` fixes: it can look upwards for a target that was scrolled past (a lazy list may drop it, or its frame sits wholly above the screen), and it accepts a hittable target once scrolling stops moving it (Load more under the last row).
- `-only-testing:AtumMobileUITests/SharedCollectionsUITests` on the iPhone 17 simulator (iOS 27.0, locked): 5 of 5 passed, including See all → page → Load more to the room start → photo viewer, and failed → retry.
- Cross-family review (Codex): no blocking findings.
- Still not exercised: Save to Photos, Share, Quick Look, dark mode, VoiceOver, live homeserver data.
- Public guard (no exceptions): two synthetic test values matched its private-hostname rule, so they were renamed rather than allowlisted. An unknown Matrix event type in `SharedCollectionsTests` is now `io.test.unknown-kind`, and the scripted senders use Quân in place of the cast member whose name ends in `.lan`.
