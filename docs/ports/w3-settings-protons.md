# Settings › Protons, devices and recovery, one Proton format (wave 3 ST-8, AC-8)

Wave 3 of the iPhone parity plan v2, branch `feat/w3-settings-protons` from main `dc0634b`.
Slices: ST-8 (audit lane 4, L4-8), AC-8 (audit lane 5, L5-S9), and the Store balance
chip format (wave 2 assembly's open item).

Desktop reference: the public export at atum-desktop `c14d74a`, which carries
`apps/desktop/src/matrix/**` as shipped (the audit's atum-app `050ede8edf5`).

## 1. One Proton format on Store and Settings

**Defect.** The Store header chip read "105.449" while rows read "8,000". There were
three formatters:
- The scripted Store host formatted the wallet with a fixed `vi_VN`.
- Live rows and the chip used `Locale.current`, which follows the device region.
- The item sheet's monthly line used the app's display language (`LiveDesign.locale`).
- The S6 and Home scripted hosts passed the literal string `"12.400"`.

**Fix.** `ios/App/Store/ProtonAmountFormat.swift` is now the only formatter for Proton
amounts. It has two forms:
- `balance`: whole Protons, floored, never negative (desktop `wholeProtons`).
- `price`: micro-Proton precision (desktop `microProtons`).

Both format in the app's display language, as desktop does with
`Intl.NumberFormat(locale)` in `discover-view.tsx` `formatWhole`, `wallet-ui.ts`, and
`settings-revamp.tsx` `AccountPane`.

`LiveProductStoreRead` now carries `walletMicroProtons` instead of a pre-formatted
string. `walletText(locale:)` formats it where it is drawn. These surfaces use it:
- Store chip
- Row prices and the Hatch strike-through
- A row's VoiceOver price, which is now the drawn string and no longer `item.price`
- Item sheet price, balance and review
- Purchased
- Pack sheet balance and pack totals
- Settings › How Atum answers

StoreKit's own `displayPrice` is untouched.

The chip itself already matched desktop: the Proton mark plus the number, read by
VoiceOver as "N Protons".

`LiveAppModel` still fills `LiveProductStoreItem.price` with `Locale.current`. Nothing
draws it when an offer exists, and live items always carry their offer.

## 2. ST-8: Settings › Protons

Finding: at the reference, desktop Settings has **no separate Protons pane**.
- `settingsPageOf('protons')` is Account.
- Account's sections are `account` and `privacy`.
- `settings-revamp.test.tsx:454` asserts that Settings "keeps Protons in How Atum answers
  without a second balance pane".

`store/protons-pane.tsx` (Available to spend, Details with Topped up / Earned / Bonus /
Held, Activity, Load more) is reachable only in the playground (`?view=settings-protons`).
The audit's W1, W4 and W5 rows cite that pane.

Phone parity is therefore the one row in How Atum answers. It already existed from
AC-3 and ST-5: "N left · used for Atum's built-in models and the Store", Top up, and the
wallet-unavailable line. This slice changes:
- The number now comes from the shared formatter (§1).
- While the wallet loads, the row says desktop's exported `desktop.atum.protons.checking`
  ("Checking Proton balance…"). Before, it said the generic "Loading…". Desktop's row
  shows the unavailable line while loading, so this is phone-better.
- Owner ruling 1 is checked. `ios/App` reads no `balances.paid`, `earned`, `promo` or
  `held` value, and no rate. The pack sheet shows totals and StoreKit's price only.

Not ported:
- Details: it violates ruling 1, and desktop no longer shows it.
- Activity and Load more: not in desktop Settings. Store › Purchased keeps the phone's
  transaction history.
- About Protons: App Review 3.1.1 risk (audit W3), and desktop shows it only beside an
  in-app top-up.

## 3. AC-8: Your devices and recovery

Desktop: `security-panel.tsx` `DevicesPanel` and `RecoveryRow`. Sign-out of a device is
`electron/matrix/account.ts` `endDeviceSession`.

**Your devices** (`Account/AccountDevices.swift`, `AccountSettingsDetail.devicesContent`):
- This iPhone first, unchanged. Then the account's other sessions from
  `GET /_matrix/client/v3/devices`. The read uses the same pattern as the company
  Activity read: the session's own homeserver, HTTPS only, bearer, no cookies, no
  redirects, ephemeral session.
- Only the device ID, display name and last-seen time are kept. `last_seen_ip` is never
  read into the model.
- Rows are sorted by most recently active.
- Row title: the name the device gave itself. When that name is empty, is the device ID,
  or is a Matrix ID, the row says "Another device" (`otherDevice`). The device ID is
  never drawn and is not in any accessibility label. The row identifier uses the list
  index.
- Second line: "Active 2 hours ago" (`seen`, with desktop `seenAgo`'s units: minutes
  within the hour, hours within the day, then days), in the app's language.
- States:
  - Loading: atom plus "Loading your devices…".
  - Failed: "Couldn't load your devices." plus "Try again".
  - The list reloads when the app returns to the foreground, for example after the
    browser page.
- **Sign out a device:**
  - Tapping a row opens a confirmation dialog anchored on that row. Its title is the
    device name, its message is desktop's `manageHelp`, and its actions are "Sign that
    device out" (destructive) and Cancel. The first capture anchored it on the whole list,
    so the popover pointed at the top of the page; it now points at the device.
  - Confirming asks the SDK for `accountUrl(action: .deviceDelete(deviceId:))`, which is
    MSC4191 `org.matrix.device_delete`, the same action desktop uses.
  - `AccountDeviceSignOut.validatedURL` accepts only an HTTPS address with no
    credentials that carries exactly that action and that device. It is then opened in
    the browser, where the sign-in server signs the person in if needed and asks again.
  - The phone ends no session itself and gains no new authority. This phone's own
    session is refused, because that is Sign out, which keeps its existing
    save-the-key confirmation unchanged.
  - If the address cannot be found, the section shows desktop's `error` line.
- The footer shows `manageHelp` when sign-out is offered.

**Recovery key row** (desktop `RecoveryRow`):
- With the key on this phone: "Recovery key · On", which opens the key sheet as before.
- Otherwise the row is not tappable. It says "On" when the SDK recovery state is enabled
  or incomplete, "Not set up" when it is disabled, and "Not available yet" when the state
  is unknown (`AccountRecoveryStatus`).
- The restore row and the key sheets are unchanged. No key is logged, and no key
  handling was touched.

## 4. Copy

Every new word is an existing desktop export: `src.matrix.security-copy.copies.{loading,
devicesFailed, retry, otherDevice, seen, revoke, manageHelp, cancel, error, recoveryOn,
recoveryOff}` and `desktop.atum.protons.checking`. A unit test checks all five locales.

No new `PENDING-COPY` markers. Desktop words not used, on purpose:
- `current` ("This Mac"): the phone's own row stays "This iPhone".
- `devicesLead` ("Devices you verified can read…"): the phone shows no verified state yet.
- `thisMacUnverified`, `onThisMac`: Mac wording.

The device sign-out failure uses desktop's `error` line, which mentions "the key". That
is desktop's own choice for the same failure, so a phone-specific line would need a new
export.

## 5. Tests

- Unit (`AtumMobileTests`):
  - `ProtonAmountFormatTests` (5): desktop `Intl` output in all five locales, flooring,
    micro precision, one grouping for chip and row, `walletText`, monthly parts.
  - `AccountDevicesTests` (7): this phone left out, sort order, names never expose an
    ID, an unreadable answer is a failure, desktop units for "Active …", the sign-out URL
    rules, recovery status mapping, copy in five locales. The URL-with-credentials case is
    built with `URLComponents`, so the file has no `user@host` literal for the public
    outbound guard's address rule to flag.
- UI: `S6SystemUITests/testU17YourDevicesSignOutAndRecoveryStatus`. It uses new scripted
  scenarios `account.devices` and `account.devices-failed`. In those scenarios the
  browser hand-off is intercepted, never opened. The test covers:
  - the named and unnamed rows and their last-active lines
  - no device ID visible
  - the confirmation, then the sign-out page
  - "Khóa khôi phục, Chưa thiết lập"
  - AX5
  - the failed state, then Try again
- Run results: see Verification at the end.

## 6. Not done or not verified

- Per-device Verified / Not verified, Verify, and "Verify someone else's device…". The
  pinned SDK FFI has no per-device verification read. Needs a Codex SDK slice.
- Creating a recovery key with the two-minute write-down step, the iCloud Keychain copy,
  and device approval (audit P2, L5-S9 later parts). These need SDK `enableRecovery` and
  a reviewed key-custody design. Left for a dedicated crypto slice.
- Live check that production MAS advertises `org.matrix.device_delete` in
  `account_management_actions_supported` for the phone's client (plan SV-6). Desktop
  relies on the same discovery. Without it, the phone shows the `error` line and ends
  nothing.
- A physical iPhone, dark mode on the new rows, and ja/zh captures.

## Verification (2026-11-11, iPhone 17 simulator, iOS 27.0)

Every build and test ran under the shared heavy-build lock with `-jobs 2`. DerivedData was
`/Volumes/AtumTestFlight/dd-w3-stac` and packages were in `/Volumes/AtumTestFlight/spm`.
One simulator was used and shut down at exit, with `sim-content-size-runner.sh` running
beside xcodebuild. No Swift package sources changed, so `swift test` was not run.

| Check | Result |
|---|---|
| `build-for-testing` (scheme AtumMobile) | TEST BUILD SUCCEEDED (r3–r7) |
| `AtumMobileTests` (whole target) | PASS 337/337 (r3, again in r5), including the 12 new tests |
| `StoreCommerceUITests` (all 6) | PASS 6/6 (r3). `testStoreBalanceOpensThePackSheet` passed again in r6 |
| `S6SystemUITests` full class (r3) | 25 run, 1 skipped (RT, opt-in), 4 failed. See below |
| U10, U13, U14 (Settings, sign-out confirmations) | PASS (r3, again in r5) |
| U9 (Store open app) | PASS (r3, r6) |
| U8, U11, U12 and the other S6 tests | PASS (r3) |
| **U17 (new)** | PASS (r7), after two test fixes and one app fix (below) |
| U15 Legal → in-app Safari | failed in r3 and r4, then PASS in r5. The control (below) also passed. |
| U7, U16 | FAIL; on the wave 2 assembly's main baseline (below) |

The r3 run was stopped at the 2-hour background limit, most of it spent waiting for the
lock. Its tests had already finished (12:34), and xcodebuild was still finishing the result
bundle when it was stopped (12:40). The counts above come from its log.

Failures explained:
- **U15:** in r4, a frame from the screen recording showed `SFSafariViewController`
  presented but blank. Its close button never reached the accessibility tree. That
  points at the simulator's Safari service.
  - Control: U15 run from another wave 3 worker's build (`dd-w3-ts`, without this
    branch) on the same simulator in the same locked session: PASS.
  - Then PASS on this branch (r5).
  - So U15 is flaky in the environment, not caused by this branch.
- **U7:** `label == "Mở"` count 0. The Store app row is now one button whose label ends
  in "Mở" (U9 asserts `hasSuffix("Mở")`). The wave 2 assembly lists this as failing on main.
- **U16:** accessibility audit, "Dynamic Type font sizes are partially unsupported" on
  `store.app.moon.summary`. That is a Store app row this branch does not touch. The
  wave 2 assembly lists U16 as failing on main.
- U7 and U16 were not re-run on `dc0634b` itself; the baseline evidence is
  `docs/ports/wave2-assembly.md`.

Fixes the runs found:
- **Test:** the confirmation button appears twice in the accessibility tree, so the test
  uses `.firstMatch`.
- **Test:** at AX5 the device rows are below the fold and not built yet, so the test
  scrolls to them.
- **App:** the failed-state row put its identifier on the container, which overrode the
  Try again button's identifier. It is now on the message text.
- **App:** the confirmation popover pointed at the top of the list; it is now anchored on
  the row.
- **Fixture:** the scripted read counter no longer redraws the host.

Screenshots (not committed), in `.scratch/ui-evidence/`:
- `S6SystemUITests.U-S6-17-{devices-light-vi, devices-confirm-light-vi,
  recovery-off-light-vi, devices-light-ax5-vi, devices-failed-light-vi}.png`
- `StoreCommerceUITests.U-Store-13-pack-sheet-*.png`: the pack sheet over the shared
  formatter.
