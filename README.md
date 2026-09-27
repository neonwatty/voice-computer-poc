# Voice Computer POC

[![CI](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/ci.yml)
[![CodeQL](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml/badge.svg)](https://github.com/neonwatty/voice-computer-poc/actions/workflows/codeql.yml)

A text-only macOS prototype for sending desktop commands to `codex app-server`.
It uses the Computer Use tool configured in the local Codex installation. It does
not record audio or perform transcription.

## Build and run

Requirements: macOS 14+, Xcode, a signed-in Codex CLI, and a working
Computer Use installation. The app looks for `codex` in `~/.local/bin`,
`/opt/homebrew/bin`, and `/usr/local/bin`.

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
command, checks formatting and generated-project consistency, and scans Swift
with CodeQL. Interactive desktop behavior is verified manually and documented
in [PLAN.md](PLAN.md).

Type a command or select a sample phrase, then click Run. The app starts a local
app-server over stdio, chooses an available Codex model, starts a thread with a
read-only shell/filesystem sandbox, and sends the phrase as a turn. Desktop operations are constrained
in the prompt to the configured `cua_repl` Computer Use tool. When app-server
requests Computer Use access to an app, the prototype displays the request and
lets you allow or decline it.

The app stores its Codex working directory under its Application Support folder.
It shows the final Codex message and a short event log. Stop interrupts the
current turn. The Codex session is tied to the app process and is not persisted
by this prototype.

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
also observes macOS app-activation notifications. If the target app never
activates during the command, the result says foreground focus is unverified.
The current Computer Use path could inspect those windows but did not produce
an observed activation on this Mac.

The app observes macOS's active-Space-change notification and displays a count.
If a Space command finishes without that event, the app reports the switch as
unverified even if the model claimed success. On this Mac, both left and right
Space commands produced no change despite six configured Spaces and enabled
shortcuts. The activity log includes available tool error text for diagnostics.

## Scope

This proves the local Codex app-server and Computer Use connection on a machine
where that tool is installed. The current tool installation may depend on the
ChatGPT desktop app. Packaging an independent distribution needs a separately
supported computer-control integration and a full permissions review.
