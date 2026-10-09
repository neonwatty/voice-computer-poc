# Desktop tool capability inventory

Status: October 6, 2026. Speech input and Foil integration are deferred while
desktop actions and unattended testing are validated.
The [first capabilities plan](next-capabilities-plan.md) covers the completed
Browser and Finder slices and Codex desktop status feasibility. The
[tranche 2 plan](desktop-capabilities-tranche-2.md) covers one composed request,
read-only desktop state, and repeatable machine tests.
The [tranche 3 plan](desktop-capabilities-tranche-3.md) covers existing Safari
and Finder windows, routine exact-build Mac testing, and a separate Codex
host-status feasibility gate.
The [tranche 4 plan](desktop-capabilities-tranche-4.md) covers the PR Mac-test
gate, Safari/Finder CUA failure paths, and a bounded TextEdit document workflow.

## Current paths

| Request or observation | Computer Use | App-local native path | `desktop_tool` MCP | Current evidence |
| --- | --- | --- | --- | --- |
| Read a visible app window, click controls, enter text | Yes, with access to that app | No | No | Calculator `9 × 7 =` displayed `63` in an unattended app-server smoke run on the Mac Mini. |
| Open Calculator and verify it is frontmost | Can operate its window; a CUA action alone did not establish foreground focus | App requests Launch Services activation after a completed CUA call and checks macOS focus | No | The Mac Mini observed `com.apple.calculator` frontmost after the handoff. |
| Inspect Mission Control desktop controls | CUA targeting Mission Control/Finder did not expose usable thumbnails on either test Mac | Read-only Accessibility scan of `WindowManager` on macOS 27, Dock on older versions | No | Unattended case 13 has found two controls with live Space ID 5 unchanged, but it is intermittent when another app takes focus as Mission Control opens. It remains a fail-closed optional gate for Space control tests. |
| Switch one desktop Space | CUA Control-Arrow and Mission Control attempts did not produce a verified change | Exact phrases use one bounded Accessibility press and verify the expected live ID plus Space notification | `switch_space(direction: right\|left)` uses the same app-owned action via an authenticated bridge and visible Allow once approval | One unattended MCP right-left pair verified 5 → 6 → 5 on the Mac Mini. |
| Route other typed requests | UI can act after the request is selected | Isolated router permits Space, Calculator, local Browser and Finder fixtures, one composed Browser → Finder fixture, two exact TextEdit note fixtures, or clarification | Space switching and desktop-state reading are exposed | Router corpus v7 passed 273/279 trials (97.8%) with six misses and zero wrong direction or clarification actions. Production preflight rejects an existing new-note destination before acting. Supported actions remain narrow. |
| Navigate local Home → Docs | Safari Computer Use can open a loopback fixture, click Docs, and expose the final URL and heading | Route validator accepts only the exact fixture grammar; a bounded Safari Accessibility read matches the exact Docs URL and heading before the app reports `verified` | No Browser MCP tool | The strict Browser → Finder suite passed with app-owned and outer Safari evidence. Focused missing-link, 404, and local-redirect negatives returned app-owned `unverified`, matched fixture requests and rendered Safari state, and kept the Space unchanged. |
| Preserve an existing Safari tab | Computer Use opens a new run-specific tab in a test-owned window | App verifies the exact Docs URL and heading; the outer runner correlates the sentinel tab and window UUID before and after cleanup | No Browser MCP tool | Focused case 21 passed three positive runs, missing-link, 404, redirect, Stop, and a two-window decoy run. Three exact-SHA full suites passed with independent Safari window inventory and unchanged Space. A later large unrelated Safari page exposed the app verifier's 400-node scan bound; pruning nonmatching web areas and using `super+n` to create the fixture window produced another focused pass. The updated full suite is pending. |
| Stop Browser before Docs | The acting Safari turn is interrupted through the app's Stop button | Test fixture holds Home while a harness Accessibility helper presses Stop on the exact app PID | No MCP action | The exact-app case recorded an interrupted, unverified result, one Home request, zero Docs requests, and unchanged Space 5. |
| Submit local Docs form | Safari Computer Use enters the run-specific test query and clicks Submit once | Exact route grammar and Safari Accessibility check require the submitted URL and heading | No Browser MCP tool | The focused form case matched one Docs request, one exact submission, app-owned and independent Safari evidence, and unchanged Space 5. |
| Reveal a fixture file in Finder | Finder Go to Folder selected the exact report beside a similarly named decoy | Existing `Show File` action can open a Finder window; a bounded Finder Accessibility read requires the exact selected report URL and visible decoy | No Finder MCP tool | The strict suite matched app-owned and outer selected-file evidence, fresh command ID, and unchanged Space. Missing-file, symlink-escape, and decoy-target runs rejected the request without an acting turn. Every fixture was removed. No Finder MCP action is needed for this slice. |
| Reuse an existing Finder window | Computer Use reveals the report in a test-owned window prepared before the command | The app checks exact selection; the outer runner joins Finder's numeric window ID with prepared and acted Accessibility states | No Finder MCP tool | Focused case 22 passed three positive runs, a two-window decoy run, and missing-file, symlink-escape, and decoy-target rejections. Three exact-SHA full suites passed with the same Finder window ID and restored window inventory. With zero Finder windows, CUA returned `cgWindowNotFound` before setup; the harness now opens one run-owned fixture window before the agent observes and reuses it. The updated full suite is pending. |
| Complete Browser → Finder in one request | Separate Safari and Finder Computer Use turns act within one app command | The app verifies the exact Docs URL and heading before queuing Finder, then verifies the selected report; Stop prevents the second step | No Browser or Finder MCP action | Case 19 passed with one command, two ordered turns, app-owned Accessibility checks, independent Safari/Finder observations, exact HTTP requests, and unchanged Space. Missing link, 404, redirect, and Stop produced no Finder turn; unsafe file targets started neither actor. A later empty-Finder run failed before the second actor could bind; the positive harness now prepares a run-owned Finder window when needed, and a focused composed run passed with two verified turns. General headless Finder bootstrap remains a product capability to investigate. |
| Read current desktop state | CUA can inspect a visible app but cannot authoritatively report live Main Space IDs | The app takes a coherent native snapshot without changing Space or focus | `get_desktop_state({})` returns typed Main Space IDs, frontmost bundle ID, and observation time after visible Allow once | Case 20 agreed with an independent macOS observer on both Main Spaces; the full suite read state before and after a 5 → 6 → 5 pair. Synthetic ambiguous-topology and incomplete-read cases return non-success. |
| Save and reopen a run-owned TextEdit note | Computer Use edits the exact existing draft, saves through TextEdit, then the outer runner closes and reopens the same file through UI | Route safety binds one canonical fixture path and exact text; native verifier requires exact bytes, document URL, and visible text in one window | No TextEdit MCP action | PR #16 merged after its exact-head ten-case Mac suite passed. Focused prepared-window, decoy, route rejection, Stop, CUA failure, and verifier-failure cases also passed. |
| Create and reopen a run-owned TextEdit note | Computer Use creates a plain-text document, types through TextEdit, saves through its Save sheet, then closes and reopens it | Exact grammar requires an absent `note.txt` in a run-owned directory; the verifier requires exact bytes, document URL, and visible text | No TextEdit MCP action | Two focused positive case 24 runs passed with exact bytes, close/reopen evidence, and restored windows and Space. A focused canceled Save showed the sheet, left no note, returned `unverified`, and restored windows and Space. The new exact-head suite is pending. |
| Read existing Codex task state | The nested CUA session cannot inspect the Codex host UI | Separate app-server `thread/read` returned the exact task ID but `notLoaded` for a host-active task | No Codex status MCP tool | Cross-process status is unsupported; the [feasibility report](codex-host-status-feasibility.md) compares a host-active ID with a fresh read-only probe. |
| Record/transcribe speech | No | Local recording and transcript review exist | No | Deferred; no speech-to-action acceptance claimed. |

