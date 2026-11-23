# W4-E3: the agent's desk in the side panel, and Home's bell

Wave 4 phone catch-up, UI lane W4-E3 (tracker atum-platform/atum-mobile#47).
Branch `feat/w4-e3-side-panel-bell` from `origin/main` `1f48fb1`. It was committed
locally only: no push, PR or CI.

Desktop sources (atum-desktop, read-only checkout on `main`):

- **#51** `feat/side-panel-cloud-r2-1113`, merge `1b28c3b1`: "Side panel for cloud
  agents: browser frame, Files, and agent controls (Pause, routines)".
  Files: `src/matrix/agent-desk.tsx`, `src/matrix/agent-desk-model.ts`,
  `shared/matrix-agent-desk.ts`, `shared/matrix-agent-desk-copy.ts`,
  `electron/matrix/device/host-desk.ts`, `host-agent-control.ts`, `src/matrix/workbench.tsx`.
- **#48** `feat/titlebar-bell-roster-plus-1113`, merge `8fb1bd36`: "Roster plus
  button, short Search, notification bell in the title bar". The plus and Search
  parts were already ported (`docs/ports/roster-plus-search-bell.md`). This lane
  ports the bell: `src/matrix/attention-indicator.tsx`, `attention-copy.ts`,
  `agent-attention.ts`.

Platform routes, read at atum-platform `origin/main` `8dc33727`:
`apps/shell/src/app/api/host/{desk,agent-control}/route.ts`,
`apps/shell/src/lib/host-desk.ts`, `host-owner-bearer.ts` and `middleware.ts:266-270`.
Both routes admit a native-domain owner bearer (`nativeDomainClients`) on the
API host, which is the phone's grant.

## What desktop renders, and what the phone does

### The agent's desk (#51)

On desktop, an agent's own 1:1 chat opens its side panel (the workbench) on a
pinned tab showing the agent's face and name. The tab holds Now, Files and
Controls in one reading column. "Watch" on the chat's working line brings that tab
to the front.

| Desktop element | Desktop source | Phone (native control) |
|---|---|---|
| Entry: side panel opens on the agent's tab | `workbench.tsx` `home = deskAgent ? 'agent' : 'launcher'` | In an assistant chat the panel sheet opens on the new `ChatPanelPolicy.Page.agentDesk`, pushed on the card's `NavigationStack`, at the **medium** detent so the chat stays in view. The system Back button goes to the agent's card. Title and "…" both open it, as before. `ChatPanelHost.init`, `ChatPanelPolicy.openingPage` |
| Tab title: face and name | `workbench.tsx` tabs `id: 'agent'` | Navigation title = the chat's title. The page's accessibility label is `desk` ("Luna's desk") |
| Now: hidden while free | `NowBlock` returns null for `free` | `AgentDeskNow` draws nothing for `.free` |
| Now: "Working · 4 min" head, steer/queue hint as tooltip | `NowBlock`, `useMinuteClock` (30 s) | Atom + caption via `TimelineView(.periodic(by: 30))`. The hint becomes the accessibility hint, never on-screen text. "Since" is the latest own message before the working footer (`AgentDeskPolicy.now`) |
| Now: the line clamped with Show more / Show less; the checklist | `Clamped`, `Steps` | `AgentDeskClamped` (three lines, More/Less) and a step list (check / hollow circle) parsed by the existing `WorkingLineText` |
| Files › sent in this chat: newest 4 of the agent's own file events, with size · time and Save | `matrixAgentDeskSentFiles`, `SentFileRow` | `AgentDeskPolicy.sentFiles` (own, not local echo, with media, file or image). Save downloads through the chat's own `ChatMediaAccess.file` and opens the system export sheet (`UIDocumentPickerViewController(forExporting:asCopy:)`) |
| Files › On its computer: one folder at a time, Back, listing only | `useOwnFiles`, `OwnFiles` | Same reads and rules. A refused home reads as none, and a subfolder keeps its last listing. Folder rows are buttons, Back is a row |
| Controls › Pause switch (tooltip "Still answers you…") | `Controls`, `useAgentSchedule` | `Toggle`, shown only when the host route exists and the schedule has routines; `pauseHint` is the accessibility hint |
| Controls › Notifications (this chat's mute) | `runMatrixCommand({kind:'mute'})` | `Toggle` over the panel's existing `setMuted` (the same Matrix push rule as the card) |
| Controls › More → Routines (switch each), All settings | `Routines`, `openAssistantCard` | Disclosure row (chevron rotates). Each routine row has a `Toggle` and its line (`Next: Fri 08:00` / `Paused` / nothing when switched off on its own switch). "All settings" pops to the card |
| Optimistic switches; 409 → "Its computer is off right now."; failure → "Couldn't change that."; 429 retried once after 10.5 s; a resume that changed 0 rolls back | `useAgentSchedule` | `HostAgentDesk.optimistic` / `resolve`, and `AgentDeskPage.run` |

Wire: `NativeDomainClient.hostDeskSchedule`, `hostDeskFiles` and `hostAgentControl`
send `POST https://api.atumplatform.com/api/host/{desk,agent-control}` with the
desktop's exact bodies (`{agent, read, path?}` / `{agent, action, job?}`) and the
`X-Atum-Host-Bridge-Contract: atum.s2.host-bridge/1.0.0` header. They reuse the
client's single 401 refresh (`performAuthorized`). Replies are decoded strictly
(`HostAgentDesk`, mirroring `shared/matrix-agent-desk.ts`). A files listing must
be the folder that was asked for. The two paths and the header are added to
the client's allowlists for those paths only. The host routes are offered only
for a roster agent with `runtime: "hermes"` (`AgentsResponse.Agent.runsOnHermes`,
new and lossy), as on desktop (`hostRuntimeAgents`).

### The bell (#48)

| Desktop element | Phone |
|---|---|
| Bell in the title bar, always there while signed in; amber/red dot while something needs you | `AttentionBell` in Home's header, between the search field and the plus (on the top row at accessibility sizes). It uses the Kit `Bell` glyph in the same 44 pt glass circle as the plus, with an 8 pt badge in the Kit `warn` colour |
| Label: "Notifications"; with items "Needs you: {item}" or "Needs you: {n} things need you" | Same spoken label, built from `a11yPrefix`, the item label and `count` |
| Popover: heading, rows (dot, label, chevron) acting from themselves; "Nothing needs you right now" | `.popover` with `.presentationCompactAdaptation(.popover)`: a real popover on iPhone too, not a sheet |
| A new item is announced once, politely | `AccessibilityNotification.Announcement` on a newly added item only |
| Items (`matrixAttentionItems`, desktop order) | `AttentionBellPolicy.items`. **Sign in again** (`sign_in`) while the native domain grant needs a new sign-in, which opens the existing reauthentication. **Out of Protons** (`protons`) on a fresh wallet read with nothing spendable, which opens the existing Proton top-up sheet. No balance or rate is shown |

The domain reauthentication card under the header stays.

## Adopt-before-build inventory

What the phone already had (reused, not rebuilt):

| Need | Existing piece |
|---|---|
| Side panel container, pages, detents, scope | `ChatPanelHost` (`ios/App/Chat/Views/ChatPanelHost.swift:12`), `ChatPanelPolicy` (`ios/Sources/AtumChat/ChatPanelPolicy.swift:9`) |
| Panel actions per chat | `ChatInfoActions` (`ios/App/Chat/Views/ChatInfoSheet.swift:171`), built in `AppRoot.chatHost` (`ios/App/AppRoot.swift:800`) |
| Chat mute | `ChatInfoActions.setMuted` → `LiveAppModel.setRoomMuted` |
| Working line text and steps | `WorkingLineText` (`ios/Sources/AtumChat/WorkingLineText.swift:8`), the projection's working footer (`Projection.swift:246`) |
| Downloading a chat file | `ChatMediaAccess.file` (`ios/App/Chat/Media/ChatMediaPresentation.swift:9`) |
| Authenticated native-domain transport, 401 refresh, URL/header allowlists | `NativeDomainClient.performAuthorized`, `isApprovedURL`, `perform` (`ios/Sources/AtumNativeAPI/NativeDomainClient.swift`) |
| Strict decoding helpers | `KeyedDecodingContainer.closed/value/nullable/integer`, `NativeAPI.decode` (`NativeAPI.swift`) |
| Roster agent for a room | `LiveAppModel.agentForRoom` (private; reached through the new seam) |
| Home header slots and glass button | `HomeScreen.header` and `createButton` (`ios/App/Home/HomeScreen.swift:703`), `LiveGlass` |
| Domain reauthentication | `HomePresentation.showsDomainReauthentication`, `HomeActions.reauthenticateDomain` |
| Proton top-up | `ProtonTopUpContext` and `protonTopUpSheet` (`ios/App/Store/ProtonTopUp.swift:11`) |
| Kit glyphs and colours | `AtumGlyph.bell/clock/folder/file/slidersHorizontal/settings`, `AtumKit.ColorRole.warn` |
| Copy | the pinned export: `shared.matrix-agent-desk-copy.*` and `src.matrix.attention-copy.*` are all present |

What native SwiftUI/UIKit supplies: `NavigationStack` page push and Back, sheet
detents, `Toggle`, `.popover` with `presentationCompactAdaptation`,
`TimelineView`, `ViewThatFits`, `UIDocumentPickerViewController` export, and
`AccessibilityNotification`.

Hand-rolled (the gap only): the `HostAgentDesk` wire types and rules, three client
methods, `AgentDeskPolicy` and `AttentionBellPolicy` (pure, in `AtumChat`), the
`AgentDeskPage` view, the `AttentionBell` view, `agentDeskActions(roomID:)` (a new
`LiveAppModel` extension file), and scripted fixtures.

**LiveAppModel seam.** It is one read-only method, `agentDeskContext(roomID:)`, in
`LiveAppModel.swift` next to `agentForRoom`. Swift `private` members cannot be read
from another file, so this was the smallest possible change there. It returns the
signed-in domain client and the room's roster agent. No turn-state code was
touched. Everything else lives in `ios/App/Chat/AgentDeskLive.swift`.

## Not ported (why)

- **Watch on the working line.** It needs `WorkingLineRow` and the turn rendering,
  which belong to the queued persona and turn lanes. The desk is still one tap away
  ("…"). This is a follow-up for that lane: open the panel with `.agentDesk`.
- **Stop on the desk.** The Stop lane owns Stop. With the desk at medium, the
  composer's own Stop stays in view under it.
- **Waiting for you, the ask, and On your device.** These read an open ask, the native
  wait phase and Mac reach-down. The panel does not receive those signals, and they
  are not guessed. The phone is cloud-only, so it has no Devices section.
- **The model row in Controls.** W4-E2 owns the model picker. The card ("All
  settings") still has it.
- **The address bar and the browser frame.** The phone has no in-app browser tabs.
- **Bell items the phone cannot know.** Mac-only items (disk, unlock, runtime update,
  sign in again on this Mac) have no phone meaning. Confirm new device,
  unverified device, new sign-in, "{name} needs you", "connect ChatGPT" and
  "Connect your Atum account" need sources the phone does not have yet: approval
  requests in the bell, per-agent readiness on `/agents`, and sign-in notices.

## Copy

Every visible string comes from the pinned export through `design.text(key)`.
Nothing is hard-coded, the vendored export and `atum-design.lock` are unchanged,
and one key is pending (below). Keys used:
`shared.matrix-agent-desk-copy.matrixAgentDeskCopy.{desk, working, minutes,
steerHint, queueHint, files, sentHere, save, saveShort, more, less, onItsComputer,
back, controls, notifications, moreControls, routines, paused, nextRun,
allSettings, pause, pauseHint, controlFailed, computerOff}` and
`src.matrix.attention-copy.copies.{notifications, nothing, count, a11yPrefix,
items.sign_in, items.protons}`. `AgentDeskBellTests` checks each one in every
locale.

### Pending keys

| Key | Desktop words (en) | Phone until a repin |
|---|---|---|
| `shared.matrix-agent-desk-copy.matrixAgentDeskCopy.pauseHint` | "Still answers you. Starts nothing on its own." | This is the accessibility hint on the Pause switch. The phone shows no hint until the pin carries the key (`AgentDeskCopy.pendingText` reads the export first). No nearer exported key says this, so no words were invented. `AgentDeskBellTests` fails once the key is exported, as a reminder to drop the guard. |

## Verification

VERIFICATION_PLACEHOLDER
