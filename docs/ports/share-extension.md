# Share extension backend

Branch: `feat/share-extension`, based on `main` at `5dfceca`. This implementation
owns intake, queueing, Matrix delivery and suggestions. The recipient picker is
intentionally a plain SwiftUI placeholder for the separate UI worker.

## Delivery decision

The extension ships **durable queueing**, not direct Matrix sends. Its confirmation
says “Queued. Open Atum to send.” It never reports network delivery, opens the app
without consent, or requests credentials from the host application.

The notification service is a useful reference, but deliberately restores one
room with send queues disabled and a memory-constrained store. Sending media to
multiple encrypted rooms needs an SDK send queue, encryption readiness, upload
lifetime, and the composer's image preparation. There is no measured guarantee
that those operations fit the share process's roughly 120 MB budget. The new
extension therefore links only AtumNativeAPI/AtumChat, not MatrixRustSDK. It reads
only the Matrix custody record's validated account/store identity, including
when its access token is expired. It cannot refresh tokens or open the crypto
store. Domain credentials are not accessible.

The main app drains at session readiness, recipient-directory changes and
foreground return. It uses its existing Matrix client, whose multiprocess crypto
lock is already configured in MatrixLiveRuntime. There is no second crypto writer
or extension-specific lock bypass. `SDKAttachmentSender` is extracted from the
composer and used by both paths. Images use AttachmentPreparer's existing
metadata stripping, resizing and image upload. Videos and other files use the
existing generic file attachment path (videos are downloadable file messages,
not a new inline-video implementation). MIME type and original display name
survive UUID staging. The current homeserver upload limit is checked in the app;
intake conservatively caps each file at 20 MiB.

## Durable handoff and recovery

- The App Group's `AtumShare` directory contains a bounded recipient snapshot,
  UUID job folders, files and atomic `job.json` manifests. No credentials or
  message contents enter diagnostics, filenames or intent content.
- Files are copied inside NSItemProvider callbacks, sequentially, without
  decoding full-size images or videos. URLs/text remain bounded strings.
  Attributed content text is used when a host supplies no attachment provider;
  a webpage title alongside real providers is not duplicated as a message.
  Limits: ten items per share, twenty recipients, 64 KiB per text/caption,
  twenty job folders and 400 MiB total disk. Copies use complete file protection
  and are excluded from backup. File/directory/symlink and path checks happen
  before commit. Uncommitted folders expire on subsequent intake after a day.
- A short `flock` serializes metadata/copy/clear operations across processes.
  The extension writes the manifest only after every provider completes and
  the current Keychain identity and published recipient eligibility still match.
  Account ID plus Matrix store generation prevents delivery under another login.
- Delivery state is per recipient and item: `pending`, `handingOff`, `accepted`.
  Preparation happens before marking handoff. The app rechecks current custody,
  joined membership and recipient eligibility. A local text echo accepted by the
  SDK is its durable send queue's responsibility. An attachment is accepted after
  its existing upload join completes. Original files stay until all destinations
  are accepted. Separate app staging copies avoid one destination deleting
  another's upload source.
- The pinned SDK cannot accept a caller-selected transaction ID for timeline
  sends. Termination between handing off and persisting acceptance is ambiguous.
  Such an item is **never silently replayed**: the app asks the person to check
  the chats, explicitly retry remaining items (possible duplicates), leave them
  for later, or discard queued copies. Accepted destinations are never replayed.
  Preflight failures remain pending and show a separate retry/discard notice.
- Sign-out removes queue contents and the directory. A racing old extension
  cannot commit after custody is removed; generation checks also cover sign-in
  races. SDK-owned local echoes retain the app's ordinary delivery/retry behavior.

## Outgoing Share Suggestions

Every ordinary text send (including replies) donates after SDK acceptance;
attachments donate after upload completion. Queue drain sends donate too. Edits,
reactions and incoming notifications do not become outgoing donations.

`ShareSuggestions.interaction` builds INSendMessageIntent with the Matrix room ID
as `conversationIdentifier`, recipient Matrix handles and INImage avatars,
`speakableGroupName` and a group image for group chats. Cached authenticated
192-pixel room/hero avatars are used when available; otherwise a small monogram
is generated. Group recipients currently use the conversation avatar/monogram.
The interaction direction is outgoing; its group identifier is the room ID.
Message content is omitted from the intent.

