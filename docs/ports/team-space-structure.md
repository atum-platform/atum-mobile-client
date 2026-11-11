# Team Space structure (wave 2, TS-6…TS-10)

Branch `feat/w2-team-space-structure`, based on main `dd26d6e` (all of wave 1). Evidence: parity
audit lane 2 (`docs/research/2026-11-10-parity-audit/lane2-team-space.md` in the private plan
repo), slices L2-S6, S7, S8, S11 and S14. Desktop reference `atum-app@050ede8edf5`
(`apps/desktop/src/matrix/**`).

The phone speaks company wire 1.1 for channels, which is the desktop's **legacy profile** (no
team-admin read, no channel admission). Wherever the desktop's own legacy behaviour differs from
its C1/C2 behaviour, the phone follows the legacy one, and the gated part is listed below.

## What changed

| Slice | Phone now | Desktop source |
|---|---|---|
| TS-10 pages | A segmented **Chat · Board** control under the company header. The page is kept per company for the session. **Board** shows the desktop board's own "Board is unavailable." state, because the phone has no board read yet. **Marketplace** is not drawn: the desktop shows it only while the company Store answers, and the phone has no company Store read. A remembered page that is gone opens Chat. | `company-space-tabs.tsx`, `company-marketplace-store.ts:51–61`, `company-board.tsx:1763` (unavailable) |
| TS-8 company menu | The "…" is the desktop company menu. It shows **Company overview**, then Wallet / Invite people / Company settings when allowed, then **Add company** (opens the create form) and **Leave company**. An entry the viewer may not use is not drawn (`CompanyMenuAllowed`). The company list itself stays in the header's switcher sheet. Members moved into the overview, as the desktop folds it. | `team-space/company-menu.tsx:26–36,159–196`, `company-workspace.tsx:2717–2725` |
| TS-8 overview | **Company overview** sheet: logo (circle), name, your role pill, member count, Members (pushes the roster with photos and role pills), the Chief of Staff's state line, Leave company. | `company-workspace.tsx:3165–3403` (`CompanyOverviewFrame`) |
| TS-6 search | `.searchable` "Search {company}" filters channels (by the shown name, so `#chung`/`#general` too), "You" (by "You" or "Your personal notes"), the Chief of Staff (by name or state line) and DM rows (by title). Hidden conversations are not filtered, as on the desktop. | `channel-sections.tsx:69–73`, `conversation-sections.tsx:115–139` |
| TS-6 rows | **Saved** appears once the account's Saved list has an entry and opens a sheet of saved messages, newest first. A message that is gone, or not in a company room, says "Message unavailable". Tapping one opens its room. The list is the desktop's own `com.atum.saved_messages` account data (`version: 1`, pointers `room_id`/`event_id`/`saved_at`), read only. A malformed or newer record hides the row rather than guessing. **Threads** and **Drafts** stay hidden (see Deferred). | `team-space/sidebar-entry-visibility.ts`, `shared/matrix-saved-messages.ts`, `team-space/saved-messages.tsx` |
| TS-6 invite | An **Invite teammates** footer and an **Invite people** menu entry are wired, gated on `CompanyMenuAllowed.invite` (an admin, plus an invite sheet). The phone has no invite sheet until TS-11, so neither is drawn yet. **Wave 3:** both open the TS-11 sheet now (`w3-team-space.md`). | `company-workspace.tsx:2791–2802` |
| TS-7 Activity | A bell icon beside the company menu, always there while a company is open, with the desktop badge rule (unread mentions as a count, else a dot for an unread thread reply). It opens **Activity**: All / Mentions, 25 at a time with Load more, empty states, each row with the kind, room name, sender, time, unread dot and text. Tapping a row opens its room. | `team-space/activity-button.tsx`, `team-space/activity.tsx`, `company-workspace.tsx:2748–2754` |
| TS-9 channel chrome | The chat header for a company channel is **"# name"** with the room's topic under it. Beside it is a **members capsule** (up to three faces and the platform's channel count) and the channel's own **"…"**: Channel details, Add to/Remove from favorites, Mute/Unmute. There is **no Leave in a channel**: on the legacy wire, desktop's channel menu has no exit, and Leave company is only in the company menu (D6 fixed). The channel's info sheet now shows Channel details (name, topic, or the default channel's purpose; company · member count; created on), **Pinned messages** (a list read from `m.room.pinned_events`), and the roster with photos and role pills. An empty channel opens on its **intro**: "# name", the default channel's purpose, "Created on {date}". | `company-channel-menu.tsx:155–282`, `team-space/channel-chrome.tsx`, `team-space/channel-intro.tsx`, `team-space/pinned-panel.tsx` |

### How Activity is read

