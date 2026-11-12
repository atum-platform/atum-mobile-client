# Communication notifications (sender and group faces)

Owner request, 2026-11-11: push banners should look like other chat apps. The
sender's avatar, or the group's picture, is the big image, with the Atum icon
in the corner. Before this change the notification service extension (NSE) set
only title, subtitle and body, so iOS showed the Atum icon as the big image.

This uses Apple's communication notifications, as Element X iOS does: the NSE
builds an `INSendMessageIntent` whose sender is an `INPerson` carrying an
`INImage`; a group also gets `speakableGroupName` and a group image
(`setImage(_:forParameterNamed: \.speakableGroupName)`). It donates the
incoming `INInteraction` and returns `content.updating(from: intent)`.

## Which image is the big one

`CommunicationNotificationPolicy.plan` (AtumChat, pure) decides. Candidates are
tried in order; when none loads, the NSE draws the app's monogram.

| Room kind | iOS style | Group name | Image order | Monogram |
| --- | --- | --- | --- | --- |
| Person-to-person (SDK `isDirect`, no app entry) | Person | none | sender's avatar | sender's name |
| Assistant chat | Person | none | the header face the app drew → room avatar → bot's member avatar | the assistant's name (header title) |
| App bot chat | Person | none | the header face the app drew → room avatar → bot's member avatar | the app's name |
| Ordinary group | Group | SDK room name (validated) | room avatar | room name |
| Team Space channel | Group | `# channel · Company` (Team Space label + company) | channel avatar → company logo | company name |
| Team Space group conversation | Group | `Title · Company` | room avatar → company logo | company name |
| Team Space 1:1 conversation | Person | none | sender's avatar | sender's name |
| No sender, unvalidated group name, undecryptable, filtered, not found, timeout | Today's content | — | — | — |

In group style the sender is still named on the message (`INPerson`
`displayName`); the group's image is the big one, as in Element X.

Coordinator decisions applied: a channel is group style named the way Team
Space labels it, with the company logo as the fallback so a glance tells you the
company. Team Space conversations follow ordinary groups with the logo
fallback; their group name also carries the company (the format Saved rows
use). A company 1:1 conversation is a person chat: a person's face, never the
company logo. The monogram fallback for channels names the company, not the
channel.

## Where the facts come from

- **SDK (in the NSE):** sender name and avatar URI (`senderInfo`), room name,
  avatar URI and `isDirect` (`roomInfo`) from `NotificationClient`. Names keep
  the existing `RichPushPresentation` validation; the plan uses the validated
  `senderName`/`roomName` it now exposes.