The live app resolver excludes hidden chats, company-hidden/inactive
conversations, archived company channels, `m.lowpriority` rooms, invites,
nonjoined, synthetic and quarantined rows. Eligibility is rechecked after async
donation to remove late results from a hide/leave/sign-out race. A persistent
room-group index enables deletion even after a room leaves the roster.
`INInteraction.delete(with: roomID)` deletes a room's group on leave. Directory
reconciliation also removes hidden/archived donations; sign-out removes every
indexed group. Failed deletions stay indexed for retry. Incoming notification
intent behavior is unchanged.

The extension declares `NSExtensionAttributes.IntentsSupported` containing
`INSendMessageIntent`. It reads `extensionContext.intent`, takes the conversation
identifier only from INSendMessageIntent, and preselects it only if present in
the current account's eligible directory. Stale/deleted/hidden suggestions have
no selected target and cannot bypass the picker.

## UI worker entry point

`ios/Share/ShareComposerModel.swift` is `@MainActor @Observable`:

| Member | Contract |
| --- | --- |
| `recentChats: [ShareChat]` | Read-only recent eligible snapshot, up to 512 chats. |
| `search: String` | Writable, case-insensitive local name search. |
| `chats: [ShareChat]` | Computed search results. |
| `selection: Set<String>` | Writable Matrix room IDs, preserved across searches. |
| `toggle(_ chat: ShareChat)` | Toggle a target, up to twenty, while ready. |
| `caption: String` | Writable optional caption, attached once per destination to its first item. |
| `items: [ShareItem]` | Read-only loaded attachment/text descriptors. |
| `phase: Phase` | loading, ready, queuing, queued, failed. |
| `progress: Double` | Intake fraction, zero to one. |
| `error: String?` | Safe user-facing intake/commit error; no raw provider errors. |
| `canSend: Bool` | Valid ready intake, selection and caption. |
| `load(providers:intent:) async` | One intake; resolves suggestion preselection and stages files. |
| `send()` | Commits durable queue. queued is the success state; does not dismiss. |
| `cancel()` | Cancels uncommitted intake and removes staged files. |

Construct with `ShareComposerModel(queue: try ShareQueue())`. The controller owns
the load task and extension context. On queued confirmation call
`completeRequest(returningItems: nil)`; on cancellation cancel its load task,
call model.cancel(), then cancelRequest. Keep the queued wording and explicit
Done button. `ShareViewController` is the principal class; replace only the
placeholder view for the designed picker.

`SharePendingCopy` is **PENDING-COPY**. Proposed keys are `share.title`, `search`,
`caption`, `send`, `cancel`, `queued`, `done`, `empty`, `failed`, `loading`,
`queueHelp`, `reviewTitle`, `reviewBody`, `waitingTitle`, `waitingBody`, `retry`,
`discard`, `later`, all under the `share.` prefix. Temporary Vietnamese and English
values are local; unsupported languages fall back to English. Move these into
the pinned export when approved. System app display name remains Atum.

## Apple setup (coordinator only)

No Developer account or provisioning changes were made.

1. Register an explicit iOS App ID **com.atum.mobile.share** under the same team
   and AppIdentifierPrefix as **com.atum.mobile**.
2. Enable **App Groups**; associate **group.com.atum.mobile.shared**.
3. Configure **Keychain Sharing** for the existing Matrix-only access group
   **$(AppIdentifierPrefix)com.atum.mobile.matrix**. The extension does not need
   the private **com.atum.mobile** credential group.
4. Generate development and distribution provisioning profiles for the new App
   ID with those entitlements. The XcodeGen development profile name is
   **Atum Mobile Share Development**. The committed ExportOptions mapping names
   **Atum Mobile Share App Store** for distribution. The coordinator must create
   that profile and apply the intended archive signing settings before upload.
5. Effective extension entitlements: `com.apple.security.application-groups`
   (the shared group) and `keychain-access-groups` (the Matrix group), plus the
   normal signing-generated application identifier/team/get-task-allow values.
   Push, associated domains, communication-notification and Siri voice handling
   entitlements are not required for this queue-only share extension. The main
   app's existing communication entitlement/NSUserActivityTypes remain present.

