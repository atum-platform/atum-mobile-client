# `atum.company-private-cos/1.3`

Additive locale and recovery contract for the private Chief of Staff. The
optional ensure `locale` is stored on the membership incarnation; `vi` stays
Vietnamese while `ja`, `zh`, `zh-hant`, missing and unknown preferences render
the English greeting.

Ready binding is replayable, room creation keeps one stable `attemptId` in the
room marker so a controller crash can find rather than duplicate the room, and
private session rotation adopts the existing Company AI 0391 behavior:
same-session regeneration is allowed after expiry, abandoned/unknown rotation
retains the current session, and post-commit attach retries rotate normally.

Funding compatibility: 0395 extends the shared daily calculation across
`company_channel` and `company_private_cos`. The private reservation's cloud
admission subject kind is `company_private_cos`. The pre-0395/0394 channel path
used `company_ai`; the subject-kind difference is recorded and the 0323 plus
0390–0394 regression suites remain the compatibility gate for channel scope.
