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
- **Quarantine:** `QUARANTINE` lists tests that fail on `main` today, each
  tracked in atum-mobile#50. As of the first hosted run (PR #29):
  `ChatPanelUITests/testPersonPanelShowsConversationFactsAndBlocksInPlace` (the
  Block button isn't found in the sheet; the wave 3 chats lane is fixing it) and
  `ChatInfoUITests/testAssistantComposerThinkingLevelSavesTheCurrentModelWithTheChosenLevel`
  (the thinking level never reaches the scripted save, still under investigation) and
  `ChatKindsUITests/testAccessibilityAuditKinds` ("Dynamic Type font sizes are
  partially unsupported": the known avatar-monogram Dynamic Type debt, wave 2
  carry-over; its quote-preview contrast finding is a size-driven audit
  false positive, see `docs/ports/quote-contrast.md`) and
  `HomeShellUITests/testHomeSearchPeopleAccessibilityAudit` (added quarantined,
  13 Nov: at AX-XXXL one intermittent "Dynamic Type font sizes are partially
  unsupported" finding comes back with no element attached, so it can't be
  traced to a view; the control audit of the same search without the People
  section passes, and the decorative monogram is exempted by identifier. Same
  avatar-monogram family; see `docs/ports/home-search-people.md`). Third hosted run (after #28 and #31 merged):
  `HomeShellUITests/testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning`
  (Retry state not reached after a failed create, line 349) and
  `TeamSpaceDailyUITests/testChannelMarksRenderFromCountsAndMutedStaysQuiet`
  (`company.channel.ops` row not found); both under diagnosis. Remove a line when its fix lands.
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
- 2026-11-12: `HomeChatsWave3UITests/testSearchFindsAWordThreePagesBackAndCloses` is
  **quarantined** (atum-mobile#50). On `86228cb` the CI recording shows the count reaching
  "1/1" while the transcript stayed at the bottom for the rest of the 20 s wait. The search
  found the match but never scrolled to it. On the two earlier #44 heads it did scroll, late.
  That reads as an intermittent app race in scroll-to-result on a slow host, not test timing.
  It still runs locally. Remove the line when the race is fixed.
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
