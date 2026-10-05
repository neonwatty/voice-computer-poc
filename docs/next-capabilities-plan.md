# Next desktop capabilities: Browser, Finder, and Codex

The follow-on [tranche 2 plan](desktop-capabilities-tranche-2.md) records the
composed Browser → Finder and read-only desktop-state implementation built from
these isolated Browser and Finder cases.

Status: October 4, 2026. The narrow Safari and Finder slices are implemented;
three isolated Safari runs and multiple Safari→Finder sequences passed, as did
repeated Finder runs. The default suite passed on the final app build, and all
three focused Browser negatives, the Stop-before-Docs case, the bounded form
submission, and three Finder rejection cases passed. The
optional Mission Control gate is intermittent. The Codex host task
status route is deferred because a separate app-server process cannot read the
host's live state. Speech transcription and Foil integration remain deferred.
The app now verifies exact Safari and Finder fixture results with bounded native
Accessibility reads. The [capability inventory](tool-capability-inventory.md)
records the measured boundary.
Router v4 classified 208 of 210 independent model turns correctly, with zero
unsafe clarification actions; the validator rejected the one overbroad Browser
classification before it reached an actor.

## Goal and scope

Make three useful typed requests work through Voice Computer POC and prove each
result without relying on the agent's final sentence:

1. Navigate a known page in Safari and read a visible result.
2. Reveal a known test file in Finder.
3. Read the status of a known Codex task, if a supported structured interface
   to the Codex desktop app is available.

Start with a disposable local web page, a disposable file tree, and an existing
read-only Codex target. Do not start with arbitrary websites, private files,
new Codex tasks, messages to other chats, uploads, or speech input.

## Capability contracts

| Candidate phrase | Route and actor | Required evidence | Failure result |
| --- | --- | --- | --- |
| “Open the test site and follow the Docs link.” | Validated Browser route; Voice Computer's Computer Use targets Safari | Exact final local URL, expected heading in rendered state, and the fixture server's matching run ID | `unverified` if navigation, page state, or run ID is missing |
| “Show the test report in Finder.” | Validated file route; try Computer Use first | Exact fixture file selected in Finder, Finder visible, and canonical fixture path exists | `unverified` if selection or identity cannot be established |
| “What is the status of Codex task `<ID>`?” | Read-only structured Codex interface, if available | Exact task ID, state, and observation time from the supported interface | `unsupported` or `ambiguous_target`; never guess from a title |

These are separate route types. Do not pass the raw phrase directly to an
unrestricted acting agent and call a plausible answer success. The router now
accepts the narrow Browser and Finder fixtures alongside Space moves and
opening Calculator; its schema, validator, corpus, and handoff change together.

## Work package 0: preserve the test baseline

- Keep the existing exact-bundle preflight, one-process check, unlocked-console
  check, helper hash check, owner-only JSONL receipts, and command ID linkage.
- Run the read-only Mission Control case as a separate diagnostic or an explicit
  Space-control gate. Record the starting Space and frontmost bundle ID. New
  Browser and Finder tests must not change Space.
- Keep Computer Use app approvals scoped to the named target. If the inner
  Voice Computer run asks for another app, a shell command, or an unexpected
  MCP tool, stop and record the request.
- Add a fixture run ID to each test. Clean up fixture data after the app result
  and evidence have been captured; keep only the private receipt.

**Gate:** The current read-only case, Calculator case, and MCP Space pair still
pass on the exact build. A regression blocks expansion work.

## Work package 1: route contracts and observability

Extend `CommandRoute`, `RouteSafety`, `RouterAgent`, and `AppServerClient+Routing`
with typed Browser, Finder, and Codex intents. Version the router corpus rather
than silently changing `router-v1`'s meaning. Each intent needs an explicit
action, target, and finite workflow bound. The Browser fixture route permits
one Home navigation and one Docs click; Finder permits one reveal; Codex permits
one status read. Validate the target against the original phrase before
starting an actor:

- Browser: accept only `http` or `https` URLs. For the first hardware tests,
  require the exact loopback fixture origin and reject `file:`, `javascript:`,
  `data:`, missing URLs, and extra steps. Treat an observed final origin that
  differs from the requested fixture origin as unverified.
- Finder: resolve and canonicalize one path under the dedicated fixture root;
  reject missing files, symlink escapes, multiple paths, and destructive verbs.
