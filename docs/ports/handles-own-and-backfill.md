# Owner handle and handle backfill

Phone base: `161ada7`. Desktop reference: `origin/main` at
`6c5aacbc1e4799b9e2aecdf09e504ef47c069e85`, fetched and read without editing its
working tree. Reference files, relative to `apps/desktop/`:
`electron/matrix/aliases.ts`, `shared/matrix-aliases.ts`,
`src/matrix/person-handles.ts`, `src/matrix/person-handle-contacts.ts`,
`src/matrix/people.ts`, and `src/matrix/rail-account.tsx`.

## Plan and ownership

### parallel MECE workstreams

1. Contracts and fixed-endpoint transport: owner current read and contacts wire.
2. State and caching: verified evidence, account binding, request cadence, model entry points.
3. Verification and UI handoff: package tests, outbound guard, this port note.

These scopes are exhaustive and separate, but execution is sequential: state
needs transport contracts, and verification needs the assembled implementation.
This implementation worker delegates nothing and leaves review/integration to
the coordinator. No SwiftUI views, layouts, `LiveRosterRows.swift`, or Home
search sections are edited. No push, PR, CI, deployment, or paid operation.

## Behavior and transport

- `NativeDomainClient.aliasCurrent()` sends the owner's authenticated
  `GET /api/matrix/v1/aliases/current` with no query or body. The existing
  assistant-selecting overload is unchanged. The response is the existing
  strict `AliasCurrentResponse`: `{handle,generation}` or JSON `null`.
- `aliasContacts(_:)` sends `POST /api/matrix/v1/aliases/contacts` with
  `{matrixUsers,schemaVersion:2}`. A request carries 1–50 distinct validated
  local Matrix IDs, at most 255 UTF-8 bytes each. Replies must contain exactly
  the requested IDs in order. Version 2 validates directory revision and
  resolved/not_visible/unknown evidence; legacy replies are accepted only for
  an explicitly legacy request. Unknown fields and incoherent evidence fail.
- Both calls use the existing fixed-origin, no-cookie/no-redirect, bounded-body
  native transport and its shared authorization/401 handling. These two additive
  reads return authentication failures to the cache without invoking the global
  authentication-failure observer: a failed handle read cannot switch off account
  service or create a sign-in prompt. Credential checks and the one 401 refresh
  still run; other endpoints retain their existing observer behavior. The current read
  allows a bare URL in addition to the existing assistant query. No arbitrary
  endpoint or caller-selected owner is introduced.

## Cache and state

`VerifiedHandleStore` is a MainActor package helper with injected transport,
clock and optional UserDefaults storage. `LiveAppModel` mirrors changes into
its observable `knownHandles` dictionary. Its entry points are:

```swift
model.ownHandle                         // String?, bare handle
model.handle(for: matrixUserID)         // String?, observes knownHandles
model.requestHandles(for: visibleIDs)   // fire-and-forget, pooled and deduplicated
await model.loadOwnHandle()             // optional consumer/retry entry point
```

- The owner's read starts independently when the domain client becomes
  available. Successful answers, including null, are cached once per account
  for the store's lifetime, as in desktop's window. Concurrent readers join one
  flight. Failure retains evidence and permits another consumer/foreground
  refresh to try again; no toast, error row, or readiness dependency is added.
- Verified handles persist per owner for seven days. Missing, corrupt, expired,
  future-dated or invalid storage becomes a cache miss. Storage holds public
  identity evidence only, no credentials. A missing entry never guesses a
  handle from the Matrix localpart.
- Current, exact lookup and handle-bearing search answers teach exact evidence.
  One handle has one holder. A new proof moves it, and changes notify observers.
- Contacts pool for 250 ms, batch 50 IDs, skip the owner and foreign/invalid IDs,
  and suppress queued/in-flight duplicates. Hits refresh after 30 minutes;
  nulls live at most two hours and clear earlier on a directory revision change.
  Nulls remove only contacts-derived evidence. Recent exact proof wins over a
  disagreeing contacts reply, and exact proof survives a contacts miss.
- Reads have desktop's local caps: 12 per ten minutes and 96 per day. Failures
  preserve evidence and retry with 30-second exponential backoff capped at 30
  minutes; denied/missing/authentication refusals wait 30 minutes, and rate
  limits honor the server wait. A versioned 400 alone tries a legacy contacts
  request and remembers successful negotiation for this directory binding.
- Publishing a signed-in account restores its cache before the domain client
  exists, so offline identity still benefits from remembered evidence.
  Account invalidation clears the published dictionary and cancels queued work.
  Account and client generations fence late answers, including sign out then
  sign back into the same account. Losing the domain client stops backfill while
  retaining the current account's last good evidence.
