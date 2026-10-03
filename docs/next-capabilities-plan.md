# Next desktop capabilities: Browser, Finder, and Codex

Status: October 3, 2026. This is an implementation and validation plan, not a
claim that the commands below already work. Speech transcription and Foil
integration remain deferred. The [capability inventory](tool-capability-inventory.md)
records what has been verified so far.

## Goal and scope

Make three useful typed requests work through Voice Computer POC and prove each
result without relying on the agent's final sentence:

1. Navigate a known page in the built-in Browser and read a visible result.
2. Reveal a known test file in Finder.
3. Read the status of a known Codex task, if a supported structured interface
   to the Codex desktop app is available.

Start with a disposable local web page, a disposable file tree, and an existing
read-only Codex target. Do not start with arbitrary websites, private files,
new Codex tasks, messages to other chats, uploads, or speech input.

## Capability contracts

| Candidate phrase | Route and actor | Required evidence | Failure result |
| --- | --- | --- | --- |
| “Open the test site and follow the Docs link.” | Validated Browser route; Computer Use targets the built-in Browser | Exact final local URL, expected heading in rendered state, and the fixture server's matching run ID | `unverified` if navigation, page state, or run ID is missing |
| “Show the test report in Finder.” | Validated file route; try Computer Use first | Exact fixture file selected in Finder, Finder visible, and canonical fixture path exists | `unverified` if selection or identity cannot be established |
| “What is the status of Codex task `<ID>`?” | Read-only structured Codex interface, if available | Exact task ID, state, and observation time from the supported interface | `unsupported` or `ambiguous_target`; never guess from a title |

These are separate route types. Do not pass the raw phrase directly to an
unrestricted acting agent and call a plausible answer success. The existing
router currently accepts only Space moves and opening Calculator; its schema,
validator, corpus, and handoff must be expanded together.

## Work package 0: preserve the test baseline

- Keep the existing exact-bundle preflight, one-process check, unlocked-console
  check, helper hash check, owner-only JSONL receipts, and command ID linkage.
- Run the read-only Mission Control case before new acting tests. Record the
  starting Space and frontmost bundle ID. New tests must not change Space.
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

The app should log route, action, target category, actor, approval, start and
finish IDs, elapsed time, and verification status. Normal logs should omit raw
page content, file contents, screenshots, and full command text.

**Gate:** No corpus example for an unsupported or ambiguous request starts an
actor. Unit tests cover parser rejection and command ID continuity.

## Work package 2: Browser vertical slice

Build a tiny HTTP fixture bound to `127.0.0.1` on a temporary port. It should
serve a Home page, a Docs page with a unique heading and run ID, a simple form,
and an intentional error page. The runner places its exact fixture URL in the
test phrase, so neither the router nor the app hardcodes a port. The first
shipped request is Home → Docs; form
submission and tabs are follow-on cases after navigation is reliable.

The acting turn uses Computer Use with the built-in Browser. It opens the exact
fixture URL, reads the rendered page, clicks the Docs link, and reports the
observed final URL and heading. The fixture records requests with the run ID.
The outer smoke driver checks both the visible Browser result and the fixture
server record. A server request alone does not prove the page rendered; an
agent sentence alone does not prove navigation.

Test normal navigation, an absent link, a 404 page, a redirect to an unexpected
path within the local fixture, and interruption before click. Do not use an
external redirect fixture: the browser could follow it before the agent can
check the final URL. Stop on the first unexpected origin or Computer Use
failure. Keep the built-in Browser as the initial target:
its [profile is separate from regular Chrome](https://learn.chatgpt.com/docs/browser),
and this Mac has had ambiguous Chrome bundle resolution. Expand to a user's
browser profile only after this slice is stable and that profile is explicitly
chosen.

**Gate:** Three clean unattended Home → Docs runs on the unlocked Mac, plus
negative cases that return non-success without visiting an unapproved origin.
The starting desktop Space remains unchanged.

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

## Work package 5: unattended runner and release gate

Extend `scripts/smoke_app_server.py` with one case per slice and a suite mode
that runs preflight → read-only gate → Browser → Finder → Codex status. Each
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
a failure.

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
