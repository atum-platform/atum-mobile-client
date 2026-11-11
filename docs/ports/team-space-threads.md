# Team Space threads (TS-6b)

Branch `feat/team-space-threads`, rebased on main `e9c8997` (includes #28 invites and channel
sections, #31, #32, #34 chat header search). Backlog: atum-platform/atum-mobile#50, TS-6b
"Threads: open threads, follow, read state, and the sidebar Threads row". Evidence: parity audit
lane 2 (private plan repo, `docs/research/2026-11-10-parity-audit/lane2-team-space.md`, rows
"Threads row" and "Threads"). Desktop reference: atum-desktop `origin/main` `583ae946`.

## What changed

| Surface | Phone now | Desktop source |
|---|---|---|
| Threads row | Team space shows **Threads** above Saved once the open company has a thread (desktop `teamSpaceSidebarEntryVisibility`). Its mark is the desktop `threadsBadge`: unread thread mentions as a count, else a dot while any thread is unread. | `company-workspace.tsx:2766–2776,2865–2884`, `team-space/sidebar-entry-visibility.ts` |
| Company threads list | The row opens **Threads**: Recent / Following / Unread, 25 at a time with Load more, the desktop's three empty states. Each row: the room (`#` for a channel, the conversation's name), an unread dot, the root's text (two lines, or "Message unavailable"), the root sender's and newest replier's faces, "N replies · Last reply {time ago}", **Mark read** (while unread) and **Follow / Unfollow** (bell). A tap that fails says "Couldn't update this thread. Try again." and puts the row back. A row opens its room with the thread on top. Only the company's own channels and conversations are listed, rechecked against the directory after the reads (`authorizedCompanyThreads`). | `team-space/company-threads.tsx`, `team-space/company-threads-copy.ts`, `threads.ts` `matrixCompanyThreads` |
| Channel thread panel | The channel's "…" menu starts with **Open threads** (desktop `onThreads`). It opens the room's panel (a sheet): "Threads", Recent / Following / Unread, rows with the root's text, "N replies · date", an `@N` pill for unread mentions and an unread dot; "No threads yet." / "No threads here."; a close button ("Close threads"). | `app.tsx` `MatrixThreadPanel` (4726–4900), `company-channel-menu.tsx:220–226` |
| Reply in thread | A message's long-press menu in a Team Space channel or conversation offers **Reply in thread** after Reply, on a server message that is not itself a thread reply (never a nested thread). It opens the panel straight on that thread. | `app.tsx:951–955` (`onThread`), `threads.ts` `requireFlatThreadTarget` |
| One thread | The room's own chat screen on the thread's own timeline: the root, then its replies, in the transcript the channel uses (flat runs, reactions, media, reply, edit, delete). The header says **Thread** with the place under it ("# general" or the conversation), and the **Following / Follow** capsule (its hint says Unfollow / Follow). The composer says **Reply** and sends in the thread (text, mentions and attachments). From the panel's list Back returns to the list; opened straight on a thread there is no list to return to, as on the desktop. A root that is gone says "This thread is no longer available." (with "Back to threads" from the list). | `app.tsx` `MatrixThreadDetail` (4490–4724), `threads.ts` `sendMatrixThreadReply` |
| Read state | Reading a thread is a **private threaded receipt** (`m.read.private`, `thread_id` = root), on the thread's own timeline as the person reaches its end, and from the list's Mark read on the newest reply. It never moves the channel's fully-read marker or unread flag. | `threads.ts` `readMatrixThread` |
| Follow | The desktop's own record: room account data `io.atum.thread_attention.v1` = `{"v":1,"followed":[…],"unfollowed":[…]}` (sorted, ≤1000 each, disjoint, strict keys; anything else reads as no choices). Followed = not unfollowed, and (followed, or automatic: you take part, or you are mentioned). A toggle rewrites the record whole, last write wins across devices, like the desktop. | `threads.ts` `MATRIX_THREAD_ATTENTION`, `matrixThreadAttention`, `setMatrixThreadFollow` |