`ios/project.yml` is authoritative. Regenerate with
`xcodegen generate --spec ios/project.yml`. The app embeds AtumShare.appex and
AtumNotifications.appex once each; the share target embeds no SDK frameworks.

## Verification

The AtumShare scheme includes the extension and a hostless iOS test bundle.
Tests cover every supported provider category, mixed/sequential loading,
unsupported and excessive input, intent shape/avatar/deletion/preselection,
model selection/caption/identity changes, durable queue/account binding,
copy ownership, bounds, interrupted handoff, explicit retry and discard.

Every xcodebuild/swift test must run with the shared heavy-build lock, TMPDIR on
the build volume, two jobs, and derived data at the designated share-extension
build directory. Simulator boot and shutdown happen inside that same locked
script, with at most one simulator booted. No push, PR, CI or deployment belongs
to this worker's handoff. See the final verification record below.

## Owner device checklist

- Register/sign/profile the target above; install a signed app and confirm the
  Atum icon is available in the real iOS share sheet, including after reinstall.
- From Photos share JPEG/HEIC/PNG/GIF and video; from Files share PDF and other
  files (including an iCloud download); from Safari share URL, selected text and
  URL+text; try ten mixed items, oversized input, and cancellation mid-load.
- Select one and multiple chats, add a caption and search without losing
  selection. Confirm the extension says queued, dismiss it, force quit the host,
  then open Atum. Confirm exactly the intended rooms receive the right files,
  names/MIME types and one caption each.
- Repeat for encrypted DMs and groups, locked/unlocked device, offline-to-online,
  expired token, concurrent notification decryption, and background/foreground.
  Use Instruments on device to confirm the share process stays below its memory
  budget for large photos/videos; no SDK client should appear in that process.
- Interrupt the main app before preparation and during SDK handoff. Confirm
  accepted destinations are not replayed and ambiguous handoffs ask for review.
  Verify explicit retry/discard, unreadable/removed files, server file limits,
  revoked membership and hidden/archived targets fail visibly without wrong sends.
- Send text, reply and media in direct/group chats; allow iOS to learn usage.
  Confirm outgoing room suggestions show names and avatars, and tapping a
  suggestion preselects its room. The OS controls ranking/timing; the simulator
  cannot establish real share-sheet suggestion behavior.
- Hide/archive/leave a chat and sign out; confirm its suggestions disappear.
  Reopen an old suggestion and verify it cannot select an ineligible room.
  Sign in as a different account (and as the same account with a new store
  generation); old queued items and suggestions must not cross the boundary.
- Confirm notification incoming avatars and ordinary composer uploads/retries
  still work. Review temporary copy with the UI/copy owner before release.

## Verification record — 2026-11-15

- Xcode 27, arm64 iPhone 17e simulator, Debug, signing disabled for simulator.
- Initial standalone Debug app build succeeded, embedding the new extension.
  The final expanded build-for-testing also rebuilt the app and extension.
- Final share suite: **42 tests, zero failures**: 11 provider-loading,
  17 queue/drain/recovery, 5 intent construction/preselection/deletion,
  5 donation lifecycle/deletion race, and 4 composer-model tests.
- Attachment preparation regression suite: **4 tests, zero failures**,
  including the three existing image tests and a new UUID-staged video
  filename/MIME test. Total final focused coverage: **46 passing tests**.
- Source and built app/extension Info.plists, extension entitlements/privacy
  manifest, and export options pass plutil lint.
- The built app contains one AtumShare.appex and one AtumNotifications.appex.
  The share executable's dynamic dependencies contain no MatrixRustSDK.
- Regenerated project comparison preserves every previous file-reference path
  and existing target build setting. Reordered/generated object identifiers are
  XcodeGen normalization, not missing source files.
- Simulator tests use one simulator inside the shared heavy-build lock; the
  locked script shuts down all simulators on exit. All derived data stays in
  the designated share-extension directory. No physical-device suggestion,
  encrypted delivery, memory profile or distribution-signing claim is made.
