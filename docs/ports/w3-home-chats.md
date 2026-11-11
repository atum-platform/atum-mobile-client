# Home and chats, wave 3 (HC-6, HC-7; HC-12 and HC-11 blocked)

Parity plan v2, wave 3, stream HC. Audit evidence: lane 1 slices S6, S7, S13 and S12, checked against the shipped Matrix renderer (`apps/desktop/src/matrix/`, cited below as `m/`).

## HC-6: chat header subtitle and in-chat search (L1-S6)

### Subtitle

Desktop (`m/app.tsx` header identity, `data-matrix-agent-title`; `m/group-details.tsx` `MatrixGroupHeaderTopic`) puts one quiet line next to the chat's name: an assistant's title (what it is for), a personal group's topic, the Founder's line.

The phone (`ChatTitleCapsule`, `ios/App/Chat/Views/ChatScreen.swift`):

- The title capsule now has two lines: the name (with its seal) and, under it, `ChatTitleCapsule.subtitle(_:)`: the assistant's title, the group's `m.room.topic` or the Founder's subtitle. Person and app chats have none. The text is one line, newlines folded, empty means none.
- The data was already in `ChatInfoPresentation` (`subtitle`, `topic`); nothing new is read.
- At the accessibility text sizes the line is left out: the navigation bar has no room for two lines there, and a truncated topic is what the clipped-text audit flags. The long-press large content viewer shows the name and the subtitle together, and VoiceOver reads the subtitle as the title's value.
- Desktop hides the group topic in a narrow window (`max-width: 780px`). The phone shows it, as the audit asked.

### In-chat search

Desktop `MatrixChatSearch` (`m/chat-search.tsx`, `m/chat-search-matches.ts`, `m/history-search.ts`, copy `m/chat-search-copy.ts`).

Pure core (`ios/Sources/AtumChat/ChatSearch.swift`):

- `ChatSearchText.fold` ports `foldSearchChar`: marks removed (NFD), lower case, đ as d, any space as one, a line break that no match may cross. ASCII takes a fast path.
- `ChatSearchText.words(of:)`: what a message shows as words. Answers go through `markdownWords` (a port of desktop `historyMessageText`: no link destinations, no `*_~\``). My own messages are searched as typed, since the phone shows them literally (B6). Notices, working lines, media and placeholders are not searched, as on desktop.
- `ChatSearchIndex` keeps each row's folded words by row ID and body, so each new snapshot folds only what changed. Matches come newest first: the one nearest the composer is result 1. Within one message the later words count as newer.
- `ChatSearch.step` (wraps both ways), `keptIndex` (the match you are on stays put when rows change) and `highlights` port `stepMatch` and `sameMatchIndex`.
- `ChatHistorySearch.run` ports `searchOlderMatrixHistory`. When nothing loaded matches, it loads older pages one at a time until a match arrives, the room's start, a failed page or the cap. The bounds are desktop's: 40 pages of 50 events, "of 2,200" in the count, and a 180 ms debounce after typing.
- `ChatSearchReadout` holds the counter's values ("2/5" or none, plus the history line).
- `ConversationCore.startSearchPage(now:)` claims the one page in flight for search (a new `PageRequest.search`). Scrolling's `PaginationPolicy` is held at `.paginating` until `paginationFinished`, so the two never page at the same time.

App (`ios/App/Chat/Views/ChatSearchBar.swift`, `ChatScreen`, `TranscriptView`, `MessageBubbleRow`):

