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
