# W4-Y1 native Work model selection

The iPhone uses the owner bearer on `POST /api/matrix/v1/device-services` for
Work picks. `work_selection_read` returns the assistant's Work selection and
the revision from `matrix_model_choices`. Revision zero with a null selection
represents a missing row. A cleared choice can have a nonzero revision.
`work_selection_set` sends that Work revision and returns the saved plan,
model and revision. The decoder validates required fields and tolerates
additive metadata. [Platform #948](https://github.com/atum-platform/atum-platform/pull/948)

The picker reads `work_plan_eligibility_read` over the same owner transport.
The platform checks the assistant, plan, and current Work publication on the
Mac that reported the model. Stale plan facts count while that same publication
is current. The phone uses the returned model IDs and names for selectable
rows and checks eligibility again when a queued save starts. Account connection
catalogs remain available to the Connect and handoff views.
[Platform #954 and migration 0555](https://github.com/atum-platform/atum-platform/pull/954) ·
[W4-Q](w4-q-picker-data.md#connected-plans-and-the-missing-owner-read)

## Picker contract

- `AssistantModelDestinationActions.makeWorkSelection` creates a
  `PhoneModelPickerWorkSelection` bound to the assistant principal, account
  generation and domain client. The conversation picker keeps the instance and
  retires it on close. The app also retires registered pickers on account-scope
  changes and client replacement.
- `reload(within:)` reads selection and eligibility independently under the
  picker's existing per-source deadline. The `rows` projection checks a saved
  choice from the selection read even if eligibility is unavailable. A saved
  model absent from eligibility appears with its plan in the label. Any
  missing operation, transport error or malformed eligibility payload disables
  Work picks. The decoder keeps extensible plan IDs and the picker projects
  the plans the current Work selection wire type supports.
- `save(row.id)` uses the Work revision. The write queue is scoped per
  assistant across reopened pickers and domain-client replacement. An
  in-flight write settles before the latest pending intent reads or writes. A superseded intent cannot
  dispatch a retry. A first 409 can reread once and retry only against an
  advanced revision, or settle if readback already matches the pick. The
  second 409 invalidates the ready revision, reports a conflict and leaves the
  next read to an explicit refresh or save. An ambiguous transport failure also
  invalidates the revision while retaining the last saved model name.
- Cloud Thinking requires a ready, cleared Work choice at the managed offer's
  persisted revision. Every effort request retains that Work fence, including
  an automatic managed retry. Revision zero means there is no row to lock.
  The managed upsert and Work insert use different advisory locks, so the
  effort control waits for a persisted choice there as well. Explicit cloud
  model picks continue through the existing model selection actions.

Work selection readback requires migration 0552 and the Shell
`work_selection_read` operation. Selectable Work rows and saves also require
migration 0555 and the Shell `work_plan_eligibility_read` operation. Production
deployment of that eligibility contract was pending at assignment. W4-Y2 owns
rendering the selectable Work rows and their status in the picker.

## Verification

The initial shared-lock Swift package run passed 821 tests, including 13
Work selection fixtures. The arm64 Debug simulator build-for-testing passed.

Review round 2 started from `ac1af9b` on a separate local branch because
the feature branch was already checked out. The base already contained
`origin/main`. The regression tests cover a successful Work save from a
last-seen catalog, catalog replacement during authorization, observable
retirement, the saved plan label and a fresh revision following an
ambiguous write failure.

Design lint passed with its existing baseline and all 10 lint unit tests
passed. `git diff --check` passed. The standalone public guard passed at
`de6ea67` against `origin/main`. No local UI tests ran.

The round 2 Swift tests and arm64 Debug app build were submitted as one
script under the shared build lock. After the lock became available, Swift
compilation stopped making progress on the `AtumTestFlight` build volume.
Process samples found both compiler jobs blocked in the kernel rename call.
A separate temporary-file rename stalled on that volume and completed on
the host temporary filesystem. The Swift tests returned no result and the Debug build did not start. Retained logs and the
batch script are under `/Volumes/AtumTestFlight/w4-y1-r2`.

### Review round 3

Regressions cover the Thinking gate and managed revision conflict, the
platform eligibility payload and fail-closed rollout, the bounded Work
conflict reread, and the latest pending pick across client replacement
and authorization replay.

From the worktree root, both build commands run in one invocation of
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash -c`.
The build command uses the arm64 iPhone 17 simulator with code signing disabled.

```bash
lane="$PWD/ios/.build/w4-y1-r3"
swift test --package-path ios --scratch-path "$lane/swift" --jobs 3 \
  --filter 'PhoneWorkSelectionTests|PhoneModelPicker|PhoneSubscriptionModelsTests|NativeDomainClientTests'
xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -configuration Debug \
  -destination 'platform=iOS Simulator,id=939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C' \
  -derivedDataPath "$lane/xcode" -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm \
  -disableAutomaticPackageResolution -jobs 3 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
python3 scripts/public_guard.py --base origin/main --head HEAD
```

The locked Swift package run passed 235 tests, including 18 Work selection
tests, and exited 0. The locked Debug build exited 0, and `lipo -archs`
confirmed the arm64 simulator executable. The standalone public guard
exited 0. Design lint and `git diff --check` passed.
