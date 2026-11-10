# Report and Block (wave 1 · HC-2)

App Review guideline 1.2 asks for a way to report people and their content, beside Block. The phone had Block (the person panel and a group's Members page) but no Report. This slice adds Report person and Report message with the desktop's rules, words and flow. Evidence: parity audit lane 1, slice S2 (`docs/research/2026-11-10-parity-audit/lane1-home-chats.md`, rows "Report person", "Report message", "Block / Unblock", "Members page").

## What the phone does now

| Where | Desktop (`atum-app` `050ede8edf5`) | Phone |
|---|---|---|
| Person chat side panel | Report person above Block, then Delete chat (`m/person-info-panel.tsx:224-245`) | The last group of the panel is **Report person**, **Block / Unblock**, then **Delete chat** (`ChatInfoSheet.swift` `exitSection`). |
| Group › Members › a member's "…" | Ignore, **Report**, Ban/Unban, Remove (`m/conversation-controls.tsx` members menu) | **Block / Unblock**, **Report person**, then Remove, Ban, Unban by power level (`ChatPanelHost.swift` `ChatMembersPage`, `ChatMemberModeration.actions(... mayReport:)`). |
| Long-press on a message | **Report** for someone else's message (`m/message-actions.tsx:380-420`, `m/app.tsx` `reportMenu`) | **Report** is the last item of the menu (before Delete, which only your own messages have) for a person's message, image or file (`MessageMenuRules.items(... nonPersonSenders:)`). |
| Chat "…" | Report / Block in `m/conversation-menu.tsx` | The "…" opens the side panel, which has them (above). |
| Home row menu | Report / Block (`m/roster-context-menu.tsx:440-467`) | **Not in this slice.** `ios/App/Home/HomeScreen.swift` belongs to the Home worker; the Home row menu gets Report and Block in a later slice (lane 1 S7 "Row and chat menu parity"). The rules it needs are ready: `ReportPolicy.mayReportPerson` and `ChatExitPolicy.mayIgnore`. |

Block was already on the phone and is reused unchanged (`ChatInfoActions.setIgnored`, Matrix `m.ignored_user_list`); Report now sits beside it in each place the desktop has both.

### Who can be reported (`ios/Sources/AtumChat/ReportPolicy.swift`)

- **Report person** (desktop `roster-model.ts` `reportablePerson`): a person, never yourself, an assistant or an app's bot, in a chat that offers Delete chat or Leave group. So: person chats, groups and the Founder chat (unless you are the Founder); never assistant chats, app chats, Team Space rooms, system rooms or invitations.
- **Report message** (desktop `app.tsx` `reportMenu`): a message, image or file from someone else that the server has (an event ID, not a local echo or failed send), in a person chat or a group. Never your own, an assistant's or an app bot's. The phone knows assistants and bots from the room's agent, the account's `/agents`, the catalog apps' bots and the members the panel marks as assistant or app; a host that passes no such set offers no Report (it fails closed).
- Desktop note: the desktop's message `person` check leaves app bots in (it only excludes agents). The phone also excludes app bots, as the task asked; their messages already have their own minimal menu.

### The report sheet (`ReportSheet` in `MessageMenu.swift`)

Desktop `MatrixReportDialog`: title, one line, an optional one-line reason (500 characters), Cancel and Report. Sending shows a spinner; a failure shows the generic error and keeps the sheet open; success shows **"Report sent."** for a beat (with a success haptic and a VoiceOver announcement) and closes.

### The Matrix calls (SDK, no raw HTTP)

The phone's Matrix Rust SDK (`atum-matrix-rust-components-swift` `66c18d3`) exposes `Room.reportContent(eventId:reason:)` and `Room.reportRoom(reason:)`, but **no user report** (MSC4260, the `users/{userId}/report` endpoint under the client API, which the desktop calls with raw HTTP). The phone does not pull the access token out of the SDK's custody for a raw request. So, in `LiveConversationStore`:

- **Message:** `Room.reportContent(eventId:, reason:)` → `POST /rooms/{roomId}/report/{eventId}`. Only the event ID and the reason; never the message text.
- **Person:** the desktop's own fallback for a homeserver without user reports: report **the latest message they sent in this chat** that the chat has loaded (`ReportPolicy.personRequest`). In a person chat where none is loaded, it reports the chat itself (`Room.reportRoom`), which is only theirs and yours. A group with nothing loaded fails with the generic error (a room report would name everyone in it).
- With no reason, the phone sends the desktop's fixed protocol value `abuse` (`MATRIX_REPORT_DEFAULT_REASON`). The reason is cleaned as the desktop does (control characters to spaces, white space collapsed, trimmed, 500 characters).
- The store checks the row again before it reports, so a stale menu can never report your own message or a bot's.

Follow-up when the SDK pin gains a user report: switch `reportPerson` to it and keep the latest-message path as the fallback, as the desktop does.

## Files

- `ios/Sources/AtumChat/ReportPolicy.swift` (new): availability rules, reason cleaning, request construction, `ReportPendingCopy`.
- `ios/Sources/AtumChat/MessageMenuRules.swift`: `.report` item; `items(for:in:nonPersonSenders:)`.
- `ios/Sources/AtumChat/ChatMemberModeration.swift`: `.report` member action, `personalActions`.
- `ios/Sources/AtumChat/ConversationStore.swift`: `ChatActions.report`.
- `ios/Sources/AtumChat/ChatCopyKey.swift`: `report`, `reportTitle`, `reportBody`, `reportSent`, `reportNote`.
- `ios/App/Chat/Stores/ConversationStore.swift`: `nonPersonSenders`, `report`, `reportPerson` (SDK calls).
- `ios/App/Chat/Views/MessageMenu.swift`: menu item, presenter request, `ReportSheet`, `ReportCopy`.
- `ios/App/Chat/Views/ChatInfoSheet.swift`: `ChatInfoActions.reportPerson`, Report row in the person panel.
- `ios/App/Chat/Views/ChatPanelHost.swift`: Report in the Members row menu.
- `ios/App/Chat/Views/ChatScreen.swift`, `ChatEnvironment.swift`, `ChatRowView.swift`: wiring (`chatNonPersonSenders`, the panel's `reportPerson` from the chat's store).
- `ios/App/LiveMatrixSession.swift`: one line, `.report` is not a moderation call.
- `ios/App/Chat/Views/ScriptedChatHost.swift`: the scripted panel's `reportPerson` records `report <user>` to the UI probe; `.report` in its moderation switch.
- Tests: `ios/Tests/AtumChat/ReportPolicyTests.swift` (new), `ios/Tests/ChatCopyContractTests.swift`.

No shared file (`AppRoot.swift`, `LiveAppModel.swift`, `DesignSystem/*`) was touched, and no file was added to the Xcode project (the new code is in the AtumChat package or in existing app files).

Glyph: the vendored Phosphor subset has no flag (desktop's `Flag`), so Report uses the Kit's warning circle (`AlertCircle`). Adding `Flag` needs `phosphor-map.json` plus `scripts/generate-phosphor-symbols.py`, a DesignSystem change left to the coordinator.

## Verification

Run under the heavy-build lock on 2026-11-10/11:

- `swift test --filter "ReportPolicyTests|MessageMenuRulesTests|ChatMemberModerationTests|ChatCopyContractTests"`: 27 tests, 0 failures (ReportPolicyTests 12, MessageMenuRulesTests 10, ChatMemberModerationTests 3, ChatCopyContractTests 2). The existing menu and moderation tests pass unchanged: the new parameters default to "no Report".
- `xcodebuild -scheme AtumMobile build` for the iPhone simulator (arm64, `ONLY_ACTIVE_ARCH=YES`): **BUILD SUCCEEDED**. (A `generic/platform=iOS Simulator` build fails to link because the pinned SDK's simulator library is arm64-only; that is not caused by this change.)
- `scripts/public_guard.py --base origin/main --head HEAD`: PASS.
- Not run: simulator UI tests and a live homeserver report. Those are the device checks below.

### Manual device checks (coordinator)

On a TestFlight or dev build, signed in to a test account with a second test person:

1. Person chat › "…" › panel: **Report person** sits above Block and Delete chat. Tap it: the sheet shows "Report this person?" (or its stand-in, see PENDING-COPY), the line, a reason field focused with the keyboard up.
2. Type a reason, tap **Report**: a spinner, then "Report sent." and the sheet closes. Check the homeserver's admin event reports (Synapse `GET /_synapse/admin/v1/event_reports`) for the person's latest message with the reason.
3. Repeat with an empty reason: the report arrives with reason `abuse`.
4. Person chat where the other person has sent nothing loaded: Report person reports the room (Synapse `GET /_synapse/admin/v1/room_reports`, if the server version has it). If the server rejects room reports, the sheet shows the generic error and stays open.
5. Long-press the other person's message: **Report** is the last item; the sheet says "Report this message?". Send; check the event report. Long-press your own message: no Report.
6. Group › Members › a person's "…": Block, **Report person**, then any Remove / Ban. An assistant or app bot member: no Report. Your own row: no menu.
7. Long-press an assistant's or an app bot's message in a group: no Report. Assistant chat and app chat: no Report anywhere (menu and panel).
8. Airplane mode, then Report: the generic error, the sheet stays open; back online, Report works.
9. Block still works beside Report in the panel and the Members page (Block → confirm; Unblock in place).
10. VoiceOver: the long-press actions list includes Report; "Report sent." is announced. Dynamic Type XXL: the sheet scrolls, nothing clips.
11. Vietnamese and English device languages: all words are exported copy (no raw keys).

## PENDING-COPY

The design export lacks the desktop's Report person words. Each use reads the key through `ReportCopy.text`, which shows the key once the pin has it and its stand-in until then (`ReportPendingCopy` in `ReportPolicy.swift`; `// PENDING-COPY:<key>` at each use).

| Key | en | vi | Where used | Stand-in until pinned |
|---|---|---|---|---|
| `src.matrix.chat-copy.copies.reportPerson` | Report person | Báo cáo người này | Panel row; Members menu item | `src.matrix.chat-copy.copies.report` ("Report") |
| `src.matrix.chat-copy.copies.reportPersonTitle` | Report this person? | Báo cáo người này? | Report sheet title (person) | `src.matrix.chat-copy.copies.report` ("Report") |
| `src.matrix.chat-copy.copies.reportPersonBody` | Atum’s moderators get the report. They aren’t blocked. | Đội kiểm duyệt của Atum sẽ nhận báo cáo. Người này không bị chặn. | Report sheet line (person) | `src.matrix.chat-copy.copies.reportBody` |
| `src.matrix.chat-copy.copies.reportReason` | Reason (optional) | Lý do (không bắt buộc) | Report sheet reason placeholder (both) | `desktop.dm.group.report.note` ("Add details (optional)") |

ja / zh / zh-Hant values are in desktop `apps/desktop/src/matrix/chat-copy.ts` (lines 456-459, 614-617, 770-773). Once the copy worker's keys are pinned, the stand-ins stop showing with no code change; `ChatCopyContractTests.testEveryPendingReportKeyResolvesOrFallsBackInEveryLocale` then checks the real keys in every locale.
