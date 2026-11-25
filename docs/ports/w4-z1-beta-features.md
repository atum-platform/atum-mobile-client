# W4-Z1 account beta features

`LiveAppModel.betaFeatures` is the observable Boolean for Team Space, Store
hires and skills, and Researcher hire. Platform #946 supplies the value on
native `GET /api/matrix/v1/me` for operator-assigned internal principals. The
UI can use the flag for presentation. The platform authorizes each action.

First sign-in, domain retry and reauthentication reuse the `/me` response
already verified during Matrix and domain account binding. Session restore
reads the same route through `NativeDomainClient.me(for:)` and checks the
issuer, subject and principal against the Keychain-restored binding. The read
runs alongside product startup.

As in desktop #132, the app loads the last answer for the active account and
keeps it if the request or binding check fails. A successful false answer,
including an omitted field on an older server, replaces a cached true.
The cache holds one Boolean per Matrix user ID, keyed by its full SHA-256
digest in local defaults. Sign-out clears the active flag and account
replacement loads the new account's entry, with false as the default. The
account scope and domain client checks discard replies from retired sessions.

## Verification

- `OIDCTests` covers true, false and absent on the existing decoder.
- `OIDCSignInTests` checks sign-in's existing request and tests the restored
  client's exact route, bearer and principal check.
- `AccountBetaFeaturesTests` covers relaunch, failure retention, revocation,
  sign-out, account separation and late replies.
- Run the Swift package suite and the app's Debug build-for-testing under the
  shared TestFlight lock. Run the public guard and design lint independently.
