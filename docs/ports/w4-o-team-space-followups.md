# Team Space search and channel opening follow-ups

Issue #86 items 5, 6, 8 and 9 follow the Team Space revamp on iPhone. The desktop
reference is `team-space/company-search.tsx` for the 25-result page and
`workspace.tsx` for the room, event and optional thread target.

- Team Space reconfirms the chosen Matrix event and its company before opening
  the room. The room transcript or the reply's thread scrolls to the exact
  event and highlights its row. Older events use the existing bounded chat
  history walk with the same cap as desktop, 40 pages of 50 events. A
  timeline reattach, including a channel agent binding refresh, keeps the
  selected event and resumes the walk on the replacement timeline. The
  interrupted request counts toward the same 40-page cap. If the timeline
  cannot reach the event, the room stays open and the phone gives error
  feedback.
- The search sheet accepts one result tap at a time. Dismissing it or changing
  the selected company cancels outstanding work. Home search keeps its existing
  room-only route and ten-result pages.
- Team Space requests 25 messages from the selected company. Load more sends
  Matrix's opaque `next_batch` token while the room bindings and resolved
  senders match the previous request, then appends unique results in server
  order. A change to either filter starts at page one and replaces prior
  pages on success. The sheet filters all displayed results against current
  room eligibility, including when a page fails. A failure shows the pinned
  company error and keeps the eligible results available during a retry.
  Submitting fewer than two code points clears results, errors and the
  previous request. The desktop search-specific Show more key is pending in
  the export. The phone uses the pinned Load more copy meanwhile.
- Channel opens return `opened`, `failed` or `superseded`. Only a current
  failure shows Try again. A cancelled or overtaken open clears its own
  progress without changing a newer route.
- Board, List and Mine each have a 44-point minimum hit area. A horizontal
  fit check moves Mine below the segments when the controls need more width.
  The board mode and owner filter keep their existing selection behavior.

The Forward glyph, the Files search tab and board-card reads remain in their
existing lanes.

## Focused checks

- The package suites `CompanySearchServiceTests`, `CompanyMessageSearchTests`,
  `TeamSpaceRevampPolicyTests` and `ChatSearchTests` passed 66 tests with zero
  failures in the review follow-up. They cover exact event matching after a
  reattach, the shared 40-page limit, cursor reuse and restart, and the live
  eligibility filter over previously loaded results.
- The AppTests store fixture now replaces a timeline with a page in flight and
  verifies the routed event remains selected and is found. The review
  follow-up parsed that test source and ran the package suites and Debug build.
- The initial copy pin check passed all seven tests.
- The Debug app build passed for the iPhone 17 simulator. The package tests
  and build each used two jobs under the shared build lock
  `/Volumes/AtumTestFlight/.heavy-build.lock` and the task lock
  `/tmp/atum-build.lock`. Build and test logs are under
  `/Volumes/AtumTestFlight/dd-w4-o-team-space-followups`.
- The hosted UI assertion checks the control heights and verifies that all
  three targets fit and Mine can be toggled at the largest accessibility text
  size in Vietnamese. Local verification parsed the UI test source and left
  UI execution to hosted CI.
- Run `python3 scripts/public_guard.py --base origin/main --head HEAD` on
  the assembled branch before publishing it.

## Follow-up coverage

The scripted Team Space host uses a placeholder room destination. Its search
walk covers tapping the result and navigating to the room. To cover production
focus placement and highlighting in that walk, the host would need a
scripted transcript and thread destination. That fixture remains deferred.

## CI fix: transcript type-check time (24 Nov)

The hosted runners (UI shard 0 and AppTests on `000caac`) failed with
`TranscriptView.swift:185: the compiler is unable to type-check this expression in reasonable time`.
The routed-match highlight added one more closure to the transcript's single long modifier chain.
`transcript(_:)` now builds the same view through three helpers (`scrollBody`, `observingChanges`,
`withRowInteractions`), and each row comes from `transcriptRow`, whose highlight is a plain `Color`
background. Behaviour is unchanged. Verified with a locked Debug build carrying
`-warn-long-expression-type-checking=300 -warn-long-function-bodies=1500`: BUILD SUCCEEDED, no
TranscriptView timing warnings.
