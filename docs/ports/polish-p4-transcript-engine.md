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

The adapter captures the top visible surviving row before a detached snapshot and restores its distance from the viewport top after the diff. The transient history-loading row is skipped when selecting an anchor. Native layout invalidation supplies offset adjustments for later self-sizing of cells above the reading row. A following chat uses the bottom edge during layout. The collection extends under the glass, with content insets derived from the unobscured SwiftUI viewport. The adapter feeds UIKit scroll motion and rounded geometry to the existing follow, pagination and read-visibility rules. The store can apply incoming rows during drag and deceleration. The debug probe records a timeline-edge clamp separately from an offset correction that UIKit can perform.

Search holds the selected row at its viewport position while sizes resolve. A routed search completes after the current projection's target cell is laid out and visible. A user drag releases placement and cancels the route. The native pan and a simultaneous tap preserve the keyboard-dismissal directions and leave the draft in the composer. A short pull into the keyboard keeps a following transcript attached. A longer pull or one starting farther up continues into history.

Explicit animated scrolls use UIKit's scroll animation. The two legacy G-scroll launch arguments exercise this same renderer while retaining the existing test entry points.

## Scroll replay

The original audit used `simctl io recordVideo` with animations enabled and scripted data. The table aggregates `ffprobe` frame-presentation gaps inside the audit's motion bursts. A gap of 250 ms or more separates bursts, and a burst must contain six or more frames. The percentages use the number of gaps as the denominator. The audit highlighted individual paging bursts in the 15–26% range, while the table also includes the faster bursts. Simulator recording and XCUITest overhead make these relative measurements.

| Scenario | Baseline bursts | Baseline gaps over 34 ms | Baseline worst gap | P4 bursts | P4 gaps over 34 ms | P4 worst gap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Long scroll | 9 | 39/720 (5.4%) | 233 ms | 9 | 35/1,053 (3.3%) | 225 ms |
| Paging older history | 12 | 60/546 (11.0%) | 243 ms | 14 | 40/1,408 (2.8%) | 173 ms |

The first collection replay at `eeb7457` measured 24 of 936 gaps (2.6%, worst 177 ms) on long scroll and 38 of 697 gaps (5.5%, worst 230 ms) on paging. Its screenshot comparison also identified clipping at the navigation glass, which prompted the viewport-inset change.

The P4 column uses `d98d492` on the audit's iPhone 17 with iOS 27.0. It repeated the two scripted scenarios with animations enabled and the audit's five long-scroll flings and eight paging flings. The recording steps, clips and frame-gap counts are under `/Volumes/AtumTestFlight/dd-polish-p4`. The paging probe recorded 14 applied offset corrections and zero missed corrections. All 14 occurred during user motion. The initial long-scroll screenshot shows transcript content behind the navigation glass with a 116-point top inset.

## Local verification

- Swift package tests passed on the Mac. AtumChat passed 821, AtumDesign passed 1,045, AtumDrive passed 48 and AtumTelemetry passed 16, for 1,930 total.
- Debug build-for-testing passed on iOS 27.0 at the first implementation, after the interaction changes and after the viewport change.
- The revised smoke run passed all three selected tests for press-and-slide, keyboard dismissal with draft retention, and opening the latest row and finding a day divider.
- The first audit scroll replay passed. Its supplementary animations-enabled send capture failed when XCUITest lost composer focus before entering text.
- The replay after the viewport change passed its one audit test, which recorded both scroll scenarios.
- The initial full UI run at `d98d492` executed 72 cases, including the additional three-page search check. It passed 58 and reported 14 failures. The case log finished at 05:08. Xcode stalled during result finalization and was terminated four minutes after the completed suite totals were written. The full case log and the per-class summary are in the external logs directory.
- Two attempts to start a dedicated simulator on the external volume stalled in LaunchServices migration. The existing audit iPhone 17 booted successfully. Derived data, test scratch, result bundles and recordings use `/Volumes/AtumTestFlight/dd-polish-p4`, and the build, test and capture scripts take the shared heavy-build lock.

## Session log

- 2026-11-26. Started P4 from `80968a9`, inventoried native APIs and existing behavior before changing the transcript.
- 2026-11-26. Implemented the collection adapter and recovered the audit's baseline from the original two recordings. The transcript type-checked against local iOS Simulator modules with the current routed-search API, and design lint passed. The Debug build and Swift package run were queued on the shared build lock.
- 2026-11-26. The initial smoke run reached the latest row and reported three failures. The press-and-slide menu and keyboard dismissal failed, and the day-divider check queried a recycled offscreen row. Limited environment forwarding to the values used by the row, restored the original simultaneous tap recognizer, and made the divider assertion scroll the row into view after checking the initial position. The superseded smoke run was interrupted during pagination.
- 2026-11-26. All three smoke regressions passed on the revised build. The first scroll replay recorded lower hitch rates in both scenarios. Compared the initial viewport against the audit and added insets for drawing under the glass. Added separate diagnostics for the timeline-start clamps exposed by the paging replay and excluded the transient loading row from anchor selection.
- 2026-11-26. Replayed both scroll scenarios at `d98d492`, verified drawing under the navigation glass, and recorded the frame-gap and paging anchor results above. Started the full local UI run on this build.
- 2026-11-26. The full run passed Chat Info (14 cases), Composer (12 cases), and the three-page search check. Dynamic Type reached the detached view, then its distance assertion read an offscreen accessibility element and got `-1`. The distance helper now uses the UIKit layout probe when the newest cell is recycled. G-scroll's two initial attempts failed around the scripted typing phase. One opening screenshot comparison crossed an incoming answer. Added debug-only step pacing for the two G-scroll cases and kept their geometry tolerances and assertions.
- 2026-11-26. The full run passed live-answer folding, tap-to-dismiss and 12 of 14 message-menu cases. The static refold recording showed the toggle visible after the immediate hittability assertion. The test now waits for that state. The far-up send test dragged from a point under the navigation bar with the keyboard open, so the drag helper now starts in the visible viewport. Both model-picker cases queried `claude` while the baseline emits `claude-plan`. Updated those test identifiers and left the picker unchanged. The local accessibility audit reproduced the quote finding documented in `docs/ports/quote-contrast.md`. For a reported region inside a quote, the audit test now uses the existing pixel measurement and still requires a 4.5:1 contrast ratio.
- 2026-11-26. Both detached incoming-message checks passed with 0 pt of reading-row movement. Normal paging also passed with 0 pt maximum drift. Late details held all 12 measured reading windows at 0 pt, with all 15 adjustments applied during motion. The reaction sample now checks each viewport while paging. The first full-run day-divider check exhausted its four slow swipes before reaching the first loaded day, so it uses history flings. The working-footer check uses the debug fixture pacing and waits for the footer before measuring it.
- 2026-11-26. The keyboard-hide check reproduced a follow regression after a short pull into the keyboard. Used the window's keyboard layout guide and the pan's travel to distinguish that pull from a drag into history. The distinction preserves existing follow policy inputs for ordinary scrolling. Queued a new Debug build and focused reruns after the full run finishes.
- 2026-11-26. The full run finished its case list, including six passing turn-stop cases. Retained the per-case and suite results, then released the lock from the stalled Xcode finalizer so the focused rerun could proceed.