- **The app (`NotificationRoomPublisher`, App/Push):** which rooms are assistant
  or app chats (the roster's own classification), Team Space channels and
  conversations (`CompanyWorkspaceModel` claims), `teamSpaceRoomLabel`,
  `companyName` and `logoURIs` (company logos from #15). It writes
  `NotificationRoomDirectory` (versioned, bound to the account's Matrix user
  ID, at most 512 rooms / 512 KiB) to the App Group. For assistant and app chats
  it renders the chat-header face (`AtumAvatar` with the same art loader and
  mark as `ChatInfoAvatar`, light scheme, 64 pt at 3x) to a PNG named by the
  hash of what was drawn. A face that should show a photo is not written while
  the photo cannot load, so a transient failure never caches a monogram.
  Publishing is a `.task(id:)` on the signed-in shell, debounced two seconds.
- **Never the push.** The payload still only routes (room/event ID, badge).
  No image URI, name or display string is read from it. Only `mxc://server/id`
  URIs are fetched; face file names must be 64 hex digits + `.png`.

## Fetching and caching in the extension

`MatrixNotificationFetcher.face` runs while the one short-lived SDK client is
still alive, before `pause()`:

1. An app-drawn face is read from `AtumNotifications/faces/`.
2. A Matrix URI is looked up in `AtumNotifications/avatars/` (key: SHA-256 of
   size + URI; content URIs are immutable, so entries never go stale).
3. Otherwise `client.getMediaThumbnail` (the SDK's authenticated media path,
   the same call `LiveMatrixSession.avatarThumbnail` uses) asks for 192 px with
   a two-second deadline (`firstOf`, which does not wait for an SDK call that
   ignores cancellation). At most two network reads per notification.
4. Bytes are decoded by ImageIO at ≤192 px and re-encoded (JPEG for opaque
   photos, PNG for logos with transparency); undecodable data is refused.

The avatar cache is capped at 160 files and 4 MiB with least-recently-used
eviction (reads touch the modification date); files over 512 KiB are refused.
All files use after-first-unlock protection, mode 0700 folders and backup
exclusion. Sign-out (`clearAccountCaches`) removes the whole folder: faces,
avatars and room names. File names never contain IDs or URIs.

Donation has a two-second deadline. If donation fails or times out, or
`updating(from:)` throws, the notification keeps today's rich title/subtitle/
body; an avatar problem never turns a notification generic. The whole fetch
still sits under the existing 20-second once-only gate and OS expiry, and the
token-refresh-under-lock path from #32 is unchanged (it runs before SDK
construction; this work only adds steps after the event is fetched).

Diagnostics stay closed codes: `communication_alert style=person|group image=picture|monogram` on success, `plain_alert reason=no_plan|donation_failed|update_failed`.
No names, IDs, tokens or media URLs are logged.

## Entitlement, Info.plist and Apple account (coordinator release step)

- `App/AtumMobile.entitlements`: `com.apple.developer.usernotifications.communication = true`
  (app target `AtumMobile`, bundle ID `com.atum.mobile`). Element X 1.7.5 puts
  it on the app only; the NSE entitlements are unchanged.
- `NSUserActivityTypes: [INSendMessageIntent]` in the app's Info.plist
  (required by Apple) and, harmlessly, the NSE's (`project.yml`, regenerated
  with XcodeGen 2.46.0; the regeneration also dropped a duplicate
  `SharedCollectionsUITests.swift` reference a merge had left in the project).
- **Apple developer account:** enable the **Communication Notifications**
  capability on the App ID **`com.atum.mobile`**, then regenerate the
  `Atum Mobile Development` profile and the App Store / TestFlight
  distribution profile for that App ID. The NSE App ID
  `com.atum.mobile.notifications` needs no new capability and its profiles are
  unchanged. Until the app profiles include the capability, signed device and
  archive builds of the app fail with an entitlement/profile mismatch;
  unsigned simulator builds are unaffected.

## Element X study (Apache-2.0 only)

Consulted release tag `1.7.5` (`7b03c23b`, 2024-09-04), the last release before
the AGPL switch (`664e87fe87`, 2024-09-06); the files are byte-identical at the
approved parts-bin revision `0f3b33c5ae`. No AGPL revision was read.

- `NotificationContentBuilder.icon(for:)`: DM → sender avatar on the person;
  group → room avatar plus group info (room name, room ID).
- `UNMutableNotificationContent.addSenderIcon`: 100×100 thumbnail through the
  SDK media loader (`getMediaThumbnail`); on failure or no avatar, a
  `PlaceholderAvatarImage` rendered with `ImageRenderer` and cached in the temp
  directory; `INPerson` with `INPersonHandle(value: userID, type: .unknown)`; in
  a group, `speakableGroupName`, recipients `[sender, me(isMe)]`, the image on
  `\.speakableGroupName` and none on the sender; `conversationIdentifier` =
  room ID; incoming interaction donated, then `updating(from:)`. A pre-iOS 17.2
  device flip workaround.
- Entitlement on the app target only; `NSUserActivityTypes` in the app plist.

Reused (pattern, adapted and attributed in `Vendor/Notices/ElementX-NSE.md`
and the file header): the intent/person/group mapping, the DM-versus-group
split, donate-then-update. Not reused: its placeholder view and renderer, its
media provider/Kingfisher cache, its strings, its error propagation (Element X
lets a donation error fail the content; Atum keeps the rich text), and the flip
workaround (iOS 26 only).

## Verification (2026-11-11/12, iPhone 17e simulator, iOS 26, Xcode 27)

All builds and simulator work ran under `lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`,
derived data `/Volumes/AtumTestFlight/dd-comm-notif`, `-jobs 2 ARCHS=arm64`.

Tests. Final locked batch (2026-11-11 19:29–19:32 UTC, on the committed
tree): `swift test --filter 'CommunicationNotificationPolicyTests|PushDeliveryTests|RichPushPresentation|…'`
35 passed; `AtumNotifications` test-without-building 20 passed; `AtumMobile`
generic simulator build succeeded. Earlier in the same session:
`TeamSpaceStructureTests` 4 passed. Coverage:

