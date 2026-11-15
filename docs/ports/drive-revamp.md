# Drive revamp: desktop's Finder Drive in iPhone form

Desktop reference: atum-desktop `origin/main` at `b77e4e3a19`, the 13 Nov Drive revamp:

- PR #43, Finder-like Drive: sidebar, Icons/List, sortable list columns, sync badges.
- PR #44: column view, gallery view, Group By.
- PR #45: whole-Drive search with a scope bar, "Only on this Mac" badges, and a per-file sync-status consumer.

Files: `apps/desktop/src/matrix/drive.tsx`, `drive-browser.tsx`, `drive-finder.ts`, `drive-groups.ts`, `drive-gallery-view.tsx`, `drive-search.ts` and `drive-copy.ts`.

The owner's ruling: parity means the same capabilities, judged by what renders and how it behaves. Finder's own metaphors (a sidebar, Miller columns, the keyboard) don't fit a phone, so each capability takes a native iPhone shape, close to the Files app.

The phone stays read-only over `atum.mobile-drive/1`. Nothing on the server changed.

## What the phone does now

At the root, Drive shows desktop's two places, Recents and All files, as a segmented control. The large title has a search field under it and a "…" button on the right.

- **"…" view options (Files-style).** The menu has three sections:
  - **View:** Icons or List.
  - **Sort:** Name, Modified or Size. The chosen column shows an up or down arrow. Tapping it again flips the direction (desktop's `nextDriveSort`). A new column starts where Finder starts it: names A to Z, dates and sizes largest first.
  - **Group:** a submenu with None, Kind, Date Modified and Size.
- **Icons** is the default, as on desktop. Each icon is a glyph on a quiet plate with the name under it. A long name is cut in the middle at 22 characters (desktop's `middleTruncateDriveName` and `ICON_LABEL_LENGTH`), so its start and its type both stay readable.
  - Long-press shows the whole name as the menu title. VoiceOver reads the whole name.
  - The kept-offline pin and the download progress sit on the plate's corner, where desktop puts its sync badge.
- **List** keeps the phone's rows: glyph, name, size and modified time, plus the per-row "…" menu.
- **Sort.** This is desktop's `sortDriveRows`. Names are compared the way a person reads them: "Report 2" comes before "Report 10", and case and accents are ignored. Folders are mixed in with files.
  - A folder has no size of its own, so it sorts below the smallest file.
  - An item with no modified time counts as the oldest.
  - Recents opens newest first and All files and every folder open by name, as on desktop.
  - Recents' order lasts for the visit (desktop's `sortChoice`). The folder sort is remembered.
- **Group By.** This is desktop's `groupDriveRows`, with its group names and order:
  - **Kind:** groups sorted by name, with Other last.
  - **Date Modified:** Today, Yesterday, Previous 7 Days, Previous 30 Days, then each month of this year, then each earlier year.
  - **Size:** More than 1 GB down to Less than 100 KB, then Empty, then Folders.

  Each group keeps the sort inside it. In Icons a group is a titled block. In List it is a section.
- **Remembered.** The view, Group By and the folder sort are kept on this iPhone. View and Group By use desktop's keys (`io.atum.drive.layout`, `io.atum.drive.group`), and the sort uses `io.atum.drive.sort`.
- **Search.** The field filters the open folder's listing by name, ignoring case (desktop's local filter). While you type, a scope line replaces the status line. It reads "Search: <folder>", or "Search: Atum Drive" at the root, with "Searches this folder, not its subfolders." under it. An empty result says desktop's "No files match this search."
- **Preview gallery.** Tapping a picture or a PDF opens desktop's Gallery as a sheet:
  - The item is shown large, with its name and "Kind · size · modified" under it (desktop's caption).
  - The folder's pictures and PDFs sit in a strip along the bottom, in the order the folder shows them.
  - Swipe to move, or tap the strip. Pictures zoom (the chat media viewer's `ZoomableMediaImage`). PDFs page and zoom in PDFKit.
  - Each page downloads its file when shown, and the next one is fetched ahead.
  - A failure is said on the page, with Try again. It never raises the screen's alert behind the sheet.
  - An older kept copy shown while offline says so.
  - Other files open as before: Quick Look for safe types, the share sheet for the rest.
- **Share.** Share is in the gallery's toolbar and in each file's menu (the row's "…", or long-press in List and Icons). It downloads the file if needed, then opens the iOS share sheet. The file goes out under its own name: when Share is tapped, `DriveShareFile` hard-links or copies it out of the cache's opaque key into a temporary folder, which is removed when the sheet closes.
- **Recents board removed.** Desktop dropped the four-tile Recents board in #43. Recents is now the root listing, newest first, in the chosen view. The phone follows.

## Capability map

| Desktop (#43–#45) | Phone | Status |
|---|---|---|
| Icons / List switch, remembered | "…" › View | Mapped |
| List columns Name / Modified / Size, click to sort | "…" › Sort, tap again to flip | Mapped. Folder sort remembered. |
| Group By None / Kind / Date Modified / Size | "…" › Group | Mapped, same names and order |
| Middle-cut long names in Icons | Same, 22 characters; whole name in long-press title and VoiceOver | Mapped. Desktop's "full when selected" has no phone equivalent (no selection). |
| Gallery view (large preview + filmstrip) | Swipeable preview sheet + strip, for pictures and PDFs | Mapped in iPhone form (below) |
| Quick Look (Space) | Tap opens the gallery or Quick Look | Mapped |
| Search Drive + scope bar (This Drive / folder) | Search field + "Search: <folder>" line | Folder scope only. Whole-Drive search is platform ask 1. |
| Sidebar: Recents, Favorites (top-level folders), Locations | Recents / All files segmented control; folders push | Phone shape (Files app); unchanged from AC-4 |
| Back / Forward, ⌘[ ⌘] | Native back, breadcrumbs | Phone shape |
| Column view (Miller columns) | Folder push + breadcrumbs | Not a phone shape (owner ruling) |
| Keyboard: arrows, type-select, Return, Esc | None | Not a phone shape (owner ruling) |
| Per-item sync badges (synced / waiting / paused) | None | Not applicable (below), platform ask 2 |
| "Only on this Mac" badge | None | Mac-local (below) |
| Share (a #43 follow-up on desktop) | Share sheet from the gallery and file menus | Phone ahead of desktop |
| Reveal in Finder, Import, use in a chat | None | Unchanged: Mac-only, or lane 1 |

### Why some things are not mapped

- **Column view and keyboard navigation.** The owner accepted that Miller columns and Finder's keys don't fit a phone. The capability they serve, moving through the hierarchy and seeing where you are, is native back plus the breadcrumb row.
- **Desktop's gallery as a view mode.** On the phone, the large preview plus strip is the preview itself. It opens on a picture or PDF and swipes through the folder's others. Desktop's gallery also shows glyphs for folders and other files, and draws text files as a page. The phone keeps those as rows or icons, and keeps text files in Quick Look, because a preview sheet that swiped onto files it can't show would only offer a glyph.
- **Sync badges.** Desktop's badges describe the Mac's local sync engine: whether a file on that Mac has reached the server. The phone has no local sync copy. It lists the server's own copy through `atum.mobile-drive/1`, so every listed item is by definition on the server, and the listing carries no per-file state. A phone badge would be invented, so there is none. The phone's own per-file state, Kept offline, is unchanged.
- **"Only on this Mac."** This marks files that the Mac's engine excludes from sync (its fixed exclusion patterns). Those files never reach the server, so the phone can't see them and has nothing to badge. It does not apply on the phone.
- **The page glyph with the type stamped on it.** Desktop's Icons view draws a white page with its extension (`ConsumerFileGlyph`), using kit tokens (`--atum-page`, `--atum-folder-*`, `--atum-shadow-tile`) that the phone's vendored kit export does not carry. The phone keeps its Phosphor family glyphs on a plate. A repin that carries those tokens can match the glyph.

## Platform asks

1. **Whole-Drive search for `atum.mobile-drive`.**
   - **The gap.** The phone reads OpenCloud's LibreGraph children listing one folder at a time. Without a search route it can only filter the open folder. Desktop walks its local copy instead (`electron/matrix/drive-search.ts`).
   - **The ask.** A bounded name-and-metadata search in the mobile Drive contract (a `/2`, or an extension of `/1`). It would take a query and an optional folder scope, and return the same `DriveItem` shape plus each match's folder path. Mirror desktop's bounds: at most 500 results, a truncation flag, and no file contents.
   - **Possible routes.** OpenCloud's search service (WebDAV `REPORT` `oc:search-files`), or a platform proxy.
   - **What the phone does then.** Show desktop's full scope bar, "This Drive" and "<folder>", and the folder path on each result row. It would drop the phone-only "not its subfolders" line.
2. **Per-file sync state, if the owner wants it on the phone.**
   - **What desktop has.** The #45 consumer shows nothing until the Mac engine reports per-file state, and that producer is a desktop follow-up.
   - **The ask.** For the phone to say "Waiting to sync from your Mac" or "Sync conflict", the platform would need that state in the listing, for example an optional `syncState` per item from the uploading device. Until then, "no badge" is correct. "Only on this Mac" stays Mac-only either way.

## Copy (PENDING-COPY)

The pinned export has desktop's Name, Modified, Size, Recents and All files. It also has the chat media "Share" (`mobileChatCopy.media.share`) and "Close" (`desktop.common.close`). It lacks the #43–#45 words.

`DrivePendingCopy.desktop` holds desktop's own five-locale values for 52 keys, extracted mechanically from `drive-copy.ts` at `b77e4e3a19`. Each key is a suffix of `src.matrix.drive-copy.matrixDriveCopy.`:

- `search`, `searchScope.title`, `searchEmpty` and `browser.drive`.
- `viewMode`, `listView` and `gridView`.
- `groups.{title,none,kind,modified,size}`.
- `groups.kinds.*` (12), `groups.dates.*` (4) and `groups.sizes.*` (8).
- `itemKinds.*` (12).
- `preview.{error,loading,unavailable}`.

`DriveCopy.pending` reads the export first. A repin that carries these keys switches over with no code change; then delete the table. Each use is marked `// PENDING-COPY:matrixDriveCopy.<key>`.

There is one phone-only key, which is proposed: `src.matrix.mobile-copy.mobilePhoneCopy.drive.searchFolderOnly`.

| en | vi |
|---|---|
| Searches this folder, not its subfolders. | Chỉ tìm trong thư mục này, không tìm trong thư mục con. |

The ja, zh and zh-Hant values were written here and need copy review.

Desktop's scope bar reads "Search: [This Drive] [<folder>]". The phone shows "Search:" with the folder only, because it has one scope (platform ask 1).

## Code

- `ios/Sources/AtumDrive/DriveArrangement.swift` (pure, unit-tested) contains:
  - `DriveLayout`, `DriveSort`, `DriveGroupBy`, `DriveKindFamily` (desktop's extension table, folded as `drive-groups.ts` folds it), `DriveSizeBand` and `DriveGroupKey`.
  - `DriveArrangement.sort`, `.filter`, `.groups` and `.middleTruncated`.
  - `DriveGalleryPolicy`: pictures and PDFs only. Anything `DrivePreviewPolicy` refuses, such as SVG, stays out.
- `DriveFeatureModel` gains:
  - `gallery`, `openGallery(_:startingAt:)` and `dismissGallery()`.
  - `galleryFile(for:)`: per-page downloads that return their failure instead of raising the alert.
  - `share(_:)`: download, then the share sheet.

  Failures are now mapped to a notice in one place (`transferNotice`). `DriveRecents` is gone; Recents is `DriveSort.recent`.
- `ios/App/Drive/DriveScreen.swift`: the list and icon bodies, the "…" menu, search and the scope line, groups, and Share in file menus.
- `ios/App/Drive/DriveGalleryView.swift`: the gallery sheet, the PDF view and `DriveShareFile`.
- `ios/App/Drive/DriveCopy.swift` and `DrivePendingCopy.swift`: the copy.
- `ZoomableMediaImage` in the chat `MediaViewer.swift` is now internal, with a `pansOnlyWhenZoomed` option, so the gallery can reuse it and still page. The chat viewer's behaviour is unchanged.
- **Scripted Drive host (closes D12).** `ios/App/Debug/ScriptedDriveHost.swift` is Debug-only and excluded from Release by `Scripted*.swift`.
  - Launch with `-AtumScripted home.roster -AtumDebugDrive -AtumScriptedDrive`. That puts the real `DriveScreen` and `DriveFeatureModel` on Home's Drive tab over a scripted `DriveReading`.
  - The pictures and PDFs in it are drawn at launch, so their bytes are real.
  - The host forgets the view, sort and Group By at launch unless `-AtumScriptedDriveKeep` is passed.
- `ios/AtumMobile.xcodeproj`: the four new app and UI-test files were added by hand (16 lines), matching what `project.yml`'s folder globs produce. A full `xcodegen generate` (2.46.0) reshuffles every ID of the committed project and mints one with a 13-digit run that `public_guard.py` refuses, so it was not committed.

## Review fixes (PR #57, cross-family review)

1. **A gallery page could point at an evicted file (P1).** The Drive cache's 250 MiB budget could evict a page's file while another page downloaded. For example, open a 200 MB PDF, then prefetch a 100 MB one: the first is removed, and going back would hand PDFKit a missing URL.
   - `DriveCache.holdPreview(_:)` keeps the shown page's file out of budget eviction. The gallery holds the shown page before it prefetches the next; `releasePreview()` lets it go.
   - Each time a page is shown, the gallery re-checks its file. If the file is gone, it resolves it again through the cache, downloading it if needed. A page whose file has vanished waits rather than failing.
   - Tests: `testTheShownPageSurvivesThePrefetchOfTheNext` and `testAnEvictedPageIsDownloadedAgainWhenShown`.
2. **PDFs opened on the main thread (P2).** A page now opens its `PDFDocument` on a detached task and attaches it on the main actor. `DrivePDFView` only displays a document it is given.
3. **Silent render failures (P2).** A page draws a failure state instead of spinning forever or going blank. `DriveGalleryRenderFailure` is pure and tested:
   - `unreadable`: a picture that doesn't decode, a PDF that doesn't open, or one with no pages. It says "Couldn't open this preview." with Try again. Try again drops this iPhone's copy (`DriveCache.discard`) and downloads it again.
   - `unsupported`: a password-protected PDF. It says "A preview isn't available for this file." with no retry; Share still works.
   - Tests: `testRenderFailuresSayWhatWentWrongAndWhetherRetryHelps` and `testRetryForAnUnreadablePageDownloadsItAgain`.
4. **Share copies piled up (P2).** The named share file is staged only when Share is tapped, in the gallery and in file menus. It is removed when the sheet closes, so there is one at a time. A pass on gallery close clears anything left over. Test: `DriveShareFileTests` (app unit tests).
5. **Gallery order ignored grouping.** The gallery now takes its pages from the screen's grouped, flattened order (`DriveGalleryPolicy.items(in:)`). Test: `testTheGalleryFollowsTheGroupedOrderOnScreen`.
6. **Device calendar.** Date groups and their month and year names now always use the Gregorian calendar in the local time zone (`DriveArrangement.gregorian`), as desktop's JavaScript dates do. A Japanese-calendar iPhone groups by 2025, not by an era year. Test: `testDatesAreGregorianWhateverTheDeviceCalendar`.

## Known risks and follow-ups

- **Folders mixed in by name.** All files now mixes folders in by name, as desktop's Finder sort does. AC-4's folders-first order is retired.
- **HEIF.** `.heif` groups as Other, because desktop's kind table lacks it. The phone glyph still draws it as an image. Raise it with desktop if it matters.
- **Swipe preview limits.** A picture larger than 4096 px is shown downsampled. Animated GIFs show their first frame.
- **Swipe on a loaded simulator.** A short synthesized swipe sometimes did not turn the page. The tests now drag past halfway. Worth a check on a device with quick flicks.
- **Sort on Recents.** Desktop also lets Recents be re-sorted for the visit; the phone does the same, and the menu shows the current order.

## Verification

Every heavy step ran under the shared lock (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`), with `-j 2` / `-jobs 2`. Derived data was in `/Volumes/AtumTestFlight/dd-drive-revamp`. The simulator was one iPhone 17 (iOS 26), shut down at the end of each run.

- **`swift test --filter AtumDriveTests`** (run 1): 39 tests, 0 failures. These include:
  - `DriveArrangementTests`, 14 new: sort, next sort, stored choices, Kind/Size/Date groups and their order, month and year names, ungrouped, kind table, search, middle cut, gallery items.
  - `DriveFeatureModelTests`, 3 new: the gallery and per-page failures without the alert, Share then the share sheet, an account change closing the gallery.
  - The updated `DriveBrowsingTests` Recents order.
- **`xcodebuild build-for-testing`** (AtumMobile, Debug): succeeded in every run.
- **`AtumMobileTests`**: 387 tests, 0 failures (runs 1 and 3).
- **`DriveRevampUITests`**, on the scripted Drive host: 5 of 5 passed in run 7.
  - `testViewSortAndGroupAreChosenAndRemembered`: Icons by default; List, Size and Kind from "…"; List and Group By survive a relaunch; the folder sort is kept for All files.
  - `testSearchFiltersTheFolderAndShowsItsScope`: the scope line reads "Atum Drive"; the matches are filtered; no matches shows the empty line.
  - `testGallerySwipesThroughTheFolderAndShares`: the picture opens at its caption; a drag moves to the PDF; the strip jumps back; Share shows the system sheet.
  - `testRowMenuShares`: a long-press on a row, then Share, shows the system sheet.
  - `testCaptureDriveSurfaces`: en/vi × light/dark, eight surfaces each.

**After the review fixes** (run 8, one locked run, then run 9 for AtumDriveTests alone):

- **`swift test --filter AtumDriveTests`**: 45 tests, 0 failures (run 9). Run 8 had found one failure in a new test: with a `@calendar=japanese` locale, the Gregorian year read "西暦2025年". The fix drops the locale's calendar preference when naming months and years. The app always passes a plain export locale such as `ja`, so the app was not affected.
- **`xcodebuild build-for-testing`**: succeeded.
- **`AtumMobileTests`**: 391 tests, 0 failures. This includes the 4 new `DriveShareFileTests`.
- **`DriveRevampUITests`**: 5 of 5 passed, with no `DRIVE-SWIPE-MISS`.
- Run 9 changed only `DriveGroupKey.dateLabel`'s locale handling inside AtumDrive, so the app and UI runs were not repeated for it.

Earlier runs found and fixed these:

- An outer container accessibility identifier hid `drive.grid` and the gallery's image. Those identifiers moved inward.
- iOS 26 ends search with a close (X) button, not Cancel.
- A picture's zoom view took the horizontal pan at 1×, so the pager could not turn. `ZoomableMediaImage` now has a `pansOnlyWhenZoomed` option, used by the gallery only; the chat viewer is unchanged.
- In dark mode, list rows drew on black instead of the app's ground.
- XCUITest's short `swipeLeft` sometimes failed to page on a loaded host: 2 of about 12 swipes in runs 4 and 5. Run 6 was also degraded, with the internal disk nearly full and a launch with no process ID. The tests now drag most of the page width, as a person does. Run 7 logged no `DRIVE-SWIPE-MISS`.

Screenshots are in `/Volumes/AtumTestFlight/drive-revamp-shots/`:

- `drive-{en,vi}-{light,dark}-{1-icons-recents,2-view-menu,3-list-group-kind,4-icons-group-size,5-search,6-folder-icons,7-gallery-image,8-gallery-pdf}.png`
- `drive-behaviour-{list-kind,gallery-share,row-share}.png`

The share-sheet captures show the file offered under its own name ("Hội An lanterns"), not the cache key.

Not checked:

- A physical iPhone, or a live Drive account.
- ja and zh on screen.
- Dynamic Type at accessibility sizes.
- VoiceOver beyond the labels the tests read.
