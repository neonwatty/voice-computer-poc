# Desktop capabilities, tranche 2

Status: implemented and tested locally October 5, 2026, starting from merged
`main` at `2fa1470`. CI and CodeQL require a pushed review head.
Speech input and Foil acceptance remain deferred. This tranche uses typed requests
and the unlocked Mac Mini test host.

## Outcome

Prove that Voice Computer can finish one bounded request spanning Safari and
Finder, report live desktop state through a read-only MCP tool, and repeat both
tests unattended with evidence independent of the acting agent's final text.
Keep UI navigation in Computer Use. Use MCP for structured macOS state that
Computer Use cannot establish reliably.

The existing [capability inventory](tool-capability-inventory.md) and
[first Browser/Finder plan](next-capabilities-plan.md) are the baseline. The
current suite's cases 17 and 18 are **two separate app commands**; their passing
sequence does not prove a composed request.

## Work package 0: freeze a reproducible baseline

1. Record the source SHA, built app path, sole app PID and process start time,
   bundled MCP helper hash, macOS version, Accessibility status, and live main
   Space topology before each machine run. Reject a locked console, multiple
   app copies, mismatched helper, or unreadable Space state.
2. Preserve the current Browser and Finder fixture tests and a passing MCP
   right/left pair. Keep the intermittent Mission Control control scan as an
   optional diagnostic; it is not a prerequisite for ordinary UI tests.
3. Require a unique fixture run ID and an owner-only JSONL receipt. The runner
   captures the starting Space and frontmost bundle ID and verifies fixture
   cleanup after each outcome.

**Gate:** Static tests and current isolated machine cases pass on the exact
build chosen for the new work. A regression is fixed before expanding routes.

## Work package 1: one Browser → Finder command

### Contract and implementation

Accept one exact fixture phrase containing a loopback Home URL and a canonical
`report.txt` under `VoiceComputerPOC/TestFixtures/<run-id>/`. Require the URL
`run_id` and file-directory run ID to match; reject extra steps, other origins,
multiple paths, missing files, symlinks, ambiguity, negation, and destructive
verbs before starting any actor. Add an explicit typed route (for example,
`browserThenFinder(homeURL, reportURL)`) to `CommandRoute`, the validator, router
schema/corpus, and app handoff. A free-form multi-app instruction is not an
accepted route.

The app owns a two-step state machine under **one command ID**:

1. Start a Safari-only Computer Use turn. Allow one new fixture tab, one Home
   navigation, and one Docs click. Record its turn ID and CUA item IDs.
2. On completed CUA tools, perform the existing bounded Safari Accessibility
   check for the exact Docs URL and heading. Only a verified observation may
   advance the command. Record a `browser_step_verified` event with the command
   and turn IDs. If the turn fails, is interrupted, or is unverified, finish
   without starting Finder.
3. Start a separate Finder-only turn. Permit one reveal of the prevalidated
   report. Perform the existing bounded Finder selection check and record a
   `finder_step_verified` event with its own turn ID.
4. Report overall `verified` only when both step observations, CUA completions,
   command correlation, and unchanged live Space are present. Stop cancels the
   active turn and prevents any later step from starting. Do not reuse stale
   CUA evidence or let an agent's summary advance the state machine.

Keep Safari and Finder permissions scoped to each step. The existing fixture
verification code currently chooses **one** fixture kind at turn completion;
extend its lifecycle to verify and retain each step separately. Preserve the
original command ID while giving each turn and observation distinct IDs.

### Tests and acceptance

- Add a focused `scripts/smoke_app_server.py` case (next available case 19)
  that submits one app command. The outer runner independently observes Safari
  after step 1 and Finder after step 2, checks the HTTP fixture's Home/Docs
  request log, and correlates the app's route, two turns, approvals, and two
  verification events. It rejects a second app command or unexpected tool.
- Positive run: exactly one Home request, one Docs request, one selected report,
  Safari then Finder order, one app command, unchanged Space, and cleanup.
  Require three clean unattended runs on one exact app build.
- Failure runs: absent Docs link, Home 404, local redirect, Safari CUA error,
  and Stop before Docs each produce no Finder turn. Missing or escaped report
  is rejected before Safari. Finder wrong selection or CUA failure makes the
  overall result unverified without claiming a successful composition.
- Unit tests cover route grammar, matched run IDs, state transitions, Stop
  between steps, and stale/wrong turn IDs. Add positive and unsafe negatives to
  a new router corpus version; require zero unsafe acting handoffs in repeated
  model evaluation.

**Gate:** The app and runner agree on both steps and final status. Every
failure stops at the correct boundary, leaves the Space unchanged, and cleans
up its fixture. A plausible final sentence alone never passes.

## Work package 2: read-only MCP `get_desktop_state`

### Contract and boundary

Add `desktop_tool.get_desktop_state` with an empty input object and a typed
result: `status`, `observed_at`, `display_scope: "Main"`, `current_main_space_id`,
`ordered_main_space_ids`, and `frontmost_bundle_id`. On an incomplete or
inconsistent observation, return `unavailable` with a bounded reason and no
guessed IDs. An ambiguous display topology gets its own non-success status.
Do not return window titles, screenshots, document names, other displays'
windows, or raw Accessibility trees.

Reuse the app's native Space and foreground observers. Take a coherent
snapshot, checking for a Space change during collection; stale or mixed
readings cannot report success. Extend the current authenticated helper bridge
with an explicit read request and response type. Keep its exact helper identity
and app-server lineage checks; do not route the read request through the
`switch_space` action or weaken the existing approval and command binding.
Document the actual app-server approval behavior for this read-only tool.

### Tests and acceptance

