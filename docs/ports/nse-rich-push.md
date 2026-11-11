# Rich notification service extension

The notification extension now restores the current Matrix session with the
same `MatrixSessionReader`, `MatrixStoreDirectory` and encrypted App Group
store used by the app. APNs remains `event_id_only`: the push is validated by
`MobilePush.payload`, and its display fields are never trusted. Rich text comes
only from the pinned MatrixRustSDK notification API.

The extension links MatrixRustSDK and AtumChat. It builds one short-lived
client, disables automatic token refresh, omits the refresh token from its SDK
session, disables automatic cross-signing/backup creation and send queues, and
restores only the pushed room with `restoreSessionWith(..., .one(roomId:))`.
It never creates a SyncService, room-list service, login or recovery flow.
A bounded Matrix-only custody writer can rotate an existing grant before SDK
construction; the SDK delegate remains read-only. The pinned SDK no longer exposes the historical
`setupEncryption: false` switch: no explicit encryption setup is called.
Its NotificationClient owns bounded encryption sync/decryption and uses
`.multipleProcesses` with custom timeouts. The base client's SDK cross-process
lock has a fresh per-fetch holder name.

The shared Matrix record must be ready and free of an interrupted refresh.
Expired credentials, or credentials with 30 seconds or less remaining, go
through the same journaled OIDC refresh used by the app before SDK construction. Both store files must already exist. Recorded device keys are compared
after restore; the record is rechecked before SDK work and before returning
content. SDK callback attempts to change the session invalidate the result
without writing it. Missing/locked Keychain, invalid store, a busy refresh lock,
a changed record, unresolved refresh, network failures and decryption failures
keep the generic alert. `notificationReader()` selects the shared Matrix record
using the deployed issuer and Matrix client ID. Refresh uses verified MAS
discovery as a reachability preflight; no domain/recovery Keychain access or
private app installation-marker access is needed by the extension.

One accepted fetch per process bounds overlapping SDK allocations; overlapping
requests receive generic content. A 20-second deadline and OS expiry both use
the same thread-safe, once-only completion gate. The gate cancels pending work
and delivers without waiting for cooperative cancellation. Late results cannot
replace a delivered fallback. SDK network requests have no retries and a
five-second timeout, notification sync uses one-second polls plus four-second
network allowance, and missing-key decryption has a five-second deadline.

## Coordinated token renewal (2026-11-11)

Both app refresh entry points (cold launch and foreground renewal) and the NSE
reuse `OIDCGrantRefresh` and `MatrixSessionKeychain.RefreshStore`. An exclusive,
nonblocking `flock` on `group.com.atum.mobile.shared/matrix-refresh.lock` covers
rereading the expected record, durable `refreshAttempt` write/readback, one MAS
POST, response validation and replacement write/readback. The lock file is
never unlinked or renamed; closing the descriptor or process death releases the
kernel lock. A busy lock produces generic content without a journal write or
HTTP spend. A changed snapshot is refused without spending. The app rereads
expiry through `accessToken(minimumValidity:)` so an NSE-completed rotation is
reused instead of rotated again based on the app's stale expiry decision.

The SDK's existing multi-process lock remains in place for encrypted database
work. It cannot protect the OIDC request made before the SDK exists, so it is
not the token mutex. Automatic SDK refresh stays disabled in both processes;
the NSE's SDK session still receives no refresh token. Its SQLite builder now
uses the pinned SDK's `systemIsMemoryConstrained()` configuration.

The NSE allows six seconds for discovery, refresh and optional JWKS retrieval,
then cancels through the existing cancellable MAS transport. A check under the
refresh lock refuses to journal/start a spend if discovery or scheduling has
left less than three seconds for POST/JWKS/save. Cancellation of
the NSE coordinator reaches its refresh task; app/domain refresh flights retain
their existing behavior of completing a spend after a UI caller cancels. A timeout/lost response/process
death after journaling leaves `refreshAttempt` intact: neither process retries
that one-time token. A fresh app resume reports `.refreshInterrupted`; existing
explicit recovery is required. This prevents token reuse, but cannot recover a
replacement token lost between server acceptance and durable local persistence.
A live refresh owner is classified as temporarily unreadable by app continuity,
not an expired session. After acquiring a released lock, app resume rereads the
record to distinguish a completed rotation from an abandoned journal.

### Locked-phone storage audit

- The Matrix custody writer already uses and the reader validates
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable, in the
  Matrix-only shared Keychain access group. No accessibility migration needed.
  `errSecInteractionNotAllowed` now has the distinct `keychain_locked` code.
