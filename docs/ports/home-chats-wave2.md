# Home and chats, wave 2 (HC-3, HC-4, HC-5)

Parity plan v2, wave 2, stream HC. Audit evidence: lane 1 slices S3, S4 and S5, checked against the shipped Matrix renderer at atum-app `050ede8edf5`.

## HC-3: an assistant at work shows on its Home row (L1-S3)

Desktop (`m/roster-working.ts`, `m/roster-conversations.tsx:131-146`, `:186-187`, `:1097-1100`) puts Atum's atom where the row's time goes while an assistant's turn runs, with "Lan is working" for a tooltip and a screen reader. The current step replaces the preview when the runtime knows it. Otherwise the preview stays.

The phone:

- `RosterWorking.rooms(typing:ownUserID:assistantRoomIDs:)` (AtumChat) is the rule. An assistant room is working while anyone other than me is typing in it. Only my assistants' own rooms count. People, groups and app bots never show the atom.
- `HomeAssistantActivity` (`ios/App/Home/`) subscribes to `Room.subscribeToTypingNotifications` for the assistant rooms Home lists. That is a handful of rooms, all already in the SDK room list. It publishes `workingRoomIDs`. Changing the session drops every old subscription.
- `HomeRow.isWorking` and `HomeRow.memberCount` are live-only. `HomeRow.applyingLive` sets them after the cached or live rows are chosen. They are never written to `ChatListSnapshot`, so a cold launch never paints a stale atom.
- `HomeRowView` draws `AtomWait` in the time slot and reads `working-copy.copies.working` ("Lan is working") in place of the time. As on desktop, the atom is hidden while Home is searching.
- The preview line is unchanged. It is the room's latest event, which during a turn is usually the agent's `io.atum.progress` working line. So the current step shows when the agent posts one.

Why typing and not desktop's activity: desktop reads its own agent runtime (`snapshot.agentTurns`, `electron/matrix/main.ts:7475`). The phone has no runtime. The SDK's `LatestEventValue` carries no raw JSON, so the `io.atum.progress` marker cannot be read from the room list. The agent's typing notice is the one per-room signal the phone gets without opening the timeline.

Debug capture: `-AtumScripted home.roster -AtumDebugWorking` shows the first assistant at work (`ScriptedHomeHost.workingRows`).

## HC-4: empty chat greeting and starters (L1-S4)

Desktop `AssistantGreeting` (`m/greeting.tsx:24-58`, `m/app.tsx:5656-5675`): the assistant's large face, the time of day's greeting, "What can I do for you today?", and three starter chips that fill the composer without sending. People and groups show "No messages yet."

The phone (`EmptyChatGreeting.swift`, `ChatScreen`):

