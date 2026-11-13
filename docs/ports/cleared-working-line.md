# Cleared working lines

Port of desktop PR #42, main 4a967f53c3 (13 November 2026), specifically
matrix-transient-lines.ts and matrix/message.ts. The pinned Swift SDK exposes
LazyTimelineItemProvider.debugInfo().originalJson. Parse its persisted
unsigned.redacted_because sender and content.reason: only an original sender's
exact `Turn ended` redaction sets ChatItem.redactedAsEndedTurn. Hide that
redacted item for any non-own sender, including cloud agents absent from the
known-agent list. As on desktop (`matrixHideEndedTransientLines`), any
redaction by a listed agent still shows nothing, whatever its reason. Other
redactions (people, unlisted senders without the reason) keep their
placeholder.

Desktop room-preview.ts previewOf still returns `deleted` for all redactions;
RowPreview therefore remains unchanged for parity. The phone has no progress
publisher/cleanup path; SDKTimelineSource.redact is a user deletion with nil
reason and stays that way. No views or layout changed.

Tests cover cloud and known agents, absent/other reason, another redacter,
owner visibility, malformed JSON, and the existing projection behavior.

Coordinator fix (13 Nov): the first cut also made a listed agent's redaction
without the reason show a placeholder, and edited two existing tests to fit.
Desktop still hides every listed-agent redaction, so that rule and both tests
are restored; the new test asserts it.

Verification (coordinator, under the shared build lock, 13 Nov):
- `swift test --package-path ios -j 2 --filter AtumChatTests`: 726 executed, 0 failures.
- `xcodebuild build -jobs 2` (AtumMobile, Debug, generic iOS Simulator): BUILD SUCCEEDED.

Not verified live: a cloud agent's cleared line after a reload on a device.