- `MatrixStoreDirectory.createPrepared` already creates root/generation/data/cache
  directories with `NSFileProtectionCompleteUntilFirstUserAuthentication`, mode
  0700, and backup exclusion. `requireExisting` already validates that protection
  on the directories and nonempty state/crypto SQLite files. It now also checks
  existing data/cache children (including WAL/SHM/journals) and reports permission
  or protection failures without attempting a repair from the NSE.
- The lock file explicitly uses the same after-first-unlock file-protection
  class. `requireExisting` has no foreground/unlocked-only policy. The SDK opens
  these existing paths with the stored passphrase and its own database lock;
  it has no UIKit protected-data gate in this adapter. SQLite files created by
  the SDK should inherit their parent protection, but actual installed file
  attributes and SDK open behavior on a locked physical phone remain unproven.
  Before first unlock after reboot, generic fallback is expected.

### Privacy-safe diagnostics

Subsystem `com.atum.mobile.notifications`, category `rich-push`, emits public
`generic_alert reason=<closed code>` once for the gate that actually delivers
fallback. Late errors after another delivery do not emit a second fallback.
Codes include `invalid_payload`, `fetch_busy`, `refresh_busy`, `refresh_failed`,
`refresh_interrupted`, `refresh_timeout`, `record_changed`, `keychain_locked`,
`custody_unavailable`, `expired`, `store_locked`, `store_unavailable`,
`sdk_build_failed`, `sdk_restore_failed`, `fetch_timeout`, `fetch_failed`,
`event_not_found`, `event_mismatch`, `presentation_unavailable`, `system_expiry`.
SDK open/restore errors intentionally use gate codes rather than parsing or
logging SDK error strings. No tokens, Matrix IDs, names, messages or raw errors
are logged. `event_id_only` and presentation/privacy filtering are unchanged.

## Content mapping

| Event | Title / subtitle | Body |
| --- | --- | --- |
| Direct text or notice | Sender / empty | SDK plain message body |
| Group or channel text or notice | Room / sender | SDK plain message body |
| Emote | Same title/subtitle rules | Sender followed by the action text |
| Image, video, audio, file, sticker | Same rules | Exported localized home-preview phrase |
| Invite | Same rules | Exported localized chat invitation phrase |
| Location | Same rules | Generic body; `PENDING-COPY` for an exported location phrase |
| Missing media copy | Same rules | Generic body |
| Undecryptable, unknown, empty text, not found | Generic alert | Generic body |
| Filtered, redacted or own event | Empty alert | Badge only; no sound |

Names pass through `MatrixPersonName.name(_:userID:)`, then exclude Matrix IDs,
localparts, server names and control characters. Missing sender names use the
exported unnamed-user word; missing usable group names keep the generic alert.
The SDK's raw event JSON, media filenames and formatted HTML are never rendered.
Rich and generic alerts retain validated room/event IDs, room thread identifier,
badge and default sound. Suppression follows the historical Element X empty
notification pattern, retaining only the badge.

`generate-push-localization.py` projects the existing unnamed, photo, video,
audio, file, sticker and invite copy into the extension's string catalog in all
five exported locales. Vendor copy itself is unchanged. Historical Element X
Apache source attribution and adaptation notes are in
`ios/Vendor/Notices/ElementX-NSE.md`; the extension bundles that notice and the
existing full Apache license.

## Verification and remaining device proof

Pure package tests cover mapping, missing copy, unsafe names, UTD, self events,
concurrent completion, fetch failure, deadline cancellation, OS expiry and late
results from a fetch ignoring cancellation. Hostless iOS notification tests
compile the actual extension source and cover payload sanitation, metadata,
SDK statuses, SDK invite projection and localized copy. Prior rich-push
verification on 2026-11-11 (before the token-refresh change below):

- Swift package: 1,306 tests passed (including nine mapping and seven completion tests).
- `AtumNotifications` simulator scheme: nine tests passed; actual extension built.
- `AtumMobileStateTests` simulator scheme: 297 AppTests passed; assembled app and embedded extension built.
- Both compiled bundles match all eight generated strings in all five locales.
- Localization generator check, deterministic XcodeGen regeneration, Python syntax checks and diff whitespace checks passed.

All builds/tests used the required external-volume lock, derived-data and
SwiftPM scratch directories, two build jobs, and one simulator. The simulator
was shut down before releasing the lock. Command-line signing was disabled;
repository signing settings and entitlements were unchanged. The localization
assertion in the candidate-build audit now checks the entire generated catalog
instead of assuming the generic key is the only key. No signing workflow was run.

