# Polish P0: motion and radius tokens, design lint

Lane P0 of the iPhone polish wave. The owner said the phone "doesn't feel
polished". The UX audit traced part of that to drift: screens use 24 raw padding
values, 9 corner radii and 8 animation curves, and the `AtumKit` tokens are used
almost only by Store. This lane adds the missing tokens and a lint that stops new
drift. It migrates no call sites. Lanes P1 to P5 move their own files onto the
tokens.

## Tokens

Spacing and type already exist: `kit.space(.s1 … .s12)` (4, 8, 12, 16, 20, 24,
32, 48) and `kit.font(.role)`, in `ios/App/DesignSystem/AtumKit.swift`.

**Corner radius:** `AtumKit.PhoneRadius`, read with `kit.phoneRadius(_:)`.

| Token | Points | Use | Kit radius it reads |
|---|---|---|---|
| `.sm` | 10 | chips, small tiles | `md` |
| `.lg` | 20 | bubbles, cards, the composer | `xl` |
| `.full` | 999 | capsules (prefer `Capsule()`) | `full` |

The phone tokens point at existing kit radii instead of new numbers, so the
desktop token export stays the single source. The kit's own `radius(.sm)` is 8 and
`radius(.lg)` is 14. That is why the phone names live in a separate
`PhoneRadius` enum, just as `PhoneControlHeight` does for control heights.
`AtumKitTests` pins 10 and 20 against the vendored export, so a re-pin that
moves them fails. Grouped lists keep the system radius. A message run's inner
corner stays `ChatLayout.runRadius` (6).

**Motion:** `Motion`, in `ios/App/DesignSystem/Motion.swift`.

| Token | Curve | Use |
|---|---|---|
| `.quick` | `.snappy(duration: 0.2)` | state swaps, chips, toggles |
| `.standard` | `.smooth(duration: 0.3)` | scroll-to, expand and collapse |
| `.send` | `.spring(duration: 0.3, bounce: 0.15)` | sending, presenting the message menu |

Under Reduce Motion every token becomes `.easeInOut(duration: 0.15)`, and
`motionTransition` swaps its transition for `.opacity`, so nothing slides or
springs. Use the helpers, which read Reduce Motion for you:

```swift
.motion(.quick, value: isSending)                 // implicit animation
.motionTransition(.move(edge: .bottom).combined(with: .opacity))
withMotion(.send) { draft = ""; rows.append(echo) } // explicit animation
```

`withMotion` reads `UIAccessibility.isReduceMotionEnabled` by default. A view that
already reads `\.accessibilityReduceMotion` can pass it with
`withMotion(.send, reduceMotion: reduceMotion) { … }`.

## Rules

Outside `ios/App/DesignSystem/`:

- **Spacing:** only `kit.space(.sN)`. The screen side margin is 16, the inset
  between rows 12, and the gap between sections 24. Avoid odd values such as 5,
  7, 9, 14 and 22.
- **Type:** only `kit.font(.role)` for text. A glyph uses the text style of the
  text beside it, never `.font(.system(size:))`.
- **Corner radius:** only `kit.phoneRadius(.sm | .lg)` or `Capsule()`.
- **Motion:** every visible state change uses a `Motion` token. Never use a bare
  curve, a bare `withAnimation {}` or `.default`.

## Design lint

`scripts/design_lint.py` uses only the Python standard library. It counts five
kinds of drift in every Swift file under `ios/App/` except `DesignSystem/`:

| Kind | Counted |
|---|---|
| `padding` | number literals in `.padding(…)` and `.safeAreaPadding(…)`, and each non-zero edge of `EdgeInsets(…)` |
| `spacing` | `spacing:`, `horizontalSpacing:` and `verticalSpacing:` literals |
| `radius` | `cornerRadius` literals, `.cornerRadius(…)`, `top…Radius:` and `bottom…Radius:` literals, `RectangleCornerRadii(…)` literals |
| `font-size` | `.system(size: …)` |
| `animation` | a bare curve (`.easeOut`, `.spring`, `.snappy`, `.smooth`, `.linear`, `.timingCurve`, …), `.default` as an animation, a bare `withAnimation {}` |

Zero values are not counted. Comments and string literals are ignored. A value
read from a named constant is not counted either, so the lint catches the
common case, not every case.

The counts are compared with `scripts/design-lint-baseline.json`, which holds the
counts per file and kind from the day the lint landed: 1,030 findings in 70
files.

- **A count above its baseline fails.** This is new drift. A new file starts at
  zero. The failure lists every line of that kind in the file, and the new one
  is among them.
- **A count below its baseline passes with a reminder** to run `--update`
  (coordinator decision, 24 Nov: several lanes edit these files in parallel, and
  a strict ratchet would fail CI on every removal, deletion or rename). Lanes
  that migrate a file run `--update` to lock their progress in.
- **For a real exception**, such as a 1 pt hairline or an ambient loop like the
  atom mark's breathing, put `// design-lint: allow: <reason>` on the line.

Run it and update the baseline:

```sh
python3 scripts/design_lint.py            # check; exit 1 on any mismatch
python3 scripts/design_lint.py --update   # rewrite the baseline to today's counts
python3 -m unittest tests.test_design_lint
```

After migrating a file to tokens, run `--update` and commit the baseline in the
same change. Each file has its own block in the JSON, so lanes in different
files can merge their baseline edits cleanly. CI runs the check and its tests in
the `client` job of `.github/workflows/public-client.yml`.

## Out of scope

- **Dark `bubble-own` colour (audit issue 8):** unchanged. In dark mode your own
  bubble sits close to incoming bubbles. The fix has to be made in the desktop
  token source and re-pinned, or added as one documented phone override in
  `AtumKit`. Desktop parity makes that the owner's decision, so this lane leaves
  the colour as it is.
- **Call-site migration:** each polish lane, P1 to P5, migrates the files it owns.
- **Haptics and close-affordance rules:** the lanes apply them as they touch
  screens. The lint does not check them.

## Verification

- `python3 -m unittest tests.test_design_lint`: 10 tests passed.
- `python3 scripts/design_lint.py`: exit 0 on the branch. With an extra
  `.padding(.horizontal, 22)` added to `StoreScreen.swift`, it exited 1 and
  listed the file.
- `python3 -m unittest tests.test_ios_project_sources`: 6 tests passed. Motion
  and its tests are in the committed Xcode project.
- New AppTests: `MotionTests` checks the curves, the Reduce Motion ease and
  `withMotion`. `AtumKitTests` checks the phone radii against the vendored
  export. They run in hosted CI, in the `app-tests` job.
- A Debug `build-for-testing` for the arm64 simulator succeeded under the shared
  heavy-build lock. It compiles the app and the new AppTests. No Swift package
  was touched, so no `swift test` run was needed.
- `python3 scripts/public_guard.py --base origin/main --head HEAD`: exit 0.