The desktop projects Activity from the SDK's synced tail of each company room. The pinned Rust SDK
has no such projection, so the phone asks the homeserver for the same two things with one
`GET /_matrix/client/v3/notifications?limit=200` (session bearer, HTTPS only, ephemeral session,
no cookies, redirects refused, the same transport as the notes room's create). `CompanyActivityFeed`
keeps a `m.room.message` from someone else that **highlights** (push-rule highlight tweak, or
`m.mentions.user_ids` names you) as a mention, or that is a **thread reply** (`m.relates_to.rel_type
== m.thread`) as a reply. It keeps only rooms the company directory lists: channels,
conversations, "You" and the Chief of Staff (desktop `authorizedCompanyActivity`). Unread is the
notification's own `read` flag.

Difference from the desktop: the desktop's "thread reply" means a reply in a thread you take part
in. The phone counts a thread reply that notified you. With default push rules these are the same
for most people. Reading does not mark anything read.

## Shared files touched (minimal, for the coordinator)

- `ios/App/AppRoot.swift`: passes `menu`, `viewerRole`, `loadActivity`, `loadSavedPointers` and
  `loadSavedRows` to `TeamSpaceScreen`, and `companyChannel` (`CompanyChannelActions`) to the chat's
  `ChatInfoActions`. Additive.
- `ios/App/LiveAppModel.swift` (`companyChatInfo`): the channel name is the localized one for the
  default channel; it adds `memberCount` and `isDefaultChannel`. All new reads live in an extension
  in `ios/App/Company/CompanySpaceReads.swift`.
- `ios/App/Chat/Views/ChatScreen.swift` (HC stream): a company channel's title, capsule and "…" are
  now the `CompanyChannel*` views; the "Leave company" item and its confirmation are gone; an empty
  channel shows `CompanyChannelIntro`.
- `ios/App/Chat/Views/ChatInfoSheet.swift` (HC stream): the company section is now
  `CompanyChannelInfoSection` (the old inline section and its Leave company confirmation were
  removed); `CompanyChatInfo` gains `memberCount` and `isDefaultChannel`; `ChatInfoActions` gains
  `companyChannel`. `leaveCompany` stays declared for hosts that still pass it.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: only the 7 new files' entries were added (XcodeGen
  IDs). A full `xcodegen generate` would also renumber other streams' hand-assigned IDs, so it
  was not committed.

## PENDING-COPY (design export dependency, EX-1)

None of these keys is in the pinned export. Each is read first from the export under the proposed
key; until then `ios/App/Company/TeamSpacePendingCopy.swift` holds the **desktop's own values,
generated verbatim** from the desktop tables (en, vi, ja, zh, zh-Hant where the desktop has them;
saved, pinned: en and vi only, as on the desktop). Proposed key → desktop source (English):

| Proposed export key | Desktop source | English |
|---|---|---|
| `shared.matrix-company-board-copy.copy.chat` | `shared/matrix-company-board-copy.ts` `chat` | Chat |
| `shared.matrix-company-board-copy.copy.board` | `board` | Board |
| `shared.matrix-company-board-copy.copy.marketplace` | `marketplace` | Marketplace |
| `shared.matrix-company-board-copy.copy.tabs` | `tabs` | Company pages |
| `shared.matrix-company-board-copy.copy.unavailable` | `unavailable` | Board is unavailable. |
| `shared.matrix-company-copy.copy.companyOverview` | `shared/matrix-company-copy.ts` `companyOverview` | Company overview |
| `shared.matrix-company-copy.copy.channelDetails` | `channelDetails` | Channel details |
| `shared.matrix-team-space-copy.copy.sidebarSearch` | `shared/matrix-team-space-copy.ts` `sidebarSearch(company)` | Search {company} |
| `shared.matrix-team-space-copy.copy.inviteTeammates` | `inviteTeammates` | Invite teammates |
| `shared.matrix-team-space-copy.copy.invitePeople` | `invitePeople` | Invite teammates |
| `shared.matrix-team-space-copy.copy.companySettings` | `companySettings` | Company settings |
| `shared.matrix-team-space-copy.copy.leaveChannel` | `leaveChannel` | Leave channel (not drawn on 1.1) |
| `shared.matrix-team-space-copy.copy.channelMembersTitle` | `channelMembersTitle` | Channel members |
| `shared.matrix-team-space-copy.copy.favoriteChannel` | `favoriteChannel` | Add to favorites |
| `shared.matrix-team-space-copy.copy.unfavoriteChannel` | `unfavoriteChannel` | Remove from favorites |
| `shared.matrix-team-space-copy.copy.defaultChannelPurpose` | `defaultChannelPurpose` | Everyone in the company is here: news and anything all of us should see. |
| `shared.matrix-team-space-copy.copy.channelTopicLabel` | `channelTopicLabel` | Topic |
| `shared.matrix-team-space-copy.copy.channelStartTitle` | `channelStartTitle(channel)` | This is the start of #{channel} |
| `shared.matrix-team-space-copy.copy.channelCreatedOn` | `channelCreatedOn(date)` | Created on {date}. |
| `src.matrix.team-space.layout-copy.copy.addCompany` | `src/matrix/team-space/layout-copy.ts` `addCompany` | Add company |
| `src.matrix.team-space.activity-copy.copy.{title,all,mentions,filterLabel,mention,threadReply,unread,emptyAllTitle,emptyAllBody,emptyMentionsTitle,emptyMentionsBody,loadMore,failed,someone,open}` | `src/matrix/team-space/activity-copy.ts` | Activity, All, Mentions, Filter activity, Mentioned you, Thread reply, Unread, No activity yet, …, Open in {room} |
| `src.matrix.team-space.saved-messages-copy.copy.{title,emptyTitle,emptyBody,unavailable,unavailableBody,failed,you}` | `src/matrix/team-space/saved-messages-copy.ts` | Saved, No saved messages, …, Message unavailable, It was deleted or you no longer have access., …, You |
| `src.matrix.team-space.drafts-copy.copy.*` | `src/matrix/team-space/drafts-copy.ts` | (table carried; row not drawn yet) |
| `src.matrix.team-space.pinned-copy.copy.{pinnedMessages,noPinnedMessages,pinnedMessageUnavailable,pinnedMessageCount}` | `src/matrix/team-space/pinned-copy.ts` | Pinned messages, No pinned messages yet., This pinned message is unavailable., {n} pinned message(s) |

