# Wave 4 iPhone chat and data wiring

The integration starts from the copy repin to desktop `46f5a518` and merges the turn-state and data-parity lanes. The native transport keeps the wallet projection header on the wallet GET and the host-bridge headers on the scheduled Stop POST.

## Chat turn state

- The live Matrix item mapper passes the latest SDK event and, for edits, the original event to `AtumTurnMarkers` and applies its complete result. Marked interims stay in the transcript, and a threaded interim cannot settle room-level progress or remove the room question's Stop candidate. The original event checks keep edits from substituting another company turn or schedule execution.
- The existing footer resolves all seven tool activities, heartbeat and approval wait through `AtumCopy`, including a numeric heartbeat argument and the publisher's checklist. A descriptor can supply the entire header when the body is empty. `shared.matrix-status-line-copy.matrixVideoConsentWaitCopy` is the pending export and still uses the existing English line. A status without a recognized descriptor uses its message body.
- The composer dispatches exact schedule intents through the existing authenticated Stop callback. A pending or unknown schedule receipt re-enables the same intent after 15 seconds if the composer still shows it. An ordinary turn Stop continues to wait for its existing confirmation.

## Company chat and data parity

- Channel room transcripts remain unbound. A selected channel thread uses its own copy of the room context, reads the platform's authenticated Company AI view, and checks that the account and returned Matrix agent are currently joined to the directory-bound room. The proof is scoped to that session, channel and thread, refreshed every 30 seconds while the thread is open, and expires after 60 seconds. A room-list membership change invalidates the proof immediately. Same-count changes outside the room-list heroes are caught by the joined-member refresh.
- A private Chief of Staff room uses its ready platform pair and the exact joined account/agent membership of the current unencrypted room. The binding includes the membership incarnation. The chat store revalidates the scope before attaching to a renewed session and rebuilds its mapper on scope changes. The previous company footer is removed while the new mapper attaches, and the transcript and draft stay in place. Unadmitted markers remain ordinary messages.
- A Stop callback is scoped to the open assistant store, so a receipt from a closed chat cannot affect a reopened one. The merged data lane displays the wallet 1.4 spendable Proton balance, retries an eligible model pick once with refreshed revision and policy fences, and skips same-sender cleared working lines in roster previews. Purchase affordability continues to use the ledger.

## Review fixes

- The private Chief of Staff and channel-thread bindings each expire against a monotonic deadline 60 seconds after their successful read began. Expiry clears the binding and removes its footer even while a membership read or timeline attachment is stalled. The session, membership and refresh generation fence late results.
- Refused Stops are keyed by the attempted turn event or exact job and execution pair for that agent. Either endpoint can refuse its source while the other route and later sources remain available.
- An ambiguous model write retains the dispatched request ID and snapshot, including the refreshed revision and policy digest from a conflict retry. Repeating the same choice replays that write even after a newer snapshot arrives. A different choice gets its own request.
- A correlated interrupted or finished receipt suppresses that exact schedule for the open conversation, including across timeline reattachment. Other schedules and ordinary turns still participate in selection. Abandoned cron footers age out after nine minutes from the latest accepted revision, using the desktop company-progress presentation bound.
- The company interim projector keeps the accepted revision, body and relations while taking reactions, receipts and sender metadata from the incoming item. The rendered Markdown uses the accepted body.
- The Stop UI fixtures wait for the composer field to become hittable and take keyboard focus before typing. The existing Stop assertions still run after that wait.

## Remaining parity and verification scope

- A native top-level interim still needs a publisher marker when its event shape is indistinguishable from a final reply.
- Channel membership is revalidated when the phone room-list signal changes and during the open thread's refresh. Desktop also refreshes immediately on an unknown sender's marker. Settled company-turn memory remains scoped to the current projector, and Matrix provides the original and latest edit.
- Live hosted Matrix and platform behavior, including an actual scheduled interruption, require a live account run. Scripted UI and fixture-based contract tests exercise the local paths.

## Verification

The integrated checks used the shared heavy-build lock, two build jobs, and an iPhone 17 simulator on iOS 27.0. Logs and result bundles are in `/Volumes/AtumTestFlight/dd-w4-ab-wiring`.

| Check | Result | Evidence |
| --- | --- | --- |
| Swift package | 1,717 passed, 0 failed. AtumChat ran 748, AtumDesign and Native API ran 905, AtumDrive ran 48, and AtumTelemetry ran 16. | `package-final.log` |
| Debug simulator build | Passed, arm64. | `debug-build-retry.log`, `debug-build-retry.xcresult` |
| Focused AppTests | 164 passed, 0 failed. Includes the cleared working-line roster case. | `app-tests.log`, `app-tests.xcresult` |
| Picker UI | 5 passed. | `ui-tests.log`, `ui-tests.xcresult` |
| Roster UI | 2 passed, including the S1 Matrix roster and Home roster. | `ui-tests.log`, `ui-tests.xcresult` |
| Transcript UI | 3 passed, including the descriptor-only reading footer in light and dark appearance. | `ui-tests.log`, `ui-tests.xcresult` |
| Stop UI | 3 passed, 1 failed while XCTest attempted to focus the composer field. The isolated retry timed out during simulator app launch, before it reached the Stop assertions. | `ui-tests.log`, `ui-tests.xcresult`, `ui-stop-retry.log`, `ui-stop-retry.xcresult` |
| Public boundary | `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0. | `guard-final.log` |

The initial package run used a core compiled before the binding-expiry edit. The first simulator build caught the immutable thread context. The successful package rerun and simulator build include both fixes, and the initial logs and build bundle were kept.

The lane's Swift and Xcode `Intermediates.noindex` directories were removed after their last runs. The test logs, `Logs`, `TestResults`, and result bundles remain on the external volume.

### Review-fix verification

One batch ran under the shared heavy-build lock with two build jobs. It reused the already-booted iPhone 17 on iOS 27.0. The boot-state search emitted a diagnostic and a redundant boot request was refused because the device was already booted. Boot status and the final `simctl shutdown all` both exited 0.

| Check | Result | Evidence |
| --- | --- | --- |
| Swift package | 1,722 passed, 0 failed. This includes the scoped Stop refusal, exact picker replay, terminal schedule receipt, abandoned schedule expiry and company interim metadata cases. | `fix-round-package.log` |
| Debug simulator build | Passed, arm64. | `fix-round-debug-build.log`, `fix-round-debug-build.xcresult` |
| Focused AppTests | 165 passed, 0 failed, including proof expiry during a stalled member read and rejection of superseded results. | `fix-round-app-tests.log`, `fix-round-app-tests.xcresult` |
| Picker UI | 5 passed. | `fix-round-ui-tests.log`, `fix-round-ui-tests.xcresult` |
| Stop UI | 4 passed, including `testStopWhileWorkingThenStopped`. | `fix-round-ui-tests.log`, `fix-round-ui-tests.xcresult` |
| Transcript UI | 2 passed, 1 failed. The timed `testReplyAtBottomHidesTheWorkingLine` observed zero working rows at its first assertion after the delayed initial timeline paint. The UI command exited 65. | `fix-round-ui-tests.log`, `fix-round-ui-tests.xcresult` |
| Public boundary | `python3 scripts/public_guard.py --base origin/main --head HEAD` exited 0. | `fix-round-guard-final.log` |

The logs and result bundles are in `/Volumes/AtumTestFlight/dd-w4-ab-wiring`. The batch's exit codes are in `fix-round-verification.log`. Cleanup removed only this lane's `Build/Intermediates.noindex` and preserved the logs, TestResults and result bundles.
