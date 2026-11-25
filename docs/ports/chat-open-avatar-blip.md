# Chat open: the agent's face no longer blinks

Owner report, 25 Nov 2026, on that day's first TestFlight build: "when i open a chat there's a
little blip where the avatar (and maybe name) of the agent flashes - avatar disappears
for a moment then appears again".

## Cause

Every face that loads a photo began with no art and cleared it again on each load:

- `ChatInfoAvatar` (`ios/App/Chat/Views/ChatInfoSheet.swift`), which draws the chat
  title's 32 pt face, the 64 pt greeting face and the info sheet header, had
  `@State art = nil` and its `.task(id:)` set `art = nil` and then awaited
  `AtumAvatarCandidateLoader.load`. The decoder's cache (`AtumAvatarArtDecoder`) is
  keyed by the bytes' hash, so even a hit is reached only after an async thumbnail
  read and an actor hop. The title's first frame always drew the placeholder (the
  monogram, a mark), and the photo arrived a frame or more later. The toolbar's
  principal item is rebuilt during the push, so the fresh `@State` can start empty
  more than once.
- `ChatFaceView` (`ios/App/Chat/Views/ChatFaces.swift`), used by the transcript rows,
  the typing bubble, Seen marks and the greeting before room info, had the same
  pattern. Any change of its request (the room's face becoming the room info's face,
  a member profile arriving) cleared the photo before loading the new one.
- `HomeAvatar` already kept decoded rows in a private `HomeAvatarArtCache`, but only
  read it inside `.task`, after the first frame, and nothing else could read it. The
  chat never benefited from the photo Home had just drawn.

The title swap the coordinator suspected (`Text(store.title)` while `info` is nil,
then `ChatTitleCapsule`) does not happen on a roster open: roster rows are built from
`liveMatrix.rooms`, and `LiveAppModel.chatInfoPresentation` falls back to
`conversationOpenedRoom` (the roster row) when the product list lags. `openConversation`
sets `conversation` and `conversationOpenedRoom` together, so the info, and the
capsule, are there on the chat's first frame. `ChatScreen.swift` is left unchanged; the
plain title remains only for a room whose Matrix room is not yet known (a cold push
open) and for company DMs, which have no capsule by design.

## Fix: one loading face, seeded on its first frame

All in `ios/App/DesignSystem/AtumAvatar.swift`, reusing the existing loader, decoder
and LRU:

- `AtumAvatarSource`: a face's Matrix URI, resolved catalog candidates and
  `prefersRemote`, built the same way from a `HomeRow`, a `ChatInfoPresentation` and a
  `ChatFace`.
- `AtumAvatarCandidateLoader.load(source:pixelSide:loadMatrixThumbnail:)` returns the
  decoded art and its `AtumAvatarArtOrigin` (the Matrix URI or the catalog candidate
  that decoded). The existing `load` calls are unchanged wrappers.
- `AtumAvatarArtMemo` (main actor, 200 entries, `AvatarArtLRU`): decoded art by origin,
  read synchronously, keeping the sharpest copy. It replaces `HomeAvatarArtCache`.
  Keyed by origin, not by each surface's request, so Home's 216 px row thumbnail
  serves the 96 px title and the 192 px greeting at once. A hit is final when it comes
  from the face's first-choice origin at its size or better; otherwise it is shown and
  the load still runs.
- `AtumAvatarArtTransition`: when a source changes, the face shows the memo's art, else
  keeps its current photo if it is the same person, else clears. When the load ends it
  shows the result, else the memo's copy, else the placeholder (a removed or
  unreadable photo still falls back, as before).
- `AtumSourcedAvatar`: `AtumAvatar` plus that load. Its `@State` is initialised from the
  memo in `init`, so a rebuilt view (toolbar, list diff, scroll back) wears the photo on
  its first frame. Its task key is the source, pixel size and identity (round 2), so a
  name-only update never reloads.

`HomeAvatar`, `ChatInfoAvatar` and `ChatFaceView` now draw `AtumSourcedAvatar` with
identities `row.id`, `info.roomID` and (round 2) the face's Matrix user or room ID,
else kind plus name. Home keeps its 72 pt pixel size
whatever the face size.

An agent's transcript face prefers its roster photo (desktop parity) while Home
loads the Matrix photo first. On the first open the Matrix copy stands in until the
roster photo decodes, instead of a monogram; after that both are memoised.

