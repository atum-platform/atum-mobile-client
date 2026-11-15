# Hosted UI tests

`.github/workflows/ui-tests.yml` runs the scripted UI suite (`ios/UITests`) on
standard GitHub-hosted `macos-26` runners. Before it, every UI run waited on the
one build Mac, where all simulator work shares one lock (about an hour's queue
per run on 2026-11-11 with six lanes active).

- **When:** every pull request, and on demand (`workflow_dispatch`, optional
  `only` input naming UITest classes).
- **How:** a planning job lists `ios/UITests/*UITests.swift` and splits the
  classes round-robin into up to 4 shards. Each shard builds for testing
  (unsigned) and runs its classes on one hosted iPhone simulator. A failing
  shard uploads its `.xcresult` for 7 days.
- **Stays on the build Mac:** classes that drive the simulator through the private
  content-size runner (`scripts/sim-content-size-runner.sh` in the release repo):
  `GScrollDynamicTypeUITests`, `S1MatrixUITests`, `S6SystemUITests`,
  `TranscriptUITests`. Also `KitBoardCaptureUITests`, which captures evidence and
  is not a check. Also `GScrollUITests`: its scenario clock is too tight for the
  slower hosted runners (first hosted run, 2026-11-11: checks 3 and 9 timed out).
  These are listed in `LOCAL_ONLY` in the workflow. `LOCAL_ONLY_TESTS` holds the
  two `Wave2MediaBotUITests` tests, `AssistantsWave3UITests/testNewAssistantReadsInDark` and
  `TeamSpaceInviteUITests/testInviteSheetAtAX5DarkHasNoClippedText`, which need the
  appearance/content-size runner,
  plus three tests whose scenario windows hosted runners miss (second hosted run,
  2026-11-11): `HomeShellUITests/testInvitationShowsJoinProgressThenPushes`
  (the 0.8 s "joining" window passes before the poll sees it),
  `HomeShellUITests/testPlusOpensStartChatWithRealRowsAndAvailableCreationActions`
  (3 s push window) and
  `ChatKindsUITests/testLinksGoThroughLinkPolicyAndNothingIsReadWhileCovered`
  (UI query timed out after 195 s). All three pass on the build Mac.
- **Quarantine:** `QUARANTINE` tracks failures in atum-mobile#50. The
  2026-11-14 baseline recheck below distinguishes stale entries from remaining
  failures. Entries are removed only after repeated local verification; this
  lane does not trigger hosted CI.
  - `ChatKindsUITests/testAccessibilityAuditKinds`: avatar Dynamic Type debt;
    the new baseline also reproduces the quote-preview contrast finding
    documented in `docs/ports/quote-contrast.md`.
  - `HomeShellUITests/testHomeSearchPeopleAccessibilityAudit`: the baseline
    reproduces a Dynamic Type finding with no element attached. See
    `docs/ports/home-search-people.md` and the UI-worker handoff below.
  - `ChatInfoUITests/testAssistantComposerThinkingLevelSavesTheCurrentModelWithTheChosenLevel`:
    passes on the build Mac but still fails on the hosted runner (PR #51,
    shard 2, line 241). See "Thinking-level save" below.
  - `HomeShellUITests/testHomeSearchChannelsMessagesFilesAccessibilityAudit`
    (added quarantined, 14 Nov): the same element-less "Dynamic Type font
    sizes are unsupported" finding, frame zero. A build-Mac diagnostic audited
    roster-only, People-only, Channel-only, Message-only and File-only results
    at AX-XXXL: every global search section produced it once, the roster never
    did, and the roster rows' button style did not change it. So it belongs to
    the global search block, not to one row type. See
    `docs/ports/home-search-channels-messages-files.md`.
- 2026-11-12: `ChatInfoUITests/testAssistantCardChoosesOneServerDestinationDefault`
  failed on PR #33 (`84d891a`) because the hosted runner was slow: launch took 32 s and
  `chat.title` 30 s, then the 2 s + 3 s waits for `assistant.card.model` ran out. Its
  siblings with the same flow passed. The three card-model waits in `ChatInfoUITests`
  are now 8 s + 10 s.
- 2026-11-12: on PR #46 (`9d63d30`) shard 2 failed
  `ChatInfoUITests/testAssistantCardModelRowOpensTheComposerPicker` at the last step:
  the tapped row's "Đang dùng" value (the check) did not appear within 3 s. No crash,
  copy unchanged, and it passed on `19c5539`. That wait is now 10 s, like the others
  after the sheet opens.
- 2026-11-12: on PR #41 (`6fd2587`) shard 2's first test,
  `ChatInfoUITests/testAppInfoConfirmsPhoneOnlyChatDeletion`, failed before any test code
  ran: "Failed to launch ... Timed out while launching application via Xcode" (62 s)
  on a cold simulator. The other 24 tests in the shard passed. Each shard now boots the
  simulator, waits with `simctl bootstatus -b`, then installs, launches and terminates
  the app once before `test-without-building`. The warm-up launch is best-effort; the
  boot wait is not.
