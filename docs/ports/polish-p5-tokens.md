# Polish P5: token migration sweep

Lane P5 of the iPhone polish wave (audit issue 10). P0 added the phone tokens
and `scripts/design_lint.py` (see `polish-p0-tokens.md`). This lane moves every
`ios/App/**` file that no other polish or wave-4 lane owns onto those tokens. It
is a consistency pass, not a redesign: each screen keeps its layout.

## Files

Owned by this lane: Store, Drive, Account (except
`AccountConnectionsSection.swift`), Recovery, AppBots, Onboarding, Auth, the
Home side files (`AppCardSheet`, `AttentionBell`, `HomeGlobalSearch`,
`ListingHireView`) and the debug `S6SystemGallery`.

Not touched, because another lane owns them: `DesignSystem/` (P0), the shell
and router files (P1), `HomeScreen.swift`, `Company/`, `ChatInfoSheet`,
`AssistantCard`, `AgentDeskPage` (P2), everything under `Chat/` (P3, P4,
W4-S), and the model picker, `Composer.swift` and
`AccountConnectionsSection.swift` (W4-Q, W4-R).

## How values were mapped

- **On-grid values** (4, 8, 12, 16, 20, 24, 32, 48) become `kit.space(.sN)`
  with no visual change.
- **Off-grid values** snap to the nearest step where the change is a point or
  two:
  - 2 and 3 (title over subtitle, the Proton mark beside its amount) → `.s1` (4)
  - 5 → `.s1`; 6 and 7 → `.s2` (8)
  - 10 → `.s3` (12), the row inset from the audit rules
  - 14 → `.s4` (16) for horizontal row and card insets, so rows and their
    dividers line up with the 16 pt screen margin; 14 → `.s3` for vertical
  - 18 → `.s4`, 28 → `.s6` (24, the section gap)
- **Kept with `// design-lint: allow: <reason>`** where a raw number is
  geometry rather than spacing: the Store Get pill's 6 pt vertical inset (it
  matches the system App Store pill height), monograms sized as a fraction of
  their tile, and indents that line text up past a fixed glyph column.
- **A divider or indent that aligns past a glyph** is written as the sum it
  stands for (`kit.space(.s4) + 28 + kit.space(.s3)`), so it follows the row.
- **Radii:** `kit.radius(.xl)` and literal 20 → `kit.phoneRadius(.lg)` (same
  20); cards at 14 or 16 → `.lg`; chips and small tiles at 8, 10, 12 or 14 →
  `.sm` (10).
- **Glyph sizes:** `.font(.system(size:))` becomes the text style with that
  point size at the default Dynamic Type size, so glyphs now scale with text:
  20 → `.title3`, 22 → `.title2`, 34 → `.largeTitle`. Large empty-state glyphs
  (40–48) use `.largeTitle` with `.imageScale(.large)`.
- **Motion:** a bare `withAnimation { scrollTo }` becomes
  `withMotion(.standard)`, and a bare 0.2 s ease becomes `.motion(.quick, …)` or
  `withMotion(.quick)`. Reduce Motion is handled by the tokens.
- **Haptics** (audit rule: only `.sensoryFeedback`, one per action): a credited
  top-up pack and a finished Store purchase play `.success`, and a failure line
  plays `.error`, through `StoreNotice.Tone.feedback`. The recovery sheets
  move from `UINotificationFeedbackGenerator` to `.sensoryFeedback`: copying the
  key plays `.success`, and a restore plays `.success` or, for a wrong key,
  `.error`. The Appearance segmented
  control plays `.selection`.

Text styles such as `.font(.body)` were left as they are. Moving them to
`kit.font(_:)` can change weight, so that belongs to the lanes that own each
screen's look.

## Areas

| Area | Files | Findings before → after |
|---|---|---|
| Store | `StoreScreen`, `StoreItemSheet`, `StorePurchasedScreen`, `ProtonTopUp` | 55 → 0 |
| Drive | `DriveScreen`, `DriveGalleryView` | 40 → 0 |
| Account | `AccountProfileHeader`, `AccountScreen`, `AccountSettingsDetail`, `DeleteAccountRequestSheet`, `IgnoredPeopleList`, `LegalScreens`, `PhoneApprovalSettings` | 56 → 0 |
| Recovery | `RecoverySheets` | 15 → 0 |
| AppBots | `AppBotViews`, `AppOnboardingViews` | 14 → 0 |

## Verification

To be filled in at the end of the lane.
