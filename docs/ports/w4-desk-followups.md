# W4 agent desk follow-ups

[Mobile client issue #72](https://github.com/atum-platform/atum-mobile-client/issues/72)

| Follow-up | Change | Regression test in `AgentDeskBellTests` |
|---|---|---|
| Schedule after an ambiguous control failure | The live schedule action passes the host's 429 through the account and agent checks. The model retries the read after the existing 10.5-second cooldown while the desk is open and applies the returned schedule to the switches. Controls stay disabled during reconciliation. | `testAmbiguousControlFailureRetriesABusyScheduleAndUsesHostState` simulates an applied change, an ambiguous control response, and one busy read. It verifies that the refreshed jobs match the host and that the control is sent once. |
| Forward folder navigation | A forward tap requests a fresh listing and shows the current folder until that listing arrives. Back restores a cached parent when available. | `testForwardNavigationRefetchesAPreviouslyOpenedFolder` opens a folder, goes Back, then reopens it and checks that the displayed rows come from a second host read. |
| Checklist accessibility | Checklist rows expose localized progress values to VoiceOver. Completed steps use 100% and pending steps use 0%. | `testChecklistExposesCompletionAsAnAccessibilityValue` checks both values and verifies that the ordinary working line gets no progress value. |

The pinned `matrixAgentDeskCopy` export has no checklist completion labels.
The remaining copy follow-up is to export done and pending labels for VoiceOver.

## Verification

The verification script ran under the shared heavy-build lock on the Mac mini.
It used one iPhone 17 simulator and shut down simulators before releasing the lock.

| Check | Result | Exit code |
|---|---|---|
| `swift test --package-path ios -j 2 --filter AgentDesk` | 8 passed | 0 |
| Debug `AtumMobileStateTests` build for testing | Passed | 0 |
| `test-without-building -only-testing:AtumMobileTests/AgentDeskBellTests` | 11 passed | 0 |
| `xcrun simctl shutdown all` | Passed | 0 |

The accessibility test checks the values passed to SwiftUI. Actual VoiceOver
speech was outside the test scope.
