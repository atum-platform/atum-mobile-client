# Home faces and order (wave 1, HC-1)

Parity plan v2 slice HC-1. Audit evidence: lane 1 S1 (D1, D2, D3, D10) and lane 3 S1 (D-6), checked against desktop `050ede8edf5`.

## What changed

### 1. Assistant mark faces render (lane 1 D1)

A named assistant whose `/agents` identity is a shape mark (`LiveProductAvatar.mark`) now shows its coloured mark instead of a grey initial.

- `AtumAvatar` takes an optional `mark: AgentMark?`. `AtumAvatar.treatment(kind:hasArt:mark:name:)` picks the face in desktop's order (`at/assistant-avatar.tsx:67-128`): photo, then Atum's crescent, then the mark, then the initial. Apps never wear a mark. The mark is drawn on the Kit `fill-quiet` ground at 62 % of the face (desktop's roster `size-[62%]`), using the existing `AssistantMarkGlyphShape` and `AssistantMarkPalette`, which had no callers before.
- `HomeRow` carries `mark`, set from `room.avatar?.agentMark` for `.assistant` rows only. `HomeAvatar` passes it, so Home rows, Start chat and the assistant card face (`AssistantCardIdentity.homeRow`) all draw it. Settings › Assistants also uses `HomeAvatar`, but `AccountAssistantSummary` carries no mark, so it still shows the initial there. That is out of this slice's files and is a follow-up.
- `ChatListSnapshot.Room` stores the mark as raw `shape`/`color` strings (optional, so older snapshots still decode). Home always paints through the snapshot round trip, so without this the mark would vanish on the next refresh. `merged` lets a live mark reach a cached row. An unknown raw value from a newer platform draws the initial.
- Chat: `ChatInfoAvatar` (the header title capsule and the info panel) and `ChatFaceView` (transcript, typing and Seen faces that wear the room face) pass `avatar?.agentMark`.

### 2. Start chat rows show real faces (lane 1 D2, lane 3 D-6, lane 3 S1)

`HomeStartChatSheet` rows draw `HomeAvatar` (36 pt) instead of a bare `AtumAvatar` monogram. They now show assistant photos and marks, the Atum crescent, the Founder raven, app squircle tiles with their catalog art, and people's and groups' photos, as desktop `m/start-chat.tsx:114-182` does. The main assistant (`HomeRow.kind == .atum`, i.e. `isDefault`) gets desktop's `MainAgentBadge`: a filled star in `ink-3` beside the name (`m/main-agent-badge.tsx`). The rule is `HomeRow.showsMainAssistantBadge`.

Desktop draws people and groups in Start chat as initials only. The phone shows their photos, as the task asked. This is phone-better.

### 3. Home order matches desktop (lane 1 D3, D10)

`RosterProjection.chatRows` now follows desktop `roster-conversations.tsx:948-955` plus `room-navigation.ts` `sortConversations`:

1. The Founder room.
2. Pins (`m.favourite`), app chats included, in the existing pin order.
3. **One recency sort over ordinary chats and each app's chat together.** Low priority still sinks, app chats included. Moon or Andy with a fresh message now sits among the recent chats instead of after every chat.
4. Apps without a chat (`RosterProjection.App.hasChat == false`), in catalog order.
5. Coming-soon placeholders, in catalog order.

A bot chat the person deleted on this phone (`isHiddenOnThisDevice`, `reopensHiddenRoom`) keeps its place by its last message. Desktop does the same: a deleted bot chat stays on its row with `appBot.hidden` (`roster-model.ts:24-28`).

`AppRoot.rosterSnapshot` sets `hasChat: !room.awaitsStart`. This is a one-argument change in a shared file.

Assistants: the default assistant comes first, then `/agents` order. A pin no longer moves an assistant up (`roster-model.ts:196-246`, lane 1 D10). `assistantPinOrder` is removed.

## Desktop rows matched

| Audit row | Desktop | Phone now |
|---|---|---|
| L1 §2.2 Avatar: assistant (mark) / D1 | `at/assistant-avatar.tsx:100-114` | `AtumAvatar` `.mark` treatment via `HomeAvatar`, `ChatInfoAvatar`, `ChatFaceView` |
| L1 §2.3 Start chat rows: faces / D2; L3 §2.5 / D-6 | `m/start-chat.tsx:114-182` | `HomeAvatar` in the sheet |
| L3 §2.2 Main-assistant star (Start chat part) | `m/main-agent-badge.tsx` | star beside the primary in Start chat |
| L1 §2.2 Chat ordering / D3 | `roster-conversations.tsx:948-955`, `room-navigation.ts:7-28` | `RosterProjection.chatRows` |
| L1 §2.2 Assistant ordering / D10 | `roster-model.ts:196-246` | `RosterProjection.assistantRows` |

## Verification

All runs used the heavy-build lock on simulator iPhone 17 (939B69F8), 2026-11-10:

- `swift test --filter AtumChatTests`: 569 tests, 0 failures.
- `AtumMobileStateTests` with `S2StateTests`, `RosterAvatarKindTests`, `AvatarFrameTests` and `AvatarArtTests`: 91 tests, 0 failures.
- `AtumMobile` scheme simulator `build`: BUILD SUCCEEDED.
- `scripts/public_guard.py --base origin/main --head HEAD`: PASS.

`testRosterStoreKeepsClassificationAcrossRoomOnlyUpdates` gave its rooms timestamps. With none, the app chat and the person chat tie on recency and sort by ID. The test covers classification, not order.

Tests added or changed:

- `ios/Tests/AtumChat/S2PolicyTests.swift`: recency mixing (`testAppChatsInterleaveWithPeopleAndGroupsByRecency`, the updated `testRosterOrdersAssistantsAndMixesAppChatsWithChatsByRecency`), apps without a chat then placeholders (`testAppsWithoutAChatFollowEveryChatThenPlaceholdersInCatalogOrder`), pins and low priority (`testPinnedAppChatSortsWithPinsAndLowPriorityAppChatSinks`), deleted bot chat (`testDeletedAppChatKeepsItsPlaceByRecency`), assistant pins (`testPinnedAssistantDoesNotJumpAboveServerOrder`). `testRosterUsesAppRowForHiddenRoomAndRejectsDuplicateAndLegacyRows` now expects the ID tie-break between two rooms with no message.
- `ios/AppTests/S2StateTests.swift`: `testHomeOrderMixesBotChatsByRecencyAndPutsAppsWithoutAChatLast` covers `AppRoot.rosterSnapshot` → projection.
- `ios/AppTests/AvatarArtTests.swift` (`RosterAvatarKindTests`): mark mapping from `LiveProductRoom`, primary star rule, app never marked, snapshot round trip and merge, and `AtumAvatar.treatment` order.

Not done here: an on-device capture against desktop. `ScriptedRoster` has no mark assistant or newer-bot fixture yet (lane 1 §6 asks for one). `App/Debug` is outside this slice.

## PENDING-COPY

| Key | en | vi | Where |
|---|---|---|---|
| `desktop.matrixShell.mainAgent` | Main agent | Trợ lý chính | Start chat: spoken label of the main assistant's star (`HomeStartChatSheet.mainAssistantLabel`). Until the key exists the star is hidden from VoiceOver. |