- Codex: require an exact task ID obtained from a supported interface; a title
  alone can be ambiguous. Keep this route disabled until work package 4 passes
  its feasibility gate.
- Preserve the current fail-closed behavior for negation, uncertainty, and
  unsupported commands. Add positive and negative examples to a versioned
  router corpus, then run both parser tests and repeated model evaluations.

The app logs route, action, target category, actor, approval, start and finish
IDs, elapsed time, and verification status. Normal logs omit raw page content,
file contents, screenshots, and full command text. Browser and Finder fixture
turns require an exact app-owned Accessibility match before reporting `verified`;
the outer smoke runner also checks the target UI independently.

**Gate:** No corpus example for an unsupported or ambiguous request starts an
actor. Unit tests cover parser rejection and command ID continuity.

## Work package 2: Browser vertical slice

Build a tiny HTTP fixture bound to `127.0.0.1` on a temporary port. It should
serve a Home page, a Docs page with a unique heading and run ID, a simple form,
and an intentional error page. The runner places its exact fixture URL in the
test phrase, so neither the router nor the app hardcodes a port. The first
shipped request is Home → Docs. A bounded form submission is now a focused
follow-on case; tab handling remains future work.

The acting turn uses Computer Use with Safari. It opens the exact
fixture URL, reads the rendered page, clicks the Docs link, and reports the
observed final URL and heading. The fixture records requests with the run ID.
The outer smoke driver checks both the visible Safari result and the fixture
server record. A server request alone does not prove the page rendered; an
agent sentence alone does not prove navigation.

Test normal navigation, an absent link, a 404 page, a redirect to an unexpected
path within the local fixture, and interruption before click. Do not use an
external redirect fixture: the browser could follow it before the agent can
check the final URL. Stop on the first unexpected origin or Computer Use
failure. The Codex desktop chat can use its built-in Browser, but the nested
`codex app-server` session reported `Browser is not available: iab` and returned
no browser entries from `cua.getState()`. Safari's native Accessibility tree
did expose the local Home URL, Docs link, final URL, and heading. The route
therefore uses Safari for the app test. Keep navigation limited to the loopback
fixture; regular browser profile expansion needs a separate decision.

**Gate:** Three clean unattended Home → Docs runs on the unlocked Mac, plus
negative cases that return non-success without visiting an unapproved origin.
The starting desktop Space remains unchanged.

**Measured negatives:** The missing-link, Home 404, and local redirect-to-error
fixtures each passed a focused exact-app run. The runner verified the local
request sequence and rendered Safari URL and heading. The app recorded
`unverified` for each because the exact Docs URL and heading were absent.
The timed interruption case held the Home response, pressed the exact app's
Stop button through Accessibility, and passed on the October 4 exact build:
one Home request, zero Docs requests, an interrupted and unverified app result,
and unchanged live Space ID 5. The fixture was released and removed afterward.
The follow-on form case loaded the local Docs page and submitted only its
run-specific test query. An October 4 exact-app run matched the fixture's one
Docs request and one submitted request, the app-owned Safari URL and heading,
an independent Safari observation, and unchanged live Space ID 5. Tab handling
and other form inputs remain separate future cases.

## Work package 3: Finder vertical slice

Create a unique directory under Voice Computer POC's Application Support test
area with one known report file and one similarly named decoy. Ask Finder to
reveal the exact report. Capture the Finder Accessibility state and verify that
the selected item is the canonical target; separately verify the on-disk path
and frontmost app. Do not treat “Finder opened” as proof that the right file is
selected.

Try Computer Use first. If Finder selection is not exposed reliably, add a
narrow native or MCP `reveal_file` action confined to an allowed path and return
the selected canonical URL plus an independent Finder observation. Keep
`activate_app` allowlisted to Finder and Calculator if foreground activation
needs a deterministic handoff. Avoid a general filesystem or arbitrary
AppleScript tool.

Test the report, decoy ambiguity, missing file, symlink escape, and an already
open Finder window. Preserve user files and windows outside the test fixture.

**Measured negatives:** Focused exact-app runs with a missing report, a report
symlink to an outside temporary file, and the similarly named decoy each
finished with `no_action`. The runner required a fresh app command, no acting
turn or tool, the same live Space ID, and fixture cleanup.

**Gate:** Three unattended reveals select the exact report, including one run
with Finder initially in the background. Every negative case returns no action
or a typed non-success, and the fixture is removed after evidence capture.