- 2026-11-12: on PR #43 (`d9c55c2`) shard 3 failed two `HomeChatsWave3UITests` that pass
  locally on #43 and on main (locked run, iPhone 17, iOS 27):
  `testSearchFindsAWordThreePagesBackAndCloses` ("the match was not brought into view":
  the recording shows the match in view, highlighted, a few seconds after the 3 s wait
  ended) now waits 10 s; `testSearchBarAtAccessibilitySizePassesTheAudit` ("Audit failed to
  complete in time" at AX XXXL) now makes one more full attempt after a timeout. A finding,
  or a second timeout, still fails.
- 2026-11-12: on PR #44 (`22ff66c`) shard 3 failed the same two tests with that hardening in place.
  The search test's recording shows the match in view and highlighted from ~34 s, yet
  `firstMatch.isHittable` stayed false for the full 10 s. The test now checks that some element
  whose label carries the word lies inside the window, and prints the hierarchy if not. A
  message that was never scrolled to is unloaded or off-window, so the check still fails then.
  The audit timed out on both attempts. A second timeout now skips the test (`XCTSkip`, with
  a `MEASURE` line) rather than failing it. A finding still fails, and locked local runs
  cover the audit. This loosens the hosted check on purpose (owner ruling: make it work first).
- 2026-11-12: on `78d9de7` the audit passed and the search test failed earlier. The count
  appeared ~0.2 s after typing, while the match three pages back was not loaded within the
  5 s existence wait; the failure dump moments later shows it in the window. The separate
  existence wait is gone, and one 20 s "in view" wait now covers loading and scrolling.
- 2026-11-12: on `86228cb` shard 2 failed `ChatInfoUITests.testAssistantCardChoosesOneServerDestinationDefault`
  (it passed on both earlier #44 heads): the model sheet's first row did not appear within 3 s of the
  tap. In `ChatInfoUITests`, each wait for the sheet's first row after opening it is now 10 s.
- 2026-11-12: the search quarantine originated in atum-mobile#50. On `86228cb`
  the CI recording showed "1/1" while the transcript stayed at the bottom
  throughout the 20 s wait; two earlier #44 heads scrolled late. The
  2026-11-14 fix below addresses the app's placement/anchor lifecycle, keeps
  the existing test waits, and restores this hosted test.
- 2026-11-14: on PR #52 (`cb57fcf`) shard 3 failed
  `HomeChatsWave3UITests/testSearchBarAtAccessibilitySizePassesTheAudit` at line 124:
  the failure message already read "Result 1 of 1. Searched 89 of 2200", so the match
  was found just after the 15 s wait ran out (PR #49 failed the same way at 70 of 2200).
  The app is correct and the hosted runner is slow at AX-XXXL; #52 doesn't touch chat
  search. That wait is now 30 s.
- 2026-11-14: `HomeChatsWave3UITests/testSearchBarAtAccessibilitySizePassesTheAudit` is
  **quarantined** (atum-mobile#50). With the 30 s wait, PR #54 (`285c443`, shard 3) still
  failed at line 126 with "No results. Searched 70 of 2200": the in-chat search walk
  stopped, not slowed (PR #49: 70 of 2200; PR #52 run 1: 89 of 2200). None of those PRs
  touch chat search. This reads as an intermittent stall in the search walk on the hosted
  runner, so it is under diagnosis as an app bug. Remove the line when the stall is fixed.
- 2026-11-14: `HomeChatsWave3UITests/testSearchFindsAWordThreePagesBackAndCloses` and
  `testSearchWithNoMatchSaysNoResultsInVietnamese` are **quarantined** (atum-mobile#50) with
  the AX-XXXL audit. All three walk the 2200-row scripted transcript, and on the hosted
  iPhone 16e / iOS 26.2 simulator the walk runs short on and off across unrelated PRs:
  #55 run 1 on main ("No results. Searched 70 of 2200", complete); PR #56's paging fix runs
  ("Searching 70 / 108 of 2200…", still in progress). The build Mac (iOS 27) passes them.
  Under diagnosis on `fix/chat-search-walk-stall` (PR #56). Remove these lines when the
  walk is fixed on iOS 26.
- 2026-11-14: `TranscriptKeyboardAndFoldUITests/testALiveLongAnswerFoldsOnceFinalAndOpensInPlace`
  failed twice on PR #55 (header-only change) at two different steps: run 1 "Show more is out
  of view" (checked 0.6 s after the fold, before layout settled) and run 2 "the answer finished
  before it was seen growing" (the scripted answer's last growth at 9.5 s and typing's end at
  13.5 s left a 4 s window the hosted runner missed). The scripted stream in
  `chat.bubbles-live` now grows every 8 s (Debug-only), and the hittable check waits up to
  5 s for the settled layout instead of a fixed pause. The waits that follow the stream
  scale with it: growth to long 20 s (lands at 9.5 s), typing's end 30 s (at 25.5 s).

- 2026-11-15: `TranscriptKeyboardAndFoldUITests/testALiveLongAnswerFoldsOnceFinalAndOpensInPlace`
  missed the streaming phase on hosted `4982102` and reported Show more out of view on
  `ea03554`. The UI test opts into a Debug-only 20 s growth interval (the ordinary
  fixture remains 8 s), observes any partial body together with typing and no toggle
  in one accessibility snapshot, then requires a longer final body and a fold.
  Show more gets a 20 s window/composer-containment wait instead of `isHittable`;
  the bottom-placement, in-place expansion and detached-chat assertions stay.
- 2026-11-15: `StoreCommerceUITests/testSettlingCheckoutWaitsNeutrallyThenOffersGet`
  missed the launch-relative 20 s settling window on hosted `2e3d39f`. A test-only
  release file now gates the Debug scripted Apple reply until the neutral wait,
  absent Get/closed line, price and absent top-up have all been checked. The test
  then releases checkout, polls for Get while checking for a closed line, and
  checks again that the closed line is absent after opening. Other slow-checkout
  scenarios keep their existing clock; Release is unaffected.
- 2026-11-15: `HomeShellUITests/testSearchFiltersNamesAndCancelRestoresRows` failed
  on hosted `9d63d30` (run 43180498415), line 183: the 2 s no-results assertion
  expected the old conversation-only empty text. Baseline `61612ed` already uses
  the current global-search text. Keep that text and all filter/clear/cancel
  assertions, give the transitions 15 s and add messages identifying the failed
  state. No product copy changes.
- 2026-11-15: `AssistantsWave3UITests/testRoutineRowsSayTheScheduleAndPauseFromASwipe`
  failed on hosted `67ca0cc` (run 43052459166), “no swipe Pause”: the 2 s wait
  after the swipe expired before the hosted simulator exposed the action.
  Wait up to 15 s for Pause; the schedule, tap and paused-state checks stay.
- 2026-11-15: `TranscriptUITestSupport.launchTimedChat` now waits 30 s instead of
  8 s for the initial latest row to paint after the source starts. The reported
  hosted failure was at line 40; its run SHA was not supplied and could not be
  recovered from the available failed hosted logs (baseline `61612ed`). The
  source-start probe and all timed-scenario assertions remain unchanged. Verify
  this shared boundary through `TranscriptUITests`, including the timed U2 test.

- **Not a required check** yet. Make it required once it has been green on
  `main` for a few runs.
- No secrets, signing or uploads beyond failure result bundles. Actions are pinned
  by SHA.

Run one class against a branch:
`gh workflow run ui-tests.yml --ref <branch> -f only="ChatPanelUITests"`

## Local-only failure: `ComposerUITests/testTheModelSheetListsTheAccountSubscriptions` (2026-11-12)

Failed locally ("no Subscriptions section", iOS 27.0 simulator, iPhone 16e and iPhone 17) while hosted
`macos-26` shards passed it. Cause was in the test, not the app or the environment: it waited for
`app.navigationBars.firstMatch`, which is the chat's own bar behind the model sheet, then swiped up on it.
The swipe lands on the dimmed area and dismisses the half sheet (the recording shows the sheet open, then the bare
chat). The test also never scrolled the sheet, whose list is lazy and opens at the medium detent. The test now waits
for the sheet's `composer.model.close` button and scrolls inside the sheet until the header exists.
Which bar `firstMatch` returns differs between the hosted runtime and the local iOS 27.0 runtime; that is the likely
reason hosted passed, but it was not verified on a hosted runner. After the fix the test passes locally on both devices.

## Quarantine baseline recheck (2026-11-14)

Before source edits, all seven quarantined tests ran against `161ada7` on one
locked iPhone 17 simulator (iOS 27.0, Xcode 27). There were **3 passes, 4 failures,
0 skips**. The result bundle is `dd-approvals-2b/quarantine/baseline.xcresult`
inside the assigned build/scratch volume. Use that bundle and the extracted
`baseline-tests.json` / activity JSON files as the baseline evidence: the local
shell wrapper overwrote its console log after the suite completed. The bundle
retains all seven outcomes and durations.

| Quarantined test | Baseline result | First observed boundary |
| --- | --- | --- |
| `ChatInfoUITests/testAssistantComposerThinkingLevelSavesTheCurrentModelWithTheChosenLevel` | PASS, 25.100 s | The scripted save and unchanged current-model check both pass. |
| `ChatKindsUITests/testAccessibilityAuditKinds` | FAIL, 78.103 s | Contrast on the quote preview “Mình đi được, hẹn 12 giờ nhé.”; existing Dynamic Type debt remains. |
| `ChatPanelUITests/testPersonPanelShowsConversationFactsAndBlocksInPlace` | FAIL, 41.251 s | `info.block` exists; XCTest scrolls it during the tap, then the confirmation is absent. |
| `HomeChatsWave3UITests/testSearchFindsAWordThreePagesBackAndCloses` | PASS, 34.621 s | One local pass does not resolve the documented intermittent hosted race. |
| `HomeShellUITests/testHomeSearchPeopleAccessibilityAudit` | FAIL, 27.099 s | Dynamic Type unsupported, no target, zero frame. |
| `HomeShellUITests/testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning` | FAIL, 30.542 s | The disclosure is not found at the old line 341; creation/Retry is never reached. |
| `TeamSpaceDailyUITests/testChannelMarksRenderFromCountsAndMutedStaysQuiet` | PASS, 38.936 s | The existing `f08450a` reveal logic reaches every channel and checks the marks. |

All local heavy commands use `TMPDIR=/Volumes/AtumTestFlight/tmp`, the shared
`.heavy-build.lock`, two build jobs and the existing `dd-approvals-2b` derived
data/scratch tree. Each verification batch boots one simulator and shuts down
all simulators on exit. The cached SDK packages are APFS clones within that
scratch tree. Subsequent runs use `-collect-test-diagnostics never` to avoid
Xcode's 600-second post-failure simulator-log collection; assertions, ordinary
failure attachments, logs and result bundles remain enabled.

## UI-worker handoff: audits retained

No visual, layout, copy or audit-exemption change belongs to this lane.

- `AtumAvatar` (`ios/App/DesignSystem/AtumAvatar.swift`) resolves its face through
  `@ScaledMetric`, then caps the face at `baseSize * 1.35` in `cappedPointSize`.
  The monogram font is `.system(size: size * monogramScale)`, so it inherits that
  cap and stops growing at accessibility sizes. Proposal for the UI owner:
  scale the glyph independently with a second `@ScaledMetric(relativeTo: .body)`
  initialized from `baseSize * monogramScale`, then check its fit inside the
  prescribed face across the full Dynamic Type range. The UI owner decides any
  necessary face/fit adjustment. Do not hide the finding or enlarge exemptions.
- The People audit reproduces an untargeted, zero-frame Dynamic Type issue.
  This run cannot attribute that issue to a particular view. The capped glyph
  is a concrete shared limitation and a candidate for an isolated view change,
  not proof that it is the only cause of the untargeted finding. Re-run the
  People audit and its roster-only control after the view change.
- The kinds audit also fails on footnote-size quote-preview contrast in this
  baseline. `docs/ports/quote-contrast.md` records passing measured token/pixel
  ratios and a finding that follows font size even with darker ink. The UI
  owner must evaluate the proposed semantic quote-font adjustment and re-run
  the audit; no quote colour/font/layout change or new exemption was made here.

## Verified removals (2026-11-14)

### Thinking-level save: passes locally, fails hosted (re-quarantined)

**Correction, 2026-11-14:** the removal below was wrong. On PR #51's first hosted
run (`9d34aee`, UI shard 2) the test failed at `ChatInfoUITests.swift:241`, "The
thinking level did not reach the scripted save boundary" (16.3 s), the same
failure that put it in quarantine. The local evidence (iOS 27 on the build Mac)
does not carry over to the hosted macos-26 runner, so the test is back in
`QUARANTINE` (atum-mobile#50) until the hosted-only cause is found. The four
other removals in this change passed on hosted CI.

The original (local-only) note follows.


`ChatInfoUITests/testAssistantComposerThinkingLevelSavesTheCurrentModelWithTheChosenLevel`
needs no app or test change. It passed the untouched `161ada7` baseline, then
three consecutive repetitions in fresh test-runner processes (36.638, 38.466,
30.135 s). The entire `ChatInfoUITests` class passed **12/12**, including this
test again (32.871 s). Every run retained the scripted save boundary
`saved nguyet-thuc 2 high`, the selected thorough
level and the unchanged current-model check. The quarantine was stale.

Evidence: `baseline-model-repeat.xcresult` and `baseline-model-repeat.log`
(the log has all three repetition outcomes; XCTest's summary counts one unique
test), plus `baseline-model-class.xcresult` / `.log`, under the same quarantine
scratch folder. This repeat/class build also compiles the pending search and
scroll-interaction fixes; the model save path and its test are unchanged.
No hosted workflow was triggered.

### Person-panel Block: reveal before tapping

`ChatPanelUITests/testPersonPanelShowsConversationFactsAndBlocksInPlace` failed
on the baseline after XCTest implicitly scrolled `info.block` during `tap()`;
the confirmation never appeared. The test now reveals the whole button inside
the panel's own scroll view, then taps it. The additive
`TranscriptUITestSupport.revealByScrolling` helper requires existence,
hittability and full containment in that scroll container. It scrolls only
while the target is outside the viewport, with a bounded number of gestures;
it adds no sleep or timeout. No existing support method was rewritten.

The Block confirmation, Unblock transition, low-priority switch and two scripted
ignore writes remain asserted. No app or visual change was needed. Fresh-run
repetitions passed **3/3** (57.641, 39.878, 41.175 s). The entire
`ChatPanelUITests` class passed **4 tests with 1 existing iPad-only skip**, no
failures; Block passed again in 31.243 s. Its quarantine entry is removed.
Evidence: `assembly-1-ChatPanelUITests-repeat.xcresult` / `.log` and
`assembly-1-ChatPanelUITests-class.xcresult` / `.log`.

### New assistant: reveal the disclosure in its form

`HomeShellUITests/testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning`
failed on the baseline before any create/Retry assertion: the added photo,
handle and persona fields put the disclosure below the keyboard in the lazy
form. The test now identifies the form containing the visible name field,
resolves that container by index so it remains addressable when cells unload,
reveals the disclosure, then scrolls back to the name field. It still checks
the disclosure before Create, the disabled name plus Retry state, and the two
unchanged `newAssistant Mây` probe writes. The prior `f08450a` nonduplicate-name
fix remains intact. No assistant creation state, layout or copy changed.

Fresh-run repetitions passed **3/3** (48.722, 32.094, 32.698 s), and the test
passed inside the full class (31.438 s). `HomeShellUITests` ran all **21 tests:
20 passed, 1 failed**. The sole failure is the retained People accessibility
audit with the same untargeted Dynamic Type finding; the roster-only control
and the full roster audit both passed. That visual audit remains quarantined;
only the new-assistant entry is removed.
Evidence: `assembly-1-HomeShellUITests-repeat.xcresult` / `.log` and
`assembly-1-HomeShellUITests-class.xcresult` / `.log`. In `HomeShellUITests.swift`,
only this test method is edited; `HomeScreen.swift`, its search sections and
`LiveRosterRows.swift` are untouched.

### Channel marks: already passing

`TeamSpaceDailyUITests/testChannelMarksRenderFromCountsAndMutedStaysQuiet`
already passes on `161ada7`. `f08450a` fixed the old test's lookup of lazy
below-fold channel rows by revealing them before reading their marks, but the
quarantine entry remained. No badge logic or test change is needed here.
The baseline passed in 38.936 s; fresh-run repetitions passed **3/3** (21.129,
22.408, 27.398 s). The complete `TeamSpaceDailyUITests` class passed **10/10**,
including the marks test again (21.058 s). Mention, unread, muted and tab-count
assertions are unchanged, and the stale quarantine entry is removed.
Evidence: `assembly-1-TeamSpaceDailyUITests-repeat.xcresult` / `.log` and
`assembly-1-TeamSpaceDailyUITests-class.xcresult` / `.log`.

### In-chat search: retain the requested match through late layout

The untouched baseline's search pass is insufficient to clear the recorded
intermittent race. The first local fix preserved a pending request through
missing geometry and stopped follow/hold callbacks from overriding placement,
but its fresh-run check was **2 passes, 1 failure** (45.945, 33.464,
103.064 s). The failed recording still says `1/1` while showing earlier rows,
and the hold probe records an ordinary reading anchor on `chat.search.0030`
instead of the requested match. A single apparent successful placement had
released the search anchor before the page's remaining layout arrived.
Evidence: `assembly-1-HomeChatsWave3UITests-repeat.xcresult` / `.log`, exported
recording/activity attachments and `search-attempt-1-last.png` in the scratch
folder. The existing 15-second count and 20-second visibility waits are intact;
the visibility assertion now also requires the match between the navigation
bar and search bar, above the keyboard.

The fix keeps the explicitly requested row as the anchor after
its first successful position. Row/viewport geometry can correct that anchor
later; no polling timer remains while it is in place. Near-bottom samples keep
following detached while Find owns the position; actual visibility still
drives read receipts. A drag, explicit jump,
new query, close, row removal or disappearance cancels it. Repeated scroll
commands against unchanged layout measurements remain bounded at 14. Search close and a
query with no current match clear the stale focus and return the settled
position to the normal follow/hold rules. The Debug-only
`search-placement.txt` probe records target, focus, geometry, motion and
cancellation for scripted runs; it contains no message body and is compiled
out of Release. No layout, font, copy, test timeout or audit exemption changed.

The revised fix passed **3/3 fresh-run repetitions** (32.764, 26.969,
23.213 s), then the complete `HomeChatsWave3UITests` class passed **7/7**,
including search again (33.781 s), the largest-text search-bar audit (27.978 s)
and the no-results walk (32.342 s). The Debug probes retain the requested
`chat.search.0052` anchor through placement and report cancellation with
`focus=nil`, `open=false` when Close is tapped. Its quarantine entry is removed.
No timeout, skipped assertion or audit exemption was added.
Evidence: `search-2-repeat.xcresult` / `.log`, `search-2-class.xcresult` / `.log`
and the three fresh `search-placement.txt` probe files. Other restored tests'
successful repeat/class runs exercise paths that do not open in-chat search;
their test fixes and assertions are unchanged by this revision.

Final quarantine: only `ChatKindsUITests/testAccessibilityAuditKinds` and
`HomeShellUITests/testHomeSearchPeopleAccessibilityAudit`, with the visual
causes/proposals recorded above. Five entries are restored. No Home search
view, avatar, quote styling, layout or product copy was changed by this lane.
The final public-boundary check is
`python3 scripts/public_guard.py --base 161ada7 --head HEAD`; its output is
retained as `quarantine/public-guard.log` alongside the result bundles. Work is
committed locally only; no push, pull request, hosted CI or deployment was run.


## In-chat search page-publication race (2026-11-14)

The terminal “No results. Searched 70 of 2200” label is not a walk waiting
for row layout. `2200` is the product search bound; `chat.search` contains
140 messages, configured for 40 cached events and older pages of 20.
Projection hides transient events, so the observed searched counts are
35 → 52 → 70 → 89 when the match is found on page 3.
The Debug gated-source regression reproduces exactly `complete`, one page,
70 searched, bound 2200 against the unchanged app while the matching page is
still withheld. Publishing it later cannot restart that completed walk. `rowsChanged` can
still update the match count, but does not update terminal walk progress or
request focus, explaining late “Result 1 of 1. Searched …” labels too.

`paginateBackwards` returns independently of the ordered source-output →
mapper → projector → main-actor publication pipeline. The old search loader
released the core's page claim at the call's return, then waited at most one
second for **any row-count change**. Adding/removing the loading row could
satisfy that condition, and a slow publication could outlast it. Search could
consume its page budget or see timeline-start before searching the page's
rows. Cancelling a query also cancelled those sleeps; after four seconds
waiting for a claimed slot, the loader could issue a page without owning it.

`TimelineController` normally keeps page completion behind the ordered
pagination idle publication, after the preceding batch and loading-row
removal reach the store. This applies to scroll/background pages too. The
review follow-up below adds an explicit queued-output flush and a five-second
fallback for absent/deduplicated status callbacks. Closing the controller, a
broken projection, or source-stream termination also releases the wait.
`LiveConversationStore` owns and shares each search-page task through that
barrier; a new query joins the existing page, and detach/close cancels its
owner. Slot acquisition no longer falls through after a timed polling limit.
No transcript view structure, layout, search bound, wait, or assertion changes.

Regression coverage lives in `HomeChatsWave3StateTests`: a controllable source
returns before publishing an older match, holds the output beyond the former
one-second fallback, and releases it explicitly. The unchanged app fails by
completing at 70; the fixed app must remain pending and then find row 71.
Additional tests cover query replacement during an unpublished page and
teardown. Search UI tests now pass `-AtumScriptedSearchPageDelay 1.2`; the
Debug probe delays older batches while retaining output order, exercising the
slow-runner interleaving at AX-XXXL. Walk phase, page count and searched count
join placement events in `search-placement.txt`, without logging query text.

The audit test was absent from `QUARANTINE` on the original main baseline
(`ba594e1`). PR #54 (`feat/handles-ui`) introduced its quarantine line; it is
present again on PR #56's `b6ac948` baseline. The new iOS 26.2 input-delivery
investigation below retains that line pending verification on that runtime.

Verification on iPhone 17 / iOS 27, one simulator under the heavy-build
lock, with two build jobs and a shared derived-data directory:

- Before the fix: the gated publication test failed at `complete`, 70 searched
  (three assertions); the query-replacement coverage passed.
- After the fix: all 1,631 Swift package tests and 12 focused app state tests
  (`HomeChatsWave3StateTests` and `HomeChatsWave2StateTests`) passed.
- `testSearchBarAtAccessibilitySizePassesTheAudit`: 5 consecutive delayed-page
  runs passed, zero skips. All five probes recorded 35 → 52 → 70 → 89, found
  on page 3.
- The complete `HomeChatsWave3UITests` class: 7/7 passed, zero skips, including
  another AX-XXXL audit run. The delayed no-match walk completed all five
  older pages at 128 projected event-content rows.
- Existing search waits and assertions are unchanged. The simulator was shut
  down before the locked batch released. No hosted CI, push or deployment.


### Review follow-up: missing pagination statuses

Review of `d6edefb` identified that SDK status notifications can be absent or
deduplicated, so idle cannot be an unconditional completion requirement.
Tracking is installed on the controller's main actor before the SDK call;
the consumer cannot process a status from that call before tracking exists.
After the call returns, an output-boundary marker drains already-queued
publications. The SDK source inserts this marker into its **input** stream,
behind callbacks still awaiting mapping; the scripted source and delayed
probe preserve the same ordering. This avoids using `Task.yield`, a loading
row, or a guessed delay as proof that queued work was published.

After that flush, a call with no observed `.paginating` returns its SDK
result immediately. A call which observed `.paginating` waits for published
idle, with a five-second bound covering both the flush and idle wait. Timeout
returns the SDK result and writes `search.page.timeout` to the Debug
`search-placement.txt` probe. It also clears a remaining loading status and
row: otherwise the core's next page could remain blocked even after the
controller returned. Ended output streams release the wait too.

Both controller callers were checked: the search loader and the common
scroll/background effect runner. The core already claims one page at a
time; scrolling is held while search owns that claim, and search waits while
scrolling/background work owns it. Core tests cover both directions. An
unexpected concurrent controller call now joins the current request and
receives its result, rather than throwing a cancellation error for a scroll
load. Shared-collection paging calls the SDK directly and is unchanged.

`TimelinePaginationPublicationTests` uses controllable sources for no status
(with queued rows), immediate timeline start, a status consumed before SDK
return, statuses queued after return, missing idle, ended outputs, and
concurrent search/scroll callers. The missing-idle test injects a 100 ms
bound, checks completion at that bound and a cleared loading status, and
successfully requests a second page. Production defaults to five seconds.
The original 70-row gated regression remains unchanged.

Follow-up verification (same heavy-build lock, two jobs, `dd-search-stall`,
one iPhone 17 / iOS 27 simulator):

- All 1,632 package tests passed, including both core page-ownership directions.
- All 19 focused app tests passed, including the original stall regression and
  seven controller cases. No-status and timeline-start cases returned in
  1 ms; the two 100 ms missing-idle requests completed in 206 ms together.
- The AX-XXXL audit passed 5 consecutive delayed-page runs, zero skips.
- The full `HomeChatsWave3UITests` class passed 7/7, zero skips. All eight
  search probes in this rerun used normal completion, with zero timeout
  fallbacks. Existing waits and assertions remain unchanged.
- The simulator was shut down inside the locked script before it exited.
  The follow-up is committed locally only; no push, PR, hosted CI or deploy.


## PR #56 run 2: completed walk for a malformed query (2026-11-14)

The supplied `pr56-run2-shard3.xcresult` identifies iPhone 16e, iOS 26.2,
OS build `23C54`. Its failed AX-XXXL audit does **not** show a walk stopping
short. `xcresulttool get test-results activities`, exported attachments and
exported diagnostics establish the following:

- XCTest requested `da lat` at 15:11:35.801 UTC. The synthesized-event binary
  plist also contains `string = da lat` and `typingSpeed = 60`.
- The screen recording shows `d` while typing, then `da at`; the missing `l`
  stays missing. The failed app's AX snapshots report `chat.search.field`
  value `da at` from 15:11:37.666 through the end of the test. There is no
  captured field value `da lat` for that app process.
- The AX count changes to Searching 35 at 15:11:39.198, 52 at 15:11:41.525,
  70 at 15:11:45.157, 89 at 15:11:49.788, and 108 at 15:11:54.962. At
  15:12:01.740 it says **No results. Searched 128 of 2200**. The assertion
  fails at 15:12:08.930, over seven seconds after that terminal result.
- 128 is the full projected event-content count of this five-page fixture;
  2200 is the search bound. The deterministic scripted fixture test confirms
  that `da at` completes at 128 with no match, whereas `da lat` finds one
  match on page 3 at 89. More waiting cannot make the wrong query match.
- The subsequent three-pages-back test on the same hosted device actually
  receives `da lat` and reports Result 1 of 1 / Searched 89 at 15:12:40.555,
  about 13 seconds after its typing activity started.

The bundle has the recording and synthesized-event attachments, plus AX
stdout in exported diagnostics. It has **no** `search-placement.txt` probe
attachment/file or `search.walk` / `search.page.timeout` lines in those logs.
Therefore this artifact cannot establish whether any individual page hit
its five-second fallback. Some progress intervals are several seconds long,
but the completed full-fixture walk and malformed field value explain this
failure independently. It is not evidence for increasing the search wait.

No production app change is justified by this artifact. The binding forwards
received text to `ChatSearchSession.setQuery`, which stores it unchanged;
only Return handling strips newlines. The missing character could originate
in event synthesis or the UIKit/SwiftUI text-input/update interleaving. The
available traces do not distinguish those causes, and this investigation
does not claim that fast real-user typing is unaffected.

A local baseline run on iPhone 16e / iOS 27 reproduced a separate input
setup failure: iteration 2 could not synthesize typing because neither the
field nor a descendant had keyboard focus. The helper had accepted any
visible keyboard as proof of field focus. Setup now taps the search field
explicitly, then asserts keyboard presence within the existing five-second
window. This is a test action, not a product focus or layout change; it does
not establish why the hosted run lost only `l`.

Test changes preserve bulk `typeText`, the page delay, all existing wait
budgets, result assertions, and the quarantine. Each search test now asserts
the field's exact value immediately after typing. An input failure fails there,
with its actual value, rather than being mislabeled as pagination 30 seconds
later. Teardown attaches `search-placement.txt` with keep-always lifetime,
including the intended synthetic query (or an explicit missing-file note).
The new deterministic package test compares both delivered strings through
the real scripted player, projector, index and bounded history search.

The honest next step on iOS 26.2 is to compare bulk injection with paced
single-character typing and exact prefix readback, with the probe attached.
For the bar's accessibility audit, confirmed input can be a setup
precondition; retain a separate bulk-typing check to keep character loss
visible. Do not silently retry/repair the string, accept `da at`, extend the
search wait, or restore the quarantined test based only on iOS 27 results.

Local runtime inventory contains **only iOS 27.0 (24A434)**. No iOS 26 runtime
was downloaded or installed. The local batch uses the installed iPhone 16e
device type (390 × 844 points) with iOS 27, so it matches device size but
cannot reproduce or clear the iOS 26.2 input-delivery issue.

Verification: pending the locked local batch in `dd-search-stall`.

### Search walk follow-up (2026-11-15)

The controller unnecessarily required an output boundary after a published
loading-to-idle transition. The ordered consumer has already published the page
rows at that point; the boundary is needed only when pagination emits no status.
The preserved `testPublishedIdleCompletesWithoutAnOutputBoundary` regression
checks this path. The candidate fix accepts that transition independently.

Hosted run 43610604978, shard 3, was downloaded and inspected with xcresulttool.
The three-pages-back test failed after 46.8 s, still searching 70 of 2200 rows;
its count reads were several seconds apart. This confirms incomplete progress,
but does not establish that the redundant boundary wait caused that run.
All three chat search walk tests remain quarantined under atum-mobile#50.

### Search walk quarantine lifted (2026-11-15)

PR #56 (search waits for page publication, bounded) merged on an all-green head, but its
hosted shards skipped the three walk tests. This change removes
`testSearchBarAtAccessibilitySizePassesTheAudit`, `testSearchFindsAWordThreePagesBackAndCloses`
and `testSearchWithNoMatchSaysNoResultsInVietnamese` from `QUARANTINE`, so the hosted
iPhone 16e / iOS 26.2 shards run them again. That hosted run is the evidence for
atum-mobile#50; iOS 27 results on the build Mac are not. If the walk runs short again,
restore the lines with the failing run linked here rather than extending any wait.
Local AtumChat verification passed all 730 tests under the shared lock. The
state/UI verification initially failed before building because device lookup
required the exact name `iPhone 16e` (the device is `Atum iPhone 16e`). The
corrected run queued behind other tasks, but the build volume subsequently
became unavailable and the queued processes disappeared. State/controller
regressions and the three UI repetitions remain unverified. Only iOS 27.0 was
installed; the intended fallback was iPhone 16e on iOS 27.0. Do not lift quarantine
on this evidence.

The coordinator subsequently verified the prior head on iPhone 17e / iOS 27:
399 app tests ran with one failure, the preserved joined-search regression;
two complete HomeChatsWave3 UI runs passed, and the third failed query-entry
checks (`qqz` / `da at` instead of `qqzzxx` / `da lat`). The shared-page bug
is confirmed: the original caller cleared the handle after awaiting it, allowing
a joined walk to resume first and consume its 40-page budget on the same
completed task. Cleanup now runs inside the shared task before any waiter
receives its result. The regression assertions are unchanged. Query entry now
uses character-by-character typing with three bounded, logged attempts and
requires the field value to match before testing search behavior. Follow-up verification used iPhone 17e / iOS 27.0, the shared lock,
two build jobs, and the existing derived data. Build passed; all 399 app tests
passed, including the unchanged joined-page regression and published-idle
regression. All three search tests passed in UI runs 1 and 2 (6 executions,
0 search failures; no query retries were logged). The full classes had 1 and
2 non-search failures respectively: a stalled panel launch recovered by
terminating the app in run 1, and missing Home long-press targets in run 2.
Run 3 had the same two Home failures and stalled during panel launch. After
runner recovery, it stalled again before query entry in the accessibility search
launch; that run was stopped. Thus a clean third search repetition remains
unverified. Logs and process samples were retained in the external verification
directory. Quarantine remains unchanged pending reliable hosted verification.

### Review follow-up

Search slot acquisition now has a monotonic four-second deadline and fails when
attachment or paging never makes the slot available; later queries receive a
new bounded attempt. The controller also clears its coalesced request inside
the shared task before releasing waiters. The joined-walk regression documents
its most-recent-waiter scheduling assumption. At the start of history, search
waits 300 ms and rechecks matches because SDK status and diffs have independent
listeners; this bounds the grace period rather than guaranteeing arbitrarily
late diffs. A regression delivers the final match after idle. UI query retries
select all before clearing, independent of cursor position. Scripted probe stop
now cancels its relay and finishes its stream, including cancellation exits.
The unrelated checkout delay and corresponding test waits are restored to main;
no chat search test needs the store change. Quarantine remains unchanged.

Review follow-up verification passed on iPhone 17e / iOS 27.0: build succeeded,
400 AtumMobileTests passed (including the unreleased-slot deadline regression),
and HomeChatsWave3UITests passed 7/7 in each of three runs (21/21 overall,
9/9 search walk executions). No query retries were logged, so the select-all
retry branch was not exercised by these runs. The AtumChat package suite passed
731/731, including the new idle-before-diffs final-page regression. All build
and test commands used the shared lock, two jobs, and existing derived data;
the verification script shut down simulators afterward. These local iOS 27
results do not lift the iOS 26 hosted quarantine.

## Hosted flake hardening verification (2026-11-15)

Local-only checkpoint from `61612ed`, on `test/hosted-flake-hardening`.
The single locked batch builds and tests with scratch, derived data and package
cache on the assigned external volume, two jobs and one iPhone 17 / iOS 27
simulator. `build-for-testing` passed. The first focused repetition passed the
live fold, settling checkout, Home search and routine swipe tests. The shared
30 s initial-paint wait also passed; the unchanged timed U2 test subsequently
missed its short typing-footer window during a slow accessibility snapshot.
The remaining repetitions and five full classes are still running. Results
and logs are retained under `dd-flake-hardening/results` on that volume.
Final outcomes and outbound-guard evidence will replace this checkpoint note.
