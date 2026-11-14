# Home search: People section (desktop → phone)

Date: 2026-11-13. Phone base: `c2283da`. Desktop source of truth:
`b3df36a6c4c71ab9d62a69668fb60dc158233f27` (`origin/main` of the desktop checkout),
read with `git show`. Desktop paths are relative to `apps/desktop/`.

## Why

On the 2026-11-12 TestFlight build, the owner typed a new account's `@handle` into Home's
search and saw nothing. The phone's Home search filtered only the chats already
on the list by name. Desktop's roster search also asks the people directory and
lists who it finds.

## Desktop as rendered

- `src/matrix/roster-global-search.ts`: one controller per roster. The People
  source is asked only for a trimmed query of **2+ code points**, **250 ms**
  after the last keystroke. It is set to `pending` right away. A generation
  fence drops answers that arrive for an older query. A failed request becomes
  an empty `complete` (`.catch(() => [])`), so there is no error row and no retry.
- `src/matrix/app.tsx` (`MatrixAccountView`): `globalPeople` drops this
  account, its agents and anyone you already have a direct room with
  (`directRoomWith`). The results block sits **above** the roster's own matches
  in the same scroll view. From top to bottom:
  1. `t.atum.roster.searching` ("Searching…"), shown while the query is long
     enough and People has not answered yet;
  2. a `t.atum.roster.people` ("People") header, then one row per person:
     avatar, name, and a `PersonHandleLine` (`@handle`, left out when it only
     repeats the name);
  3. then Channels, Messages and Files, then the roster's own conversations.
- The empty state ("No results found") shows only after every source has
  answered and the total count is still 0 (`roster-conversations.tsx`).
- Tapping a person (`openGlobalPerson`) reuses or creates the direct room,
  then selects it. A failure goes to the generic `fail` toast.
- Desktop's main search has **no** "Find @name" row. That row lives only in
  the Start chat sheet, which the phone already mirrors
  (`HomeStartChatSheet`). The older `app/atum/roster-panel.tsx` link, "Find
  people on Atum", belongs to the pre-Matrix shell, so it was not ported.

## Phone now

`ios/App/Home/HomeScreen.swift`:

- `HomePeopleSearchPolicy`: the 2-scalar minimum, the 250 ms debounce, and
  `shown()` (people only, no existing direct chat, one row per identity).
  `HomePeopleSearchState` holds one query's answer: `pending` or done.
- `HomeScreen` runs `.task(id: peopleSearchTerm)`. A new term cancels the old
  task, and a late answer is dropped unless its term is still the one on
  screen. It binds only to `HomePeopleDiscoveryActions.search` / `.open`, so
  the separate handle/email lookup fix in `LiveAppModel.searchPeople` flows
  straight in.
- The List shows "Searching…" (`desktop.atum.roster.searching`), then the
  People header (`desktop.atum.roster.people`), then rows drawn with the
  existing `HomeDiscoveryPersonRow` (the Add friend view's row), all above
  Assistants and Chats. "No results" waits for People to answer, as on desktop.
  A failed search shows nothing extra.
- Tap: `discovery.open(userID)`, then `actions.openRoom(roomID)`. A failure
  plays the error haptic and posts the generic error announcement, the
  pattern already used for invitations.
- The section is hidden whenever `peopleDiscovery` is nil (signed out, Matrix
  not ready, `canAddFriend` false).
- `HomeDiscoveryPersonRow` now leaves out a handle that only repeats the name
  (desktop `PersonHandleLine`). This applies in Add friend too.
- The row is now one accessibility element, read as "name, @handle", like the
  Home row. At accessibility sizes the name and handle wrap (up to 3 lines)
  instead of clipping. Home passes `avatarSize: 52`, the roster's face size;
  the pickers keep 36.
- `HomePeopleDiscoveryActions.directRoom` (new, optional) answers "already a
  chat?". `AppRoot` wires it to a one-to-one live room whose only other member
  is that person.

Both copy keys were already in the design export (en and vi), so this change
needs no `PENDING-COPY` entries.

## Left for later

- ~~**Messages and Files** (company search, `searchCompanies` in
  `roster-global-search.ts`) and **Channels** (team-space rooms matched by
  name) are not ported.~~ Ported on 2026-11-14: see
  [home-search-channels-messages-files.md](home-search-channels-messages-files.md).
  The "Searching…" line now covers all three sources, and People's own
  pending line moved into the shared block.
- Desktop backfills a missing handle from its handle cache
  (`knownHandles[userId]`, `requestMatrixHandles`). The phone shows a handle
  only when the search result has one. The handle/email lookup work in
  `LiveAppModel.searchPeople` (`fix/people-search-handle`) adds the handle for
  an @handle hit.
- If the account has no chats at all, Home shows its first-run empty state, and
  search there does not reach People.

## Verification

- `AtumMobileTests/HomePeopleSearchPolicyTests/testHomePeopleSearchAsksFromTwoCharactersAndListsOnlyNewPeople`
- `AtumMobileUITests/HomeShellUITests`:
  - `testHomeSearchFindsAPersonByHandleAndOpensTheirChat`: one character asks
    nothing; `@somehandle` lists the person; a tap opens the chat.
  - `testHomeSearchDoesNotListAKnownChatAgainUnderPeople`
  - `testHomeSearchPeopleAppearances`: en/vi × light/dark at L, plus AX XXXL.
  - `testHomeSearchPeopleAccessibilityAudit`: `performAccessibilityAudit` at
    AX XXXL with the keyboard dismissed.
  - `testHomeSearchRosterMatchAccessibilityAuditControl`: the same search
    header with only a roster match, to tell header findings from People-row
    findings.
- Audit decision: `TranscriptUITestSupport.handleAuditIssue` now ignores
  Dynamic Type findings on `avatar.monogram`. This mirrors the existing
  contrast exemption for the same node. The initial is decorative and hidden
  from VoiceOver, and its face follows Dynamic Type up to S6's 135 % cap. The
  Xcode audit flagged it in the People row but not in the roster row at the
  same 70 pt face.
- Scripted directory: `ScriptedHomeHost.scriptedPeopleDiscovery` (Debug only).
