# Polish P1: system tab bar

The UX polish audit (24 Nov 2026) ranked the hand-rolled tab bar as the worst
problem on the phone. This lane replaces it with the system tab bar and adds
the scripted host's missing pop hook (follow-up F2).

## What changed

- `ios/App/Shell/RootTabs.swift`: the `VStack` that held a `switch
  router.selectedTab` and a glass `HStack` bar is now a system
  `TabView(selection:)` with four `Tab(value:)` entries. Each one hosts its
  own `NavigationStack(path:)` on the router's existing paths. The deployment
  target is iOS 26.0, so the `Tab` API (iOS 18) and Liquid Glass are
  available without fallbacks.
  - The selection binding writes through `Router.select(tab:)`, so a tab tap
    still cancels an in-flight room open (`onUserSelectedTab`), and a re-tap
    of the selected tab still pops it or scrolls Home's roster to the top.
    Programmatic routing (notifications, `open(roomId:)`) still sets
    `selectedTab`, and the bar follows.
  - Each `Tab` keeps its `phone.tab.*` accessibility identifier, the exported
    title as its accessibility label, and the same accessibility value: the
    mention description, or "coming soon" for an unavailable tab.
  - The identifiers are also pinned on the UIKit tab bar items
    (`TabBarItemIdentifiers`). `TabContent.accessibilityIdentifier` alone
    did not last: after the roster scrolled, iOS 26 rebuilt the bar's buttons
    with their labels and values but without the identifiers, and
    `testRetappingHomeAtRootScrollsRosterToTop` could not find
    `phone.tab.chats`. The item's own identifier survives that rebuild.
  - The Team Space mention mark is now the system `.badge`, with the same
    "99+" cap as a Home row. Only a mention earns a mark, as before.
  - Coming-soon tabs behave as before. They are never dimmed, they open
    `PhoneComingSoonView`, and they say "coming soon" in their value.
- Chat destinations hide the bar with `.toolbarVisibility(.hidden, for:
  .tabBar)`. UIKit animates the hide as part of the push and the return as
  part of the pop, including an interactive swipe-back.
  - `AppRoot.swift` applies it to both chat destinations (Home and Team
    Space), so it covers every `chatHost` branch: the chat, the app-bot
    joining view and the blank placeholder. The placeholder previously
    showed the bar for a frame.
  - `ChatScreen.swift` now uses `.toolbarVisibility(.hidden, for: .tabBar)`
    instead of the dead `.toolbar(.hidden, for: .tabBar)`. The modifier has
    an effect now, because a system bar exists. The duplicate line on the
    app-bot joining view in `AppRoot.swift` was removed.
- `Router.swift`: `activeRoomID` is documented as routing presentation
  reports and the same-room fast path only. It no longer decides whether the
  bar is shown. The router's API is unchanged.
- `ios/App/Debug/ScriptedHomeHost.swift` (F2): it now has the live shell's
  `homePath.count` and `teamSpacePath.count` hooks, which call
  `didPopHomeRoom` and `didPopTeamSpaceRoom` when the path empties. Before
  this, a Back in a scripted run left `homeRoomID` set. Tapping the same row
  again then took the "already open" fast path instead of pushing. The
  scripted Team Space destination also hides the bar, as the live channel
  chat does.

## What this fixes (audit issue 1)

- **Push and pop:** the bar no longer vanishes on the first frame of a push
  and pops back in after the pop. Both pages keep their full height through
  the transition.
- **Keyboard:** the bar stays behind the keyboard. It no longer floats on
  top of the keyboard while you search Team Space.
- **Content under glass:** lists run to the bottom edge and scroll beneath
  the bar. The system insets each list so its last row still rests above
  the bar.
- **Per-tab state:** all four tabs stay alive. Switching tabs keeps each
  tab's scroll position, search text and view state.

## Visible design change (for the owner)

- **Selection:** the selected tab used to sit on a filled `fill-selected`
  capsule inside our own glass capsule, and every glyph was ink. The system
  now draws the selection. The selected glyph is ink (the app tint) and
  filled. Unselected glyphs are the system's secondary grey. The bar is the
  iOS 26 floating Liquid Glass bar instead of our `LiveGlass` capsule.
- **Glyphs:** the four Phosphor glyphs stay (Light at rest, Fill when
  selected). The bar stays icon-only, as in FlowPhone2's phone shell. Titles
  remain the accessibility labels, and the system large-content viewer
  shows them on a long press at accessibility text sizes.
- **Badge:** the Team Space mention mark is now the system red badge, not
  our `HomeBadgeView` pill.
- **Chats:** the bar slides away with the push instead of disappearing
  first. It returns with the pop.

