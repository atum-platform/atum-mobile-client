# `atum.company-private-cos/1.2`

Integration contract for the live private Chief of Staff path. It keeps v1 and
v1.1 intact while freezing the controller capability endpoint, plain private
room posture, ready-pair resume projection, member-addressed greeting with an
agent pill, locale and board fallback, and durable leave teardown.

For both board-link variants, the published greeting repeats the exact claim
URL in the plain body and renders the platform-authored link title as an anchor
to that URL in `formatted_body`; the claim alone is not a user-visible link.

Synapse room-history purge is not implemented in this version: no existing
platform write authority can perform the admin purge. Retirement revokes both
MAS sessions and all Atum access immediately; physical Synapse history removal
remains a named follow-up rather than a false deletion claim.