## Work package 4: Codex desktop feasibility and read-only status

Treat the Codex desktop app as a separate integration target. Voice Computer
POC already owns a `codex app-server` session, but that does not prove it can
inspect or navigate this desktop app's existing chats. First determine whether
a supported app tool, app-server method, or documented deep link is available
to the nested acting session. Do not infer host-app access from tools available
only in the development chat, and do not use Computer Use to click through the
host's own chat UI. The [Computer Use documentation](https://learn.chatgpt.com/docs/computer-use)
excludes automation of ChatGPT itself; verify the Codex desktop boundary rather
than assuming it is available.

If a supported read-only interface exists, implement `get_codex_task_status`
for an exact task ID. Return ID, source, state, observation time, and a concise
status; keep the response free of unrelated chat content. Compare it with a
second read of the same task through the host interface. Test one known ID,
unknown ID, and an ambiguous title. Only after this passes, consider “Open
this PR in Codex review” as a separate navigation action with a verified
destination tab.

If no supported interface is callable from Voice Computer POC, mark host-app
status unsupported. The bounded fallback is status for Voice Computer POC's
own command or app-server turn, labeled as such; it must not claim to describe
the user's other Codex chats.

**Gate:** One exact existing task can be read with matching ID and state, or
the capability is explicitly deferred with a recorded reason. No test creates
a chat or sends a message to another chat.

**Feasibility result (October 3):** The generated local app-server schema has
`thread/read`, and a separate app-server process returned this task's exact ID
and source. Its protocol status was `notLoaded` while the Codex desktop host
reported the same task `active`. That status describes the probe process, so
it cannot verify the host app's live task state. `scripts/probe_codex_status.py`
records this as `unavailable_cross_process` without reading task turns. Keep
the Codex status route disabled until a supported host-aware status interface
is available to Voice Computer.

## Work package 5: unattended runner and release gate

Extend `scripts/smoke_app_server.py` with one case per slice and a suite mode
that runs preflight → Browser → Finder. An exact `--codex-thread-id` adds the
read-only Codex feasibility probe. The optional `--mission-control-gate`
inserts read-only case 13 before Browser. Each
case gets a finite tool-call and time budget, one target allowlist, a unique
fixture run ID, a private receipt, and a command-correlated app log check.
Fail closed on missing evidence, a wrong app, an unexpected approval, changed
Space, a stale command ID, or a model-reported success without observation.
Do not retry an acting request blindly; diagnose the first failure before
another run.

CI should run fixture, router, protocol, and parser tests without a desktop
session. The unlocked Mac runs the UI suite against one exact Debug app build.
The review receipt should state build SHA, app path and PID, OS version, case
IDs, observed URL/path/task ID, approvals, verification status, and cleanup
status. Keep any screenshot or detailed CUA trace local unless needed to debug
a failure. Browser and Finder only need an unlocked desktop, the exact app,
their target app's Accessibility state, and stable live Space IDs. Keep Mission
Control's read-only control scan as a separate diagnostic and an opt-in
`--mission-control-gate` for Space control testing.

**Current Mission Control limit:** Case 13 has both passed with two WindowManager
Desktop controls and failed when another app became frontmost while Mission
Control opened. The optional gate remains fail-closed. The default Browser →
Finder suite checks its own prerequisites and does not depend on Mission Control
controls. One recoverable
stale UI binding before the read-only command can be accepted only after the
exact app log proves a fresh command completed with both controls and the
Space ID unchanged. Other Computer Use errors still fail the case.

**Release gate:** CI and CodeQL pass on the same commit as the app tested on
the Mac; each enabled UI case has a successful unattended receipt; failures
remain truthful and leave the machine on its original Space.

## Sequence and decision points

1. Add contracts and fixtures, then Browser navigation. This is the most
   repeatable UI test and exercises the new router without OS window ambiguity.
2. Add Finder reveal. Decide from measured selection and focus evidence whether
   Computer Use suffices or a narrow MCP/native action is justified.
3. Run the Codex interface probe early enough to avoid assuming access, then
   implement only the supported read-only status path.
4. After all three isolated cases pass, try a cross-app request such as “Open
   the local Docs page, then reveal its downloaded test report.” It needs a
   separate explicit multi-step route and verification after each step.

Keep each work package reviewable on its own. Do not widen arbitrary browser,
file, or Codex actions merely to make the first fixture pass.
