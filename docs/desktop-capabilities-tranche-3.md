# Desktop capabilities, tranche 3

Status: planned October 5, 2026. Start from merged `main` at `db494e5`.
Speech input and Foil integration remain deferred.

## Goal and baseline

Make Voice Computer reliable when Safari and Finder already have windows open,
then make its Mac desktop tests routine for each reviewed build. Investigate a
supported way for Voice Computer to read Codex desktop task status, but do not
enable that route unless the probe can observe the host's actual state.

The current exact-build suite `20, 17, 18, 19, 15, 16, 20` passed on the Mac
Mini. It verifies local Safari navigation, Finder selection, one composed
Safari-to-Finder request, read-only desktop state, and an approved Space pair.
Its fixtures are disposable and the final Space matched the starting Space.
Current Safari instructions always create a new tab; the Finder smoke test
opens a fixture window. Neither proves behavior around pre-existing context.
The machine suite is run explicitly on the unlocked Mac, while hosted CI covers
tests that do not require desktop access.

Keep the existing split: Computer Use performs visible UI work; the app owns
route validation and independent Accessibility verification; `desktop_tool`
provides typed macOS Space actions and state. A new MCP action needs a measured
failure of this split and a narrowly bounded contract.

## Work package 0: freeze the baseline

1. Record exact source SHA, build results, bundled helper hash, app path and
   PID, process start time, macOS version, Accessibility trust, unlock state,
   frontmost bundle ID, and Main Space topology. Require one running copy of
   the exact app and a clean source tree.
2. Run static tests, router evaluation, and the existing focused Browser,
   Finder, composed, and desktop-state cases. Keep intermittent Mission
   Control case 13 as an optional diagnostic.
3. Inventory open Safari and Finder windows read-only. Tests create and
   identify their own context rather than adopting unrelated user content.

**Gate:** the baseline suite passes on one exact build, ends on its starting
Space, and removes its fixtures. Diagnose any regression before adding routes.

## Work package 1: Safari tab lifecycle in existing windows

Keep the current loopback Home-to-Docs route and expand its test conditions
before broadening accepted websites. The runner creates a test-owned Safari
window with a sentinel tab and records its window and tab state. It submits
one Voice Computer command. Computer Use opens a fresh run-specific tab,
follows Docs once, and leaves earlier tabs untouched. The app continues to
require the exact Docs URL and heading before reporting `verified`.

Add focused case 21:

| Scenario | Required observation |
| --- | --- |
| Existing window and one sentinel tab | New run-ID tab reaches Docs; sentinel URL and title remain. |
| Safari in background | Same result; correct window brought forward; no Space change. |
| Two test-owned windows with similar tabs | Run-ID tab belongs to intended window; other sentinels remain. |
| Missing link, 404, redirect, Stop, or CUA failure | Unverified or interrupted; no extra navigation or later step. |
| Tab or parent-window identity ambiguous | Fail without closing an uncertain tab; record residue for targeted cleanup. |

The outer runner checks fixture HTTP counts, rendered URL and heading, app
command and CUA IDs, tab parent window, sentinel before and after state, and
unchanged Main Space. Close only a tab whose run ID and creation evidence match
this case. Confirm sentinel state and tab/window counts return to baseline.
Never close or navigate an unrelated tab. If Accessibility cannot establish
stable identity, record the gap and retain the current isolated route.

**Gate:** three clean unattended case-21 runs on one build, including a
background run. All negative variants fail at the expected step. Passing runs
leave no fixture tab and preserve other windows and tabs.

**Measured so far (October 5):** Three focused positive runs passed on the
same Debug app build, along with missing-link, Home 404, and local redirect
variants. The runner correlated the app-owned Browser result with the fixture
requests, full Safari Accessibility states for the sentinel and acted tabs,
one Safari window UUID, an independent before/after window inventory, and
unchanged Main Space. One redirect attempt stopped at a repeated nested
Safari approval; the stale approval was declined and the app command stopped.
The runner now directs the acting test to grant Safari for that test session,
and the focused redirect rerun passed. Case 21 is included in the ordered
suite; the exact-head suite receipt is still pending.

## Work package 2: Finder selection in an already-open window

Keep the canonical fixture-root-only report route and its missing-file,
symlink-escape, and decoy rejections. The runner opens a test-owned Finder
window before the command, showing a sentinel beside the report fixture. It
records window identity, initial selection, and window count. Computer Use
uses Go to Folder to reveal `report.txt`; the app's bounded Accessibility read
must identify the exact selected canonical file URL.

Add focused case 22:

| Scenario | Required observation |
| --- | --- |
| Target fixture window frontmost | Exact report selected in that window; no extra window or file open. |
| Target window in background | Finder becomes frontmost; exact report selected in original window. |
| Two similar test-owned windows and decoy | Intended report selected; other window and decoy unchanged. |
| Missing file, symlink escape, or ambiguous target | Rejected before Finder turn; existing selections unchanged. |
| CUA failure or wrong selection | App and outer runner report unverified. |

