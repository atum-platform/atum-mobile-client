# Team Space search follow-ups

Issue #93 covers routed reply focus during a timeline reattach and Team Space
message pagination when a room's eligibility changes in flight.

The routed history walk uses the transcript's projection generation. If an
in-flight page is interrupted by a reattach, the walk ignores rows from that
generation even if the old page published the selected reply just before the
reattach. The interrupted page counts against the same 40-page limit. When the
reply is found in the replacement projection, the transcript assigns the scroll
and highlight row and consumes the selected event in the same main-actor turn.

The scripted Team Space host still opens a placeholder room. Exercising focus
placement and highlighting in that walk requires a transcript and thread
fixture, so that coverage is deferred. The package regression test covers the
old reply arriving just before a binding refresh and the replacement having to
page back to the reply again.
