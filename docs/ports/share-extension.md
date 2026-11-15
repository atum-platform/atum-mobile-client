# Share extension backend

Branch: `feat/share-extension`, based on `main` at `5dfceca`. This implementation
owns intake, queueing, Matrix delivery and suggestions. The designed recipient
picker is built on `feat/share-picker`, on top of it; see "Picker UI" below.

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

`SharePendingCopy` is **PENDING-COPY**. Proposed keys are `share.title`,
`caption`, `queued`, `empty`, `failed`, `loading`, `queueHelp`, `link`, `text`,
`items`, `limit`, `reviewTitle`, `reviewBody`, `waitingTitle`, `waitingBody`,
`retry`, `discard`, `later`, all under the `share.` prefix. Temporary Vietnamese
and English values are local; unsupported languages fall back to English. Move
these into the pinned export when approved. System app display name remains Atum.
The backend's proposed `search`, `send`, `cancel` and `done` were dropped: the
export already has those words (see "Picker UI › Copy").

## Picker UI

`ios/Share/SharePickerView.swift` replaces the placeholder. The sheet is a native
`NavigationStack`: Cancel, a principal title ("Share to Atum" with the export's
"N selected" under it once a chat is chosen) and Send (`confirmationAction`,
disabled until `canSend`, a spinner while queuing). Below it, in an inset list:

- **Preview strip** (`SharePickerPreview.swift`): one tile per item. Photos and
  videos show thumbnails of the *staged copies* (ImageIO thumbnail /
  `AVAssetImageGenerator` capped at 3x the tile, off the main actor; never a
  full-size decode). Files, links and texts are quiet tiles with the file name,
  the link's host, or the text's first line. While intake runs the strip shows
  "Preparing…" with the model's progress.
- **Caption** (vertical text field, up to five lines) and the queue help line.
- **Search** (`.searchable`, always visible) bound to `model.search`; the empty
  result uses the Forward picker's "No chats found".
- **Recent** (`SharePickerSections`): the Share Suggestion's chat first when the
  intent named an eligible room (it is preselected by the model), then the newest
  chats, five in all. **Chats**: every other chat in Home's recency order, each
  chat listed once. While searching, one list of matches.
- Rows (`SharePickerRow.swift`) draw Home's face with the app's own `AtumAvatar`
  (circle, app squircle, Atum crescent, assistant mark, Kit monogram) at 40 pt,
  the name, and the Kit selection mark (ink ring / ink disc with check). Rows
  beyond the twenty-chat bound disable and a notice explains the limit.
- Notices: no published chats ("Open Atum and sign in…"), intake/commit failure.
- **Queued** (`SharePickerQueued`): check, "Queued. Open Atum to send.", the
  help line and an explicit Done (Kit primary capsule). VoiceOver announces it.

The controller sets `isModalInPresentation` so swipe-down cannot bypass Cancel's
cleanup of staged copies. If the queue or Kit tokens cannot load, a minimal
failure screen still offers Cancel (the placeholder had no way out).

Model additions (`ShareComposerModel`): `suggestedChatID`, `maximumSelection`,
`isAtSelectionLimit`, `stagedFile(for:)`, and toggling is allowed while intake is
still loading (only chats in the current snapshot; Send still waits for ready).
`ShareChat` gained optional `face` (Home roster kind) and `mark` (assistant
mark); the app fills them from `HomeRow(product:)`, and older snapshots without
them decode (faces then fall back to group/person).

### Design system reuse

The extension does not link the app or the 6 MB AtumDesign resource bundle. It
compiles two app files and one token file:

- `App/DesignSystem/AtumKit.swift`: the Kit token reader, environment, capsule
  buttons and elevation. The app-only half (`vendored()`, legacy palette roles,
  `.atumDesign`, `AtumNotice`, `AtumAskCard`) moved verbatim to
  `AtumKitComposites.swift`.
- `App/DesignSystem/AtumAvatar.swift`: the face renderer and decoder. The
  catalog/remote loaders moved verbatim to `AtumAvatarLoading.swift`. The
  renderer now reads only `\.atumKit`; `.atumDesign` always installs it beside
  `\.atum`, so app rendering is unchanged (`AvatarArtTests` now installs the
  pair through `.atumDesign`).
- `Vendor/AtumDesign/atum-kit-tokens.json` as a resource. Every colour, radius,
  space and type role comes from these tokens; light and dark follow the system.
- Icons: `Share/Assets.xcassets` carries eight Phosphor symbols generated by
  `scripts/generate-phosphor-symbols.py` (`SHARE_ALIASES`, also covered by
  `--check`).

Avatars: the extension never fetches. It reads the App Group's cached 192 px
Matrix thumbnails (`NotificationSharedStore`, filled by the notification
service), the same bytes Share Suggestions donate. A chat without a cached face
shows Home's placeholder treatment (monogram, mark or crescent).

### Copy

Exported desktop keys, projected into `Share/ShareLocalizable.xcstrings` by
`scripts/generate-share-localization.py` (validates the export digest, five
locales and parameter shapes; `--check` mode):

