# Team Space search follow-ups

Issue #93 covers routed reply focus during a timeline reattach and Team Space
message pagination when a room's eligibility changes in flight.

## Review round 2

The routed history walk checks the live timeline generation before accepting
end of history. An interrupted page and an end-of-history response superseded
during the 300 ms wait both count against the same 40-page limit. Retained rows
from a detached timeline remain visible while the replacement projects.

The selected event stays pending until the transcript confirms scroll
placement on the current projection. If a candidate disappears before
placement, the same walk resumes with its remaining pages. Placement cleanup
clears the pending row and restores bottom visibility when the route ends.
The settled highlight stays with its scroll anchor until normal transcript
interaction dismisses it.

Team Space filters hits using the room bindings at response time. If that check
removes any requested room, the response omits its continuation token. Search
state keeps eligible hits from both pages and deduplicates overlapping events.
Load more is unavailable until the query is resubmitted from page one.

The package regressions cover reattachment during the end-of-history wait,
a reply disappearing before placement, and the cursor change through Team
Space search state. The scripted Team Space host still opens a placeholder
room, so exercising actual scroll placement there requires a transcript and
thread fixture.

Focused verification covers `ChatSearchTests`, `ConversationCoreTests`,
`CompanySearchServiceTests`, `CompanyMessageSearchTests` and
`TeamSpaceRevampPolicyTests`, plus a Debug simulator build of `AtumMobile`.
The SwiftPM and Xcode builds run under the shared heavy-build lock.

## Routed placement timeout (#100)

Once the walk finds a candidate, the transcript gives layout three seconds to
confirm placement. That covers the 14 scroll commands (about 1.9 seconds) and
allows time for a late layout pass. If confirmation never arrives, the walk
fails, clears the pending event, and resumes bottom visibility tracking from
the last geometry. A replaced projection can still retry within the original
40-page walk and its 300 ms end-of-history grace period.

Coordinator follow-up: when layout confirms after the waiter already timed out, the callback no longer returns early, so `updateBottomVisible()` still runs on that tick.