## Decisions

- **No `.tabBarMinimizeBehavior(.onScrollDown)`.** Minimizing suits
  content-reading apps with a single main tab, such as Music and News. Here
  the four tabs are peer destinations. A long roster is exactly when you
  scroll down, and a minimized bar would hide the other three tabs behind an
  extra tap. It would also change the list's bottom inset while you scroll.
  It can be enabled with one modifier if the owner wants it.
- **Icon-only tabs kept.** System tab bars normally show titles. The phone
  design is four icon tabs, and the owner's rule is parity with desktop as
  rendered, so this lane changes only the selection treatment. Adding titles
  is a separate design decision.
- **No new Router API.** The `TabView` binding is built inside `RootTabs`
  from `selectedTab` and `select(tab:)`.

## Verification

Every heavy step ran under the shared heavy-build lock, with derived data in
`dd-polish-p1` on the build volume, on one iPhone 17 simulator (iOS 27.0).
No Swift package was touched, so no `swift test` ran.

| Run | Debug build-for-testing | UI tests |
| --- | --- | --- |
| 1 | `65`: the temporary capture harness named the audit's class in a default argument. App sources had no errors. | none |
| 2 | `0` | `HomeShellUITests`, full class: 26 of 31 passed. The after-capture class: 4 of 4. |
| 3, with the identifier pin | `0` | The four `HomeShellUITests` cases below: 4 of 4. |

The five failures in run 2:

- `testHomeSearchPeopleAccessibilityAudit` and
  `testHomeSearchChannelsMessagesFilesAccessibilityAudit`: the element-less
  "Dynamic Type font sizes are unsupported" finding. Both are already
  quarantined in `docs/ci-ui-tests.md`.
- `testNewAssistantShowsCloudDisclosureAndKeepsTheSameSetupRunning`: the
  disclosure reveal fails at the same step as in the 14 Nov baseline in
  `docs/ci-ui-tests.md`. It is pre-existing.
- `testRetappingHomeAtRootScrollsRosterToTop`: the tab buttons had lost
  their identifiers (see "What changed"). It was fixed by the identifier pin
  and passed in run 3.
- `testInvitationShowsJoinProgressThenPushes`: the push completed before the
  test polled for the 0.8 s "joining" state. This is the timing window
  `docs/ci-ui-tests.md` already lists. It passed in run 3.

Run 3 selected `testRetappingHomeAtRootScrollsRosterToTop`,
`testPersonalRosterHeaderAndFourDistinctDestinations` (four tabs,
selection, labels, values and the Team Space mark),
`testSyntheticRosterLastRowScrollsAboveTheInsetTabBarAtCompactAndLargeText`
(the last row rests above the system bar at L and AX-XXXL) and
`testInvitationShowsJoinProgressThenPushes` (the bar is gone in a pushed
chat).

### Before and after captures

The "before" evidence is the audit's own capture of `0521e76`. `RootTabs`
did not change between that commit and this lane's base. The "after" capture
came from a temporary capture class built for run 2. It ran with animations
on, under the same fixtures as the audit, and was never committed. Both sets
are kept outside the repository, beside the audit's evidence on the build
volume.

| Moment | Before (audit) | After (this lane) |
| --- | --- | --- |
| 0.25 s into a push from Home | Bar gone at frame 1, both pages short, an empty strip where the bar was | Chat already full height; the bar slides away with the push |
| Back to Home | No bar, then the bar pops in and the list shrinks | Bar returns during the pop; the list keeps its height |
| Same row tapped again after Back (scripted host) | Did not push (stale room mirror) | Pushes again (F2) |
| Team Space search with the keyboard up | Bar floats on top of the keyboard | Bar stays behind the keyboard |
| Home list | Cut off above an opaque slot | Rows scroll beneath the Liquid Glass bar |
| Home scrolled, then Store, Drive, Home | Home rebuilt at the top | Home returns at the same scroll position |

The dark, Vietnamese and AX-L Home captures show the bar with its Team
Space badge and the selected glyph filled.

## Deferred

- `.tabBarMinimizeBehavior` (see Decisions).
- Tab titles under the glyphs (see Decisions).
- Hosted CI runs the full UI suites. This lane ran one targeted shell class
  locally. `TeamSpaceDailyUITests` and `S1MatrixUITests` also query
  `phone.tab.*` buttons, and did not run here.
- The system bar draws the Phosphor glyphs at its own symbol size (about
  17 pt), smaller than the old 24 pt glyphs. That is the system standard.

## Session log

- 25 Nov 2026, design sub-agent (P1): branch `feat/polish-p1-tab-bar` from
  `main` `09850de`, one local commit, no push, no PR, no CI.
