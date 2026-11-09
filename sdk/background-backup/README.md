# Background backup test packs

These Apache-2.0 SDK patches are unselected. Apply the custody, lease-fence,
lease-binding, live-lease, protected-tasks and publication-cancellation chain
to the pinned upstream revision. The baseline branch applies baseline.patch;
the correction branch independently applies operation.patch then renewal.patch.
Do not apply operation.patch on top of baseline.patch.

`public-acceptance.json` binds the public patch hashes and source postimages
to Cargo 1.96.0 acceptance: one stale-ack baseline test, four operation/renewal
tests and fifteen upstream backup controls passed using encrypted SQLite and
loopback MockServer HTTP. The room keys are fresh synthetic v1 exported Megolm
fixtures, generated with scripts/public-megolm-fixture.

Run `cargo test --locked -j 2 -p matrix-sdk --no-default-features --features
e2e-encryption,bundled-sqlite --lib` with the selectors recorded in the receipt.
This is source/test acceptance only. It does not select a runtime SDK, prove
physical iOS/NSE behavior or grant release authority. Historical private logs
and reviews do not establish acceptance of these public bytes.
