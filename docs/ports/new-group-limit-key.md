# New-group member-limit copy

The member-limit notice now uses the producer's existing `src.matrix.group-picker-copy.copies.block.full` key. The previous key was absent from the catalog and caused the strict copy lookup to stop the app. No design resources or producer pin changed.

The regression check scans shipped Swift copy literals against both pinned resources and retains the existing guarded pending-key exceptions. It passes all three cases. Local validation also passed: public Megolm vectors, design verification, eight importer tests, push fixture verification, two push projection tests, Swift package parse/resolve, native project parse and 500 Swift package tests. The checks used the existing package and import mechanisms; no new dependency or framework was added. Native simulator/device execution remains separate from package validation.

State: implemented and verified locally; publication remains pending.
