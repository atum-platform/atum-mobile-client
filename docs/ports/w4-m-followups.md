# Wave 4 agent desk and Stop follow-ups

## Agent desk

An ambiguous schedule control failure keeps the optimistic switch values
visible and disables Pause and the routine switches until a host schedule
read succeeds. The existing automatic read retry still runs once on HTTP
429. If reconciliation cannot confirm the schedule, Refresh uses the
vendored `desktop.common.refresh` label and starts a schedule read with
the same busy retry. Closing the desk cancels its outstanding reads,
including a reconciliation retry. [Mobile client issue #85](https://github.com/atum-platform/atum-mobile-client/issues/85)

`AgentDeskBellTests` covers a Pause that reached the host even though its
response failed, two subsequent busy reads, and recovery through Refresh.
The reopen regression counts read starts after the closed desk's original
one-second retry deadline.

### Review r1 fixes (coordinator)

Review r1 (Sol, MERGE) raised two should-fix items, both fixed:

- The schedule starts unconfirmed, so a failed entry read (for example a
  desk reopened while the host is still unavailable) also offers Refresh
  instead of showing neither the switches nor Refresh.
- A successful manual Refresh clears the earlier "Couldn't change that"
  problem, since the shown schedule is now the host's answer.

`testFailedEntryReadOffersRefresh` covers the first; the existing Refresh
test now asserts the problem clears. The review's nit (the Refresh test does
not observe the in-flight read) is left as is. Locked rerun: Debug build-for-testing exit 0,
`AgentDeskBellTests` 14 passed (exit 0); the package sources are unchanged.

## Stop

Each room retains up to 32 terminal Stop attempts to preserve recent
outcomes across transcript gaps. At capacity, the oldest terminal attempt
outside the current composer selection and the visible confirmation band
is evicted. Pending, in-flight, and retryable attempts retain the first
request ID and reply baseline. [Stop follow-up #87](https://github.com/atum-platform/atum-mobile-client/pull/87)

The package regression fills the terminal cache and checks eviction order
and request ID reuse for a hidden in-flight turn and pending schedule.

## Verification

The Swift and Xcode commands ran inside one
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash`
session. The simulator was an iPhone 17 on iOS 27.0. Build logs and the
AppTests result bundle are under `/Volumes/AtumTestFlight/dd-w4-m`.

| Check | Result | Exit code |
| --- | --- | --- |
| Filtered SwiftPM tests | 807 AtumChat tests and 11 HostAgentDesk tests passed | 0 |
| Debug build-for-testing | Passed | 0 |
| `AgentDeskBellTests` | 13 passed | 0 |
| Simulator shutdown | The simulator was already shut down | 149 |

```bash
lane=/Volumes/AtumTestFlight/dd-w4-m
swift test --package-path ios -j 2 --scratch-path "$lane/swift" --filter 'AtumChatTests|AgentDesk'
xcode_args=(-project ios/AtumMobile.xcodeproj -scheme AtumMobileStateTests
  -configuration Debug -destination 'platform=iOS Simulator,id=939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C'
  -derivedDataPath "$lane" -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm
  -disableAutomaticPackageResolution -jobs 2 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild "${xcode_args[@]}" build-for-testing
xcodebuild "${xcode_args[@]}" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:AtumMobileTests/AgentDeskBellTests -resultBundlePath "$lane/AgentDeskBellTests.xcresult" \
  test-without-building
xcrun simctl shutdown 939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C
```

The public guard passed separately against the committed branch (exit 0).

```bash
python3 scripts/public_guard.py --base origin/main --head HEAD
```