Physical APNs proof is still required: locked phone after first unlock, reboot
before first unlock, force-quit app, encrypted incoming message with cached and
missing keys, expiry/network loss, simultaneous main-app store access,
sign-out/session rotation during fetch, and a burst of overlapping pushes.
Measure peak physical extension memory against the approximately 24 MB budget;
one-room restore and no media downloads limit work but are not memory proof.
Verify badge-only suppression on the supported OS and locale choices on device.

The selected SDK provides stock restore with filesystem preflight and a
post-restore identity check, not an atomic existing-only restore API. Device
proof must include missing-store/concurrent-removal behavior. No signing,
provisioning, APNs credentials or SDK revision was changed by this port.

## CI follow-up

`tests/test_native_push_projection.py` asserted that the generated push
localization held only the provider's generic key. It now also expects the seven
rich-notification phrases (unnamed, image, video, audio, file, sticker, invite),
each in all five locales.

## Release packaging fix

The first TestFlight export after #24 failed App Store validation: the
extension embedded its own `MatrixRustSDK.framework` ("disallowed file
Frameworks", "disallowed nested bundles", and a CFBundleIdentifier collision with
the app's copy). CI does not run a release export, so it passed. The extension
now links the SDK without embedding it and finds the app's copy through
`LD_RUNPATH_SEARCH_PATHS` (`@executable_path/../../Frameworks`). The project file
was regenerated from `ios/project.yml` with XcodeGen.

## Token-refresh verification checkpoint

The 2026-11-11 token-refresh change adds regression coverage for independent
lock descriptors and a separate OS process (including process termination),
app/NSE coordinator contention, lock-busy/no-write/no-network behavior, a changed
record after preflight, already-rotated credential reuse, the durable crash
journal, cancellation deadline and once-only fallback diagnostics. Existing
journal-persistence and response-save-failure tests remain in the focused suite.

Verification uses SwiftPM scratch path
`/Volumes/AtumTestFlight/swiftbuild-nse-refresh`, derived data
`/Volumes/AtumTestFlight/dd-nse-refresh`, `TMPDIR=/Volumes/AtumTestFlight/tmp`
and two jobs, under the required external-volume `lockf -k` lock.

The first batch completed on 2026-11-11 at 09:38:38 UTC:

- Filtered Swift package tests: **115 passed, zero failures** (98 native API
  tests and 17 chat tests). These include Matrix custody/refresh locks, Matrix
  recovery, stranded-session recovery, OIDC, MAS HTTP, continuity, push
  completion and rich presentation.
- Python push projection/localization tests: **2 passed**.
- `git diff --check`: passed.
- `AtumNotifications` build-for-testing and `AtumMobile` build: both exited 65
  at the same iOS-only compile error in `MatrixRefreshLock`: FileManager's
  protection setter requires `ofItemAtPath:`, not `atPath:`. The label is now
  corrected. The macOS package-test path does not compile this iOS conditional.

The second batch completed at 10:48:32 UTC. Both builds passed the corrected
iOS-only protection call and then failed while linking MatrixRustSDK for
x86_64. The generic simulator invocation requested both architectures, but the
pinned SDK's `MatrixSDKFFI.xcframework/Info.plist` declares only
`ios-arm64-simulator` and `ios-arm64` slices. This is a build-invocation
architecture mismatch, not evidence that the token-refresh code failed.

Both affected builds are queued again with **`ARCHS=arm64`**, using
`/Volumes/AtumTestFlight/nse-refresh-arm64-checks.sh`:

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash /Volumes/AtumTestFlight/nse-refresh-arm64-checks.sh
```

The batch runs unsigned `xcodebuild -jobs 2 CODE_SIGNING_ALLOWED=NO ARCHS=arm64`
`build-for-testing` for `AtumNotifications` and `build` for `AtumMobile`, both
with `generic/platform=iOS Simulator`. Its summary is
`/Volumes/AtumTestFlight/nse-refresh-arm64-checks.log`; individual logs are
`/Volumes/AtumTestFlight/nse-refresh-extension-r3.log` and
`/Volumes/AtumTestFlight/nse-refresh-app-r3.log`. Final iOS build verification is
pending both successful exit codes. The new iOS notification test assertions
are scheduled for compilation, not simulator execution.

Evidence retained on `/Volumes/AtumTestFlight`:

- `nse-refresh-package.log`: 115 passing package tests.
- `nse-refresh-checks.log`, `nse-refresh-extension.log`, `nse-refresh-app.log`:
  initial iOS argument-label failure.
- `nse-refresh-build-checks.log`, `nse-refresh-extension-r2.log`,
  `nse-refresh-app-r2.log`: x86_64 SDK link failure after correcting the label.

No simulator boot, signing, upload, push, PR or owner's-phone operation is part
of this checkpoint. Physical APNs content, locked-phone store access and peak
NSE memory still require a separately authorized device test.
