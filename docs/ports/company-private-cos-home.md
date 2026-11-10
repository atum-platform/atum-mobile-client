# Company-private CoS Home exclusion (Round 2)

Local implementation checkpoint; no push, PR, remote CI, deployment, paid
operation, nested worker or review. Round 1 evidence is retained in commit
`c99ac337b4fe196957d06971d4605314c3bb76ec`.

## Contract authority and provenance

Fetched `atum-platform` `origin/main` and pinned revision
`7df04652c7c1ce39f757891e01e0d14951db31bb`. Frozen packs are vendored verbatim
under `docs/contracts/provider/company-private-cos`, including predecessor
packs required by v2. `PROVENANCE.json` records the protocol source SHA256.
The view handler at that revision is `apps/shell/src/lib/company-private-cos.ts`.

| Pack | Frozen pack SHA256 |
| --- | --- |
| v1 | `8b15bce75a11a084af9ba27fe86d2d48b73b0fe7b6a94ec9d72f187321019266` |
| v1.1 | `107d39e43b04325b9aa81fe4d7981f321f60ab44a810833f21ebc14baccac0ff` |
| v1.2 | `bb2ba35a2569f5d851233399f3eee5f742952f782964eba17a43947c523661a4` |
| v1.3 | `27f221629350fff7b483f8d0e04e1aef60a88523dcca809b2b33860dbc3c3731` |
| v2 | `9b6b5f29b684ae907ac9e823e00d7cc79d7b0f2ea530c671655c4aefa0b705bb` |

V2 freezes capability/execution, not a new view response. The pinned Shell
GET handler still returns `CompanyPrivateCosViewSchema` (v1 bound/uncreated)
or `CompanyPrivateCosEnsureAcceptedSchema` (v1.1 asynchronous preparing).
The capability handler currently advertises 1.3; the client understands the
frozen 1.3 and v2 advertisements, without requesting execution or downgrading
any native turn. View GET uses `Atum-Company-Wire: 1.3`, which that handler
accepts for both read response shapes.

`python3 scripts/generate-company-private-cos-fixtures.py --check` verifies
every length-prefixed provider pack hash, then verifies exact selected fixture
bytes and generated manifests. The phone exposes only two typed GETs:
`/cloud/controller/company-private-cos` and `/companies/{companyId}/private-cos`.
They use the existing MAS authorization/401 refresh path, no cookies or
redirects, 15-second request / 30-second resource timeouts, 4,096-byte request
and 262,144-byte response budgets. There are no ensure, spend or stop methods.

## Behavior and scope

The existing company workspace refresh probes the capability and reads each
company already present in its authenticated list. In-memory positive bindings
are scoped to the account and company, with the complete member/incarnation
pair retained and checked against the binding scope. Replacement accounts,
removed companies, leave and workspace downgrade clear their bindings. A new
pair replaces the old incarnation, even if the new view is uncreated. Every
completion checks refresh generation, provider identity and account; late
answers cannot populate a replacement scope.

The private-CoS company entry captures its company before opening and rechecks
the selection and binding around every join/open await. Selecting another
company changes the navigation fence and shows only that
company's entry. Other current companies' bindings remain account-wide, so
switching the displayed company cannot leak their rooms back into Home.

Before personal agent/bot selection, exact bound rooms bypass those choosers
and the bound agent principal/Matrix identity is removed from personal agent
selection (including the waiting row). The app retains plain joined/invited
room rows for its existing opener, including a room hidden by the personal
ledger, but Home excludes them after both roster projection and cache merging.
New waiting-row caches retain optional agent principal/Matrix identity so a
positive binding can exclude them before `/agents` answers. Legacy caches are
still readable; a legacy waiting row without identity needs the agent catalog
to match its registry row ID. Room-ID cache exclusion works without the catalog.
No display name or private-CoS room-state marker participates in classification.

The company workspace exposes the bound room through its existing channel
entry/opener, routes it to Team Space regardless of its personal-looking row
kind, and includes its unread signals in company/tab/app-icon marks. Company
access is published before applying a binding that excludes a Home row.
The entry uses the existing Matrix room name, or room ID while syncing. The
current design export has no private-CoS title key; no visible Swift string
literal was added and `ios/Vendor/AtumDesign` was not edited.

Absent/off/forbidden/failed/malformed capability or view reads add no
classification, retry on the next refresh and emit only the fixed outcome
`unclassified`. Successful reads emit `bound` or `unbound`. Empty reads never
prove personal/company status or erase a positive same-incarnation binding.
An unclassified room retains existing Home behavior; failed reads preserve
any previously proven binding within its scope.