Exported keys reused: `src.matrix.thread-copy.copy.threads`, `shared.matrix-company-board-copy.copy.chiefOfStaff`,
`shared.matrix-company-copy.copy.members` (plural count), the company leave/role words, the
private-CoS state words, `desktop.common.close`, the chat mute words.

Glyph dependency: the phone's Phosphor set has no Bookmark or Activity glyph. **Saved uses Star**
and **Activity uses Bell** until the glyph export adds `Bookmark` and `Activity`.

## Server-gated, deferred, unverified

- **Board** content needs a phone client for the platform's `board-*` native routes
  (`matrix-company-workspace.ts:1991–2004`) and `ATUM_MATRIX_COMPANY_BOARD_ENABLED`. Until then the
  page shows the desktop's unavailable line. **Marketplace** needs a company Store read.
- **Company settings, Wallet, Invite people / Invite teammates** are wired but not drawn:
  team-admin read (wire 1.3 admin), company wallet (TS-15) and the invite sheet (TS-11).
- **Leave channel, Channel members, Add people, Edit/Archive/Restore** need channel admission (wire
  1.4, `ATUM_MATRIX_COMPANY_CHANNEL_ADMISSION_ENABLED` + `…PRIVATE_CHANNELS_READY`). Not drawn.
- **Header topic**: the desktop shows its header line only with a 1.4 channel record. The phone
  shows the room's own `m.room.topic` when it has one, and nothing otherwise.
- **Threads row**: no phone thread projection yet (lane 1 thread UI). **Drafts row**: the desktop's
  drafts are per-target `com.atum.draft.v2.*` account data merged with `com.atum.drafts`; the
  pinned SDK cannot list account-data types, so the phone cannot read them fully. Both rows stay
  hidden (the desktop also hides a row with nothing to open), so nothing false is shown.
- **Channel intro** shows only in an empty channel (the desktop also shows it at the top of a
  history); the "who created it" line needs a 1.4 channel record, so the phone says "Created on".
- **Pinned** rows do not jump to the message (needs the chat timeline's focus API).
- **Activity** semantics differ slightly (see above). Not verified on a live account: the
  homeserver's `/notifications` answer for company rooms, Saved resolution against real desktop
  saves, pinned events written by the desktop.
- The scripted debug host (`ios/App/Debug`, not this stream's) passes no `menu`, so its "…" is
  hidden there; captures of the company menu need a live account or a host update.

## Verification

Every command ran under the heavy-build lock (`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k
/Volumes/AtumTestFlight/.heavy-build.lock …`), on the full working tree (all three commits).

| Command | Result |
|---|---|
| `cd ios && swift test --scratch-path /Volumes/AtumTestFlight/swiftbuild-w2-ts -j 2 --filter "CompanySpacePolicyTests\|CompanyNotesSelfTests\|CompanyPrivateCosTests\|CompanyConversations\|CompanyWorkspace"` | 77 tests, 0 failures |
| `… swift test … --filter CompanySpacePolicyTests` | 11 tests, 0 failures (tabs, menu, sidebar, search, Saved parse, Activity parse and badge) |
| `xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -sdk iphonesimulator -destination id=<iPhone 17> -derivedDataPath /Volumes/AtumTestFlight/dd-w2-ts -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build` | BUILD SUCCEEDED |
| `xcodebuild … -scheme AtumMobileStateTests -only-testing:AtumMobileTests/{TeamSpaceStructureTests,TeamSpaceDailyTests,ConversationTests,CompanySwitcherTests,S2StateTests} test` (iPhone 17 simulator) | 144 tests, 0 failures (new TeamSpaceStructureTests: 3) |

Not run: UI tests, simulator screenshots, a live account, a physical iPhone.

## Session log

- 2026-11-11, wave 2 TS worker: pure policy + tests (commit 1); Team Space screen structure, TS-6/7/8/10
  (commit 2); channel chrome, TS-9 (commit 3). Verified under the heavy-build lock; results in the
  worker report and below.
