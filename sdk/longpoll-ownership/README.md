# Long-poll and owner-device SDK candidate

This unselected source authority extends the pinned Matrix Rust SDK revision
recorded in `source.json`. It combines the previously verified multi-process
long-poll ownership correction with the two narrow FFI capabilities needed by
Atum's owner-device enrollment:

- expose the exact peer device ID and Matrix flow ID already bound to the active
  SAS verification; and
- recover with the server-current default key while checking an expected key ID
  before recovery and detecting default-key rotation afterward.

The app's normal dependency remains unchanged. The candidate may be consumed
only through the repository's explicit unselected Apple build and receipt
verifiers. `source.json` pins every upstream file, both modified-file preimages,
the resulting prototype hashes, the complete patch and the Apache notice.

The recovery API returns private key material only because the caller must place
the SDK-validated current root in device-only Keychain custody. Callers must not
log it, expose it to UI, sync it, or persist it outside that boundary.

## Mobile verification boundary

The generated `flowDetails()` binding reads the active verification request and
retains the same Matrix flow ID while that request transitions into SAS. Its
peer device comes from the request/SAS object; the iOS adapter pins the first
valid `(flow ID, device ID)` pair and refuses any later mismatch.

For a locally-created outgoing request, the SDK initially reports `Created` and
does not know which owner device will answer. `flowDetails()` therefore returns
no value until the request reaches `Ready` (or SAS). The iOS adapter treats only
that pre-peer observation as pending; it still rejects malformed or competing
details and requires a pinned pair before showing or confirming SAS data.

For encrypted recovery grants, the iOS adapter accepts `shieldStateStrict ==
.none` only. In the pinned upstream source inventoried by `source.json`,
`VerificationState::to_shield_state_strict()` maps only
`VerificationState::Verified` to `ShieldState::None`; every unverified state is
red. The FFI callback is converted synchronously to a primitive `Sendable`
snapshot before crossing into the main actor, so the generated message object
does not cross that concurrency boundary.

`recoverWithDetails()` checks the current key ID before and after recovery and
zeroizes its mutable Rust input. Swift `String` storage cannot promise physical
zeroization, so the consumer deliberately keeps recovery-key strings out of UI,
diagnostics and long-lived model state, validates a maximum of 128 UTF-8 bytes,
and immediately replaces the value with device-only Keychain custody after SDK
validation. No stronger Swift-memory erasure claim is made.
