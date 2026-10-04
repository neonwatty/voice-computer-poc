# Desktop tool capability inventory

Status: October 4, 2026. Speech input and Foil integration are deferred while
desktop actions and unattended testing are validated.
The [next-capabilities plan](next-capabilities-plan.md) covers Browser, Finder,
and Codex desktop status work.

## Current paths

| Request or observation | Computer Use | App-local native path | `desktop_tool` MCP | Current evidence |
| --- | --- | --- | --- | --- |
| Read a visible app window, click controls, enter text | Yes, with access to that app | No | No | Calculator `9 × 7 =` displayed `63` in an unattended app-server smoke run on the Mac Mini. |
| Open Calculator and verify it is frontmost | Can operate its window; a CUA action alone did not establish foreground focus | App requests Launch Services activation after a completed CUA call and checks macOS focus | No | The Mac Mini observed `com.apple.calculator` frontmost after the handoff. |
| Inspect Mission Control desktop controls | CUA targeting Mission Control/Finder did not expose usable thumbnails on either test Mac | Read-only Accessibility scan of `WindowManager` on macOS 27, Dock on older versions | No | Unattended case 13 has found two controls with live Space ID 5 unchanged, but it is intermittent when another app takes focus as Mission Control opens. It remains a fail-closed optional gate for Space control tests. |
| Switch one desktop Space | CUA Control-Arrow and Mission Control attempts did not produce a verified change | Exact phrases use one bounded Accessibility press and verify the expected live ID plus Space notification | `switch_space(direction: right\|left)` uses the same app-owned action via an authenticated bridge and visible Allow once approval | One unattended MCP right-left pair verified 5 → 6 → 5 on the Mac Mini. |
| Route other typed requests | UI can act after the request is selected | Isolated router permits Space, Calculator, a local Browser fixture, a Finder fixture report, or clarification | Only the Space action is exposed | Router corpus and local tests pass; supported actions remain narrow. |
| Navigate local Home → Docs | Safari Computer Use can open a loopback fixture, click Docs, and expose the final URL and heading | Route validator accepts only the exact fixture grammar; a bounded Safari Accessibility read matches the exact Docs URL and heading before the app reports `verified` | No Browser MCP tool | The strict Browser → Finder suite passed with app-owned and outer Safari evidence. Focused missing-link, 404, and local-redirect negatives returned app-owned `unverified`, matched fixture requests and rendered Safari state, and kept the Space unchanged. |
| Reveal a fixture file in Finder | Finder Go to Folder selected the exact report beside a similarly named decoy | Existing `Show File` action can open a Finder window; a bounded Finder Accessibility read requires the exact selected report URL and visible decoy | No Finder MCP tool | The strict suite matched app-owned and outer selected-file evidence, fresh command ID, and unchanged Space. Missing-file, symlink-escape, and decoy-target runs rejected the request without an acting turn. Every fixture was removed. No Finder MCP action is needed for this slice. |
| Read existing Codex task state | The nested CUA session cannot inspect the Codex host UI | Separate app-server `thread/read` returned the exact task ID but `notLoaded` for a host-active task | No Codex status MCP tool | Cross-process status is unsupported; `scripts/probe_codex_status.py` records this without reading task turns. |
| Record/transcribe speech | No | Local recording and transcript review exist | No | Deferred; no speech-to-action acceptance claimed. |

The exact Space phrases currently bypass MCP, while `agent switch desktop space
right/left` invokes it. Both ultimately call the same app-owned Space action.
Keeping this distinction visible is important when attributing a test result.

## Next commands to build and validate

1. **Read-only desktop state:** `get_desktop_state` should return the live main
   Space ID, ordered main desktop IDs, frontmost bundle ID, and observation
   status. It should omit window titles, screenshots, and unrelated app data.
   Validate it against an independent macOS observer on both Spaces, including
   unavailable and multi-display cases. This is the most useful next MCP tool:
   an agent can check a precondition and verify a move without guessing from a
   visual change.
2. **One allowlisted app activation:** `activate_app` should accept a small
   enumerated target set, starting with Calculator and Finder, and return the
   observed frontmost bundle ID. Validate activation from another app, an
   already-frontmost target, and a missing target. Reuse the existing macOS
   focus observation. Expose Voice Computer only if a real request needs it;
   the app's own test handoff already handles its foreground requirement.
3. **Existing Space action:** Repeat unattended right-left MCP pairs from a
   verified two-Space starting state. The first pair passed on October 3.
   Require separate Allow once approvals, exact tool items and command IDs,
   one AX press per step, Space notifications, typed `verified` results, and
   independent IDs 5 → 6 → 5. Stop on the first failure. Then test a boundary
   `no_adjacent_space` result without an AX press.
4. **UI action fixture:** Keep Calculator arithmetic as a Computer Use test,
   with a fresh visible result. Add a small disposable in-repo UI fixture only
   when a text-entry or multiwindow test needs repeatable state; avoid writing
   into personal documents for a smoke test.

Do not add a general shell, arbitrary keystroke, or unrestricted app-control
MCP tool. Each MCP action should have a typed schema, one bounded effect,
explicit approval where acting, and independent observation before it reports
success.

## Where MCP is useful

Computer Use is suitable for app UI tasks whose target and result are visible
through Accessibility or a screenshot. The observed gaps on these Macs are
reliable desktop Space selection, authoritative live Space state, and confirmed
foreground activation. The current MCP Space tool addresses selection; the two
proposed tools address state and focus. Computer Use can continue to operate
Calculator, text fields, and ordinary app controls. A tool should be added to
MCP when repeatable execution and OS-level verification matter, not merely
because a UI action takes several clicks.

## Unattended test ladder

1. **Static gate:** format, Swift and Python tests, router corpus, helper
   bundle/hash check, and CI/CodeQL on the exact commit.
2. **Machine preflight:** require an unlocked console, one running app process
   from the exact tested bundle, a matching bundled helper, accessible window,
   and a fresh private log. Capture the live Space state before acting.
3. **Read-only run:** case 13 in `scripts/smoke_app_server.py` checks the app's
   Mission Control scan and proves the live Space ID did not change. The Mac
   Mini passed unattended on October 3 with command
   `0C09F9D8-D8E9-4A3A-A030-F1D55FDCD5C1` and two controls.
4. **One bounded action, then pair:** run case 15 once with
   `--single-mcp-step` for diagnosis, or cases 15 and 16 as a complete pair
   once the read-only gate passes. The driver grants CUA access only to the
   exact app, stops on an unverified step, and checks independent live Space
   IDs and command-correlated app JSONL. A visible inner MCP Allow once decision
   remains part of each test. The first unattended pair passed on October 3:
   command `BA729AE8-B9B2-4DB6-94E2-DC8D019FA4DD` moved 5 → 6 and command
   `CF45A32D-679D-493E-9C0B-BF067603CB92` returned 6 → 5. The app rotates
   its app-server after each MCP Space step because Codex can keep earlier
   helper processes alive; the bridge continues to require one matching helper
   child per server session.
5. **UI fixture:** run Calculator case 2 and independently read its displayed
   result. Keep receipts under `~/Library/Application Support/VoiceComputerPOC/`
   with owner-only access; logs can contain app names and errors. Share only
   summarized IDs and status unless a full log is specifically needed.

The app's command result, agent text, and CUA output are useful diagnostics,
but a hardware action passes only when its independent macOS observation and
typed tool result agree. The driver must fail closed on missing correlation,
multiple app processes, changed Space order, a lock, or an unexpected target.