| Use | Key |
| --- | --- |
| Cancel | `src.matrix.chat-copy.copies.cancel` |
| Send | `src.matrix.chat-copy.copies.forwardSend` |
| Search prompt | `src.matrix.chat-copy.copies.forwardSearch` |
| No search results | `src.matrix.chat-copy.copies.forwardEmpty` |
| Recent section | `src.matrix.group-picker-copy.copies.recent` |
| "N selected" (plural) | `src.matrix.group-picker-copy.copies.selected` |
| Chats section | `desktop.atum.roster.title` |
| Done | `desktop.common.done` |
| Photo / Video / File tiles | `src.matrix.mobile-copy.mobileChatCopy.photo`, `…media.kind.video`, `…file` |

New **PENDING-COPY** words in `SharePendingCopy`: `share.link` ("Link"),
`share.text` ("Text"), `share.items` ("Items to share", the strip's VoiceOver
label) and `share.limit` ("You can share to up to 20 chats at once."). The
sheet shows no price or Proton figure of any kind.

### Intake fix found by the picker host

Host-style providers exposed a loader gap: when a provider answers a URL or
file-URL load with the URL's *provider data* (`Data`) rather than a URL object,
as `NSItemProvider(object: NSURL)` and some `contentsOf:` file providers do,
`ShareItemLoader` rejected the share as invalid ("Couldn't queue this share").
It now decodes that data with `NSURL.object(withItemProviderData:typeIdentifier:)`
before the existing URL/file handling. `SharePickerTests` covers
`contentsOf:` image, `contentsOf:` file and object-URL providers separately.

### Scripted host and tests

Debug builds of the app accept `-AtumScriptedShare suggested|plain|loading|empty|failed`
(`App/Debug/ScriptedShareHost.swift`, `-AtumScriptedShareScheme light|dark`):
the real picker, model, queue and item loader in a sheet over synthetic chats,
a generated photo, video, PDF, link and text, with the queue in the app's
temporary folder. Release excludes the host and the picker sources.

- `ShareTests/SharePickerTests.swift` (unit): sections and suggestion order,
  preselection and stale suggestions, choosing during intake, the twenty-chat
  bound, selection across search and after queueing, exported words resolving
  (including the plural), the table matching the generator's keys, preview
  labels, Kit tokens bundled, Home face mapping, old snapshot decoding, and a
  staged photo thumbnail that stays small.
- `UITests/SharePickerUITests.swift`: the suggestion flow (preselected, search
  keeps selection, caption, queue, Done), plain share + Cancel, loading/empty/
  failed states, and the screenshot capture (light/dark × default/AX3/AX5, the
  queued state, Vietnamese).

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

### Picker device check (owner)

The simulator proves the picker on the scripted host only. On a signed device:

- Open the share sheet from Photos, Files and Safari; confirm the Atum sheet shows
  the right preview tiles (photo/video thumbnails, file name, link host, text)
  and stays responsive while a large video copies ("Preparing…"; chats can be
  chosen, Send waits).
- Tap a Share Suggestion: its chat must lead Recent, already checked. Tap the
  Atum icon instead: nothing preselected.
- Check faces against Home: photos appear only for chats whose avatar the
  notification service has cached (others show Home's monogram, mark, crescent
  or app squircle). Decide whether the app should also publish faces for the
  picker (see open gaps).
- Search, select across results, add a caption, Send; confirm "Queued. Open Atum
  to send.", Done, and delivery on opening Atum. Cancel mid-load; swipe-down
  must not dismiss (Cancel/Done only).
- Light and dark, largest accessibility text size, VoiceOver (rows read the
  chat name and "Selected"; tiles read Photo / Video / File, name / Link, host).
- Share a Safari link and a Files document: the intake fix above must accept
  both (previously "Couldn't queue this share" for provider-data URLs).
- Review the PENDING-COPY words (`share.title`, `caption`, `queued`, `empty`,
  `failed`, `loading`, `queueHelp`, `link`, `text`, `items`, `limit`) with the
  copy owner.

### Picker open gaps

- Faces: the extension reads only the App Group's notification avatar cache. The
  app's own avatar cache is app-private; publishing picker faces (bounded, without
  evicting notification faces) is a follow-up. The Founder room shows a monogram,
  not the raven.
- While search is active, iOS 26 hides the bar's Cancel / count / Send behind
  Close (system behaviour); the selection count returns when search closes.
- A Release build of the app (picker sources excluded) was not built in this
  pass; the Debug app, extension and tests were.
- Real share-sheet presentation, Share Suggestion ranking, App Group access and
  memory under large media are device-only (unchanged from the backend list).

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

### Picker verification — 2026-11-15

- Xcode 27, iPhone 17e simulator, Debug, signing disabled; all builds and tests
  under the shared heavy-build lock, derived data in the share-extension build
  directory, one simulator, shut down at the end.
- `AtumShare` build-for-testing and `AtumMobile` build-for-testing (app, embedded
  extension, unit and UI test bundles) succeeded.
- AtumShare suite: **59 tests, 0 failures** (the backend's 42 plus 17 new
  `SharePickerTests`).
- `AvatarArtTests` (avatar renderer split regression): **14 tests, 0 failures**.
- `SharePickerUITests` on the scripted host: **4 tests, 0 failures**.
- Generators: `generate-share-localization.py --check`,
  `generate-phosphor-symbols.py --check` and `generate-push-localization.py --check` pass.
- Screenshots (light/dark × default/AX3/AX5 with scrolled views, queued light/dark,
  loading, empty, failed, empty search, Vietnamese) are kept outside the repository
  on the build volume (`share-picker-shots/`).
