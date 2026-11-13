# Cleared working lines

Port of desktop PR #42, main 4a967f53c3 (13 November 2026), specifically
matrix-transient-lines.ts and matrix/message.ts. The pinned Swift SDK exposes
LazyTimelineItemProvider.debugInfo().originalJson. Parse its persisted
unsigned.redacted_because sender and content.reason: only an original sender's
exact `Turn ended` redaction sets ChatItem.redactedAsEndedTurn. Hide that
redacted item for any non-own sender, including cloud agents absent from the
known-agent list. All other redactions retain their placeholder.

Desktop room-preview.ts previewOf still returns `deleted` for all redactions;
RowPreview therefore remains unchanged for parity. The phone has no progress
publisher/cleanup path; SDKTimelineSource.redact is a user deletion with nil
reason and stays that way. No views or layout changed.

Tests cover cloud and known agents, absent/other reason, another redacter,
owner visibility, malformed JSON, and the existing projection behavior.
Verification results are recorded below after the shared build lock clears.

Verification: `git diff --check` passed. The public outbound guard passed
against a temporary commit object of the staged patch before the final commit.
Both mandatory locked commands were queued for over ten minutes behind another
worker's UI run, produced no output, and were cancelled before execution:

- `swift test --package-path ios --scratch-path <external-volume>/build-cleared-working-line -j 2 --filter AtumChatTests`: 0 executed; pending.
- `xcodebuild build -jobs 2 -project ios/AtumMobile.xcodeproj -scheme AtumMobile -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO` with external DerivedData and shared SPM cache: pending.

Coordinator must run both under the mandatory shared lock before integration.
No live cloud/redaction reload verification was performed. No SDK fork, CI,
push, PR, SwiftUI, Store, or people-search changes were made.