- A magnifier in the toolbar (`chat.search.open`) opens the search in every personal chat (assistant, person, group, app). Company channels and company conversations keep their own lane 2 headers, so it is not shown there.
- While search is open, the search bar takes the composer's place, as iOS find bars sit above the keyboard. The bar has the field, Close, the count line ("2/5 · Searched 250 of 2200") and the older/newer chevrons. Return steps to the older match, as desktop's Enter does. The field wraps rather than clips at large sizes.
- `ChatSearchSession` (`@Observable`) owns the query, the matches, the current match, the walk's progress and the row to bring into view. The transcript scrolls only when the person asks: typing, stepping, or a walk that found something. It never scrolls because rows changed (desktop's `revealNext`).
- Placing a match (`TranscriptView.showSearchMatch`): the chat first leaves the bottom, so `FollowPolicy` does not pin it back. The row then goes a third of the way down the visible area, from its measured top, and is placed again every 0.12 s until it stays (at most 14 tries; a drag ends it). One `scrollTo(id:)` was not enough: a walk's rows have only just landed and still change height, and the UI test caught "1/1" with the match off screen. The row-hold logic waits while a match is being placed.
- `LiveConversationStore.loadOlderPageForSearch()` waits briefly for a page scrolling already has in flight. Then it loads `ChatHistorySearch.pageEvents`, reports through the core, and waits (bounded) for the projector to turn the page into rows.
- Highlights: `ChatRowView` and `MessageBubbleRow` take a `searchHighlight` value, so only matched rows change and `.equatable()` still skips the rest. `ChatSearchPaint` paints every match with a 16% ink wash and the current match in ink with the on-ink colour (desktop `::highlight(atum-chat-search)`). In my own bubble, the bubble's text colour plays the ink.
- VoiceOver: the count reads desktop's announcement ("Result 2 of 5. Searched …") and is posted whenever it changes.
- Copy: `src.matrix.chat-search-copy.copies.{search,older,newer,close,noResults,result,searching,searched}`, all in `ChatCopyKey`, so `ChatCopyContractTests` checks every locale.

Scripted capture: `-AtumScripted chat.search` is an assistant chat of 140 messages, 40 loaded at open, older pages of 20. One message three pages back says "Đà Lạt".

## HC-7: row and chat menu parity (L1-S7)

Desktop `RosterRoomMenu` and the chat "…" menu (`m/roster-context-menu.tsx:315-500`, `m/conversation-menu.tsx:92-150`, `:403-503`), and the rules in `m/roster-model.ts` (`personalChatActions`, `lowPriorityEligible`, `personalGroupDetails`).

### Home long-press (person and group chats; not the Founder, assistants, apps or invitations)

- **Rename** (`chat-copy.copies.rename`) opens the Rename alert, described below.
- **Low priority** (`person-info-copy.copy.lowPriority`) is a checkmark toggle, the iOS way to show a state in a menu. That also removes the need for desktop's separate "Remove low priority" words. It calls the existing `setRoomLowPriority`. `HomeRow.isLowPriority` is filled from live rows only.
- **Block person / Unblock** (`chat-copy.copies.blockPerson`, `unblockPerson`) appears on a person chat. Block asks first (`blockPersonTitle`, `blockPersonBody`); Unblock does not, as on desktop. The peer comes from the room's member IDs (`LiveAppModel.blockablePeer`, `ChatMenuPolicy.blockablePeer`), and `ChatExitPolicy.mayIgnore` keeps the Founder chat for the Founder's own account. Who is blocked is read once when Home is ready (`ignoredPeople`) and updated after each change.

### Chat panel

- **Rename** is a new row at the end of the conversation section, after the switches, so the rows above it keep their places. Person and group chats only (not the Founder).
- **Mark as unread** is not added. Desktop's own rule (`markable = unread || room.id !== snapshot.roomId`) never offers it on the chat being read, and the phone's read rule (B13) would clear the mark again at the bottom. It stays on the Home swipe and long-press.

### Rename (`ChatRenameAlert.swift`, `ChatMenuModel.swift`, `ChatRoomNaming.swift`)