Compare app-owned selection evidence with a separate Finder observation,
command IDs, window count, foreground bundle ID, and unchanged Space. Close
only identified test-created Finder windows after recording evidence, then
remove the fixture. If Go to Folder always creates a new window, record that
result and assess a separate UI workflow; a new window does not pass this case.

**Gate:** three clean unattended case-22 runs on one build, including a
background run, plus rejection and failure variants. Sentinels remain and no
fixture files or windows remain after passing runs.

**Measured so far (October 5):** Three focused positive runs passed on the
same Debug app build. Missing-file, symlink-escape, and decoy-target variants
each rejected the app request without an inner Finder turn, kept the prepared
window and selection unchanged, and cleaned up. The outer test correlated
Finder's numeric window ID across preparation and selection, app-owned and
independent Accessibility observations, the exact selected report URL, and
unchanged Main Space. Two simultaneous similar test-owned Finder windows and
an injected CUA failure remain to test. Case 22 is included in the ordered
suite; the exact-head suite receipt is pending.

## Work package 3: routine exact-build Mac testing

Add a local orchestration entry point around `smoke_app_server.py`; preserve
focused `--case` runs for diagnosis. The entry point should:

1. Accept an exact commit SHA and checkout. Refuse a dirty tree, built-source
   mismatch, multiple app copies, mismatched helper, inaccessible UI, locked
   console, or ambiguous Space topology.
2. Build and launch exactly that app bundle. Bind the runner to path, PID,
   start time, and owner-only session log; recheck identity after each case.
3. Run the static gate, then desktop-state read, cases 17 and 18, cases 21 and
   22, composed case 19, Space pair 15 and 16, and desktop-state read again.
   Run negative variants separately. Keep Mission Control diagnostic optional.
4. Stop on first unexplained failure or missing evidence; never blindly retry
   an acting command. Restore the starting Space through the approved path
   only with exact before/after IDs. Otherwise flag manual recovery. Clean up
   only fixtures, tabs, and windows with known run-owned identities.
5. Write a mode-0600 JSONL receipt and redacted summary containing SHA, app
   and helper identity, OS/display state, case and command/turn/CUA IDs,
   approvals, HTTP counts, observed URL and selected file URL, Space IDs,
   cleanup outcome, and failure phase. Do not publish unrelated window titles,
   raw screenshots, page text, or full private logs.

Start with a local one-command run on the dedicated unlocked Mac. Then queue
reviewed exact SHAs after CI and CodeQL pass, execute on that Mac, and attach
the redacted result to the SHA. Restrict this trigger to trusted reviewed code
because the desktop grants Accessibility access. Hosted macOS CI remains the
static gate, not a substitute for the authorized interactive desktop. Only
after several successful queued runs should the machine result become a
required merge check.

Unit tests cover case selection, run-ID/window correlation, receipt redaction,
preflight rejection, fail-fast behavior, and cleanup decisions. Test evidence
joins and failure boundaries rather than merely replaying happy-path text.

**Gate:** three unattended full-suite runs on one reviewed SHA, each with a
complete receipt, no unhandled prompts or unexplained process rotation, and
the same final Space and test-owned UI inventory as at start. A deliberately
broken fixture produces a failed run and no green commit result.

## Work package 4: Codex desktop feasibility

Treat host-task status as a separate read-only investigation. The existing
separate app-server probe returned `notLoaded` for a host-active task, which
describes the probe process rather than the desktop host. Check supported
host-aware interfaces available to Voice Computer itself. Do not infer access
from tools present only in this development chat or click through the host's
chat UI from the nested Computer Use session.

For any candidate, probe one exact known task ID without reading turn content
or creating a chat. Require task ID, source, host state, and observation time;
compare with a separate host observation. Probe an unknown ID and ambiguous
title. If host state cannot be proved, record `unsupported` and keep the route
disabled. A supported read path gets a separate small PR with its own privacy
and test contract. Review-tab navigation, messages, and task creation are
outside this tranche.

**Gate:** reproducible host-aware read agrees on exact ID and state, or the
capability remains deferred. Probe-local `notLoaded` is never host status.

## MCP decision gate

Classify repeated case-21/22 failures as route ambiguity, Computer Use
execution, Accessibility observation, app focus, or harness failure. Consider
one new MCP action only when at least two independent exact-build runs expose
the same OS-level gap, the UI path cannot verify its effect, and a typed,
reversible action has independent observation. Narrow allowlisted app
activation is a candidate only if Finder/Calculator focus repeatedly fails.
Do not add a general shell, arbitrary keystrokes, or unrestricted app control.

## Review order and completion

1. Safari context: case 21, tab ownership, and cleanup evidence.
2. Finder context: case 22, existing-window identity and selection evidence.
3. Mac orchestration: exact-SHA entry point, receipts, cleanup, trusted trigger.
4. Codex feasibility: read-only evidence report; implementation only after
   the host-aware interface gate passes.

Each slice passes static CI and CodeQL on its own head. The final release gate
is an exact-head Mac receipt for every enabled case, three clean full runs,
all run-owned UI and file fixtures removed, and the starting Space restored.
Update the capability inventory with measured outcomes; planned cases are not
marked as passed until their receipts exist.
