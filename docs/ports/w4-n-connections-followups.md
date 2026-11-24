# W4-N Connections follow-ups

## Decoder parity

The Connections registry now uses the same UTF-16 label limits as the desktop's
`apps/desktop/shared/account-connections.ts`. A model name can use up to 200
code units and a device name up to 128. An astral character uses two. The
`observedAt` field accepts integral JSON numbers such as `1.0` between zero
and JavaScript's maximum safe integer.

`AccountConnectionsTests` covers astral names at and above both limits and
integral decimals at the safe integer boundary. It also checks that fractional,
out-of-range, boolean, and string values are rejected.

## Picker refresh ordering

The conversation and destination pickers both refresh the subscription account
after a refused subscription pick. That read can take long enough for a newer
account read or Connect sheet landing to update the registry first. Each picker
now applies a read only if it is still current. The sheet's landing invalidates
earlier reads and replaces the registry while preserving the current ChatGPT
and OpenCode Go statuses. Dismissing the picker also invalidates pending reads.

`AccountConnectionsStateTests` checks that an older refresh cannot restore
Claude's Connect button after a sheet landing or a newer read. A current
refresh can still show Connect after a plan disconnects.

## Verification

The package tests, Debug builds, and AppTests ran under
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash`.
The derived data, logs, and test result bundle are under
`/Volumes/AtumTestFlight/dd-w4-n`.

The first Debug build exited 65 because the picker passed a subscription
read callback without a main actor annotation. After the callback was marked
`@MainActor`, the Debug build and AppTests were run in a second locked shell.

| Check | Result | Exit code |
| --- | --- | --- |
| `AccountConnectionsTests` | 19 passed | 0 |
| Debug build-for-testing, second attempt | Passed | 0 |
| `AccountConnectionsStateTests` | 6 passed | 0 |
| Simulator shutdown | The simulator was already shut down | 149 |

```bash
lane=/Volumes/AtumTestFlight/dd-w4-n
swift test --package-path ios -j 2 --scratch-path "$lane/swift" --filter AccountConnectionsTests
xcode_args=(-project ios/AtumMobile.xcodeproj -scheme AtumMobileStateTests
  -configuration Debug -destination 'platform=iOS Simulator,id=939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C'
  -derivedDataPath "$lane" -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm
  -disableAutomaticPackageResolution -jobs 2 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild "${xcode_args[@]}" build-for-testing
xcodebuild "${xcode_args[@]}" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:AtumMobileTests/AccountConnectionsStateTests -resultBundlePath "$lane/AccountConnectionsStateTests.xcresult" \
  test-without-building
xcrun simctl shutdown 939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C
```

The public guard runs separately against the committed branch.

```bash
python3 scripts/public_guard.py --base origin/main --head HEAD
```
