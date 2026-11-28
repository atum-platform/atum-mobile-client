# W4-W plan readiness

Settings › Connections uses the owner device-services read
`{"operation":"work_plan_readiness_read"}` to determine whether cloud
assistants can use ChatGPT, Claude, and Antigravity. The response profile
`atum.work-plan-readiness/1` requires all three plans and rejects extra
fields. The checked-in fixtures cover the request and response.

`NativeDomainClient.workPlanReadiness()` uses the current session's usable
stored bearer. It returns `.available(snapshot)` for a valid response and
`.unsupported` for HTTP 400, 404, 405, or 501. Transport failures, other
HTTP failures, invalid responses, and an unusable bearer yield
`.unavailable`. The read never refreshes a bearer, replays a 401, or reports
an authentication failure to the session.

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

Settings reads the registry first, letting its foreground authorization
renew the bearer before readiness asks for the stored token. The registry
publishes independently. If the initial registry read fails, the retry
stays visible beside any readiness rows. OpenCode Go shows the existing
read-failure text until its status is known. Home hubs come from the registry
when it answers, and a later failed refresh keeps the last successful registry.

The connect sheet used by Settings and the picker polls every three seconds
while active. It starts both reads independently with the stored bearer and
fences both by account and client. The sheet can therefore start its registry
read while the bearer still meets the 60-second margin. Settings can display
readiness while the sheet's registry read for Mac details is pending.

An unexpired `ready` can confirm the requested plan. On a server that
signals the readiness operation is unsupported, the sheet can confirm a
registry change from signed out at the time Connect was tapped to signed in.
That path leaves cloud readiness unknown and still updates the picker after
Mac sign-in. A transient poll failure leaves the sheet waiting.

Settings orders readiness replies by a local request sequence. The response's
`checkedAt` still validates the grant's time bounds. Clearing the visible
snapshot or switching account discards the prior server timestamp. Immediately
before announcing success, the sheet checks the latest state for the requested
plan, including grant expiry. The Settings registry has its own request order
so an older sheet result can complete the sheet without replacing newer Mac
or tool details.

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
The app regressions cover legacy HTTP 400 followed by Mac sign-in, readiness
after a suspended authorization, a superseded poll with its registry reply
held, and registry failure and recovery alongside readiness.
The locked run uses Swift Package Manager and the `AtumMobileStateTests`
Debug scheme. The public boundary is checked against the committed branch
with `python3 scripts/public_guard.py --base origin/main --head HEAD`.

The final review fixes add seven state regressions. They cover transient and
legacy failures with existing sign-in, a newer negative answer during a legacy
registry read, concurrent polling near bearer expiry, equal server timestamps,
a backward clock step before and after clearing, and a newer ready answer
with a newer registry. All seven failed on `7352c18` and passed with the
fixes in a macOS XCTest probe using the app's polling and state code. The
transport classification test also failed on `7352c18` and passed with the
fixes. The focused Swift package run passed 145 tests. The queued app-target
run remains the app's simulator verification.
