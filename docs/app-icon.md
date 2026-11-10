# iPhone app icon

`ios/App/Assets.xcassets/AppIcon.appiconset/atum-app-icon-1024.png` is the Atum eclipse mark, rendered from `ios/brand/atum-app-icon-ios.svg`.

- **Source:** public `atum-platform/atum-desktop` `apps/desktop/assets/icon-mac.svg`, with two changes for iOS. The tile is full-bleed and opaque, because iOS applies its own corner mask. The mark is scaled by 1024/832, so it keeps its proportion on the macOS tile.
- **History:** this replaced the placeholder square from the initial public snapshot on 2026-11-10.
- **Regenerate:** render the SVG at 1024×1024 (headless Chrome was used), then flatten it to an opaque PNG, for example `magick in.png -background '#100F0D' -alpha remove -alpha off PNG24:out.png`. App Store Connect rejects an app icon with an alpha channel.
