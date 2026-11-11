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
It never creates a SyncService, room-list service, login, recovery flow or
session writer. The pinned SDK no longer exposes the historical
`setupEncryption: false` switch: no explicit encryption setup is called.
Its NotificationClient owns bounded encryption sync/decryption and uses
`.multipleProcesses` with custom timeouts. The base client's SDK cross-process
lock has a fresh per-fetch holder name.

The shared Matrix record must be ready, unexpired and free of an interrupted
refresh. Both store files must already exist. Recorded device keys are compared
after restore; the record is rechecked before SDK work and before returning
content. SDK callback attempts to change the session invalidate the result
without writing it. Missing/locked Keychain, invalid store, expired credentials,
a changed record, network failures and decryption failures keep the generic
alert. No OIDC discovery or domain/recovery Keychain access is needed to select
the session: `notificationReader()` uses the app's deployed public issuer and
Matrix client ID with the existing validation.

One accepted fetch per process bounds overlapping SDK allocations; overlapping
requests receive generic content. A 20-second deadline and OS expiry both use
the same thread-safe, once-only completion gate. The gate cancels pending work
and delivers without waiting for cooperative cancellation. Late results cannot
replace a delivered fallback. SDK network requests have no retries and a
five-second timeout, notification sync uses one-second polls plus four-second
network allowance, and missing-key decryption has a five-second deadline.

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
SDK statuses, SDK invite projection and localized copy. Final verification on 2026-11-11:

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
