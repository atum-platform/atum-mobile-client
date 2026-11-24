# Wave 4 Stop follow-ups

Fixes atum-platform/atum-mobile-client#71.

1. Reopening a room reuses its account-scoped Stop controller. An exact turn
   keeps its pending or settled attempt and request ID. The store waits for
   transcript content before presenting the retained state. Terminal
   scheduled receipts still suppress their exact execution across reopen.
2. When the same scheduled marker returns, it clears the missing-marker
   flag. The pending timer or a failed receipt can offer a retry with the
   existing request ID.
3. The conversation store reconciles Stop before publishing each new
   transcript snapshot. A scheduled receipt for an earlier execution cannot
   announce “Stopped.” after a newer reply takes over.
4. A ready draft takes the Send slot from a disabled Stop icon. Enabled Stop
   and “Stopping…” keep priority.

## Verification

Package tests cover both scheduled retry paths and the composer action.
`ConversationStopStateTests` covers reopen and account/room isolation, plus
a stale scheduled receipt after a newer transcript publication.
`TurnStopUITests` now expects Send when the pending turn Stop settles with
a draft ready.

The first locked run passed 38 package tests (exit 0). The shared build
volume detached during the Debug build-for-testing (exit 65), before the
AppTests could start.

After the remount, the final locked run passed the package checks (38 tests,
exit 0), Debug build-for-testing (exit 0), and both
`ConversationStopStateTests` cases (exit 0). UI suites were outside this
local verification.

## Review follow-up

- Stop retains the request ID, receipt state, and timer for each exact
  target independently of the composer selection. Decryption can restore a
  turn with its original attempt, and a scheduled retry keeps its request
  ID when the marker briefly gives way to an older question.
- The transcript signal includes the latest finished reply. A new reply
  suppresses a late confirmation for the old schedule even when there is no
  live target. The schedule marker's event time distinguishes replies
  loaded from older history.

The package regressions cover a hidden scheduled attempt, receipt and timer
updates while a turn is hidden, and older reply history. The app regressions
cover an undecryptable question on reopen and a newer reply that has already
finished before the old receipt arrives.

The review follow-up passed all 78 filtered package tests (exit 0), the
Debug build-for-testing (exit 0), and all three
`ConversationStopStateTests` cases (exit 0) in one locked run.