The exact Space phrases currently bypass MCP, while `agent switch desktop space
right/left` invokes it. Both ultimately call the same app-owned Space action.
Keeping this distinction visible is important when attributing a test result.

The exact-SHA Mac runner passed its ordered nine-case suite three times on
`52b8e7edc9993089883bd5da9aa6f2e2dce13a5b`, the tested head of merged
PR #14. The app retries read-only desktop-tool discovery once if the first
nested turn lacks its tool and retries unavailable isolated router output once
before an actor starts. The app and harness reject an outdated Codex CLI model
catalog. The owner-attested PR trigger checks an exact reviewed head and green
CI/CodeQL, then posts a redacted commit status. PR #15 passed the full suite
and posted `Voice Computer / desktop suite` success on its exact SHA before
merge; a wrong-SHA dispatch was rejected before running. PR #16 passed its
ten-case exact-head Mac suite, and the active `Protect main` rule (ID 24084858)
now requires `Build and test`, `Analyze Swift`, and `Voice Computer / desktop
suite`. A pending Mac status blocked PR #16 until the same head passed.
Focused Debug case 21, 22, and 23 synthetic inner-CUA failure runs passed with
app-owned `tool_failed` results, independent sentinel/window cleanup evidence,
unchanged fixture bytes, and unchanged Space. They exercise the app's failure
classification, not a real remote CUA service outage.

## Next capabilities to build and validate

1. Complete new-document Save/Cancel coverage and run its eleven-case exact-head
   suite through the active Mac merge check.
2. Keep Codex host-task status deferred until a supported host-aware interface
   is available.

The [tranche 2 plan](desktop-capabilities-tranche-2.md) records the contracts
and acceptance evidence. Keep Calculator arithmetic as a Computer Use fixture.

Do not add a general shell, arbitrary keystroke, or unrestricted app-control
MCP tool. Each MCP action should have a typed schema, one bounded effect,
explicit approval where acting, and independent observation before it reports
success.

## Where MCP is useful

Computer Use is suitable for app UI tasks whose target and result are visible
through Accessibility or a screenshot. The observed gaps on these Macs are
reliable desktop Space selection, authoritative live Space state, and confirmed
foreground activation. The current MCP Space tool addresses selection, and the
read-only tool addresses state. Computer Use can continue to operate
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