- A person chat, or a group you may not name, gets a private name. It is stored as desktop stores it: room account data `io.atum.title` with content `{"title": …}`, or `{}` to clear it. The alert says "Rename chat" and "Only you see this name.", and an empty name clears it.
- A group whose power levels let you send `m.room.name` (`groupDetailsPowers`, `canUserSendState`) is renamed for everyone (`Room.setName`). The name may not be empty, and your private name for that group is cleared, as desktop does.
- Reading: `LiveMatrixSession.row(from:)` now reads `io.atum.title` from the SDK's cached room account data (`accountDataRaw`). `LiveRosterRows` puts the private name before the room's own name for person and group rows (desktop `matrixChatTitle`). The Founder's name and "You" stay the app's. **This also fixes a gap:** names given on desktop never showed on the phone before.
- Writing: the pinned SDK has no room account data write. `LiveMatrixSession.setPrivateTitle` sends one `PUT /_matrix/client/v3/user/{me}/rooms/{room}/account_data/io.atum.title` to the session's own homeserver with the session's bearer. It uses HTTPS only, sets no cookies and follows no redirects, the same pattern as Team Space's notification read. On success the row is patched at once, and sync brings the event back into the SDK cache.
- Limits are desktop's: 80 characters for a name, 500 for a topic (`ChatPrivateTitle`, `ChatGroupTopic`).

### Not done in HC-7

- **Group topic edit**: the session call exists (`setGroupTopic`), but the export has none of desktop `group-details.tsx`'s topic words (field label, title), so no UI was built. PENDING-COPY.
- **Members page "Add members"**: `group-picker-copy.copies.addMembers` is exported, but the picker (people search, selected chips) is a sheet of its own. Not started.
- **Report person** in the Home long-press (desktop has it beside Block): this is HC-2's area and needs the report sheet hosted on Home. Not added.

## HC-12: assistant status dots (L1-S13): blocked

Desktop `matrixAgentDot` (`m/roster-conversations.tsx:578-680`) draws, for a cloud assistant, a hollow ring when `executionPolicyAvailability` is `paused` (label `matrixAgentAccessPausedLabel`) or `unavailable` (label `agentDotUnreachable`), and nothing when ready or unknown. Two things block it on the phone:

1. **Data.** The phone reads no execution policy status. No client exists in `AtumNativeAPI` or the app for desktop's `executionPolicy` view (`status.state`, destination reachability). `/agents` as the phone reads it carries no paused or unavailable state. The audit's "derive from `/agents` and the execution policy" needs that read first: a platform contract and native client work, owned by SV and lane 3.
2. **Copy.** `matrixShell.agentDot*` and `matrix-agent-access-band-copy.ts` `paused` are not in the export. A dot without words would carry its meaning by colour alone.

Nothing was built, to avoid a dot with no data and no words.

## HC-11: answer toolbar (L1-S12): not started

Still blocked as the plan says: `goodAnswer` and `badAnswer` are not exported, and the feedback write route is undetermined.

## Shared-file and cross-stream edits

- `ios/App/AppRoot.swift` (shared, additive): `homeActions` sets the five HC-7 actions after construction, and the chat panel's `ChatInfoActions` gains `rename:`.
- `ios/App/LiveMatrixSession.swift` (additive): `LiveMatrixRoomRow.privateTitle`, the `io.atum.title` read in `row(from:)`, `setPrivateTitle`, `setGroupName`, `setGroupTopic`, `groupDetailsPowers`, and a private no-redirect delegate.
- `ios/App/LiveRosterRows.swift`: one line, the private name first.
- `ios/App/Chat/ChatMenuModel.swift`: a `LiveAppModel` extension in its own file, so `LiveAppModel.swift` is untouched.
- `ios/Sources/AtumChat/ConversationCore.swift`: the search page request (`PageRequest.search`, `startSearchPage`, `reachedTimelineStart`).
- `ios/Sources/AtumChat/LaunchArguments.swift`: the `chat.search` scenario name.
- `ios/App/Debug/ScriptedHomeHost.swift` and `ios/App/Chat/Views/ScriptedChatHost.swift`: scripted Rename, Low priority and Block, recorded to `home-actions.txt` and `panel.txt`.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: five file references added by hand (`ChatSearchBar`, `ChatRenameAlert`, `ChatMenuModel`, `HomeChatsWave3UITests`, `HomeChatsWave3StateTests`), as wave 2 did.

## PENDING-COPY

