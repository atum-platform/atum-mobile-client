# Wave 4 copy pin gaps

The scanner reported 75 literal occurrences across 72 distinct keys on
`origin/main` at `2c9c007`. Class **a** covers 63 keys (66 occurrences) with
existing guarded fallback tables. Class **b** covers unguarded reads of absent
keys and has zero entries. Class **c** covers nine stale names. The app panel
declares each of its three keys twice, once as a constant and once in its
fallback table.

The Start Chat star uses the pinned shell label. The three invite-link
formatters use the pinned plural roots and pass numbers to `AtumCopy`. This
uses the export’s zero and one forms and its plural formatting, including
“expires today” for zero days. The two obsolete member-count entries had no
shipped call sites and were removed.

The literal matcher already accepts pinned roots. The old `.one` and `.other`
entries were separate fallback table keys and the invite code assembled those
suffixed names at runtime. The scanner now follows the two separate Team Space
fallback tables to their existing guarded readers. The `client` job in
`public-client.yml` runs the scanner alongside the export checks.

## Classification

File and line numbers refer to the baseline at `2c9c007`. Table-only entries
have no current shipped lookup for that specific key. Any lookup through their
existing reader checks the pin before using the English fallback.

| Key | Baseline file:line | Class | Action |
| --- | --- | --- | --- |
| `src.matrix.app-bots.panel.panelCopy.openIn` | `ios/App/Chat/Views/AppPanelPages.swift:31` | a | Add to `PENDING`. |
| `src.matrix.app-bots.panel.panelCopy.noScreens` | `ios/App/Chat/Views/AppPanelPages.swift:33` | a | Add to `PENDING`. |
| `src.matrix.app-bots.panel.panelCopy.failed` | `ios/App/Chat/Views/AppPanelPages.swift:35` | a | Add to `PENDING`. |
| `src.matrix.app-bots.panel.panelCopy.openIn` | `ios/App/Chat/Views/AppPanelPages.swift:56` | a | Add to `PENDING`. |
| `src.matrix.app-bots.panel.panelCopy.noScreens` | `ios/App/Chat/Views/AppPanelPages.swift:63` | a | Add to `PENDING`. |
| `src.matrix.app-bots.panel.panelCopy.failed` | `ios/App/Chat/Views/AppPanelPages.swift:70` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.all` | `ios/App/Company/TeamSpacePendingCopy.swift:142` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.emptyAllBody` | `ios/App/Company/TeamSpacePendingCopy.swift:149` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.emptyAllTitle` | `ios/App/Company/TeamSpacePendingCopy.swift:156` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.emptyMentionsBody` | `ios/App/Company/TeamSpacePendingCopy.swift:163` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.emptyMentionsTitle` | `ios/App/Company/TeamSpacePendingCopy.swift:170` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.failed` | `ios/App/Company/TeamSpacePendingCopy.swift:177` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.filterLabel` | `ios/App/Company/TeamSpacePendingCopy.swift:184` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.loadMore` | `ios/App/Company/TeamSpacePendingCopy.swift:191` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.mention` | `ios/App/Company/TeamSpacePendingCopy.swift:198` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.mentions` | `ios/App/Company/TeamSpacePendingCopy.swift:205` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.open` | `ios/App/Company/TeamSpacePendingCopy.swift:212` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.someone` | `ios/App/Company/TeamSpacePendingCopy.swift:219` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.threadReply` | `ios/App/Company/TeamSpacePendingCopy.swift:226` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.title` | `ios/App/Company/TeamSpacePendingCopy.swift:233` | a | Add to `PENDING`. |
| `src.matrix.team-space.activity-copy.copy.unread` | `ios/App/Company/TeamSpacePendingCopy.swift:240` | a | Add to `PENDING`. |
| `src.matrix.team-space.drafts-copy.copy.emptyBody` | `ios/App/Company/TeamSpacePendingCopy.swift:247` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.emptyTitle` | `ios/App/Company/TeamSpacePendingCopy.swift:254` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.failed` | `ios/App/Company/TeamSpacePendingCopy.swift:261` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.open` | `ios/App/Company/TeamSpacePendingCopy.swift:268` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.roomDraft` | `ios/App/Company/TeamSpacePendingCopy.swift:275` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.threadDraft` | `ios/App/Company/TeamSpacePendingCopy.swift:282` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.drafts-copy.copy.title` | `ios/App/Company/TeamSpacePendingCopy.swift:289` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.team-space.pinned-copy.copy.noPinnedMessages` | `ios/App/Company/TeamSpacePendingCopy.swift:303` | a | Add to `PENDING`. |
| `src.matrix.team-space.pinned-copy.copy.pinnedMessageCount.one` | `ios/App/Company/TeamSpacePendingCopy.swift:306` | a | Add to `PENDING`. |
| `src.matrix.team-space.pinned-copy.copy.pinnedMessageCount.other` | `ios/App/Company/TeamSpacePendingCopy.swift:310` | a | Add to `PENDING`. |
| `src.matrix.team-space.pinned-copy.copy.pinnedMessageUnavailable` | `ios/App/Company/TeamSpacePendingCopy.swift:314` | a | Add to `PENDING`. |
| `src.matrix.team-space.pinned-copy.copy.pinnedMessages` | `ios/App/Company/TeamSpacePendingCopy.swift:317` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.emptyBody` | `ios/App/Company/TeamSpacePendingCopy.swift:320` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.emptyTitle` | `ios/App/Company/TeamSpacePendingCopy.swift:324` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.failed` | `ios/App/Company/TeamSpacePendingCopy.swift:328` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.title` | `ios/App/Company/TeamSpacePendingCopy.swift:332` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.unavailable` | `ios/App/Company/TeamSpacePendingCopy.swift:336` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.unavailableBody` | `ios/App/Company/TeamSpacePendingCopy.swift:340` | a | Add to `PENDING`. |
| `src.matrix.team-space.saved-messages-copy.copy.you` | `ios/App/Company/TeamSpacePendingCopy.swift:344` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.actionFailed` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:9` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyFollowingBody` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:16` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyFollowingTitle` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:23` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyRecentBody` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:30` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyRecentTitle` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:37` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyUnreadBody` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:44` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.emptyUnreadTitle` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:51` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.filterLabel` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:58` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.follow` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:65` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.following` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:72` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.lastReply` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:79` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.loadMore` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:86` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.markRead` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:93` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.noPreview` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:100` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.open` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:107` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.recent` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:114` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.replies.one` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:121` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.replies.other` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:128` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.title` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:135` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.unfollow` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:142` | a | Add to `PENDING`. |
| `src.matrix.team-space.company-threads-copy.copy.unread` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:149` | a | Add to `PENDING`. |
| `src.matrix.thread-copy.copy.lastReply` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:156` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `src.matrix.thread-copy.copy.reply` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:163` | a | Add to `PENDING`. |
| `src.matrix.thread-copy.copy.thread` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:170` | a | Add to `PENDING`. |
| `src.matrix.thread-copy.copy.threadOptions` | `ios/App/Company/TeamSpaceThreadsPendingCopy.swift:177` | a | Add table-only entry to `PENDING` under its guarded reader. |
| `shared.matrix-team-space-copy.copy.channelMemberCount.one` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:88` | c | Remove the unused fallback branch. The pin exports `shared.matrix-team-space-copy.copy.channelMemberCount`. |
| `shared.matrix-team-space-copy.copy.channelMemberCount.other` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:95` | c | Remove the unused fallback branch. The pin exports `shared.matrix-team-space-copy.copy.channelMemberCount`. |
| `shared.matrix-team-space-copy.copy.inviteLinkCapacity.one` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:186` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkCapacity` with a numeric argument. |
| `shared.matrix-team-space-copy.copy.inviteLinkCapacity.other` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:193` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkCapacity` with a numeric argument. |
| `shared.matrix-team-space-copy.copy.inviteLinkDuration.one` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:221` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkDuration` with a numeric argument. |
| `shared.matrix-team-space-copy.copy.inviteLinkDuration.other` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:228` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkDuration` with a numeric argument. |
| `shared.matrix-team-space-copy.copy.inviteLinkExpires.one` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:235` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkExpires` with a numeric argument. |
| `shared.matrix-team-space-copy.copy.inviteLinkExpires.other` | `ios/App/Company/TeamSpaceWave3PendingCopy.swift:242` | c | Remove the fallback branch and render `shared.matrix-team-space-copy.copy.inviteLinkExpires` with a numeric argument. |
| `src.matrix.mobile-copy.mobilePhoneCopy.drive.searchFolderOnly` | `ios/App/Drive/DriveCopy.swift:77` | a | Add to `PENDING`. |
| `desktop.matrixShell.mainAgent` | `ios/App/Home/HomeScreen.swift:3179` | c | Use pinned `src.matrix.mobile-copy.mobileScreensCopy.shell.mainAgent` for the star’s spoken label. |

## Desktop export follow-up

These are the 63 newly tracked gaps. Join each prefix with its listed suffixes.
The two count phrases should be exported as numeric plural roots
(`pinnedMessageCount` and `replies`). Their `.one` and `.other` suffixes
are the phone’s fallback entries. Switch the callers to the plural roots on
repin and retire the corresponding fallback entries.

- `src.matrix.app-bots.panel.panelCopy.`
  `failed`, `noScreens`, `openIn`.

- `src.matrix.mobile-copy.mobilePhoneCopy.drive.`
  `searchFolderOnly`.

- `src.matrix.team-space.activity-copy.copy.`
  `all`, `emptyAllBody`, `emptyAllTitle`, `emptyMentionsBody`, `emptyMentionsTitle`, `failed`, `filterLabel`, `loadMore`, `mention`, `mentions`, `open`, `someone`, `threadReply`, `title`, `unread`.

- `src.matrix.team-space.company-threads-copy.copy.`
  `actionFailed`, `emptyFollowingBody`, `emptyFollowingTitle`, `emptyRecentBody`, `emptyRecentTitle`, `emptyUnreadBody`, `emptyUnreadTitle`, `filterLabel`, `follow`, `following`, `lastReply`, `loadMore`, `markRead`, `noPreview`, `open`, `recent`, `replies.one`, `replies.other`, `title`, `unfollow`, `unread`.

- `src.matrix.team-space.drafts-copy.copy.`
  `emptyBody`, `emptyTitle`, `failed`, `open`, `roomDraft`, `threadDraft`, `title`.

- `src.matrix.team-space.pinned-copy.copy.`
  `noPinnedMessages`, `pinnedMessageCount.one`, `pinnedMessageCount.other`, `pinnedMessageUnavailable`, `pinnedMessages`.

- `src.matrix.team-space.saved-messages-copy.copy.`
  `emptyBody`, `emptyTitle`, `failed`, `title`, `unavailable`, `unavailableBody`, `you`.

- `src.matrix.thread-copy.copy.`
  `lastReply`, `reply`, `thread`, `threadOptions`.