- Unit and protocol tests: exact empty schema, malformed arguments, unknown
  tool, peer mismatch, stale/replayed session, app exit, and cancellation.
  A failed read never presses a Space control or changes foreground focus.
- On the Mac Mini, compare the typed result with an **independent** macOS
  observer at rest on each of two Main Spaces. Use an already verified MCP
  move between reads and confirm `A → B → A`; the new tool itself is read-only.
- Exercise locked/unavailable observation and multiple-display topology. When
  the main display cannot be identified without ambiguity, require a typed
  non-success. Check the returned timestamp and forbid stale results.
- Add a focused unattended runner case (next available case 20) with a private
  receipt containing the tool result, helper identity, independent observation,
  and before/after Space IDs.

**Gate:** Successful values match the independent observer, and all uncertain
states fail closed. The existing approved `switch_space` path still passes its
right/left and boundary tests.

## Work package 3: make the machine suite repeatable

Integrate cases 19 and 20 into a deliberate suite order: exact-build preflight
→ read-only desktop state → isolated Browser/Finder baseline → composed request
→ approved Space pair → read-only state again. Keep an option to run each
focused case. The suite stops on the first unverified result; an acting request
is never blindly retried. Preserve the optional Mission Control diagnostic as
a separate flag.

The runner must fail on a CUA transport error, missing or duplicate approval,
wrong target app, stale command or tool item ID, overlapping turns, wrong
fixture request count, mismatched AX state, unexpected Space change, app PID
replacement, or fixture cleanup failure. Record whether a failure occurred in
preflight, route validation, Browser, Finder, MCP read, or observation. Keep
private traces on the machine and publish only redacted receipts.

CI runs parsers, router corpus, bridge/protocol tests, and Swift/Python tests
without a desktop. The unlocked Mac runs the UI suite on the **same source
commit** as CI and CodeQL. Capture the source SHA, app path/PID/start identity,
OS version, case IDs, command/turn IDs, observed URL/file/Space IDs, status,
and cleanup result. Require three clean composed runs and a clean full suite
after the failure cases; diagnose any failure before another acting run.

**Release gate:** CI and CodeQL pass on the exact head; every enabled machine
case has a correlated, independent passing receipt; the machine ends on its
starting Space with all disposable fixtures removed.

## Decision points after this tranche

- Add an allowlisted `activate_app` MCP action only if repeated runs show a
  focus handoff failure that Computer Use plus the existing app-native handoff
  cannot verify. Start with Calculator/Finder and prove frontmost bundle ID.
- Keep Codex host-task status disabled until a supported host-aware interface
  is available to Voice Computer. The separate app-server's `notLoaded` result
  is not host task status.
- Consider Safari tab lifecycle and an already-open Finder window as the next
  Computer Use expansion after composition is stable. Limit tab cleanup to tabs
  the test created; leave the user's existing windows and files untouched.
- Resume spoken review/Run acceptance only when the user reopens speech work.

## Review slices

1. **Composed route and case 19:** typed grammar, state machine, per-step AX
   verification, cancellation, router evaluation, and machine receipt.
2. **Desktop-state MCP and case 20:** typed read, authenticated bridge, negative
   protocol tests, and independent two-Space observation.
3. **Suite/release hardening:** exact-build run order, failure classification,
   repeated acceptance receipts, and documentation updated with measured
   results. Fold small harness fixes into the relevant earlier slice.

Each slice stays reviewable on its own. Do not treat a planned test as passed
until its exact-build receipt exists.

## Measured implementation and test evidence

- Case 19 now exercises one app command with a Safari turn followed by a Finder
  turn. The app records `browser_step_verified` before it queues Finder and
  `finder_step_verified` before completing the command. The outer runner checks
  the Home/Docs request log, Safari heading and URL, exact Finder selection,
  command and turn order, and unchanged Main Space. Repeated focused positive
  runs passed; a later full suite also passed on the Debug app code that
  includes app-server rotation after Computer Use.
- Focused case 19 rejection runs passed for missing file, symlink escape, and
  decoy file before either actor started. Missing Docs link, Home 404, redirect,
  and Stop before Docs each recorded one unverified Browser turn and no Finder
  turn. The Stop test exposed an outer test-agent attempt to use an unavailable
  Safari browser API; the runner rejected it, then passed after the instruction
  directed cleanup through native Safari controls. A synthetic receipt test
  rejects a failed Computer Use call and wrong Finder selection.
- Case 20 passed on both Main Spaces against a separate macOS observer. The
  approved tool returns a typed Main Space and foreground observation with a
  timestamp. Unit tests cover empty arguments, incomplete success, approval
  correlation, changing observations, and ambiguous display topology. A live
  locked console or multiple-display configuration was not exercised on this
  two-Space Mac Mini.
- The full ordered suite `20, 17, 18, 19, 15, 16, 20` passed and returned
  `5 → 6 → 5` with disposable fixtures cleaned. Earlier suite runs exposed a
  duplicate helper child after several Computer Use turns. The bridge correctly
  rejected that peer; rotating the app-server after a completed Computer Use
  command gave the next MCP action a fresh helper lineage. The final suite
  passed after that fix. Machine receipts remain private under the app's Logs
  directory.
- Router v5 classified 228 of 231 independent turns correctly (98.7%), with
  zero wrong-direction actions and zero unsafe clarification handoffs. The
  production validator rejected two overbroad Browser classifications. The
  report combines 133 valid tool-free trials from the first run with 98 newly
  classified trials after correcting one duplicate fixture; CLI error items
  from the first run were excluded and replaced with clean independent turns.
- Debug and Release XCTest, Swift package tests, Python tests, strict
  swift-format and SwiftLint, source-length checks, bundled helper/hash checks,
  and Periphery all passed locally. CI and CodeQL must run on the pushed head.
