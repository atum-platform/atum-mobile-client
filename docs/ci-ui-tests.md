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
  carry-over). Third hosted run (after #28 and #31 merged):
  `HomeShellUITests/testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning`
  (Retry state not reached after a failed create, line 349) and
  `TeamSpaceDailyUITests/testChannelMarksRenderFromCountsAndMutedStaysQuiet`
  (`company.channel.ops` row not found); both under diagnosis. Remove a line when its fix lands.
- 2026-11-12: `ChatInfoUITests/testAssistantCardChoosesOneServerDestinationDefault`
  failed on PR #33 (`84d891a`) because the hosted runner was slow: launch took 32 s and
  `chat.title` 30 s, then the 2 s + 3 s waits for `assistant.card.model` ran out. Its
  siblings with the same flow passed. The three card-model waits in `ChatInfoUITests`
  are now 8 s + 10 s.
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
- **Not a required check** yet. Make it required once it has been green on
  `main` for a few runs.
- No secrets, signing or uploads beyond failure result bundles. Actions are pinned
  by SHA.

Run one class against a branch:
`gh workflow run ui-tests.yml --ref <branch> -f only="ChatPanelUITests"`
