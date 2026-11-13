# People search by handle

The phone sent a raw query (including a leading at sign) to the Matrix directory,
then only tagged an alias assignment if the directory already returned that user.
It also returned early on directory failure. This prevented discovery of new
accounts outside the directory's visible set while typing in Add friend or the
New group picker.

Reference: desktop `apps/desktop/electron/matrix/main-people-search.ts`,
`handleMatrixPeopleSearch`, read from origin/main. The phone now strips one leading
at sign, requires at least two remaining characters, and uses
`HomeAddFriendPolicy.handle` and `NativeDomainClient.aliasLookup` for exact lookup.
Only assigned human identities with a Matrix user qualify. Own user and known
non-people are excluded. An absent exact hit is inserted first; a matching row is
tagged without duplication and keeps its directory name and avatar. Alias-only
hits use the public handle as their name, avoiding an extra profile round trip.
Lookup failure preserves directory results; directory failure preserves an exact
hit. Results retain the phone's existing thirty-row bound and session/cancellation
fences. The shared helper accepts transport closures for focused failure tests.

Email alias search was skipped: the phone domain client has lookup, check, current,
claim and rename endpoints, but no email-search endpoint. No endpoint was added.
No SwiftUI views or layout changed. Home global search could gain inline people
results as a separate UI parity task; the existing Add friend and New group search
already receive this fix through the shared model method.

Verification: eight focused app-unit tests cover insertion, matching-row profile
preservation, independent transport failures, leading at sign, own-user exclusion,
all non-human kinds, and minimum length. Build and final guard results are recorded
below before the local checkpoint. Coordinator owns integration and any review;
this worker does not push, open pull requests, or change CI.

## Local verification result

- `git diff --check`: pass.
- Locked Xcode test attempt: app and test bundle compiled successfully; runner
  startup stalled after installation, with no test cases reported. Stopped the
  attempt after roughly fourteen minutes. Test counts: zero executed, zero
  reported failures; eight tests remain pending execution by the coordinator.
- Command: `TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`
  wrapping `xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
  -derivedDataPath /Volumes/AtumTestFlight/dd-people-search -jobs 2
  -parallel-testing-enabled NO -only-testing:AtumMobileTests/PeopleHandleSearchTests test`.
  The actual run selected the same simulator by ID. The batch trapped exit to
  run `xcrun simctl shutdown all` before releasing the lock.
- Public outbound preflight: pass for the staged candidate (one candidate commit,
  no leaks or boundary violations).
