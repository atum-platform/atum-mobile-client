# Team Space search follow-ups

Issue #93 covers routed reply focus during a timeline reattach and Team Space
message pagination when a room's eligibility changes in flight.

The routed history walk uses the transcript's projection generation. If an
in-flight page is interrupted by a reattach, the walk ignores rows from that
generation even if the old page published the selected reply just before the
reattach. The interrupted page counts against the same 40-page limit. When the
reply is found in the replacement projection, the transcript assigns the scroll
and highlight row and consumes the selected event in the same main-actor turn.
During a binding refresh the retained rows carry no current projection
generation, including when the old timeline first projected during the page.

The scripted Team Space host still opens a placeholder room. Exercising focus
placement and highlighting in that walk requires a transcript and thread
fixture, so that coverage is deferred. The package regression test covers the
old reply arriving just before a binding refresh and the replacement having to
page back to the reply again.

Team Space filters hits using the room bindings at response time. If that check
removes any requested room, the response omits its continuation token. The
results from eligible rooms stay visible. Submitting the query again starts
from page one, which can recover the omitted room's hits if it is eligible
again.

Focused verification covers `ChatSearchTests`, `ConversationCoreTests`,
`CompanySearchServiceTests`, `CompanyMessageSearchTests` and
`TeamSpaceRevampPolicyTests`, plus a Debug simulator build of `AtumMobile`.
The SwiftPM and Xcode builds run under the shared heavy-build lock with
artifacts under `/Volumes/AtumTestFlight/dd-w4-s`.
