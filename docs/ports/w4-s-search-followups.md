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
allows time for a late layout pass. If the current candidate times out, the
walk fails and clears the pending event. Releasing an unconfirmed placement
reconciles the last measured position with the follow policy and updates
bottom visibility. At the bottom the next incoming message scrolls into view.
Away from the bottom the unread count is preserved.

A change in live timeline generation releases a stale placement even while the
old rows are still on screen. If the timeout arrives first, the walk checks the
live generation and projection again. The walk checks for publication of the
current generation every 100 ms, with a cumulative 10-second wait budget per
route. If the budget expires while the projection is pending, the walk fails.
The live projection must publish before the walk can request a page, and the
walk tries a reply already present on that projection first. A page
invalidated by a generation change counts toward the original 40-page limit.
The 300 ms end-of-history grace period and 41-attempt placement limit still
apply.

Package regressions cover a replacement that publishes five seconds after
placement is released, timeouts before and after the replacement projects,
the placement attempt limit, and follow state on release both at and away from
the bottom. The Debug simulator build checks the live store and transcript
wiring.

### Open follow-ups

- Repeated swaps can accumulate about 123 seconds of placement waits across
  the 41 attempts. The walk still needs an overall deadline covering page
  loads, placement, and reattachment.
- The four-second page-slot deadline covers acquiring the slot. The subsequent
  SDK pagination call runs outside that deadline.
