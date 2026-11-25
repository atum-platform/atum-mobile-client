# W4-V1 · Restore the last personal chat

Desktop PR #121 makes Chats reopen the last personal conversation. The iPhone
model now provides the same restore policy for the shell follow-up after
mobile PR #95.

## Destination rules

1. Restore the remembered room when the current Matrix session lists it as
   joined, the live roster can open it, its create state is available,
   workspace classification says personal, and Matrix confirms the room has
   no private CoS state claim. An explicit v1 capability downgrade settles the
   directory step. A missing roster row or unknown workspace classification
   lets the policy consider the fallback.
2. Otherwise open the platform default assistant's joined roster
   conversation. The active assistant's Matrix user must match the room's
   other member. The platform roster also supplies the cloud-only default.
3. When the roster confirms there is no active assistant, an explicit Chats
   tap can open the first eligible conversation. Pinned rooms go first in
   Matrix tag order, low-priority unpinned rooms follow ordinary rooms, and
   the remaining ties use newest event and then room ID. Launch leaves the
   roster visible when it has no remembered room or primary conversation.

Team Space rooms, invitations and former assistants' history stay out of
the restore candidates. The private CoS room uses the same Matrix create type
as a personal assistant. The room-list SDK subscription can omit its
`io.atum.company_private_cos` state, so the restore engine reads the
empty-state-key event directly from the signed-in homeserver for the selected
candidate. A successful state read disqualifies the room, including when
directory discovery failed. A Matrix `M_NOT_FOUND` response clears that
check for the current intent. Other failures make the candidate ineligible
for that intent and allow the fallback to be considered. Every new intent
reads fresh state. A reply to a superseded intent is discarded. A current
reply publishes a revision so the shell can retry its decision. [Matrix room-state endpoint](https://spec.matrix.org/latest/client-server-api/#get_matrixclientv3roomsroomidstateeventtypestatekey)

A former assistant can appear as a people row. An untyped direct chat waits
for the first successful agent roster before it can be restored. If the
roster names its peer as a retired agent, the room stays ineligible. Other
untyped rooms use the ordinary personal-room classification.

The existing roster snapshot matches the signed-in Matrix user ID before
returning cached rows. The restore pointer uses the same identity boundary
with one UserDefaults key per full SHA-256 of the user ID. Its only value is
the canonical Matrix room ID. The shared conversation-open path writes it
after the store opens, including when an app alias resolves to a room.
Known Team Space rooms and their type claims are excluded on write. A direct
open can precede directory discovery, so each restore revalidates the room
against the live workspace and current Matrix state before opening it.

Sign-out fences restoration before its first suspension and discards pending
claim checks. If it aborts and the installation stays signed in, that
installation can restore again.

Leave and Delete record a room ID in the same account's UserDefaults and
clear a matching pointer immediately. All restore paths consult that set.
Room-list publications prune fences using the SDK's per-room membership
when it reports left or banned. An acknowledged SDK forget also removes the
fence. Unknown membership, including lookup failure or a room omitted by
pagination, keeps the fence. A successful explicit open or rejoin clears the
fence. The selected restore candidate must still be joined in the SDK before
it opens, even if a stale roster row survived a confirmed exit. App-bot
Delete clears matching pointers and uses the existing device-local hide
ledger.

## UI lane hook

```swift
@MainActor
func restorePersonalChat(
    for entry: PersonalChatRestoreEntry,
    intentID: UUID,
    hasExplicitRoute: Bool,
    stillCurrent: @escaping @MainActor () -> Bool
) -> String?
```

- Use `.launch` for signed-in startup and `.chatsTap` for an explicit Chats
  tab action. Try once live Matrix room data is available. A pending intent
  that gets `nil` can retry on updates to the room list, workspace
  classification, `hasPersonalChatAgentRoster`, or
  `personalChatRestoreRevision` under the same intent ID. Generate a fresh
  UUID for each launch intent or new Chats tap. A later tap retries a state
  check that failed or timed out in an earlier intent.
- Pass the current explicit-route state. A pending or already claimed
  notification route counts as explicit, including while the shell waits to
  validate it. Capture the shell route generation at the start of the restore
  intent. The closure should check that generation, account and tab are
  still current. Invalidate the generation when a newer action claims
  navigation.
- A returned ID names the conversation that the model has already opened.
  Publish it to the personal route synchronously in the same turn. A `nil`
  result leaves route ownership with the shell.

## Follow-ups

A permanent `/agents` failure keeps a genuine remembered untyped DM
ineligible. The roster is needed to distinguish it from a former assistant.

W4-V2 owns the shell-level route-precedence test. It should exercise a
notification claim and a newer manual navigation while a launch retry or
Chats tap waits for eligibility, and verify that the winning route retains
ownership when the model publishes a claim revision.

## Verification

Twelve focused methods in `AtumMobileTests/S2StateTests` cover relaunch and
account isolation, left and invited rooms, Team Space reclassification and
CoS state when the directory read fails, sign-out and room-exit fences,
the cold agent roster, an unlisted remembered room, former assistants,
cloud-only primary, Chats tap ordering, explicit route priority, and Matrix
pin-order parsing. The Debug build and the XCTest run use the shared
TestFlight lock and retain the `w4-v1/r2-*` logs on the build volume.
Swift 6 syntax validation and a macOS smoke run of the production resolver
and storage with synthetic room rows passed.

### R3

The r3 check uses the shared TestFlight lock for a Debug build-for-testing
and all 16 restore methods in `AtumMobileTests/S2StateTests`. The added and
updated cases cover a superseded claim reply followed by a new Team Space
marker, a timed-out claim retried by a new Chats tap, an exit fence across
publication gaps and relaunch, exit confirmation and explicit reopening,
and recovery after aborted sign-out.

Another XCTest job held the shared lock at the 90-minute deadline.
`lockf` exited 75 before the Debug build and all 16 methods could run.
The restore policy and test source type-checked against the cached iOS
modules. The lock log, type-check log and list of pending methods are
retained under `w4-v1/r3-*` on the build volume.