### How each part is read on the pinned SDK (atum-matrix-rust-components-swift 26.10.15-atum.2)

- **Thread list:** `Room.threadListService()` and one `paginate()` per room (the homeserver's
  `/threads`), giving each root, its newest reply and the reply count. Rooms are read
  concurrently. The desktop instead projects threads the SDK already synced and makes no request.
- **One thread:** `TimelineConfiguration(focus: .thread(rootEventId:))`. The Rust SDK's
  thread-focused timeline adds the `m.thread` relation (with the reply fallback) to `send`,
  `send_reply` and attachments by itself, and infers a `ReceiptThread::Thread` receipt
  (checked in `matrix-sdk-ui` at `4f7f4d49`: `Timeline::send`/`infer_reply`,
  `controller.receipt_thread()`). `SDKTimelineSource` forces the thread's reads to private and
  skips the fully-read marker and the unread flag.
- **Unread and mentions:** the homeserver's notification list (`GET /notifications`, the read the
  Activity inbox already makes): a thread is unread while a notification for one of its events
  is unread, and its mention count is its unread mention notifications. This is the same server
  notification state the desktop reads per thread (`getThreadUnreadNotificationCount`), taken
  from the 200 newest notifications.
- **Follow record:** read from the local store with `Room.accountDataRaw(eventType:)`; written
  with one `PUT /_matrix/client/v3/user/{me}/rooms/{room}/account_data/io.atum.thread_attention.v1`
  to the session's own homeserver with its bearer (HTTPS only, ephemeral session, no cookies,
  redirects refused), the same transport as the notes room's create.

## SDK gaps (what the pin does not offer)

- **No room account-data write** in the FFI (only global `setAccountData`), hence the one raw
  `PUT` above.
- **No per-thread unread counts.** `RoomInfo` has room totals only and the client does not ask
  sliding sync for `unread_thread_notifications`; hence the notification list.
- **No participation flag** on `ThreadListItem` (`current_user_participated` is not exposed, and
  `ListThreadsOptions`/`IncludeThreads.participated` exists as a type but no FFI call takes it).
  The phone's "you take part" is: the root or the newest reply is yours. A thread where only an
  older reply is yours is not automatically followed until you follow it.
- **Thread summaries in the channel transcript** (`MsgLikeContent.threadSummary`) were not
  relied on: the client is built without `threadsEnabled`, and whether the summary fills from
  bundled aggregations without it is not settled in the SDK source read.

## Deliberate differences and deferred

- **Thread replies still show in the channel transcript**, flattened with their "In a thread"
  quote, as before. The desktop keeps them only in the panel and draws "N replies · Last reply"
  under the root (`TeamSpaceThreadSummary`). Hiding them needs `hideThreadedEvents: true` on the
  channel timeline plus that summary line, a timeline-row change owned by the chat-rows stream,
  and an SDK summary the phone has not verified (see above). Hiding without the line would lose
  replies from view, so the transcript is unchanged. **Follow-up:** summary line + hide.
- **Thread "…" (Thread options)**: the desktop's per-thread notification level
  (`notificationPolicy.threadOverrides`) has no phone read; not drawn.
- **Composer typing** is not sent from a thread (no typing controller on the thread's store).
- **Thread drafts** are kept in memory for the session (keyed `room#root`), not in the desktop's
  `com.atum.draft.v2.*` account data (the Drafts row stays deferred).
- **Faces**: the company list shows the root sender's and the newest replier's faces (all the
  thread list names); the desktop shows every known participant. A sender without a display name
  shows no face (never an ID).
- **Time ago** uses `RelativeDateTimeFormatter` in the app's language (the desktop's
  `matrixAgo` is `Intl.RelativeTimeFormat`); the panel's date uses the system medium date.
