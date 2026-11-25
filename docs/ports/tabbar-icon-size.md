# Tab bar icon size (regression from polish P1)

Owner report, 25 Nov 2026, on the TestFlight build of 25 Nov 01:33: "bottom nav icons
suddenly are smaller than before?"

## Cause

Polish P1 (`df2410f`, merged in PR #95 as `da3c208`) replaced RootTabs'
hand-built glass capsule with a system `TabView`. The old bar drew each
Phosphor glyph with `.font(.system(size: icon.xl /* 24 */, weight: .light))`.
The new tab label is a bare `Image(<custom symbol>)` with no title, so the
system bar draws it at its own default symbol size, about 17 pt. That is
17/24 = 71 % of the old size. The P1 port doc listed this as "the system
standard" under Deferred, and the owner noticed it.

The owner already accepted the system bar's glass and selection look. Only
the glyph size changed. The system bar, selection, badge, accessibility
labels, values and identifiers, the `.symbolVariants(.none)` pin and the hard
bottom scroll edge are all unchanged.

## Native routes tried (iOS 27.0 simulator, Xcode 27.0, iPhone 16e)

A temporary Debug-only switch built every route into one build, and each one
was captured from the scripted Home shell (`-AtumScripted home.roster`). The
switch was removed before the commit.

| Route on the tab label | Result |
| --- | --- |
| Bare `Image(name)` (P1, `main`) | 17 pt: unselected compass 41 x 41 px |
| `.font(.system(size: 24, weight: .light))` | Ignored. Pixel-identical to bare (41 x 41 px). |
| `.imageScale(.large)` | The bar drew **no glyphs at all**, in light and dark, in two runs. Only the badge remained. |
| `Image(uiImage: UIImage(named:).applyingSymbolConfiguration(.init(pointSize: 24, weight: .light)))` | **Honoured.** 58 x 58 px, the same as the pre-P1 bar. It is still a template vector symbol, so the system selection tint and dark mode apply. |
| Rasterised template bitmap at 24 pt | Honoured, with the same size. But it is no longer a symbol, so it would be soft in the large-content viewer. Rejected. |
| `UITabBarItem` / `UITabBarAppearance` | Not tried. The appearance API has no glyph size. Setting `item.image` from UIKit would fight SwiftUI's own item updates. The SwiftUI route above already works. |

## Fix

`ios/App/Shell/RootTabs.swift`: the label uses a new `tabIcon(_:)` helper. It
returns `Image(uiImage:)` of the custom symbol with
`UIImage.SymbolConfiguration(pointSize: kit icon.xl, weight: .light)`. If the
asset is missing it falls back to the old bare `Image(name)`. The Phosphor
symbolsets are Regular-M only, so the weight leaves the stroke unchanged. The
light look comes from the Phosphor Light paths. The weight is passed to
match the old bar's font.

## Measurements

These were measured with `/Volumes/AtumTestFlight/tabbar/measure.py`. It
gives the bounding box of the glyph ink in each tab cell of a 3x screenshot.
The compass and folder are clean unselected glyphs. The selected chat glyph
and the badged briefcase are boxed together with the selection capsule or
the badge, except where noted.

| Capture | Compass (unselected) | Folder (unselected) | Chat (selected) |
| --- | --- | --- | --- |
| Pre-P1 audit capture, iPhone 17 (`ux-audit/shots/02-home-top-light.png`) | 58 x 58 px | 58 x 46 px | 59 x 59 px |
| P1 audit capture, iPhone 17 (`ux-audit-p1/shots/p1-02-home-top-light.png`) | 41 x 41 px | 41 x 33 px | n/a |
| Before, `main` (`probe-none-light.png`) | 41 x 41 px | 41 x 33 px | 41 x 42 px (AX capture) |
| After, light (`after-final-light.png`) | 58 x 58 px | 58 x 46 px | 59 x 59 px (AX capture) |
| After, dark (`after-final-dark.png`) | 58 x 58 px | 57 x 46 px | n/a |
| After, AX-XXXL light / dark | 58 x 58 / 57 x 57 px | 58 x 46 px | 59 x 59 px |

A 24 pt symbol is 72 px at 3x, and the Phosphor compass circle covers about
80 % of its em, which gives 58 px. The fix matches the pre-P1 bar pixel for
pixel, in light and dark. The bar does not grow with Dynamic Type at
AX-XXXL, either before or after. That is the system tab bar's behaviour:
accessibility sizes get the large-content viewer instead.

All captures are in `/Volumes/AtumTestFlight/tabbar/`:

- Before: `probe-none-{light,dark}.png`.
- After: `after-final-{light,dark}.png` and
  `after-axxxxl-final-{light,dark}.png`.
- Every route: `probe-*.png` and `probe2-*.png`.
- Contact sheets: `sheet-before-after.png`, `sheet-probe.png` and
  `sheet-probe2.png`.

## Verification

- Locked Debug builds (`build.sh`, `-derivedDataPath
  /Volumes/AtumTestFlight/dd-tabbar`, simulator
  CB24FAE2-75F9-4E19-A856-0F5A9F036C0B), both exit 0:
  `/Volumes/AtumTestFlight/tabbar/baseline.log` (probe build) and
  `/Volumes/AtumTestFlight/tabbar/final.log` (this commit). No warnings in
  `RootTabs`.
- `python3 scripts/design_lint.py`: exit 0, with no new raw values. The size
  comes from the Kit token.
- No UI suites were run locally. Hosted shards cover `HomeShellUITests`,
  which queries the `phone.tab.*` buttons. The identifiers, labels and
  values are untouched.

## Open gaps

- The large-content viewer (a long press on a tab at accessibility sizes)
  was not exercised. It needs an XCUITest long press, and UI suites stay on
  the hosted shards. The image is still a vector template symbol, so the
  system can scale it there as it did before.
- Only iOS 27.0 was checked. The deployment target is iOS 26.0. The route
  depends on `UITabBar` keeping a symbol image's own point size, which is
  long-standing UIKit behaviour, but it was not checked on an iOS 26
  runtime.

## Session log

- 25 Nov 2026, UI sub-agent: branch `fix/tabbar-icon-size` from `main`
  `da3c208`, one local commit, no push, no PR, no CI.