- Swift package: `CommunicationNotificationPolicyTests` (18: every room kind,
  each fallback, malformed URIs and face names, directory account/version
  trust, JSON round trip, the validated names), plus `PushDeliveryTests` and
  `RichPushPresentation` tests.
- `AtumNotifications` scheme (hostless, compiles the real extension sources):
  20 tests, including 11 new `CommunicationNotificationTests` (person vs group
  intent shape, monogram pixels and Kit-token match, normalisation, LRU
  eviction under the 4 MiB cap, no URI in file names, directory/face round trip
  and sign-out removal, image order and the two-fetch cap, cache reuse, the
  fetch deadline, SDK-only avatar sources with raw event ignored, donation
  failure keeping the content).
- `AtumMobileStateTests -only-testing:AtumMobileTests/TeamSpaceStructureTests`:
  4 tests, including the app directory (channel name "# general · Company 1",
  logo carried to a channel without its own avatar, assistant/app entries and
  faces, no entry for people or placeholder rows).
- `AtumMobile` app and extension build (unsigned simulator and, for the
  captures, simulator "Sign to Run Locally").

What the simulator proved, and how. `xcrun simctl push` on this Xcode hands
the request straight to `usernotificationsd` (`Forwarding addRequest`) and
never launches the service extension, unsigned or ad-hoc signed; the device
log shows no extension process and the banner is the payload's own generic
text. So the captures use a Debug-simulator-only path instead:
`-AtumPostScriptedNotifications dm,…` makes the app post each fixture as a
local notification whose content is built by the extension's own code
(`ScriptedNotificationFixtures` → `CommunicationNotification.image/apply`,
both compiled into the app for this), presented over the app by the
foreground delegate. SpringBoard logged `Notification serviced by the
communication context service: 1` and `Rendered avatar image: YES` for each.
Captured banners (kept outside the repository):
`/Volumes/AtumTestFlight/comm-notif-shots/final/` — `dm.png` (sender photo),
`dm-monogram.png` (Kit monogram "M"), `group.png` (room photo, "Book club",
sender "Linh"), `channel-logo.png` ("# general · Acme Studio", company logo),
`channel-no-logo.png` (company monogram "A"), `assistant.png`, and
`all-banners.png`. Each shows the face as the big image with the Atum icon in
the corner.

The permission prompt was accepted by
`CommunicationNotificationCaptureUITests` (skipped unless
`TEST_RUNNER_ATUM_CAPTURE_NOTIFICATIONS=1`), because `simctl privacy` has no
notifications service. All capture scaffolding is behind
`#if DEBUG && targetEnvironment(simulator)`.

Not proven on the simulator; owner-held device check at release, after the
profiles carry the capability:

- the extension itself producing this content from a real APNs push (fetch,
  decrypt, directory read, thumbnail fetch and timing within the ~24 MB
  budget);
- the layout on a signed build with the real entitlement and profile;
- app-drawn assistant/app faces end to end (app publishes, extension reads) on
  a live account, and Team Space names/logos from live company data;
- a locked phone after first unlock reading the App Group files; Focus,
  Announce Notifications and Siri suggestion effects of donation.

## Main integration (2026-11-12)

Merged `origin/main` at `c358c0c81f0a0af479ee0d6c81b07c82d00f6c74`
into feature head `124ac10f5bcd7a37ae0046b95880a3e950c55db4`.
The only textual conflict was `AtumMobile.xcodeproj/project.pbxproj`.

Resolution starts with main's checked-in project, preserving its format and
object identities. Added six file references with fresh 24-hex IDs and ten
separate source-build entries: the app's notification publisher and Debug
poster, communication content and scripted fixtures in the app, extension and
extension-test targets, the extension communication tests, and the capture UI
test. Removed main's redundant `SharedCollectionsUITests.swift` file reference
and source-build entry; the existing second reference remains. No XcodeGen
regeneration or conflict-hunk union was used.

The feature does not change any `XCBuildConfiguration` or `PBXProject` settings
relative to its old base `88917a7`; the app communication entitlement and both
`NSUserActivityTypes` declarations remain in their checked-in plist files.