- `searchPeople` learns exact handles, returns cache hits immediately for missing
  handles, then requests missing/stale evidence without delaying results.
  `addFriend` and `lookupGroupPerson` teach successful exact lookups.
  `groupCandidates` reads cached handles. Existing direct-room publications,
  product refreshes and loaded conversation members request backfill too.

## Exact UI handoff

No view changes are included. All returned handles are **bare**; existing
presentation adds `@` and suppresses a handle that only repeats the name.

1. **Owner / Settings**: `ios/App/AppRoot.swift`,
   `accountPresentation(_:assistants:)`: pass `directoryHandle: model.ownHandle`
   to the existing `AccountPresentation` initializer. This feeds
   `AccountProfileHeader.handleLine`, `AccountScreen.identityHeader`, and
   `AccountSettingsDetail.accountContent`'s existing public-handle row. The
   optional `loadOwnHandle()` task is safe on appearance; automatic loading is
   already wired in the model.
2. **Home People, Add friend, New group**: `ios/App/Home/HomeScreen.swift`,
   `HomeScreen`'s People result section, `HomeAddFriendView`'s discovery rows,
   and `HomeNewGroupView.candidateRow(_:)` all create
   `HomeDiscoveryPersonRow`. Resolve `person.handle ?? model.handle(for: person.id)`
   while constructing presentation and supply an observable lookup through
   `HomePeopleDiscoveryActions` / `HomeGroupActions` in `LiveRosterRows.swift`.
   Wire those closures from `AppRoot.homeActions`. A search snapshot alone will
   not repaint when the later contacts read answers; the rendering path must
   observe the lookup/dictionary. `groupCandidates` already supplies cache hits.
3. **Home existing direct chats / Start chat**: `LiveRosterRows.rows(_:)` and
   `HomeStartChatSheet.caption(for:)` are the current projection/caption points.
   For a real person row, resolve the other member's Matrix ID from
   `model.liveMatrix.rooms` and use `handle(for:)`; never use a room ID or derive
   a handle from a localpart. Bind the lookup through the Home presentation/action
   seam owned by the UI worker. The model already requests these identities.
4. **Other member lists**: `ChatInfoSheet` member presentation is keyed by
   `ChatInfoMember.id` (the Matrix ID). Read `handle(for:)` in that presentation
   path if the UI adds a handle line; loaded members already request backfill.
   A new picker/list can request its visible IDs on appearance/set change and,
   while visible, repeat at `VerifiedHandleStore.refreshInterval` (30 minutes),
   matching desktop's visible-list timer.

## Verification and remaining boundaries

Package tests exercise owner success/null/failure/single-flight caching, persisted
account scoping and expiry, contacts hits/misses/updates, observer notification,
exact-proof precedence, negative-cache revision/expiry, account/client fences,
batching/read budget, retry and legacy negotiation, plus transport and contract
validation. Final commands and counts are recorded below.

No simulator is booted. The app's UI bindings and a full iOS app build remain
with the coordinator/UI worker. Package tests cover the state helper and real
native transport; they do not compile `ios/App/LiveAppModel.swift`.

Final package result: **110 tests passed, 0 failed** (18
`VerifiedHandleStoreTests`, 3 `AliasContactsTests`, 89 `NativeDomainClientTests`).
The locked run exited 0. The initial queued attempt ended during a host/tool
reset before compilation or test execution (0 tests); after the existing build
image was mounted again, the same locked command completed successfully.
No build ran on the internal disk and no simulator was booted by this worker.

Swift frontend parse checks of the model, transport, new contracts/cache and tests
pass with zero diagnostics. `git diff --check` passes. The package emitted existing
manifest exclusions/unhandled-file warnings and an existing `AppPanelPages`
trailing-closure warning; the new files emitted no warnings.

Executed command (output and scratch stay on the build volume):

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  swift test --package-path ios \
  --scratch-path /Volumes/AtumTestFlight/dd-handles/package -j 2 \
  --filter 'VerifiedHandleStoreTests|AliasContactsTests|NativeDomainClientTests'
```


Result log: `/Volumes/AtumTestFlight/dd-handles/focused-tests-run2.log`.
The final local commit also passes the repository's public outbound guard:

```sh
python3 scripts/public_guard.py --base 161ada7 --head HEAD
```

Guard result: **PASS**, one new commit; raw paths/modes, ancestry, identifiers,
secrets and commit metadata. The guard is rerun after the documentation amendment.
The branch is local only; the coordinator owns integration and assembly review.