Not changed: `ChatInfoMemberAvatar`, `HomeDiscoveryPersonRow` and the Store, app and
account avatars keep their own loads. They are not on the chat-open path.

## Fix round 2 (review r1: HOLD)

### Account scope (blocker, privacy)

The memo was process-wide and keyed Matrix art by URI. A Matrix URI is not a
secret, so after sign-out account B asking for the URI account A decoded was
served A's bitmap on its first frame, and a hit at least as large as B's face
skipped B's own thumbnail loader, so a photo B's loader would have refused stayed
visible. Personal and Team Space faces were both affected.

- `AtumAvatarArtMemo.Scope` (generation plus account ID). `beginAccountScope(_:)`
  (a different account) and `endAccountScope()` both empty the memo and start a
  new scope. The memo is cleared whole, catalog art included: it is cheap to
  decode again and the catalog disk cache is cleared at sign-out anyway.
- `LiveAppModel.beginCompanyAccountScope` begins it when an account's product
  starts; `clearCompanyAccountScope` ends it. Every account-ending path goes
  through the latter: `signOut` (success and rollback-incomplete),
  `signOutFromStatus`, sign in again and a forced session end. It runs before
  `clearAccountCaches`, which clears the Matrix thumbnail and catalog disk caches.
- In-flight writes are fenced. `AtumAvatarArtMemo.load(source:pixelSide:loadMatrixThumbnail:)`
  captures the scope before the load and returns `.scopeEnded` without storing
  when the scope changed meanwhile; `store(_:origin:pixelSide:scope:)` refuses a
  write from an ended scope. A face whose load returns `.scopeEnded` clears its
  photo. Signed-in views are torn down at sign-out, so that clear is a backstop.
- Not changed: `AtumAvatarArtDecoder` keys its cache by the bytes' hash, so it only
  answers a caller that already holds the same bytes. It is not an exposure path.

Decision: the account ID is not added to the memo key. Clearing on scope change
plus the fence gives the same guarantee with one partition, and nothing on the
phone shows two accounts at once.

### Same sender, new kind (medium)

A group row or Seen mark can start as a `.person` face from the event or receipt
and then, once the member list loads, become a `.member` face with a new photo
URI. Identity was kind plus display name, so this counted as a different person
and the photo cleared when the memo missed.

- `ChatFace.userID`: the sender's (`ChatItem.sender`, nil when empty) or reader's
  Matrix user ID, set in `incoming`, `reader` and `memberFace`.
  `ChatFace.roomID`: the room's own face (`ChatScreen` passes `store.roomID`), so the
  title changing from the store's to the room info's is also the same face.
  `identity` is `user|<id>`, else `room|<id>`, else kind plus name.
- Identity is now part of `AtumSourcedAvatar`'s task key, so a new person with the
  same source still settles. Identities are IDs, so a name-only update still never
  reloads.
- The render path checks identity synchronously. The body draws
  `AtumAvatarArtTransition.render(...)`: the stored photo only for the same person
  with a source; for a different person, the memo's copy for the new face or the
  placeholder; for a face with no source, the placeholder. A reused view no longer
  shows the previous person, or a removed photo, for the frame before its task runs.

### Follow-ups from r1

- A smaller memo entry can seed a larger face (the 96 px title copy seeding the
  192 px greeting). The hit is not final, so the larger load still runs; on success
  it replaces the entry (the memo keeps the sharpest copy), and on failure the
  smaller copy stays. Accepted, and covered by a test.
- Known limit: when the bytes behind a URI change but the URI does not, the memo
  keeps the old decode until the entry is evicted or the account scope ends. Matrix
  media URIs are content-addressed (a new avatar gets a new `mxc://` URI), so this
  only affects catalog URLs that declare no `sha256`. A declared digest is part of
  the origin key. Not addressed.

## Fix round 3

The pinned Matrix Rust SDK [requests a size-specific thumbnail with caching enabled][sdk-thumbnail]
and [opens a SQLite media store under the configured cache path][sdk-media-store].
The app builds or restores that client with paths for the custody ticket's
installation generation (`ios/App/MatrixLiveRuntime.swift:79`, `:117`, `:647`
and `ios/Sources/AtumNativeAPI/MatrixStoreDirectory.swift:48`). Ordinary sign-out
quarantines and purges that generation's store (`ios/Sources/AtumNativeAPI/LocalSignOut.swift:274`,
`:303`). Forced end and Sign in again can preserve the old store for recovery.
A new installation opens its own cache path. The SDK's [clearCaches API][sdk-clear]
also removes room and state caches and requires recreating the client, so it
would interfere with that recovery path.