Project verification:

- `plutil -lint` passes for the project, app entitlements and both Info.plists.
- Recursive PBXGroup inspection finds no duplicate PBXFileReference paths.
- Actual PBXSourcesBuildPhase membership exactly matches all Swift sources in
  `project.yml`, with one entry per required target: AtumMobile 163,
  AtumNotifications 4, AtumNotificationsTests 6, AtumMobileTests 29,
  AtumMobileUITests 24.
- `python -m pytest tests/test_ios_project_sources.py`: 2 passed (isolated
  Python 3.14 environment because the host Python has no pytest installed).

Locked verification completed in one uninterrupted lock acquisition, 2026-11-12
00:00:06–00:09:03 UTC (07:00–07:09 local), with all commands succeeding on their
first attempt. Entry command:

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp \
  lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  bash /Volumes/AtumTestFlight/tmp/communication-merge-verify.sh
```

The batch ran `swift test --package-path ios --scratch-path
/Volumes/AtumTestFlight/tmp/swift-communication-merge -j 2`, then
`xcodebuild build-for-testing` and `test-without-building` for schemes
`AtumMobile` (`-only-testing:AtumMobileTests`) and `AtumNotifications`
(all `AtumNotificationsTests`). Common Xcode arguments: `-configuration Debug`,
`-jobs 2`, `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=YES`, `CODE_SIGNING_ALLOWED=NO`,
`COMPILER_INDEX_STORE_ENABLE=NO`, `-parallel-testing-enabled NO`,
`-maximum-concurrent-test-simulator-destinations 1`,
`-disableAutomaticPackageResolution`, `-onlyUsePackageVersionsFromResolvedFile`,
`-clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm`,
`-derivedDataPath /Volumes/AtumTestFlight/tmp/dd-communication-merge`, and
`-destination platform=iOS\ Simulator,id=CB24FAE2-75F9-4E19-A856-0F5A9F036C0B`.
Only the existing Atum iPhone 16e (iOS 27.0 runtime) booted; the batch's final
EXIT trap ran `xcrun simctl shutdown all` before releasing the lock.

Results:

- Swift package: 1,499 passed, zero failures: AtumDesignTests 787,
  AtumChatTests 674, AtumDriveTests 22, AtumTelemetryTests 16.
- App `build-for-testing`: succeeded, including the capture UI test source.
- Notification `build-for-testing`: succeeded.
- AtumMobileTests: 356 passed, zero failures.
- AtumNotificationsTests: 20 passed, zero failures, comprising
  CommunicationNotificationTests 11 and NotificationServiceTests 9.
- Total XCTest cases: 1,875 passed, zero failures; UI capture was compiled but
  not executed. The two Python project-source checks also passed.

No semantic Swift changes were required: the feature's rich-push presentation,
notification fetch/content APIs, room publisher and LiveAppModel integration
compiled and passed against main as merged. Build/test logs are under
`/Volumes/AtumTestFlight/tmp/communication-merge-results`; `.xcresult` bundles
are under the derived-data directory's `Logs/Test`. This integration is a local
merge checkpoint only; no push or pull request was requested.

## Second main integration: release-blockers #33 (2026-11-12 00:3x UTC)

Main `88f7085` (#33, demo-free Release builds) conflicted only in the
`Notifications` group of `project.pbxproj` and the app sources in
`ios/project.yml`; both sides are kept (the feature's two shared notification
files plus main's privacy manifest and licence resources). #33's project-source
test then needed two follow-ups:

- `App/Debug/ScriptedNotificationPoster.swift` now opens with a plain
  `#if DEBUG` and nests `#if targetEnvironment(simulator)`, so it matches the
  rule that Debug sources start with `#if DEBUG`. Behaviour is unchanged.
- The app target lists `Notifications/ScriptedNotificationFixtures.swift`.
  #33's test refused any `Fixtures` in the app spec. It now allows only
  `Scripted*.swift` paths, which Release already excludes through
  `EXCLUDED_SOURCE_FILE_NAMES` and which compile their fixture code only under
  `DEBUG && targetEnvironment(simulator)`.

Verified locally: `plutil -lint` on the project, and the project-source and
Info.plist localisation tests (9/0). The Debug and Release builds plus the UI
shards are verified by hosted CI on the PR, not under the local build lock.
