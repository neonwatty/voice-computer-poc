# Voice Computer POC

[![CI](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml)
[![CodeQL](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml)

A text-only macOS prototype for sending desktop commands to `codex app-server`.
It uses the Computer Use tool configured in the local Codex installation. It does
not record audio or perform transcription.

## Build and run

Requirements: macOS 14+, Xcode, a signed-in Codex CLI, and a working
Computer Use installation. The app looks for `codex` in `~/.local/bin`,
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
test CODE_SIGNING_ALLOWED=NO` for the unit tests. GitHub Actions runs this test
command, checks formatting, smoke-driver syntax, and generated-project
consistency, and scans Swift with CodeQL. Interactive desktop behavior is
verified manually and documented in [PLAN.md](PLAN.md).

Type a command or select a sample phrase, then click Run. The app starts a local
app-server over stdio, chooses an available Codex model, starts a thread with a
read-only shell/filesystem sandbox, and sends the phrase as a turn. Desktop operations are constrained
in the prompt to the configured `cua_repl` Computer Use tool. When app-server
requests Computer Use access to an app, the prototype displays the request and
lets you allow or decline it.

The app stores its Codex working directory under its Application Support folder.
It shows the final Codex message, a short Activity list, and a live **Diagnostic
Log** tab in the same window. **Show File** reveals the persistent JSONL log for
the current app launch in
`~/Library/Application Support/VoiceComputerPOC/Logs/`. Each line has a timestamp,
event name, and details. The log records entered commands, final results, server
startup and exit, request IDs, Computer Use tool names and completion status,
approval decisions, and error text. Related events carry a command ID. Completion
entries include elapsed time, macOS observations, and a verification status;
after 90 seconds without a server event, the app records an idle warning. Both
failed tool calls and tool results marked as errors are recorded. A failed
connection is reset so the next command can start a fresh session. The log does
not record screenshots or full tool inputs and outputs. Logs stay on this Mac;
they are not uploaded by the app.
They may contain personal information from commands, results, app names, and
errors, so review them before sharing. Stop interrupts the current turn. The
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
If a Space command finishes without that event, the app reports the switch as
unverified even if the model claimed success. On this Mac, both left and right
Space commands produced no change despite six configured Spaces and enabled
shortcuts. The activity log includes available tool error text for diagnostics.

## Interactive smoke test

For repeatable interactive checks on a Mac, the bounded driver in
`scripts/smoke_app_server.py` runs six default Computer Use commands through
the same local app-server protocol. It writes a private JSONL receipt and prints
each result. Select one command with `--case 1` through `--case 8`; omit
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

Add `--trace-tool-output` only when diagnosing a failure. It stores up to 3,000
characters of each tool call's input and text output in the private receipt;
those excerpts may contain visible desktop text. The normal receipt omits them.

The driver automatically grants **session** Computer Use access only to the app
named by the selected test case, for that test session. It declines other apps
and stops if the agent asks for one. Each command is
limited to 12 tool calls and 180 seconds, except the full app run can use up to
24 tool calls. The first four and the two Space cases check the backend path;
they do not test the app's approval sheet or in-window log viewer. The receipt
contains commands, responses, errors, and app names, so review it before sharing. A
preflight check stops the test if the macOS console is locked; Computer Use
cannot inspect app windows while the desktop session is locked. The original six
checks passed on the unlocked MacBook Air. The rightward Space case has not
passed there; results are in [PLAN.md](PLAN.md).

## Scope

This proves the local Codex app-server and Computer Use connection on a machine
where that tool is installed. The current tool installation may depend on the
ChatGPT desktop app. Packaging an independent distribution needs a separately
supported computer-control integration and a full permissions review.
