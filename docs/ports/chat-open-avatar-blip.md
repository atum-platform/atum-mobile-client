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
  its first frame. Its task key is the source and pixel size only, so a name-only
  update never reloads.

`HomeAvatar`, `ChatInfoAvatar` and `ChatFaceView` now draw `AtumSourcedAvatar` with
identities `row.id`, `info.roomID` and kind plus name. Home keeps its 72 pt pixel size
whatever the face size.

An agent's transcript face prefers its roster photo (desktop parity) while Home
loads the Matrix photo first. On the first open the Matrix copy stands in until the
roster photo decodes, instead of a monogram; after that both are memoised.

Not changed: `ChatInfoMemberAvatar`, `HomeDiscoveryPersonRow` and the Store, app and
account avatars keep their own loads. They are not on the chat-open path.

## Verification

- `AvatarArtMemoTests` (`ios/AppTests/AvatarArtTests.swift`): Home row and title list
  the same sources; Home's decode seeds the title as final; a second-choice origin is
  shown but not final; sharpest copy kept and the LRU bounded; same-person change
  keeps the photo, a different person or a removed photo clears; the room face keeps
  its identity when the info arrives; the tracked loader reports its origin. Run with
  the existing `AvatarArtTests` and `AvatarFrameTests`, Debug, iPhone 16e simulator,
  under the heavy-build lock. Logs: `/Volumes/AtumTestFlight/avatar-blip/`.
- Design lint 0. `scripts/public_guard.py --base origin/main --head HEAD` exit 0.
- No frame capture. The blink is one or two frames during the push, and the scripted
  host serves avatars from local fixtures. A capture needs a timed screen recording of
  the push on a simulator, which this lane did not run (UI suites run on hosted shards).
  The owner's TestFlight check is the end-to-end proof.
