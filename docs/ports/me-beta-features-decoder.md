# `/me` accepts `betaFeatures` (platform #946)

## What changed
- Platform #946 (merged 25 Nov 2026) adds `betaFeatures: Bool` to the native
  `GET /api/matrix/v1/me` response. It is true for an internal-audience account
  and drives desktop #132's beta gate (Team Space, Store hires and skills, and
  Researcher hiring show "Coming soon" without it).
- `OIDCMe` decodes with a closed field set, so any build without this change
  rejects the new response with `ContractViolation.unknownField`. That breaks
  sign-in and reauthentication as soon as the platform serves #946.
- `OIDCMe` now accepts `betaFeatures` as an optional Bool (absent means false)
  and exposes it. Every other unknown field is still rejected.

## Not in this change
- The phone doesn't apply the beta gate yet. Publishing one account-scoped flag
  and gating Team Space, the Store and the Researcher hire is the W4-Z lane
  (tracker atum-platform/atum-mobile#47).

## Verification
- `OIDCTests.testThreeWayVerifiedBindingAndDomainIndependence` covers the field
  being absent, true and false, binding with it present, a wrong type and an
  unrelated unknown field. Run on hosted CI (`swift`); the local build lock was
  held by another lane.
