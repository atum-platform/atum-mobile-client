# Working-line parity: desktop → phone

Audit date: 2026-11-12. Phone baseline: `5018d28b0e2321675760214547f2eaa120db7b01`.
Desktop source of truth: `b4506a4e78e0faad49f741705bb8dd4bc2124f1f` (`origin/main` in
`~/projects/atum-desktop`), read with `git show`. Desktop evidence below is relative
to `apps/desktop/`; phone evidence is relative to the repository root. “Before”
means the phone baseline, “after” means this branch. This is an implementation
handoff; the coordinator owns review, integration, pushing and CI.

## Rule-by-rule parity

| Desktop rule and evidence | Phone before / mismatch | Match before → after; phone evidence |
| --- | --- | --- |
| A transient line is a non-own, non-redacted **agent notice** with progress or exact trimmed retired wait copy. `shared/matrix-transient-lines.ts:29` | Pure helper already matches. View separately guessed by marker/body without checking the sender, so human/bot notices could draw a working atom. | No → Yes. `ios/Sources/AtumChat/TransientLines.swift:29`; `ios/App/Chat/Views/ChatRowView.swift:38` now renders all surviving notices as notices. |
| Retire eight historical Mac waits plus `waiting`/`waited` in all **five** locales (en, vi, ja, zh, zh-hant): 18 strings. `shared/matrix-transient-lines.ts:14`; `shared/matrix-status-line-copy.ts:10` | All 18 already present; earlier tests only sampled English/Vietnamese. | Yes → Yes. `ios/Sources/AtumChat/TransientLines.swift:15`; exhaustive `WorkingLineParityTests.testAllFiveLocalesAndHistoricalWaitCopyAreTransient`. |
| Hide a settled line, or one preceding a later same-agent non-transient, non-interim, non-pending, non-failed, decryptable message; reply target does not matter. `shared/matrix-transient-lines.ts:68` | Helper matches. Projection's extra reply-key filter could remove a still-live line after an interim, pending or failed reply. | No → Yes. `ios/Sources/AtumChat/Projection.swift:159`; obsolete `answerKeys`/`isSuperseded` filter removed. Tests cover pending, failed, both undecryptable kinds, interim and uncorrelated outcomes. |
| An agent redaction shows nothing, including removed interim remarks; humans/owner keep tombstones. `shared/matrix-transient-lines.ts:75` | Helper matches, but live group/company contexts supplied no known agents. | No in shared rooms → Yes. `ios/Sources/AtumChat/RoomKind.swift:50`; `ios/App/LiveAppModel.swift:3570`; `ios/App/Chat/SDK/ItemMapper.swift:106`. |
| Select the newest surviving line for the private chat's own assistant, while removing **all** transient messages from transcript entries. `src/matrix/app.tsx:5307`; `shared/matrix-transient-lines.ts:50` | Projection moved one event last but retained older live lines and did not constrain the selected sender. | No → Yes. `ios/Sources/AtumChat/Projection.swift:159`; `RoomContext.workingLineSenderID` defaults to the selected assistant. Other agents cannot supply this footer. |
| The working line is part of `loadingIndicator`, never its own transcript message; typing OR a live line shows one working component. `src/matrix/app.tsx:5700` | The progress event remained a `.notice` row with event/reply/latest metadata, and its ID replaced the typing ID. | No → Yes. `ios/Sources/AtumChat/Projection.swift:244` produces one stable `atum.typing` synthetic row carrying only names/body; all progress event IDs stay out of display rows. |
| First nonempty LF-delimited body line is current step; later lines are steps; ✓/✔ are done, •/◦ are pending; strip one marker and following whitespace. `src/matrix/typing-indicator.tsx:27` | Normal checks/bullets already match. Swift split on every Unicode newline and interpreted the marker as a grapheme rather than desktop's scalar regex. | No at edge cases → Yes. `ios/Sources/AtumChat/WorkingLineText.swift:32`; LF/CRLF, all four markers, unmarked rows, blank text and variation-selector tests. |
| Atom occupies identity slot; current step sits beside it; done steps use check, pending steps dotted ring. `src/matrix/typing-indicator.tsx:41` | `AgentWorkingLayout` already implements this. | Yes → Yes. `ios/App/Chat/Views/TypingRow.swift:35`; only functional routing changed in `ChatRowView`, no layout/restyling. |
| Private chat publishes one progress line; group publishes a separate legacy status notice and uses ordinary typing, not the private working component. `shared/matrix-status-ask.ts:23`; `shared/matrix-progress-line.ts:43`; `electron/matrix/main.ts:10707` | Projection could place a progress atom in any room; live group/company mapping did not recognize known agents. | No → Yes. `ios/Sources/AtumChat/Projection.swift:160,246`; `ios/App/LiveAppModel.swift:3570`; non-assistant rooms retain non-transient notices and use the composer typing line. See subtle group rule below. |
| Non-assistant rooms use `MatrixTypingLine` above composer, including app-bot rooms. `src/matrix/app.tsx:3955` | Store already splits names correctly, but direct projection calls could create a typing row in any room. | Yes through live store / No at projection boundary → Yes. `ios/Sources/AtumChat/TypingNames.swift:81`; `ios/App/Chat/Stores/ConversationStore.swift:724`; projection now enforces assistant-only footer. |
| Interim remarks are real transcript messages, never themselves working lines or final answers. `src/matrix/app.tsx:5343`; `shared/matrix-transient-lines.ts:89` | Helper/answer grouping match; old notice suppression treated an interim reply as an answer. | No → Yes. Reply-key suppression removed; interim remains in transcript alongside the footer. Existing `Delivery` no-answer handling is unchanged. |
| Ordinary outcome notices persist, including when a later answer replies to the same question. `shared/matrix-transient-lines.test.ts:76`; `src/matrix/app.tsx:5312` | Phone B17 hid **any** agent/bot notice whose reply target had a text reply. | No → Yes. `ios/Sources/AtumChat/Projection.swift:174` retains non-transient notices. Old tests now use actual retired wait text when testing hidden lines. |
| Working edits never show “(edited)”; agent message edits also lack the person-edited label. `src/matrix/typing-indicator.tsx:45`; `src/matrix/app.tsx:1153` | Working view already had no edited label, but the event carried edited metadata; shared-room agent identity was absent from grouping. | Yes for working view / No for shared-agent grouping → Yes in projection. Synthetic footer has no edit/time/delivery metadata; `ios/Sources/AtumChat/Grouping.swift:215` recognizes known shared-room agents. VoiceOver caveat below. |
| Working notices/edits do not create new-message notifications. Publisher uses `m.notice` and edits use `m.replace`; desktop ignores edits and follows SDK push actions. `src/matrix/notice-edit.ts:84`; `src/matrix/notifications.ts:70,120` | No notification effects originate from timeline projection. Phone NSE already suppresses SDK-filtered/redacted events. Full APNs behavior depends on SDK/homeserver push rules, as desktop does. | Yes at inspected projection/SDK-policy boundary; transport not exercised. `ios/Sources/AtumChat/ChatItem.swift:259`; `ios/Notifications/MatrixNotificationFetcher.swift:91`; `ios/Notifications/NotificationService.swift:113`. No blanket suppression of legitimate outcome notices added. |

