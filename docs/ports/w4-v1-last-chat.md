# W4-V1 · Restore the last personal chat

Desktop PR #121 makes Chats reopen the last personal conversation. The iPhone
model now provides the same restore policy for the shell follow-up after
mobile PR #95.

## Destination rules

1. Restore the remembered room when the current Matrix session lists it as
   joined and the live roster can open it as a personal conversation. A
   remembered room awaiting workspace classification gets time to settle
   before a fallback can replace it. The v1 workspace uses the Matrix room
   types and available directory bindings.
2. Otherwise open the platform default assistant's joined roster
   conversation. The active assistant's Matrix user must match the room's
   other member. The platform roster also supplies the cloud-only default.
3. When the roster confirms there is no active assistant, an explicit Chats
   tap can open the first eligible conversation. Pinned rooms go first in
   Matrix tag order, low-priority unpinned rooms follow ordinary rooms, and
   the remaining ties use newest event and then room ID. Launch leaves the
   roster visible when it has no remembered room or primary conversation.

Team Space rooms, invitations and former assistants' history stay out of
the restore candidates. A former assistant can appear as a people row on the
phone, so eligibility uses the Matrix assistant-room type and the current
agent's Matrix identity. For older untyped rooms, the platform roster can
identify inactive users it still names. An untyped room with no surviving
agent identity uses the ordinary personal-room classification.

The existing roster snapshot matches the signed-in Matrix user ID before
returning cached rows. The restore pointer uses the same identity boundary
with one UserDefaults key per full SHA-256 of the user ID. Its only value is
the canonical Matrix room ID. The shared conversation-open path writes it
after the store opens, including when an app alias resolves to a room.
Known Team Space rooms and their type claims are excluded on write. A direct
open can precede directory discovery, so each restore revalidates the room
against the live workspace before opening it.

## UI lane hook

```swift
@MainActor
func restorePersonalChat(
    for entry: PersonalChatRestoreEntry,
    hasExplicitRoute: Bool,
    stillCurrent: @MainActor () -> Bool
) -> String?
```

- Use `.launch` for signed-in startup and `.chatsTap` for an explicit Chats
  tab action. Try once live Matrix room data is available. A launch that
  gets `nil` while the room list, workspace classification or agent roster
  is still loading can retry on the relevant updates under the same intent.
- Pass the current explicit-route state. A pending or already claimed
  notification route counts as explicit, including while the shell waits to
  validate it. Capture the shell route generation at the start of the restore
  intent. The closure should check that generation, account and tab are
  still current. Invalidate the generation when a newer action claims
  navigation.
- A returned ID names the conversation that the model has already opened.
  Publish it to the personal route synchronously in the same turn. A `nil`
  result leaves route ownership with the shell.

## Verification

Seven focused methods in `AtumMobileTests/S2StateTests` cover relaunch and
account isolation, left and invited rooms, Team Space reclassification,
former assistants, cloud-only primary, launch and Chats tap ordering,
explicit route priority, and Matrix pin-order parsing. The Debug build and
the focused XCTest run use the shared TestFlight lock with their derived
data on the mounted volume. Lock acquisition returned exit 75 for an already
locked lane, so those commands did not start. Swift syntax validation,
Xcode project plist validation, and a macOS Swift 6 smoke run of the actual
storage, resolver, and model hook with stubbed app dependencies passed.
