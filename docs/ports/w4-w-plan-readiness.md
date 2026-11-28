# W4-W plan readiness

Settings › Connections uses the owner device-services read
`{"operation":"work_plan_readiness_read"}` to determine whether cloud
assistants can use ChatGPT, Claude, and Antigravity. The response profile
`atum.work-plan-readiness/1` requires all three plans and rejects extra
fields. The checked-in fixtures cover the request and response.

`NativeDomainClient.workPlanReadiness()` returns `.available(snapshot)` or
`.unavailable`. It uses only the current session's usable stored bearer.
An unsupported operation, a 404, a failed request, an invalid response, or
an unusable bearer yields `.unavailable`. The read never refreshes a bearer,
replays a 401, or reports an authentication failure to the session.

## State contract for the UI

Call `AccountConnectionsView.planRows(_:readiness:now:)` with the existing
registry and the current `AccountConnectionsModel.readiness` snapshot.

| Source state | `AccountPlanRow.state` | Phone action |
| --- | --- | --- |
| `ready` before `validUntil` | `.connected` | None |
| `grant_missing`, `grant_expired`, or cached `ready` at or after `validUntil` | `.needsRenew` | Handoff to Atum on the Mac |
| `not_connected` | `.notConnected` | Connect on the Mac |
| Readiness loading or unavailable | Registry sign-in state (`.signedIn`, `.stale`, `.needsAttention`, or `.notConnected`) with `readinessUnknown == true` | Existing registry-based action |

Only `.connected` represents a confirmed ready grant. A ready plan can have
stale or absent registry Mac details. The registry supplies Mac names, model
labels, and sign-in facts. Settings schedules a re-projection at the next
unexpired deadline, and the projection also checks the deadline every time
it runs.

The connect sheet used by Settings and the picker polls readiness every
three seconds while active and completes only on an unexpired `ready` for the
requested plan. Once ready, it makes an optional no-refresh registry read
to update Mac details. Both reads are fenced by account and client identity,
and Settings drops superseded responses. An unavailable poll leaves the
sheet waiting. The picker still uses the registry for its model catalogs
and Connect entries.

The engineering handoff uses the existing sheet and copy, including the
Mac handoff instruction for `.needsRenew`. Layout and copy updates belong
to the UI lane.

## Local verification

Platform main `13f46194` handles `account_connections_read` and
`work_plan_readiness_read` as separate device-services operations with
different response profiles. The readiness transport test queued a response
before checking that a missing bearer made zero requests. That response stayed
in the shared URLProtocol stub and was served to the next test's registry
request, which correctly rejected the readiness profile as `invalidResponse`.
Each transport scenario now replaces the stub's response queue. The registry
test checks the exact operation, request count, and errors for a malformed
registry and a 503. The stub fails the test if a request arrives after the
queue runs out.

The registry transport test passed on phone `origin/main` at `236b918`
before the readiness change. The Debug simulator build and all eight
`AccountConnectionsStateTests` passed on `dc363d23`.
The focused Swift package run passed all 31 tests after the stub fix.
The merge from phone `origin/main` at `236b918` did not alter the Swift
package sources, tests, or fixtures.

Focused coverage lives in `WorkPlanReadinessTests`,
`AccountConnectionsTransportTests`, and `AccountConnectionsStateTests`.
The locked run uses Swift Package Manager and the `AtumMobileStateTests`
Debug scheme. The public boundary is checked against the committed branch
with `python3 scripts/public_guard.py --base origin/main --head HEAD`.