## Verification

This is an **unverified implementation checkpoint**, not a ship decision.
An intermediate package run passed, including the generated-contract decoding,
positive binding scope tests and the two new exact-route/HTTP tests; the log
reported a 504-test AtumDesignTests suite with zero failures. Subsequent cache
identity, extra contract cases and app/navigation changes require the final
reruns below. Do not treat the intermediate result as final-revision evidence.

| Exact command | Observed result |
| --- | --- |
| `swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-cos2-swift` | Intermediate iteration passed; final rerun interrupted during compilation after more than 14 minutes without a diagnostic. Final revision NOT verified. |
| `python3 scripts/import-design-exports --verify` | PASS: selected producer pin and exported bytes. |
| `python3 -m unittest discover -s tests -p test_import_design_exports.py` | PASS: 8 tests. |
| `python3 scripts/generate-native-push-fixtures.py --check` | PASS. |
| `python3 -m unittest discover -s tests -p test_native_push_projection.py` | PASS: 2 tests. |
| `python3 scripts/generate-company-private-cos-fixtures.py --check` | PASS, repeated after final generator changes. |
| `swift package --package-path ios dump-package > /tmp/atum-cos2-package.json` | PASS. |
| `swift package --package-path ios --scratch-path /Volumes/AtumTestFlight/dd-cos2-swift resolve` | PASS. |
| `plutil -lint ios/AtumMobile.xcodeproj/project.pbxproj` | PASS. |
| `npm ci --ignore-scripts && npm test` in `scripts/public-megolm-fixture` | PASS: both public vectors; zero audit vulnerabilities. |
| `swiftc -frontend -parse ios/App/Company/CompanyWorkspaceModel.swift ios/App/LiveRosterRows.swift ios/App/LiveAppModel.swift ios/App/AppRoot.swift ios/App/LiveAuthDiagnostics.swift ios/AppTests/S2StateTests.swift` | PASS: syntax only, not type checking. |
| `git diff --check` | PASS. |

The app-level S2StateTests include four new real projection/model tests:
joined Home exclusion with company access and unchanged personal/Founder/app
rows; invites/cache/waiting rows; failure/forbidden/off plus retry; and company
selection/removal, account replacement and late responses. They were added but
**could not be executed** in this session.

Attempted simulator command (interrupted before tests ran):

```sh
xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobileStateTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C' \
  -derivedDataPath /Volumes/AtumTestFlight/dd-cos2 \
  -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm \
  -only-testing:AtumMobileTests/S2StateTests CODE_SIGNING_ALLOWED=NO test
```

A second attempt added `-jobs 1 'OTHER_SWIFT_FLAGS=$(inherited) -j1'`.
It progressed through package resolution and build preparation, but was also
interrupted. Xcode's generated driver command still appended its own `-j8`,
so that flag did not prove a one-frontend limit. Neither attempt produced a
Swift error or a test result; neither is a successful app build.

Observed resource constraint: this 8 GiB host had over 10 GiB swap in use,
compilers accumulated only seconds of CPU over minutes, and startup-disk free
space fell below 1 GiB even with all derived data on the requested volume.
Other concurrent local builds were present. Only this task's build processes
and its orphaned compiler children were stopped; unrelated work was untouched.
Before merge, rerun the exact package command and the simulator S2StateTests
in a quiet build window with adequate memory and startup-disk space. Verify
full app type checking and all new cases before treating this fix as ready.


## Remaining live-account evidence

No live account or production view was exercised. Production admission of the
phone's MAS bearer to these routes, actual affected-room bindings, Matrix
invitation acceptance/chat opening, and on-device UX need authenticated live
verification. Read-only synthetic transport and projection tests do not prove
those deployment/account facts. The phone does not gain the desktop's marker,
room-power or membership-policy verification: this change relies on the exact
authenticated platform binding for roster classification and the existing
Matrix opener for access.

## Coordinator verification (2026-11-10)

- `swift test --package-path ios -j 2` (under the shared build lock): 505 + 31 new tests, 0 failures.
- `xcodebuild test -scheme AtumMobileStateTests -only-testing:AtumMobileTests/S2StateTests` on the
  iPhone 17 simulator (iOS 27.0): 71 tests, 0 failures, after fixing one fixture. The new projection
  test's app bot used the `atum.example` homeserver, which the app catalog rejects; it now uses
  `atumplatform.com` like the other fixtures.
- Still unverified: production admission of the phone's bearer on the private-CoS view route, and
  opening the CoS from Team Space on a live account.