- Glyph: the Phosphor subset has no Messages glyph; the row, menu entry and Reply in thread use
  **MessageCircle** until the glyph export adds it.
- Chat search (#34) is not offered inside a thread (the desktop panel has none).

## PENDING-COPY (design export dependency, EX-1)

Exported and reused: `src.matrix.thread-copy.copy.{threads, openThreads, closeThreads,
backToThreads, recent, following, unread, follow, unfollow, noThreads, noFilteredThreads,
threadUnavailable, replyInThread, replies}` (replies is the export's plural), and
`desktop.common.close`.

Not in the pinned export. `CompanyThreadsCopy` reads each proposed key from the export first;
until then `ios/App/Company/TeamSpaceThreadsPendingCopy.swift` holds the **desktop's own values,
generated verbatim** (en, vi, ja, zh, zh-Hant) by a Node script that evaluates the two desktop
tables and calls each phrase with `{0}` (count phrases with 1 and with another number for
`.one`/`.other`):

| Proposed export key | Desktop source | English |
|---|---|---|
| `src.matrix.thread-copy.copy.thread` | `thread-copy.ts` `thread` | Thread |
| `src.matrix.thread-copy.copy.reply` | `reply` (thread composer prompt) | Reply |
| `src.matrix.thread-copy.copy.lastReply` | `lastReply(when)` | Last reply {0} (carried, not drawn) |
| `src.matrix.thread-copy.copy.threadOptions` | `threadOptions` | Thread options (carried, not drawn) |
| `src.matrix.team-space.company-threads-copy.copy.{title, filterLabel, recent, following, unread, follow, unfollow, markRead, loadMore, actionFailed, noPreview}` | `team-space/company-threads-copy.ts` | Threads, Filter threads, Recent, Following, Unread, Follow, Unfollow, Mark read, Load more, Couldn't update this thread. Try again., Message unavailable |
| `…company-threads-copy.copy.replies.{one,other}` | `replies(count)` | 1 reply / {0} replies |
| `…company-threads-copy.copy.lastReply` | `lastReply(value)` | Last reply {0} |
| `…company-threads-copy.copy.open` | `open(room)` | Open thread in {0} |
| `…company-threads-copy.copy.empty{Recent,Following,Unread}{Title,Body}` | empty states | No threads yet / Threads from your company conversations will appear here. … |

## Shared files touched (minimal, additive)

- `ios/App/Chat/Views/ChatScreen.swift`: three trailing params (`thread`, `openThreads`,
  `threadPanelPresented`); the thread header and Follow capsule; "Open threads" passed to the
  channel menu; `presenter.openThread` for Reply in thread; the panel counts as covering the chat;
  no search inside a thread; flat runs in a thread.
- `ios/App/Chat/Views/Composer.swift`: optional `placeholder` (nil keeps "Message {chat}").
- `ios/App/Chat/Views/MessageMenu.swift`: `MessageActionsPresenter.openThread`; the Reply in
  thread item's title, glyph and action.
- `ios/App/Chat/SDK/SDKTimelineSource.swift`, `TimelineController.swift`,
  `ios/App/Chat/Stores/ConversationStore.swift`: an optional thread root that selects the
  thread-focused timeline and private, marker-free thread reads. Nil (every existing chat) is
  unchanged.
- `ios/App/Company/CompanyChannelChrome.swift`: optional `openThreads` entry at the top of the
  channel menu.
- `ios/App/Company/CompanyWorkspaceViews.swift`: the Threads row, its sheet and read
  (`TeamSpaceActions.threads`); Drafts stays hidden.
- `ios/App/AppRoot.swift`: the `CompanyThreadsCoordinator` state, the Team space thread actions,
  the chat's `openThreads`/`threadPanelPresented` and the panel host modifier.
- `ios/App/LiveAppModel.swift`: `conversationInfo` is internal instead of private (the thread's
  store is built from the same facts).
- `ios/Sources/AtumChat/MessageMenuRules.swift`: `.replyInThread`, `items(…, threads:)`,
  `threadRootID(for:)`.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: only the 5 new files' entries.

New files: `ios/Sources/AtumNativeAPI/CompanyThreadsPolicy.swift`,
`ios/App/Company/CompanyThreads{Matrix,Reads,Copy,Views}.swift`,
`ios/App/Company/TeamSpaceThreadsPendingCopy.swift`, `ios/Tests/CompanyThreadsPolicyTests.swift`,
`ios/Tests/AtumChat/ThreadMenuTests.swift`. Not touched: `CompanySpaceViews.swift`, the Board
files, `DeliveryLine`, `ChatFaces`, `TypingRow`, `WorkingLineRow`.

## Verification

Every build ran under the heavy-build lock (`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k
/Volumes/AtumTestFlight/.heavy-build.lock …`), from `ios/`, on `e9c8997` plus this commit.

| Command | Result |
|---|---|
| `swift test --scratch-path /Volumes/AtumTestFlight/swiftbuild-threads -j 2 --filter "CompanyThreadsPolicyTests\|ThreadMenuTests\|MessageMenuRulesTests\|CompanySpacePolicyTests\|ReportPolicyTests"` | AtumChatTests: 25 tests, 0 failures (new ThreadMenuTests 3; MessageMenuRulesTests 10 and ReportPolicyTests 12 unchanged) |
| `swift test … --filter "CompanyThreadsPolicyTests\|CompanySpacePolicyTests"` | 19 tests, 0 failures (new CompanyThreadsPolicyTests 8: attention parse, sorted write and limit, follow rule, projection of unread/mentions/follow, directory fence and cap, filters and badge, row overrides; CompanySpacePolicyTests 11) |
| `xcrun swiftc -parse` on every changed or new Swift file | all parse |
| `python3 tests/test_ios_project_sources.py` | OK (2 tests) |
| `bash scripts/pre-push-public origin/main HEAD` | PASS |

Not verified (no xcodebuild, simulator or live account in this stream): that the App target
compiles (only `swiftc -parse` ran on the App files; hosted CI builds the app); the
thread-focused timeline on a device (root first, threaded send, threaded private receipt); the
production homeserver's `/threads` answer and room account-data `PUT` for the phone's bearer;
that a desktop follow/unfollow and the phone's agree across devices; the sheet-after-push timing
when a company thread opens its room. No scripted UI test: the scripted Team space host has no
thread data or thread-capable timeline source, so a capture would need a new scripted source.

## Session log

- 2026-11-11, TS-6b worker: rebased onto `e9c8997` at the coordinator's request before building
  the Threads row on #28's channel list. Policy and tests in AtumNativeAPI/AtumChat; Matrix layer,
  views and glue in new App files; additive hooks in the shared files listed above.

## Review follow-up (cross-family review of #39)

- **Follow writes no longer overwrite each other.** Writes to one room run one at a time (`CompanyThreadAttentionWrites`), each built on the record the previous one wrote. That record is kept until the synced copy matches it, or for 120 s at most so another device's later choice still wins. Before, two quick taps in one room could both read the same record and the later `PUT` dropped the earlier choice.
- **A thread opened directly** ("Reply in thread", the company list) reads its real follow state first: the explicit choice, then the automatic rule (`companyThreadFollowed`). The capsule stays disabled until it's known. Before, it always started as "Follow".
- **Room reads are bounded** to four `/threads` requests at a time, in batches of main-actor tasks. A task group with `@MainActor` child closures hit the Swift 6 region-isolation checker's "pattern … does not understand" error on hosted Xcode.
- **Mark read clears the thread's mentions** in the optimistic override until a newer reply arrives, so a read thread no longer badges `@N`.
- Verified by `swiftc -parse` and the hosted checks; the build lock was busy.
