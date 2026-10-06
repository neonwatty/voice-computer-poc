# Codex desktop status feasibility

Observed October 5, 2026. The proposed Voice Computer route remains disabled.

## Read-only probe

The Codex desktop host reported task
`01a10209-1a33-70f0-bceb-48d5f868bfe0` as `active` on host `local`.
At `2026-10-05T18:38:29Z`, `scripts/probe_codex_status.py` called
`thread/read` with `includeTurns: false` against a separate app-server. It
returned the same exact task ID and source `vscode`, but runtime status
`notLoaded`. The probe mapped that to `unavailable_cross_process`, not to an
idle host task. A nonexistent exact UUID returned a `thread not loaded`
error and was mapped to `unknown_or_unavailable`.

The probe did not read turn content, create a chat, resume a task, or inspect
the desktop host UI. Its private JSONL records are under
`~/Library/Application Support/VoiceComputerPOC/SmokeRuns/`.

## Interface assessment

The [Codex app-server protocol](https://learn.chatgpt.com/docs/app-server.md)
documents `thread/read` for stored threads and says returned threads include
runtime status. It also documents `thread/loaded/list` as the IDs loaded in
memory by that app-server. The separate process is therefore a valid source
for its own loaded state, but this probe did not establish the desktop host's
live state. A host-only tool in this development chat can observe the active
task; no supported host-aware interface callable by Voice Computer was
identified in this tranche.

Title lookup is excluded: titles can be duplicate, stale, or user-controlled.
Only an exact task ID could support this capability. Since even the exact ID
failed the host-state comparison, an ambiguous-title probe would not improve
the decision.

**Decision:** keep Codex desktop status unsupported in Voice Computer. A
future route needs a documented interface that returns exact task ID, host,
runtime state, source, and observation time to the app itself, plus an
independent host comparison and an unknown-ID test.
