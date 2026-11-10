# Team Space: Direct messages, "You", Chief of Staff, faces (wave 1, TS-1…TS-5)

Branch `feat/team-space-dms-cos`, based on main `308c5d8` (which already includes the
logo data fix, PR #15). Evidence: parity audit lane 2 (`docs/research/2026-11-10-parity-audit/lane2-team-space.md`
in the private plan repo), slices L2-S1…S5. Desktop reference `atum-app@050ede8edf5`.

## What changed

| Slice | Phone now | Desktop row it matches |
|---|---|---|
| TS-1 | `CompanyLogo` is a **circle** (`AvatarKind.group`) in the header capsule and switcher rows. A new `MatrixFace` view draws any `mxc://` face. The monogram shows only when no logo is set or the logo fails to load. Invitation cards draw no mark. | Owner ruling 2. Desktop's switcher menu (`team-space/company-menu.tsx:88–92`) already uses a circle; its header still uses `data-face="app"`, a desktop follow-up. |
| TS-2 | **Direct messages is always shown** for a loaded company (`CompanyWorkspacePresentation.directMessages`). Only the DM/group rows and "+" depend on `offersConversations` (`conversations`, still nil when the family is off). The "No direct messages yet" note is gone, because the You row is always there. | `company-workspace.tsx:2996–3030`, `team-space/conversation-sections.tsx:185–203`. |
| TS-3 | **"You"** is the first row, with the person's own snapshot photo. Tapping it opens the company's notes room. Rules are in `CompanyNotesSelf` (AtumNativeAPI) and the Matrix glue in `CompanyWorkspaceModel.swift` / `LiveAppModel` (see below). | `shared/matrix-notes-self.ts`, `src/matrix/notes-self.ts`, `conversation-sections.tsx:204–237`. |
| TS-4 | The **private Chief of Staff** is the second DM row. It is no longer a `#` channel and never shows a raw room name. It has an assistant circle face, "Chief of Staff", and a state line: Setting up… / Paused / Not available yet, plus Retry. Tapping a served pair that isn't ready ensures it (`dm_open`), then opens the bound room. Retry is the desktop's forced recheck: read again, then ensure an uncreated pair. On the first visit, an uncreated pair of the company on screen is ensured once (`first_company_visit`). The ensure is `POST /companies/{id}/private-cos` (frozen v1 body; 200 is a bound view, 202 is the v1.1 preparing view), and a retry with the same trigger replays its request ID. The CoS chat and the notes chat offer **no Delete chat, Leave group or Ignore** (`LiveAppModel.offersPersonalExits`; D5). | `conversation-sections.tsx:118–136, 238–275`, `private-cos-store.ts` (`companyPrivateCosRowStatus`, `ensureCompanyPrivateCos`, `admitCompanyPrivateCosVisit`, `recheckCompanyPrivateCos`), `private-cos-chrome.tsx`. |
| TS-5 | DM rows show the teammate's **photo** (snapshot `avatarUri` through `loadMatrixThumbnail`). Group rows show **two overlapping faces**. The members list shows photos and a **role pill** (admins a shade stronger). `ConversationRow.otherMemberRefs` carries who is in each conversation. | `conversation-sections.tsx:142–183`, `team-space/members-panel.tsx:46–110`, `role-badge.tsx`. |

### "You": the shared notes room

The phone uses the desktop's exact format, so both devices open one room:

- The room's immutable create content is `type: "com.atum.notes.self"` plus `"com.atum.notes_self.company_id": <company UUID>`. The owner is its creator and its only member.
- A per-company account-data pointer, `com.atum.notes_self.<company UUID>` = `{"version":1,"room_id":…}`, is a hint only. A known v1 pointer is repaired; unknown or newer data is never overwritten.
- Of several matching rooms, the earliest created wins (then the lowest room ID), as on the desktop. A room whose audience changed is quarantined.

When the person taps "You", `CompanyNotesSelf.openDecision` decides:

1. A synced winner opens.
2. Otherwise, only a completed initial sync **and** an absent pointer, read fresh from the server, allow a create.
3. A known pointer to a room not yet synced means another device made it, so the phone waits (bounded, 15 s) and never creates.
4. Unknown pointer data refuses both open and create.

After creating, the phone writes the pointer at once, then waits for the room to sync and prove itself by its create content. This is the same guarantee as the desktop's own `ensure`.

The pinned Matrix SDK's `CreateRoomParameters` has no `creation_content`. So the create is one raw `POST /_matrix/client/v3/createRoom` to the session's own homeserver with the session bearer: HTTPS only, ephemeral session, no cookies, redirects refused. To allow this, `LiveMatrixSession.runtime` is now internal instead of private.

