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
- **Share.** Share is in the gallery's toolbar and in each file's menu (the row's "…", or long-press in List and Icons). It downloads the file if needed, then opens the iOS share sheet. The file goes out under its own name: `DriveShareFile` hard-links or copies it out of the cache's opaque key into a temporary folder, which is cleared when the sheet closes.
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
- `ZoomableMediaImage` in the chat `MediaViewer.swift` is now internal, so the gallery can reuse it.
- **Scripted Drive host (closes D12).** `ios/App/Debug/ScriptedDriveHost.swift` is Debug-only and excluded from Release by `Scripted*.swift`.
  - Launch with `-AtumScripted home.roster -AtumDebugDrive -AtumScriptedDrive`. That puts the real `DriveScreen` and `DriveFeatureModel` on Home's Drive tab over a scripted `DriveReading`.
  - The pictures and PDFs in it are drawn at launch, so their bytes are real.
  - The host forgets the view, sort and Group By at launch unless `-AtumScriptedDriveKeep` is passed.
- `ios/AtumMobile.xcodeproj`: the four new app and UI-test files were added by hand (16 lines), matching what `project.yml`'s folder globs produce. A full `xcodegen generate` (2.46.0) reshuffles every ID of the committed project and mints one with a 13-digit run that `public_guard.py` refuses, so it was not committed.

## Known risks and follow-ups

- **Folders mixed in by name.** All files now mixes folders in by name, as desktop's Finder sort does. AC-4's folders-first order is retired.
- **HEIF.** `.heif` groups as Other, because desktop's kind table lacks it. The phone glyph still draws it as an image. Raise it with desktop if it matters.
- **Swipe preview limits.** A picture larger than 4096 px is shown downsampled. Animated GIFs show their first frame.
- **Sort on Recents.** Desktop also lets Recents be re-sorted for the visit; the phone does the same, and the menu shows the current order.

## Verification

See the session's report. Results are copied below after the locked run.