The app's separate thumbnail disk cache used URI and size alone.
`clearAccountCaches` ran after successful sign-out and contextless
`signOutFromStatus`. Forced end, Sign in again and rollback-incomplete
sign-out went through `clearCompanyAccountScope` alone, leaving those disk
entries readable.

- `MatrixAvatarThumbnailCache` now keeps only its bounded in-memory fast path.
  The SDK handles persistence. No app lookup reads the old `v1|mxc|` disk keys.
  The existing sign-out cleanup still removes legacy files alongside catalog art.
- The cache scope binds to the Matrix installation generation and a lifetime
  identifier. A live session carries that scope, including across routine token
  renewal. `clearCompanyAccountScope` retires it synchronously alongside the
  decoded memo. That method is called by successful sign-out, rollback-incomplete
  sign-out, contextless `signOutFromStatus`, Sign in again when archiving the
  stranded session, and forced session end.
- `LiveMatrixSession.avatarThumbnail` checks custody before any hit and after
  the SDK fetch. The cache checks the session's scope before reading and again
  before returning or storing a fetch result. A fetch that completes after its
  account ends returns no bytes to the caller and cannot populate the next
  account's app cache.

### Follow-ups from r2

- The empty-chat greeting can still flash when SwiftUI replaces `ChatFaceView`
  with `ChatInfoAvatar` as room info arrives (`ios/App/Chat/Views/ChatScreen.swift:475`).

[sdk-thumbnail]: https://github.com/matrix-org/matrix-rust-sdk/blob/97a1589b70bd122c1d66e0d68ea008d8554076a5/bindings/matrix-sdk-ffi/src/client.rs#L1526-L1548
[sdk-media-store]: https://github.com/matrix-org/matrix-rust-sdk/blob/97a1589b70bd122c1d66e0d68ea008d8554076a5/crates/matrix-sdk/src/client/builder/mod.rs#L825-L841
[sdk-clear]: https://github.com/matrix-org/matrix-rust-sdk/blob/97a1589b70bd122c1d66e0d68ea008d8554076a5/bindings/matrix-sdk-ffi/src/client.rs#L2141-L2163

## Verification

- `AvatarArtMemoTests` (`ios/AppTests/AvatarArtTests.swift`): Home row and title list
  the same sources; Home's decode seeds the title as final; a second-choice origin is
  shown but not final; sharpest copy kept and the LRU bounded; same-person change
  keeps the photo, a different person or a removed photo clears; the room face keeps
  its identity when the info arrives; the tracked loader reports its origin. Run with
  the existing `AvatarArtTests` and `AvatarFrameTests`, Debug, iPhone 16e simulator,
  under the heavy-build lock. Logs: `/Volumes/AtumTestFlight/avatar-blip/`.
- Round 2 (`AvatarArtMemoTests`): sign-out and an account switch empty the memo; a
  write from an ended scope is refused; a load in flight across sign-out and a new
  sign-in returns `.scopeEnded` and writes nothing; a smaller seed is kept when the
  larger load fails and replaced when it succeeds; the same Matrix user keeps one
  identity across `.person` to `.member` (Seen mark and transcript row) and a
  namesake does not; the room face survives its title changing; a different person
  or a removed photo clears on the first frame. Logs:
  `/Volumes/AtumTestFlight/avatar-blip/r2-*.log`.
- Round 3 (`MatrixAvatarThumbnailCacheTests`): a second account misses after
  the shared teardown, late fetches cannot publish or cache bytes, reopening
  the same installation creates a new scope, and a real legacy disk entry is
  ignored. The route wiring is checked at the five calls to
  `clearCompanyAccountScope`. The focused suites and the Debug app build use
  one lock acquisition. Logs are in `/Volumes/AtumTestFlight/avatar-blip/r3-*.log`.
- Design lint 0. `scripts/public_guard.py --base origin/main --head HEAD` exit 0.
- No frame capture. The blink is one or two frames during the push, and the scripted
  host serves avatars from local fixtures. A capture needs a timed screen recording of
  the push on a simulator, which this lane did not run (UI suites run on hosted shards).
  The owner's TestFlight check is the end-to-end proof.
