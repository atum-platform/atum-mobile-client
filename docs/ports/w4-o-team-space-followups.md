# Team Space search and channel opening follow-ups

Issue #86 items 5, 6 and 8 follow the Team Space revamp on iPhone. The desktop
reference is `team-space/company-search.tsx` for the 25-result page and
`workspace.tsx` for the room, event and optional thread target.

- Team Space reconfirms the chosen Matrix event and its company before opening
  the room. The room transcript or the reply's thread scrolls to the exact
  event and highlights its row. Older events use the existing bounded chat
  history walk with the same cap as desktop, 40 pages of 50 events. If the
  timeline cannot reach the event, the room stays open and the phone gives
  error feedback.
- The search sheet accepts one result tap at a time. Dismissing it or changing
  the selected company cancels outstanding work. Home search keeps its existing
  room-only route and ten-result pages.
- Team Space requests 25 messages from the selected company. Load more sends
  Matrix's opaque `next_batch` token and appends unique results in server
  order. A page failure shows the pinned company error and keeps prior pages
  available for a retry. Submitting fewer than two code points clears results,
  errors and the previous request. The desktop search-specific Show more key
  is pending in the export. The phone uses the pinned Load more copy meanwhile.
- Channel opens return `opened`, `failed` or `superseded`. Only a current
  failure shows Try again. A cancelled or overtaken open clears its own
  progress without changing a newer route.

The Forward glyph, the Files search tab and board-card reads remain in their
existing lanes.

## Focused checks

- The package suites `CompanySearchServiceTests`, `CompanyMessageSearchTests`,
  `TeamSpaceRevampPolicyTests` and `ChatSearchTests` passed 62 tests with zero
  failures. They cover the limit, the continuation token, transport failure
  versus an empty result, stale pages, superseded opens and exact event
  matching across history pages.
- The copy pin check passed all seven tests.