## Important group-room distinction

The desktop publisher's “a group keeps its status line” is **not** a renderer
exception to transient filtering. At this exact desktop revision, `app.tsx:5312`
filters transient lines in every room, and `workingLine` is selected only for
`room.assistant`. Therefore an agent's recognized fixed retired wait notice in a
group is hidden even while live; an ordinary non-transient group status/outcome
notice stays. The phone now follows this exact behavior. It does not invent a
group progress footer or exempt retired strings to reinterpret the publisher's
comment. Catalog app bots remain distinct from known assistant agents.

## Implementation and integration

- Keep raw timeline events/indices intact. Strip transient events only during
  projection, before day-divider pruning, latest-row assignment and quote grouping.
- Expose current work through the existing synthetic `.typing(names:)` row's body.
  `ChatRowView` routes a nonempty body to the existing `WorkingLineRow`; empty body
  uses `TypingRow`. ID is always `atum.typing`, including line edits and legacy waits.
- Separate account-wide known agent identities from the selected room agent/bot.
  The live adapter supplies active `/agents` identities, also in company/group rooms;
  markers are parsed for those identities, never inferred from Matrix ID shape or text.
- Update scripted working fixtures with actual progress markers, so they exercise
  the current contract instead of depending on obsolete generic-notice suppression.
- `MessageFold.swift`, `MessageFoldViews.swift` and `TranscriptView.swift` are
  untouched. Existing `.typing` handling preserves Stop and growing-message signals;
  an integration test checks both. No delegates, pushes, PRs or CI from this worker.

## Coordinator follow-ups / limits

- **View-only VoiceOver gap:** `ChatRowText.speech` in
  `ios/App/Chat/Views/ChatRowView.swift` still derives the spoken edited label from
  room kind, so a group agent's edited **interim/message** may be announced as edited
  even though `Grouping.showsEdited` correctly suppresses its visual label. It is not
  used by the working footer. Route to the UI worker along with identity-aware
  speech work; this worker only changes the notice/typing routing.
