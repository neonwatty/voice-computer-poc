# Voice Computer POC

[![CI](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml)
[![CodeQL](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml)

A macOS prototype for sending typed or spoken desktop commands to `codex app-server`.
It uses the Computer Use tool configured in the local Codex installation. The
voice-input experiment records a short command and sends it only to a local
OpenAI-compatible transcription server.

## Build and run

Requirements: macOS 14+, Xcode, a signed-in Codex CLI, and a working
Computer Use installation. Voice input also needs microphone permission and a
local transcription server at `http://127.0.0.1:8080/v1/audio/transcriptions`.
Foil's advanced External local server setup can start a compatible
`whisper-server` on this address. The app looks for `codex` in `~/.local/bin`,
the installed Codex or ChatGPT app, `/opt/homebrew/bin`, and `/usr/local/bin`.

```sh
git clone https://github.com/neonwatty/voice-computer-poc.git
cd voice-computer-poc
XCODEGEN_BIN="$(scripts/install-xcodegen.sh | tail -1)"
"$XCODEGEN_BIN" generate --spec project.yml
xcodebuild -project VoiceComputerPOC.xcodeproj -scheme VoiceComputerPOC \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
open DerivedData/Build/Products/Debug/VoiceComputerPOC.app
```

Run `xcodebuild -project VoiceComputerPOC.xcodeproj -scheme VoiceComputerPOC
-configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData
test CODE_SIGNING_ALLOWED=NO` for the unit tests. GitHub Actions runs the tests
in Debug and Release, checks formatting, source and function size, unused Swift declarations,
smoke-driver syntax, and generated-project consistency, and scans Swift with
CodeQL. Interactive desktop behavior is
verified manually and documented in [PLAN.md](PLAN.md).

Each app build compiles the pinned Swift MCP package into Xcode's derived-data
scratch directory and installs the current configuration's executable at
`VoiceComputerPOC.app/Contents/Helpers/DesktopToolServer`. The build fails if
compilation, copying, or byte comparison fails. At launch the app verifies that
exact regular executable and its build-time SHA-256 manifest before offering
the Space tool. It never builds a helper at command time or launches one from
the source checkout.

Type a command or select a sample phrase, then click Run or press Return in the
focused command field. For general commands, the app starts a local app-server
over stdio, chooses an available Codex model, starts a thread with a
read-only shell/filesystem sandbox, and sends the phrase as a turn. Desktop operations are constrained
in the prompt to the configured `cua_repl` Computer Use tool. When app-server
requests Computer Use access to an app, the prototype displays the request and
lets you allow or decline it.

For voice input, click **Record**, speak, then click **Stop Recording**. The app
records a temporary mono WAV file, posts it to the local server with model
`whisper-1`, deletes the audio file after loading it, and puts the transcript in
the command field. Review or edit the text and click **Run** to execute it.
Transcription does not run a command automatically; review the text, then click
Run or press Return in the focused command field. Reviewed voice text enters
the validated router and then its selected acting path. Recording and transcription
status appear in the window. Diagnostic events record permission, recording,
request, and error states without storing raw audio or transcript text; the
same command ID links these events to the Run, router, tool, native observation,
and final status. The command log records the input source and whether the
transcript was edited; the command text stays in the window. If Foil is using
its managed local service or a cloud provider instead of the advanced external
server on port 8080, start the external local server before trying this voice
path. The endpoint is fixed for this first experiment.

The phrases **Switch to the next desktop Space**, **Switch to the previous
desktop Space**, and **Switch one desktop Space right and then back left** use a
narrow native macOS Accessibility path. The app opens Mission Control and
presses only the verified adjacent **Desktop N** control in Dock's Accessibility
tree. It requires both an active-Space notification and the expected live Space
ID after each move. It logs each step and reports a failure if verification
does not arrive. Sentence-ending punctuation from transcription is accepted.
Enable Voice Computer POC in **System Settings → Privacy &
Security → Accessibility** if macOS requests it.

### Agent-called Swift Space tool

The explicit test commands **agent switch desktop space right** and **agent
switch desktop space left** start an acting Codex turn instructed to call the
local Swift MCP `desktop_tool.switch_space` tool once. The app configures this
stdio server only for its own app-server process. It validates the packaged helper
before launch and checks the live caller's exact executable, direct app-server parent,
and process start identity when the bridge request arrives. The helper checks the tool
arguments and sends one adjacent direction over a local Unix socket bridge with a fresh
session token. The app accepts the request only during a matching active test
command and after a visible **Allow once** approval for that exact MCP item,
turn, and direction. Space-tool session approval is unavailable; each routed
Space step needs its own approval. The app performs Accessibility work in its
own process and returns a typed result. A `verified` result requires the target
live Space ID and an active
Space notification. The existing exact phrases above still use their direct
native path. General Computer Use commands retain their approval flow.

One local Debug no-action probe (command `98DAB011-EE9A-4D3A-86EC-F29F3C46AA19`)
completed through the live MCP bridge on a stable Space ID 3. Its visible
approval used **Allow once**; the authentic tool item reached
`mcp_helper_bound` and `mcp_bridge_accepted`, then returned typed
`probe_no_action`. No native Space request, Accessibility press, or Space-change
event occurred. This proves the guarded bridge path without moving a Space;
unlocked MacBook Air acceptance is still pending.

### Routed commands

Other typed commands first go to a separate Codex router invocation. It starts
with user configuration ignored, the shell and plugin features disabled, app
tools disabled, and a read-only sandbox. Its trace must also contain no tool
items or the app discards the result. Its only accepted output is a JSON
decision for one Space step, an explicit right-then-left return, Calculator,
or clarification. The app validates the exact keys, allowed values, direction
cues in order, negation, uncertainty, and safe target before starting an acting
turn. Invalid output and
clarification end with no desktop action. Each routed Space step uses a fresh
acting turn and the same Swift MCP verification; an unverified first step stops
the sequence. Calculator keeps the visible Computer Use approval and requires
an independent frontmost-app observation to report verified.

The versioned corpus is `evals/router-v1.json`. Run
`python3 scripts/eval-router.py` for three independent model turns per phrase.
The app and evaluator use the same instruction, schema, and isolated CLI flags.
The evaluator compiles the production route contract for handoff scoring and
writes every miss, route accuracy, and the wrong-direction and clarification
action gates to `evals/router-v1-report.json`. This local model evaluation does
not replace the unlocked Air action and focus checks.

To review this slice on an unlocked MacBook Air, build and open the app, grant
the app Accessibility access, and begin on a Space with a neighbor to the
right. Enter the right test command, then the left test command, three times.
For each step, require a `desktop_tool.switch_space` item in the Diagnostic
Log, `mcp_bridge_accepted`, `native_space_step_verified`, and a
`command_finished` entry with the same command ID. Check the live Space ID
before and after every move with an independent macOS observer; after each
pair it must equal the starting ID. `mcp_tool_ready` proves app-server
discovery. At an edge, the tool must return `no_adjacent_space`; with app
Accessibility disabled, it must return `failed`. Stop after two unverified
hardware actions. Record the command IDs, observed IDs, notification counts,
tool results, and any errors in the review receipt. Do not infer a passed Air
check from unit tests or an agent message.

This remains a prototype: it expects English **Desktop N** labels and a simple
main-display desktop sequence. The current Space ID check uses a private
SkyLight read because the `com.apple.spaces` preference can be stale. A
distribution-ready app needs a supported verification method and testing across
macOS versions and multi-display layouts.

The app stores its Codex working directory under its Application Support folder.
It shows the final Codex message, a short Activity list, and a live **Diagnostic
Log** tab in the same window. **Show File** reveals the persistent JSONL log for
the current app launch in
`~/Library/Application Support/VoiceComputerPOC/Logs/`. Each line has a timestamp,
event name, and details. The log records command events, verification status, server
startup and exit, request IDs, Computer Use tool names and completion status,
approval decisions, and error details. Related events carry a command ID. Completion
entries include elapsed time, macOS observations, and a verification status;
after 90 seconds without a server event, the app records an idle warning. Both
failed tool calls and tool results marked as errors are recorded. A failed
connection is reset so the next command can start a fresh session. The log does
not record command text, activity text, screenshots, or full tool inputs and outputs. Logs stay on this Mac;
they are not uploaded by the app.
They may contain personal information from app names and errors, so review them
before sharing. Stop interrupts the current turn. The
Codex session is tied to the app process and is not persisted by this prototype.

The current Computer Use connection can request approval more than once for an
app, including during a sequence of clicks. When the request offers session
persistence, choose **Allow for session** to permit that app for the current
Codex session. **Allow once** keeps the earlier per-action behavior. This does
not permanently add an app to ChatGPT's always-allowed list.

In the current Mac test, one Calculator session approval covered a full
calculation and a later Calculator command without another prompt. TextEdit
also opened with one session approval. This Mac has two Chrome bundles with the
same identifier. The prototype now resolves the running bundle's exact path;
Computer Use could inspect its window, while targeting the other copy returned
`timeoutReached`. Chrome foreground activation was not independently confirmed.

For commands that explicitly ask to foreground Chrome or Calculator, the app
observes macOS app-activation notifications and checks the final frontmost app.
If the requested app is not frontmost when the turn ends, the result says focus
is unverified. The earlier Computer Use test could inspect those windows but
did not produce an observed activation on this Mac.

The app observes macOS's active-Space-change notification and displays a count.
The native route also checks the Space ID. The earlier Computer Use-only Space
commands produced no change on either test Mac despite enabled shortcuts. The
activity log includes available tool error text for diagnostics.

## Interactive smoke test

For repeatable interactive checks on a Mac, the bounded driver in
`scripts/smoke_app_server.py` runs six default Computer Use commands through
the same local app-server protocol. It writes a private JSONL receipt and prints
each result. Select one command with `--case 1` through `--case 14`; omit
`--case` to run the original six. Cases 5 and 6 check the app's in-window
Diagnostic Log and one full Calculator run through the app.

```sh
python3 scripts/smoke_app_server.py \
  --log "$HOME/Library/Application Support/VoiceComputerPOC/SmokeLogs/manual-$(date +%s).jsonl"
```

Cases 7 and 8 explicitly test right and left desktop Space shortcuts. They
require an adjacent Space and compare the main display's current Space ID before
and after the command. Run right before left when starting on the first Space:

```sh
python3 scripts/smoke_app_server.py --case 7 --case 8 \
  --log "$HOME/Library/Application Support/VoiceComputerPOC/SmokeLogs/spaces-$(date +%s).jsonl"
```

Cases 9, 10, and 14 run the native Accessibility action through the app. Case 10
makes a right-and-back round trip, so run it before case 9 when starting on the
first Space. Case 14 tests a one-way left move when an adjacent Space exists:

```sh
python3 scripts/smoke_app_server.py --case 10 --case 9 \
  --log "$HOME/Library/Application Support/VoiceComputerPOC/SmokeLogs/native-spaces-$(date +%s).jsonl"
```

Cases 11 and 12 probe Mission Control through Computer Use; both failed on the
Air. Case 13 inspects Dock's Mission Control Accessibility tree. The app's
native case 10 passed on the Air; see [PLAN.md](PLAN.md).

Add `--trace-tool-output` only when diagnosing a failure. It stores up to 3,000
characters of each tool call's input and text output in the private receipt;
those excerpts may contain visible desktop text. The normal receipt omits them.

The driver automatically grants **session** Computer Use access only to the app
named by the selected test case, for that test session. It declines other apps
and stops if the agent asks for one. Each command is
limited to 12 tool calls and 180 seconds, except the full app run can use up to
24 tool calls. Cases 1–4 and 7–8 check the backend path;
they do not test the app's approval sheet or in-window log viewer. The receipt
contains commands, responses, errors, and app names, so review it before sharing. A
preflight check stops the test if the macOS console is locked; Computer Use
cannot inspect app windows while the desktop session is locked. The original six
checks passed on the unlocked MacBook Air. Computer Use-only Space commands
failed there, while the native Accessibility round trip passed; results are in
[PLAN.md](PLAN.md).

## Scope

This proves the local Codex app-server and Computer Use connection on a machine
where that tool is installed. The current tool installation may depend on the
ChatGPT desktop app. Packaging an independent distribution needs a separately
supported computer-control integration and a full permissions review.
