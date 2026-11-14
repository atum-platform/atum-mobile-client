# Phone approvals, slice 2b: enrolment screens and key lifecycle

Date: 2026-11-14. Phone base: `161ada7` (main after #50), with slice 2a
(`feat/phone-approval-keys` `fe0690a`, cherry-picked cleanly) underneath.
Design (owner-approved 2026-11-11, private design repo, read-only):
`docs/design/phone-approvals.md` ("Ordered implementation slices", slice 2),
`docs/design/phone-approvals-ux.md` revision 2 (§2.5, §2.6, §2.9, §3.3,
§3.6, §3.7, §4.7, §5) and `docs/design/phone-approvals-security.md`.
Server contract: platform `feat/phone-approval-keys` (slice 1, draft #843,
migration 0453, **not deployed**), `spec/device-service/v1.3/README.md`.

Slice 2a (`docs/phone-approval-port.md`) is the key and wire layer: Secure
Enclave identity and approval keys, the iOS enrolment body and signatures,
the registry calls and the durable revocation queue. Slice 2b is everything
the owner touches, plus the lifecycle around those calls. Slices 3 (cloud
approvals: the sheet, challenge signing, refusals) and 4 (Mac seam) are not
here.

## What the owner sees

Settings › Account › **Your devices**, under This iPhone (UX §4.7; the phone
has no Security page, and desktop's `security-panel.tsx` is this section):

- Row **Approve on this iPhone**, value **On** or **Not set up** (exported
  `security-copy` `recoveryOn` / `recoveryOff`), opening its page.
- The row is **hidden** unless the server advertises phone registration or
  this iPhone already holds a registration (fail closed, below).

The page (`PhoneApprovalSettingsPage`):

| State | Shows | Action |
| --- | --- | --- |
| Off, Face ID | status "Not set up"; footer `approvalSettingsHelp` | **Set up with Face ID** |
| Off, Touch ID (iPhone SE) | same | **Set up with Touch ID** (phone-proposed) |
| Off, passcode but no biometric | footer adds `approvalSettingsPreferFaceID` | **Set up with passcode** (phone-proposed) |
| No passcode | notice `approvalNoPasscode` + `approvalNoPasscodeHelp` | none (set up hidden, UX §2.6) |
| Setting up | the button shows a 20 pt `AtomWait` and "Setting up…" and is disabled | — |
| On | "On · since {date}" (medium-abbreviated local date) | **Remove from this iPhone** → one dialog (`approvalSettingsRemoveTitle`, `…RemoveConfirm`), no Face ID (safe direction) |
| Key missing or record no longer matches | notice `approvalKeyMissing` + `approvalKeyMissingHelp` | **Set up again** (a new registration, never the old one) |
| Failed attempt | one notice line: cancelled, no prompt, offline, refused, generic (UX §3.6) | the set-up button stays live |
| Removal could not be recorded | exported `security-copy` `error` | Remove stays live |

Cancelling Face ID or the passcode **during set-up** only means "not set up"
(UX §2.9; the cancel-is-refusal rule applies to requests, slice 3). Results
are announced to VoiceOver. Identifiers: `approvals.settings.row`, `.page`,
`.status`, `.help`, `.setup`, `.remove`, `.confirm-remove`, `.failure`,
`.remove-failed`, `.notice.no-passcode`, `.notice.key-missing`.

## How it works

Package (`ios/Sources/AtumNativeAPI`, unit-tested with `swift test`):

- `PhoneApprovalLifecycle` (actor) owns set up, refresh, remove, sign-out,
  rotation, key-loss recovery and retry. It talks to a `PhoneApprovalServer`
  (production: `NativeDomainClient`) and a `PhoneApprovalKeyVault`
  (production: `SecureEnclavePhoneKeyVault`; there is no software fallback in
  Release).
- `PhoneApprovalRegistrationStore` (actor): Application Support
  `PhoneApprovals/registrations.json`, per owner: installation, generation,
  `deviceServiceId`, epoch, key IDs, `createdAt`, and a pending rotation
  generation. No key bytes, bearer or signature. An unreadable file fails
  closed (no row). The file is deliberately **kept in backups**: a restored
  iPhone finds a registration whose device-only keys did not come with it,
  revokes it and shows "Approvals need setting up again", instead of
  leaving a stale registration on the server.
- `PhoneRevocationQueue` (2a) under the same folder; one store and one queue
  per app (`PhoneApprovalLive`), so two clients never write the same file.

Behaviour:

- **Set up**: refuse without a passcode; probe the server; fetch the active
  pinned controller key IDs (`GET /api/matrix/v1/cloud/controller-keys`);
  create both keys in a new namespace (owner, installation, new generation);
  build the 2a body (display name cut to the registry's 64 UTF-16 units,
  `osVersion`, Matrix user, device and ed25519 fingerprint from the SDK,
  epoch 1, `issuedAt` now); sign (one system prompt: only the approval key
  has `.userPresence`); POST. Transient failures (transport, 503) resend the
  **identical signed request** up to twice (1 s, 3 s) with no new prompt; the
  server treats an identical epoch-1 retry as the same enrolment. The answer
  is checked (same ID, `ios`, active, epoch 1, the approval key ID we made,
  empty scopes) before anything is saved. Any failure deletes the attempt's
  keys. If the request may have landed (transport) its ID is put on the
  revocation queue, so no registration outlives its deleted key. A refusal
  (4xx) leaves nothing to revoke.
- **Refresh** (page open, Your devices load, app foreground, every new
  domain client): retry owed revocations; probe; check the keys exist
  without a prompt (`interactionNotAllowed` context); read the negotiated
  list. Keys gone → revoke, "set up again". Record revoked or absent (removed
  on another device) → delete keys and registration, Off. Approval key ID
  differs → revoke, "set up again". Offline → keep On.
- **Remove** and **sign-out**: record the revocation durably first, try
  DELETE, then delete both keys and the registration even offline. Only a
  revocation that cannot be recorded stops removal or sign-out (2a's rule:
  credentials stay). Sign-out runs first in `LiveAppModel.signOut`, while
  the bearer works; with no domain client it records the revocation for the
  owner's next sign-in (`PhoneApprovalUnreachableServer`).
- **Two iPhones**: each has its own installation, keys and
  `deviceServiceId`; removing one never touches the other. Another account
  never sees this account's registration.
- **Rotation** (lifecycle only, no screen: the UX has no rotate control):
  new generation, next epoch, `previousApprovalKid`, signed by the new keys
  and the current approval key (two prompts). A lost answer keeps both
  generations; the next refresh promotes whichever the server holds. With
  the old key gone it recovers (revoke, set up again) instead.

Transport changes (2a's `phoneDeviceServices`):

- The list now sends `Atum-Device-Service-Version: 1.3`. Without it the
  server lists **Macs only** (contract "Legacy response compatibility"), so
  2a's list could never see a phone.
- A non-JSON 5xx (proxy page) is `transportUnavailable`, not a decode crash.
- The header is allowlisted for the collection GET only, with the two
  values below.

### Fail closed: how "advertised" is decided

The 1.3 contract publishes **no capability flag**. The only behaviour unique
to a 1.3 server is that it refuses an unknown `Atum-Device-Service-Version`
with `matrix_400 invalid`; an older server ignores the header and lists Macs
(200). So the probe sends version `0.0` once per client: 400 → supported;
200 → not supported (no row, set up refused as `unavailable`); 503 (cloud
gate) or transport → unknown, which stays closed. Only "yes" is cached.
**Owner/platform decision needed** (below): prefer an explicit advertisement.

## PENDING-COPY

`PhoneApprovalPendingCopy` (`ios/Sources/AtumChat`) and
`PhoneApprovalCopy` (app) read the export first. en and vi are the UX
document's, verbatim; `desktop.cloud.enrollFailure.offline` is desktop's own
five-locale string, verbatim; **ja, zh and zh-Hant of the NEW keys were
written on the phone** and need desktop's translation (zh uses Apple's
"面容 ID / 触控 ID"; zh-Hant and ja keep "Face ID / Touch ID").

Prefix `src.matrix.mobile-device-copy.mobileDeviceCopy.` unless stated:

| Key | en | Source |
| --- | --- | --- |
| `approvalSettingsTitle` | Approve on this iPhone | UX §3.6 NEW |
| `approvalSettingsHelp` | Answer your assistants’ requests with Face ID when you’re away from your Mac. | UX §3.6 NEW |
| `approvalSettingsOn` | On · since {date} | UX §3.6 NEW |
| `approvalSettingsRemove` | Remove from this iPhone | UX §3.6 NEW |
| `approvalSettingsRemoveTitle` | Remove approvals from this iPhone? | UX §3.6 NEW |
| `approvalSettingsRemoveConfirm` | This iPhone will no longer be able to approve. You can still answer on your other devices. | UX §3.6 NEW |
| `approvalSettingsPreferFaceID` | You can approve with your passcode, or set up Face ID in Settings. | UX §3.6 NEW |
| `approvalSettingsSettingUp` | Setting up… | UX §3.6 NEW |
| `approvalEnrollCancelled` | Face ID was cancelled, so this iPhone wasn’t set up. Try again when you’re ready. | UX §3.6 NEW |
| `approvalEnrollNoPrompt` | This iPhone couldn’t ask for Face ID or your passcode. Unlock it and try again. | UX §3.6 NEW |
| `desktop.cloud.enrollFailure.offline` | Could not reach Atum’s cloud. Check your internet connection and try again. | REUSE desktop (not yet exported) |
| `approvalEnrollRefused` | Atum’s cloud did not accept this iPhone. Try again; if it keeps happening, contact support. | UX §3.6 NEW |
| `approvalEnrollGeneric` | This iPhone wasn’t set up. Try again. | UX §3.6 NEW |
| `approvalSetUpFaceID` | Set up with Face ID | UX §3.3 NEW |
| `approvalSetUpTouchID` | Set up with Touch ID | **phone-proposed** (iPhone SE) |
| `approvalSetUpPasscode` | Set up with passcode | **phone-proposed** (no biometric) |
| `approvalNoPasscode` | Set a passcode on this iPhone to approve here. | UX §3.3 NEW |
| `approvalNoPasscodeHelp` | In Settings, open Face ID & Passcode and turn on a passcode. | UX §3.3 NEW |
| `approvalKeyMissing` | Approvals need setting up again on this iPhone. | UX §3.3 NEW |
| `approvalKeyMissingHelp` | This can happen after restoring this iPhone or turning its passcode off. | UX §3.3 NEW |
| `approvalSetUpAgain` | Set up again | UX §3.3 NEW |
| `approvalEnrollReason` | Set up approvals on this iPhone | UX §3.7 `localizedReason`, **key name phone-proposed** |
| `approvalFaceIDUsage` → `NSFaceIDUsageDescription` | Atum uses Face ID so only you can approve what your assistants ask to do. | UX §3.7 NEW; projected into `InfoPlist.xcstrings` by `scripts/generate-info-plist-localization.py` until exported |

Reused exported keys: `src.matrix.security-copy.copies.recoveryOn` ("On"),
`recoveryOff` ("Not set up"), `cancel`, `error`.

## Left for later

- **Slice 3/4**: the approval sheet, ask card, notifications, challenge
  signing, refusals, the Mac seam. Until slice 3 ships an enrolled iPhone
  cannot answer anything; see owner decision 2.
- **Removing another iPhone from this one.** Owner decision 5 says a lost
  phone is removed in Your devices. The phone's Your devices lists Matrix
  sessions, not registry records, and the UX has no row or copy for "this
  device can approve" or "remove its approvals". Desktop's Your devices (or
  a later phone design) owns it. The registry call (`revoke`) is ready.
- Rotation has no screen (no UX control); the lifecycle supports it.
- Touch ID wording of `approvalSettingsHelp`, `approvalEnrollCancelled` and
  `approvalNoPasscodeHelp` (they say Face ID): needs desktop copy variants.
- Desktop export of every key above, in five locales (UX C-5).

## Owner decisions needed

1. **Capability advertisement.** Accept the version-refusal probe, or have
   the platform add an explicit signal (e.g. echo
   `Atum-Device-Service-Version: 1.3` on negotiated responses, or a field in
   an existing capability read). The phone would accept either; the probe
   stays closed on any doubt.
2. **Ship the row before slice 3?** Enrolment alone gives the owner nothing
   to approve yet, and `approvalSettingsHelp` promises answering requests.
   Today the row only appears once the server advertises phone registration
   (0453 deployed), so it stays hidden in production until then; the
   coordinator may still want a build flag until slice 3.
3. The three phone-proposed keys and the phone-written ja/zh/zh-Hant.

## Owner on-device checklist (physical iPhone; not faked here)

The simulator runs use software keys and an in-memory registry. These need a
real iPhone with the 0453 server (or staging) deployed:

1. Face ID iPhone, passcode set: Your devices shows **Approve on this
   iPhone · Not set up**. Set up: Face ID appears once (the system sheet
   shows "Set up approvals on this iPhone" only on the passcode screen),
   then "On · since {today}". The registry (`GET … device-services` with
   version 1.3) lists an `ios` record with empty scopes.
2. Face ID fails twice then **Enter Passcode**: the passcode completes set-up
   (biometrics first, passcode fallback, `.userPresence`).
3. Cancel on the Face ID sheet, and separately on the passcode screen: "Face
   ID was cancelled, so this iPhone wasn't set up…"; nothing in the registry.
4. Background the app or take a call during the prompt: not set up, no
   registration, no orphaned key (set up again works).
5. Unlock the phone with Face ID, open the app, set up: a **fresh** Face ID
   is still asked (unlock is not approval).
6. No Face ID enrolled (Settings › Face ID & Passcode › Reset Face ID):
   "Set up with passcode" and the nudge; set-up uses the passcode.
7. Passcode turned off: the notice, no set-up button. With approvals on,
   turn the passcode off, return: "Approvals need setting up again" and the
   old registration is revoked in the registry. Turn it on, Set up again: a
   new `deviceServiceId` at epoch 1.
8. Touch ID iPhone (SE): "Set up with Touch ID"; the Touch ID sheet shows
   the reason.
9. Remove from this iPhone online: the record is `revoked` (revokeSeq +1).
   In airplane mode: Off at once; back online, the next foreground revokes it.
10. Sign out with approvals on, online and in airplane mode: same as 9; sign
    back in: Off (never silently reused).
11. Two iPhones on one account: both set up; removing one leaves the other On.
    Revoke one from the other side (registry DELETE): it turns Off on next
    foreground.
12. Restore a backup to another iPhone: "Approvals need setting up again",
    old registration revoked.
13. Old server (0453 not deployed): no row at all.
14. VoiceOver: row reads "Approve on this iPhone, Not set up"; results are
    announced; Dynamic Type AX sizes wrap without truncation.

## Verification

One locked run (`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k
/Volumes/AtumTestFlight/.heavy-build.lock`, `-j 2`, derived data under
`/Volumes/AtumTestFlight/dd-approvals-2b`, one iPhone 17 simulator booted and
shut down inside the same script), on 2026-11-14:

- `swift test -j 2 --filter 'PhoneApproval|PhoneRegistry'`: **39 passed, 0
  failed**: `PhoneApprovalLifecycleTests` 24 (new), `PhoneApprovalKeyTests`
  10 (2a), `PhoneRegistryNegotiationTests` 2 (new), `PhoneRegistryTransportTests`
  1 (2a), `PhoneApprovalPendingCopyTests` 2 (new). 2a's 11 still pass on the
  new base.
- `swift build -c release --target AtumNativeAPI`: passes, so the DEBUG-only
  doubles (`PhoneApprovalTestDoubles.swift`) are not needed by Release code.
- `xcodebuild … build-for-testing` (Debug, simulator): passes.
- UI (`-only-testing:AtumMobileUITests/PhoneApprovalsUITests` plus
  `S6SystemUITests/testU17YourDevicesSignOutAndRecoveryStatus` as the Your
  devices regression): **10 passed, 0 failed**. Flows: set up with Face ID then
  remove (with "Setting up…"), cancel → only "not set up", no passcode, passcode
  only, key loss → set up again, offline, no row on a server without phone
  registry; evidence in en/vi × light/dark (dark is forced with
  `-atum.appearance` and asserted by the ground's luminance); AX XXXL capture
  and `performAccessibilityAudit`.
- `-only-testing:AtumMobileTests`: **373 passed, 0 failed**.
- Screenshots (36): `/Volumes/AtumTestFlight/approvals-2b-shots/ui-evidence/`
  (`PhoneApprovalsUITests.approvals-<state>-<en|vi>-<light|dark>.png`, the row,
  setting up, remove confirmation, AX5).

Audit decision: `TranscriptUITestSupport.handleAuditIssue` ignores a
contrast finding on `approvals.settings.help` only. At AX XXXL the audit
reports the footer with an unbounded frame (top/bottom ±∞); measured on the
capture it is (59, 63, 71) on (244, 245, 247), 9.7:1. It is the same footer ink
every Settings page uses.

Known cosmetic gap: on Your devices the shared `AtumSettingsRow` keeps a title
to one line at default sizes, so "Approve on this iPhone" truncates beside "Not
set up" on a 6.1-inch phone (it wraps at accessibility sizes). Changing the
shared row affects every Settings row, so it is left to the coordinator.

Not run here: physical-iPhone Secure Enclave, Face ID, Touch ID and passcode
behaviour, and the real 0453 server (not deployed): the owner checklist above.
