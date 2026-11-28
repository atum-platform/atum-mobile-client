# W4-AC2 phone desk and model picker

Parity target is [desktop #147](https://github.com/atum-platform/atum-desktop/pull/147). The phone uses the existing native reads and model write contracts.

- `AgentDeskModel.swift:25` publishes separate schedule and files states for unsupported, loading, empty, ready, failed and retrying. `listFolder` (line 123) preserves the confirmed path while a requested folder loads or fails, and `retryFiles` retries the failed path. `readSchedule` (line 169) retains the existing busy retry and control reconciliation. Pause stays visible for the hosted route and can be used once a nonempty schedule is confirmed.
- `AgentDeskLive.swift:18` reuses the transport and completion fences for each request. Account generation, client identity and the current Hermes principal must still match. Closing the desk cancels its tasks and their cooldown retries.
- `LiveAppModel.swift:402` and `ModelChoice.swift:81` reuse the per-agent W4-T store, revision settlement and idempotent replay. The composer observes the submitted choice. The W4-X load and consent tokens still retire on dismissal, while an already submitted write can finish, read back a conflicting snapshot and revalidate ChatGPT consent before retrying. An ambiguous destination write gets one server readback while the replay key remains available. The chip and reopened picker follow authoritative snapshots as they settle.
- Tests cover independent desk retries and empty results, cached folder continuity, stale desk replies, and a submitted picker choice surviving dismissal through conflict readback and consent revalidation. A transport-failure test checks that the pending chip yields to the server's choice. The store uses SwiftUI Observation on iOS and retains the package's macOS 13 compatibility.

The UI handoff is in `AgentDeskPage.swift:34`, `:177` and `:292`. Once W4-C9 updates the pin, use the exported `nothingScheduled`, `scheduleUnavailable`, `noFiles`, `filesUnavailable` and `tryAgain` keys, update the pin coverage, and apply the Opus row and status treatments. The current page uses the existing pinned Pause, Files and generic retry labels, with temporary English status strings borrowed from desktop.

## Review fixes

- A 1.1 pick carries the destination revision from submission. The picker and composer reconcile its receipt against the latest destination before publishing Current. An overlapping read can replace a write receipt only when the server response has a strictly higher revision.
- The composer marks a submitted name as Saving or Reconciling with pinned copy and no provider mark. Both pickers suppress Current until settlement. A lost reply and failed readback keep the name pending. A fresh authoritative read or an idempotent replay can settle it. A scripted UI test holds the write while the picker closes and the composer sends a message.
- The desk's navigation destination now has a view identity keyed by principal and account generation. A hosted SwiftUI test changes both while staying in one room. A separate host-state test holds a failed folder's retry until navigation to another folder completes.

Review fixes passed 257 focused Swift package tests, 13 standalone macOS desk host-state tests and seven copy-pin checks. The iOS AppTests and focused UI suites run under the shared simulator build lock.

The first locked Debug build caught assignments inside the SwiftUI result builder for the pending chip. Its display state now resolves before the view builder runs. The second build compiled the app and caught a nested test fixture whose observation macro needs file-level access.
