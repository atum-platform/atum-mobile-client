# P4 transcript scroll engine

## Inventory before implementation

- At `80968a9`, `ios/App/Chat/Views/TranscriptView.swift:6–22` identifies the scroll-engine seam. Lines 92–150 host rows in an eager stack. Lines 278–389 track every row's position and correct the offset with delayed settling. Lines 419–427 gate new rows on drag and deceleration. Lines 466–745 cover visibility, replies, folding and routed search.
- `ios/Sources/AtumChat/FollowPolicy.swift:63–153` owns follow state, its 24-point threshold, new-message counts and jump commands. `ios/App/Chat/Stores/ConversationStore.swift:399` forwards view inputs to the core, including pagination. Neither requires delaying incoming rows during touch motion.
- `ios/App/Chat/Views/ChatScreen.swift:121–157,285–306` supplies scroll disabling, safe-area chrome and the SwiftUI environment. `ios/App/Chat/Views/ChatRowView.swift:90–165` supplies the existing menu and motion. `ios/App/Chat/Media/MediaViewer.swift:284` and `ios/App/Chat/Views/SafariView.swift:57` already bridge UIKit with representables.
- Use an estimated, single-column `UICollectionViewCompositionalLayout`, `UIHostingConfiguration`, and `UICollectionViewDiffableDataSource` with the existing row IDs. Anchor against collection layout attributes and preserve the existing keyboard recognizers and policy inputs. [Apple's collection-view sample](https://developer.apple.com/documentation/uikit/implementing-modern-collection-views), [Apple's hosting and self-sizing example](https://developer.apple.com/videos/play/wwdc2022/10072/).
- Element X iOS moved timeline rendering to a UIKit table with SwiftUI rows for scroll stability. Exyte Chat is an MIT-licensed UITableView-backed reference with its own composer and menus. Atum keeps its own rows, composer and menus and uses the native collection APIs directly. [Element X timeline rewrite](https://github.com/element-hq/element-x-ios/pull/349), [Exyte list source](https://github.com/exyte/Chat/blob/main/Sources/ExyteChat/Views/UIList.swift), [Exyte license](https://github.com/exyte/Chat/blob/main/LICENSE).

## parallel MECE workstreams

- Establish baseline and prepare replay, local test and frame-analysis tooling. The baseline uses the original revision or the original audit artifacts.
- Implement the transcript adapter and preserve visible behavior in the existing seam. Verify the assembly with the local suite and replay against the baseline after the build succeeds.

## Design

The representable hosts a transparent, single-column collection with the transcript's 16-point side margins and 8-point top and 12-point bottom padding. Diffable snapshots use existing stable row IDs and reconfigure changed rows in place. Each self-sizing cell hosts the existing `ChatRowView` and receives the chat, design, and media environment values it needs. Its hosting graph manages its own gestures. P3's send entrance animates the bubble inside the SwiftUI row, so the hosting cell can use the existing modifier and its Reduce Motion behavior.

The adapter captures the top visible surviving row before a detached snapshot and restores its distance from the viewport top after the diff. Native layout invalidation supplies offset adjustments for later self-sizing of cells above the reading row. A following chat uses the bottom edge during layout. The adapter feeds UIKit scroll motion and rounded geometry to the existing follow, pagination and read-visibility rules. The store can apply incoming rows during drag and deceleration.

Search holds the selected row at its viewport position while sizes resolve. A routed search completes after the current projection's target cell is laid out and visible. A user drag releases placement and cancels the route. The native pan and a simultaneous tap preserve the existing keyboard-dismissal directions and leave the draft in the composer.

Explicit animated scrolls use UIKit's scroll animation. The two legacy G-scroll launch arguments exercise this same renderer while retaining the existing test entry points.

## Hitch baseline

The original audit used `simctl io recordVideo` with animations enabled and scripted data. The table aggregates `ffprobe` frame-presentation gaps inside the audit's motion bursts. A gap of 250 ms or more separates bursts, and a burst must contain six or more frames. The percentages use the number of gaps as the denominator. The audit highlighted individual paging bursts in the 15–26% range, while the table also includes the faster bursts. Simulator recording and XCUITest overhead make these relative measurements.

| Scenario | Baseline motion bursts | Baseline gaps over 34 ms | Baseline worst gap |
| --- | ---: | ---: | ---: |
| Long scroll | 9 | 39/720 (5.4%) | 233 ms |
| Paging older history | 12 | 60/546 (11.0%) | 243 ms |

## Local verification

- Swift package tests passed on the Mac. AtumChat passed 821, AtumDesign passed 1,045, AtumDrive passed 48 and AtumTelemetry passed 16, for 1,930 total.
- Debug build-for-testing passed on iOS 27.0 at the first implementation and after the interaction changes.
- Two attempts to start a dedicated simulator on the external volume stalled in LaunchServices migration. The existing audit iPhone 17 booted successfully. Derived data, test scratch, result bundles and recordings use `/Volumes/AtumTestFlight/dd-polish-p4`, and the build, test and capture scripts take the shared heavy-build lock.

## Session log

- 2026-11-26. Started P4 from `80968a9`, inventoried native APIs and existing behavior before changing the transcript.
- 2026-11-26. Implemented the collection adapter and recovered the audit's baseline from the original two recordings. The transcript type-checked against local iOS Simulator modules with the current routed-search API, and design lint passed. The Debug build and Swift package run were queued on the shared build lock.
- 2026-11-26. The initial smoke run reached the latest row and reported three failures. The press-and-slide menu and keyboard dismissal failed, and the day-divider check queried a recycled offscreen row. Limited environment forwarding to the values used by the row, restored the original simultaneous tap recognizer, and made the divider assertion scroll the row into view after checking the initial position. The superseded smoke run was interrupted during pagination.