- No simulator/UI run was required or performed. Visual spacing, first-learning
  tiles (desktop takes precedence over normal working UI), and VoiceOver wording
  remain UI-worker verification. Existing working-row layout was not restyled.
- Desktop can augment `m.typing` with its own Mac-local run/turn state
  (`app.tsx:5501`). The phone has no Mac-local turn feed; it uses synced typing and
  progress events. No speculative activity is manufactured.
- Notification parity here is source-level: SDK-filtered events suppress the alert,
  notices never count in the jump pill, and footer updates emit no notification.
  No APNs notification was sent and no push-rule configuration was changed.

## Verification

Required command (all compiler work under the shared lock, two jobs, no simulator):

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  swift test --package-path ios \
  --scratch-path /Volumes/AtumTestFlight/working-line-parity-swift \
  -j 2 --filter AtumChatTests
```

Initial run: 713 tests, four assertion failures in three existing scripted tests.
These asserted the obsolete notice event ID/suppression rule; fixtures and assertions
were corrected to exercise progress markers and the stable synthetic footer.
Final rerun: **713 tests passed, 0 failures**, including 13 new
`WorkingLineParityTests`, the existing transient-line cases ported from desktop,
and updated scripted timeline integration tests. Build completed in 17.57 seconds;
tests in 1.54 seconds. `git diff --check` passed. No Xcode/UI build was run; the
app adapter and minimal SwiftUI dispatch changes were source-reviewed only.

Log: `/Volumes/AtumTestFlight/working-line-parity-tests-final.log` (local diagnostic;
this durable report preserves the command and result for coordinator handoff).

## Recognition follow-up: owner report from Luna on 5018d28

The first projection patch alone did not address two upstream recognition defects.
The owner saw an activity notice centred in the transcript because an unrecognized
working event follows the ordinary `NoticeRow` path.

1. **Full event JSON was mistaken for content JSON.** The pinned
   `atum-matrix-rust-components-swift` revision `66c18d37`, generated
   `Sources/MatrixRustSDK/matrix_sdk_ffi.swift:7707`, documents `latestJson()` as
   the **full raw JSON string of the latest version of the event (including
   edits)**. `ItemMapper` passes that string to `AtumTurnMarkers`, whose original
   parser looked for `io.atum.progress` only at the root. Real SDK envelopes put
   it in `content`; edited events can put the effective marker in
   `content["m.new_content"]`. Existing parser tests used bare content and missed
   the boundary. This explains the centred activity path even with a fully loaded
   agent directory. The parser now unwraps both layers, preserving bare-content
   callers. Replacement content wins, including when it removes a marker; malformed
   content/replacements do not fall back to an old marker.
2. **Cold-open identity was frozen.** `conversationInfo` derives the private
   assistant and known agent set from authoritative `/agents` data plus Matrix
   room membership. Before that data arrives, the same room can open as `.person`
   with an empty agent set. The store, core, typing factory and SDK mapper kept that
   initial context. A later `/agents` response or room membership update did not
   reconcile the open chat. The mapper had already discarded the unknown sender's
   markers, so merely re-running projection could not repair cached `.notice`
   items. `refreshConversationIdentity` now runs after directory updates and room
   publications. A changed identity detaches old callbacks, updates the same store
   and core, and reattaches a fresh mapper to the SDK cache. Draft/send/follow state
   stays in the existing store; unchanged publications do not reopen the timeline.
   The first refreshed projection also replaces the old identity-dependent handover
   rows: otherwise an all-working timeline with no visible event rows could keep the
   stale notice through `SessionHandover`.

Desktop's agent set comes from `snapshot.assistant.userId` plus `snapshot.agents`
(`src/matrix/app.tsx:5282`), and changing `agentKey` reruns its transcript projection.
Its room-specific singular assistant comes from `snapshotForRoom`
(`src/matrix/room-agent.ts:32`). A room-type marker alone is not a sender identity:
`shared/matrix-assistant-room.ts:93` still requires the owner/agent IDs and members.
The phone does not have a separate Mac host's singular assistant account, so this
fix waits for its authoritative directory and then repairs the already-open room.
It does not infer identity from the name Luna, activity copy, raw Matrix ID shape,
or an untrusted room-type claim. Human and catalog-bot notices remain ordinary
notices unless the same desktop agent rules recognize the sender/event.

Regression coverage adds full original and edit SDK envelopes, interim envelopes,
replacement marker removal/malformed payloads, a cached-event late-identity race,
and an app-store integration test that opens without agents, refreshes identity,
reattaches the **same cached event**, and checks that it becomes only `atum.typing`
while preserving the draft. `chat.timeline-parity` now obtains its activity marker
from a full SDK-shaped event envelope, so the screenshot fixture crosses the repaired
parser boundary as well.

### Verification follow-up: app target and UI contract

UI tests now query `AccessibilityID.rowTyping` explicitly. `latest()` and reading
anchors intentionally remain transcript-event queries. A single accessibility
snapshot checks the working footer's uniqueness, current-step text and frame;
this avoids comparing different phases during short scripted typing windows.
G-scroll check 7 checks the edited footer and its removal after the final answer.
The reply-at-bottom test checks the same lifecycle. U2 checks typing-only footer
removal. The new step-card test checks current step + both checklist rows in one
footer, absence of a separate progress row, and keeps a screenshot. Moon's test
checks its composer typing line and the absence of an assistant footer. The Stop
test checks one footer while working; that fixture only acknowledges Stop and does
not invent a synced final event, so disappearance is asserted in the transcript
fixtures that actually finish their turn.

`ComposerAndMenuUITests.swift` contains `ComposerUITests`, `MessageMenuUITests`,
and `TurnStopUITests`, not a class named after the file; all three are included.
The first queue entry was cancelled **before acquiring the lock** on coordinator
steer. One replacement locked batch includes the new AtumChat tests, app/test-target
build, all AtumMobileTests, TranscriptUITests, GScrollUITests, these three composer/
menu/stop classes and S1MatrixUITests. No tests are skipped. It uses two build jobs,
`/Volumes/AtumTestFlight` derived data, one iPhone 17 simulator, the documented
appearance/text-size runner, and an EXIT cleanup ending in `xcrun simctl shutdown all`.

First executed batch: AtumChat **718 passed, 0 failed**. The app/test build
stopped (exit 65) at `ChatFaces.swift:147`: `Request.init` called the main-actor
avatar candidate helper from a synchronous nonisolated initializer. Corrected by
marking that UI-only initializer `@MainActor`. No app/UI test executed and no
screenshot was captured in that batch; the EXIT cleanup ran. Since the coordinator
explicitly capped execution at one locked run, a corrected build/test/capture batch
requires an exception to that run limit. Initial evidence is retained as
`/Volumes/AtumTestFlight/working-line-parity-ui/attempt-1-build.log` and
`attempt-1-status.txt`.

### Recognition follow-up: typing and Seen avatar evidence

The second owner screenshot (21:32, Luna) shows the composer-level “Luna is typing…”
line rather than the atom. This is the `.person`/`.group` branch of
`TypingNames.presentation`; it corroborates the frozen-context race above. The
app integration regression now sends real scripted typing before and after the
identity refresh: it first observes `.names(["Luna"])` above the composer, then
`.nobody` there and exactly one synthetic working footer after directory arrival.

The Seen avatar has independent stale-input paths in addition to classification:

- `openConversation` fetched Matrix members but discarded their profiles for
  assistant/app chats. It now retains them for faces in every chat. Current
  `LiveMatrixRoomRow.memberProfiles` publications replace open-time records in
  `chatInfoPresentation`, so a late photo updates the visible Seen face and an
  explicit removed photo replaces the old profile.
- `ChatScreen` built the face environment with `conversationAvatar`, captured only
  at open, although current `ChatInfoPresentation.avatar` could already have the
  new `/agents` photo. It now uses current info artwork when info exists, including
  an explicit nil, falling back to the launch avatar only before info exists.
- `ChatFace.memberFace` discarded an assistant member's actual Matrix avatar and
  substituted the room's URI. It now retains the member's URI. Before a member
  record arrives, a reader's own timeline profile precedes a room-URI fallback.
- `ChatFaceView` keyed photo requests on the entire face (including its display
  name) and unconditionally assigned a cancelled loader's nil result. Image
  requests now depend only on image sources/size/preference, and a cancelled
  request cannot overwrite a newer image.

Desktop evidence is `src/matrix/send-state.tsx:60` (Seen resolves each reader's
member) and `src/matrix/member-avatar.tsx:68` (an identified agent uses its roster
art; other members use their Matrix avatar). The phone now prefers a private
assistant's current roster photo, with the actual member photo available if the
remote photo cannot load. No size, shape, spacing, or other styling changes.

App tests cover a missing → available member photo, actual PNG decoding through
the same avatar loader, current roster-photo precedence with member fallback,
and a current member whose removed photo must not reuse an old room/event URI.
No fixture reads a live account or downloads an avatar. The second queue entry
was also cancelled before acquiring the lock; the final combined batch includes
both owner follow-ups.


The coordinator approved one corrected locked batch after the initializer fix,
with a local implementation commit before starting it. Package code is unchanged
since the 718-test pass, so that batch skips the redundant package run and includes
the app/test build, all previously selected app/UI tests, and screenshot capture.
Final results will be appended after reading the result bundle.