| Key (desktop source) | Where | Stand-in now |
|---|---|---|
| `chat-copy.ts` `renameGroupTitle` | Rename alert title for a group named for everyone | `chat-copy.copies.rename` ("Rename") |
| `chat-copy.ts` `renameGroupHelp` | Rename alert message for a shared group name | no message (the private-name line would be untrue) |
| `group-details.tsx` topic words (field label, title) | Group topic edit | not built |
| `i18n` `matrixShell.agentDotReady/NeedsYou/Offline/Unreachable`, `shared/matrix-agent-access-band-copy.ts` `paused` | HC-12 dots | not built |
| `chat-copy.ts` `goodAnswer`, `badAnswer` | HC-11 toolbar | not built |
| `chat-copy.ts` `removeLowPriority` | not needed: the phone's menu shows Low priority as a checkmark toggle | — |

`desktop.matrixShell.mainAgent` (from HC-1) is still missing too.

## Test results

Every heavy run used the shared lock (`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`) on the iPhone 17 simulator (939B69F8), 2026-11-11, with `scripts/sim-content-size-runner.sh` running beside the UI tests.

- `swift test -j 2` (whole package): AtumChatTests 616, AtumDesignTests 701, AtumDriveTests 22, AtumTelemetryTests 16, with 0 failures. New suites: `ChatSearchTests` (15), `ChatRoomNamingTests` (4). `ChatCopyContractTests` (3) now covers the search and menu keys.
- `xcodebuild … -scheme AtumMobileStateTests -only-testing:AtumMobileTests test` (includes the app build): 328 tests, 0 failures. New: `HomeChatsWave3StateTests` (3).
- UI tests:
  - `HomeChatsWave3UITests` (7: search found three pages back, no-result walk in vi, search bar AX audit, group topic subtitle, panel Rename, Home long-press Rename + Low priority + Block, group menu without Block): all 7 passed in dark. In light, 5 passed in the same run; panel Rename then passed on rerun after a test fix (it swiped the chat behind the panel instead of the panel).
  - `HomeShellUITests` (16) passed. `TranscriptUITests/testU10EmptyChatShowsTheGreeting` passed.
  - `ChatPanelUITests`: 3 passed and 1 was skipped (iPad-only). `testPersonPanelShowsConversationFactsAndBlocksInPlace` was listed as failing on main in `wave2-assembly.md`; it now passes. Two fixes: its confirmation query no longer looks for an iOS 26 `Sheet` element, and its Low priority tap retries once the panel stops decelerating.
- Bugs the UI runs caught and this branch fixes:
  1. The first match placement (one `scrollTo(id:)`) left "1/1" with the match off screen; it is now placed and re-placed from the row's measured top.
  2. The transcript showed through the search bar; the bar now has a solid ground.
  3. Rename's alert on the panel body stopped the panel's Block confirmation from presenting at all; the alert now hangs on the Rename row.
- On a loaded simulator the search field sometimes had no keyboard focus yet, so focus is asked for again 150 ms after the bar appears.
- `bash scripts/pre-push-public dc0634b <head>`: PASS.

Captures (simulator, scripted hosts), kept outside git in `.scratch/` of the worker's worktree: `hc6-search-found-{light,dark}-en`, `hc6-search-none-{light,dark}-vi`, `hc6-search-ax5-{light,dark}-en`, `hc6-group-topic-{light,dark}-vi`, `hc7-home-menu-{light,dark}-vi`, `hc7-rename-{light,dark}-en`.

## Not verified

- A live homeserver accepting the phone's `io.atum.title` PUT, and the SDK cache picking it up through sync. It was not run against a live account here: no sign-in was done. The request matches the Matrix spec endpoint and desktop's content.
- Whether the room list republishes on a room account data change from another device. If it does not, a desktop rename shows on the phone at the room's next list update.
- Search on a real encrypted room with deep history: walking pages is proven on the scripted source (`chat.search`) and in unit tests, not on a device.
- Light/dark and vi/en are captured on the simulator only, not on a physical iPhone.
