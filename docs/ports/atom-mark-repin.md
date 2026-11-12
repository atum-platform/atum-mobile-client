# Repin: the Kit working atom (schema 2)

Date: 2026-11-12. On the wave 3 TestFlight build (`5018d28`), the owner saw that the working
row in the assistant chat drew the old three-orbit atom, while desktop draws the
single-orbit Kit atom (one ring, a centre dot, one orbiting dot).

- Cause: atum-desktop's mobile export still carried the schema 1 `marks/atom.json`. The phone
  draws whichever schema the pin carries (`ios/App/Chat/Views/AtomMark.swift`).
- Upstream fix: atum-desktop #37 (merged as `4f193a16e`, both required checks green on its head `39e702e`) exports the schema 2 mark, byte-identical to the producer's
  output and matching desktop's `atum-atom.css` (radius 10.5/24, nucleus 15%, electron
  13% / at least 2.25 px, rest at −45°, one linear clockwise turn per 1600 ms, static under
  Reduce Motion).
- This repin: `atum-design.lock`, `ios/Vendor/AtumDesign/manifest.json` and
  `ios/Vendor/AtumDesign/marks/atom.json` only. No Swift change: `AtomWait` already draws
  schema 2.
- Verification: `scripts/import-design-exports --verify`, `test_import_design_exports`,
  `test_native_catalog`. `test_copy_keys_in_pin` already fails on main `5018d28` without this
  repin (pending rekey cases), so it is not affected by this change.