Proven notes rooms are let through `LiveRosterRows` (titled "You" instead of the SDK's "Empty Room"). They are classified `.notesSelf(companyID:)`, routed to Team Space, and excluded from Home. The empty-duplicate tombstoning and the `u.atum.notes_self` tag remain desktop housekeeping; the phone does not write them.

## Shared files touched (minimal)

- `ios/App/AppRoot.swift`:
  - `.notesSelf` in `RoomRootDestination` and the Home filter;
  - the `directMessages` actions;
  - exits and Ignore are nil for CoS and notes chats.
- `ios/App/LiveAppModel.swift`:
  - the notes-room discovery and open (`companyNotesSelfRoom`), triggered on room-list changes and company refresh;
  - the `LiveRosterRows` inputs;
  - `offersPersonalExits`.
- `ios/App/LiveRosterRows.swift`: the `notesSelfRoomIDs` / `notesSelfTitle` inputs.
- `ios/App/LiveMatrixSession.swift`: `runtime` is internal.
- `ios/Sources/AtumNativeAPI/NativeDomainClient.swift`: the ensure route; `companyData`/`requestData` take accepted statuses.

## Divergences and known gaps

- The CoS face is the Kit monogram in an assistant circle, not the desktop's generated `CompanyAIAvatar`.
- While a pair is preparing, the phone does not poll in the background as the desktop does (15 s, then backoff up to 5 min). It re-reads on every Team Space refresh (foreground, pull to refresh, company switch) and on Retry.
- The channel info sheet's member rows (`ChatInfoSheet.swift`) still use the glyph. Only the Team Space members list got photos and pills (that file is outside this stream).
- The notes room's chat header uses the generic chat chrome.
- **Unverified on a device or live account:**
  - production admission of the phone's bearer to the CoS ensure route;
  - that sliding sync lists the owner's notes rooms with their create state;
  - the raw `createRoom` path against the production homeserver;
  - opening "You" on the Mac after the phone made the room.

## Verification (2026-11-10, under the shared heavy-build lock)

| Command | Result |
|---|---|
| `cd ios && swift test --scratch-path /Volumes/AtumTestFlight/swiftbuild-w1-ts -j 2 --filter "CompanyNotesSelfTests\|CompanyPrivateCosTests\|NativeDomainClientTests\|CompanyConversations\|CompanyWorkspace"` | 140 tests, 0 failures. Includes the new `CompanyNotesSelfTests` (7: keys, earliest-owned winner and quarantine, pointer read, open/create/wait decision, create body, CoS row states, ensure request) and `NativeDomainClientTests.testPrivateCosEnsurePostsTheFrozenBodyAndAcceptsTheAsyncPreparingAnswer`. |
| `xcodebuild … -scheme AtumMobileStateTests -only-testing:AtumMobileTests/{S2StateTests,ConversationTests,TeamSpaceDailyTests,CompanySwitcherTests} test` (iPhone 17 simulator) | 140 tests, 0 failures. S2StateTests 77, ConversationTests 36, CompanySwitcherTests 18, TeamSpaceDailyTests 9. New: section present with conversations off, row order You → CoS → DMs, CoS not available / Retry / setting up / paused / ready with request-ID replay, first-visit ensure once, notes-room classification and roster title. The existing CoS tests now assert that the row is in Direct messages and not in Channels. |
| `xcodebuild … -scheme AtumMobile build` (simulator) | BUILD SUCCEEDED |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | PASS |

Not exercised: a physical iPhone, a live account, the production homeserver or the platform.

## PENDING-COPY

The export (`ios/Vendor/AtumDesign/Localizable.xcstrings`) has none of the Team Space, private-CoS or board copy families. Each placeholder below reads its proposed key first (`DirectMessagesCopy.pending`), so the copy worker's export repin makes it live with no code change. Until then, each falls back to the closest exported word.

| Key | en | vi | Where | Fallback until repin |
|---|---|---|---|---|
| `shared.matrix-team-space-copy.copy.personalNotes` | Your personal notes | Ghi chú cá nhân của bạn | VoiceOver label of the "You" row | `desktop.dm.you` ("You" / "Bạn") |
| `shared.matrix-company-board-copy.copy.chiefOfStaff` | Chief of Staff | Chief of Staff | CoS row name | the 1.3 capability's frozen `displayName`, else `shared.matrix-alias-copy.copy.assistant` |
| `shared.matrix-company-private-cos-copy.matrixCompanyPrivateCosRowCopy.notAvailable` | Not available yet | Chưa sẵn sàng | CoS row state | `src.matrix.assistant-card.copy.assistantCardCopies.setupRowNotReady` ("Not ready yet" / "Chưa sẵn sàng") |

Existing keys reused with the same meaning:

- `desktop.dm.you`: the "You" row.
- `src.matrix.assistant-card.copy.assistantCardCopies.setupRowWorking`: "Setting up…" / "Đang thiết lập…", identical to the desktop's CoS row copy.
- `desktop.atum.awareness.states.paused`: "Paused" / "Đã tạm dừng", identical.
- `shared.matrix-company-copy.copy.retry`: Retry.

"Direct messages" still comes from the pre-existing `ConversationPendingCopy` table (desktop `team.directMessages`). It should become `shared.matrix-team-space-copy.copy.directMessages` when that family is exported.
