# Device scope

Atum v1 ships for **iPhone only** (`TARGETED_DEVICE_FAMILY = 1` for the app, its notification
extension and the test bundles). Owner decision, 2026-11-10.

- On iPad the App Store offers the app in iPhone compatibility mode; no iPad layout is reviewed or
  promised for v1, so App Store Connect needs no iPad screenshots.
- A native iPad version (wider layouts, the side panel's trailing column "M1b") is later work. To
  re-enable it, set the family back to `1,2` in `ios/project.yml`, regenerate the project, and add
  iPad screenshots and layout review before submission.