- Assistant chats: the title capsule's own face at 64 pt (`ChatInfoAvatar`, so the crescent, photos and marks match), then the greeting by hour (`EmptyChatPolicy.period`, desktop `greetingFor`: morning from 5, afternoon from 12, evening from 18), the prompt, and three capsule chips in a centred wrapping row.
- A chip calls `LiveConversationStore.pickStarter(_:)`. That sets the draft as desktop's `composer.edit` does, replacing any draft, and bumps `composerFocusRequest` so the keyboard comes up. Nothing is sent. Chips show only while a composer exists (no read-only banner).
- People, groups and app-bot rooms without a hero: `EmptyChatNote` ("No messages yet.", `src.matrix.copy.copies.empty`). The Founder card, first-run greeting and app-bot hero keep their places ahead of these.
- Copy: `mobileScreensCopy.greeting.{morning,afternoon,evening,prompt}` (the export's copy of desktop `matrixShell.greet*`, the same words in every locale) and `chat-copy.copies.starters.{0,1,2}.{label,text}`. All are in `ChatCopyKey`, so `ChatCopyContractTests` checks every locale. The old `uiGreeting` key stays in `ChatCopyKey` but no longer draws.

## HC-5: Start chat completeness (L1-S5)

Desktop `m/start-chat.tsx:100-347`. The phone `HomeStartChatSheet`:

- Structure as desktop: **Assistants** · **People** (people, then groups, then an inline "New group" row when not searching) · **Apps**. Footer: New assistant · Add friend. New group moved from the footer into the People section.
- Captions: a group shows "N members" (`roster-create-copy.copies.members`, at least 1). The count is the SDK's joined plus invited count, live-only, via `HomeRow.applyingLive`. An assistant whose chat has not reached the phone is now listed, disabled, with its "Getting ready" line. Desktop lists every projected agent.
- "Find @x on Atum": `StartChatQuery.parse` ports desktop `parsePersonQuery`. A handle (`^[a-z][a-z0-9_]{2,31}$`, optional `@`) pushes Add friend with the handle filled in and the search already started (`HomeAddFriendView.initialHandle`). A full Matrix address opens through `peopleDiscovery.open` directly, as desktop accepts it quietly. A failure shows `startFailed` under the row.
- No match: `ContentUnavailableView` with "No matches", plus the @name hint when finding people is available.
- Return in the search field picks the first openable row. With no rows it finds the typed @name.

## Shared-file and cross-stream edits

- `ios/App/AppRoot.swift` (shared): a `@State HomeAssistantActivity`, one `.task(id:)` on `HomeScreen` that calls `watch`, and `HomeRow.applyingLive(...)` around the rows in `homePresentation`, with member counts from `model.liveMatrix?.rooms`. All additive.
- `ios/App/Debug/ScriptedHomeHost.swift`: the `-AtumDebugWorking` capture switch.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: two file references (`HomeAssistantActivity.swift`, `HomeChatsWave2StateTests.swift`), added by hand. `xcodegen generate` reorders about 100 unrelated lines with the installed version.
- `ios/App/Chat/Views/Composer.swift`: one `.onChange(of: store.composerFocusRequest)` line. The composer area is otherwise untouched, so ST-5's chat top-up entry merges cleanly.

## Verification

All heavy runs used the shared lock (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`) on the iPhone 17 simulator (939B69F8), 2026-11-11:

- `swift test -j 2` (whole package): AtumChatTests 591, AtumDesignTests 677, AtumDriveTests 16, AtumTelemetryTests 16. 0 failures. New: `HomeChatsWave2Tests` (9), `ChatCopyContractTests.testHomeWave2KeysResolveInEveryPinnedLocale`.
- `xcodebuild … -scheme AtumMobileStateTests -only-testing:AtumMobileTests test`: 302 tests, 0 failures. New: `HomeChatsWave2StateTests` (5). This includes the app build.
- Selected UITests (`-scheme AtumMobile`): `HomeShellUITests.testStartChatFindsATypedHandleOnAtum` (new), `testAddFriendFormNormalizesHandleAndShowsDirectoryResult` and `TranscriptUITests.testU10EmptyChatShowsTheGreeting` passed. `testPlusOpens…` and `testNewGroup…` failed on the first run because the inline New group row sat below the medium detent. They now scroll to it, and the rerun passed both. `S1MatrixUITests.testEmptyChat` cannot run here: its setUp needs the matrix runner's appearance host ("no simulator appearance runner beside the matrix").
- Simulator captures (scripted hosts): empty assistant chat in en light, en dark and vi, and Home with `-AtumDebugWorking` in en light and vi dark. Kept outside the repo in `/Volumes/AtumTestFlight/swiftbuild-w2-hc/logs/shot-*.png`.
- `scripts/public_guard.py --base origin/main --head HEAD`: PASS.

## Not done, gated, or unverified

- **Person @handle captions** in Start chat (and on Home rows): the phone has only forward alias lookup (`aliasLookup(handle:)`). Showing a known person's handle needs the reverse read in plan SV-4. Server-gated.
- **Working state in groups** with an assistant turn (desktop "Your assistant is working"): not done. Only assistant rows are watched, to keep the subscriptions to a handful of rooms.
- **Live typing reach (unverified on device)**: the room-list sliding sync must deliver typing EDUs for rooms that are not open. The FFI in this SDK has no `subscribeToRooms`. If the atom never shows live on a device, the fix is a room subscription for assistant rooms in `LiveMatrixSession`.
- **Group member count**: joined plus invited (`activeMembersCount`), where desktop counts joined only. It differs only while an invitation is pending.
- **Starter notice** above the composer (`MatrixStarterNotice`, L1 P3): not in this slice.

## PENDING-COPY

None new. `desktop.matrixShell.mainAgent` (from HC-1) is still missing. The keys this slice uses all resolve in the pinned export.
