# Text-to-computer-use plan

## Working prototype

1. A macOS window accepts a typed command or one of four sample phrases.
2. The app launches `codex app-server` over local stdio and selects an available model.
3. It creates a Codex thread with a read-only shell/filesystem sandbox, sends
   the command, and streams activity. Computer Use can still change the UI.
4. The prompt directs desktop work through the configured Computer Use tool.
5. The app displays Computer Use access requests and sends the user's decision
   back to app-server. It shows the final answer and can interrupt a turn.

This stage intentionally omits recording, transcription, wake phrases, and
background listening.

## Test phrases and outcomes

| Phrase | Success check | Status |
| --- | --- | --- |
| Open Calculator | Calculator is open and visible | Passed through the app |
| In Calculator, enter 7 + 8 = | Calculator shows `7+8` and `15` | Passed through the app; independently checked |
| In Calculator, enter 6 + 2 =, then 3 + 4 = | Results are `8` and `7` | Passed; one session approval for the first command, none for the second; both results independently checked |
| Open Google Chrome | Chrome window can be inspected | Passed after resolving the exact path of the running Chrome bundle; using the other Chrome copy returned `timeoutReached`. The app's activation monitor did not confirm Chrome was frontmost. |
| Bring Calculator to foreground | macOS reports Calculator as activated | Unverified: Computer Use could inspect the window, but AppKit reported no Calculator activation during the command. The app overrides the model's visual success claim. |
| Switch desktop Space | macOS reports an active Space change | Failed in both directions: macOS reported no change. This Mac has six configured Spaces, the current one was the first, and left/right Space shortcuts were enabled. A direct `Control-Right` through Computer Use also left the current Space unchanged. |
| Open TextEdit | TextEdit opens with an empty document | Passed through the app; blank `Untitled 2` window independently checked |

## MacBook Air smoke runs, September 27, 2026

The first run occurred while the Air's console reported
`CGSSessionScreenIsLocked=Yes`. Computer Use returned `cgWindowNotFound` for
Safari, Calculator, TextEdit, and Finder. Those failures reflected the locked
desktop. The smoke driver now checks for that state before sending a command
and writes a clear blocked receipt.

After the Air was unlocked, all six bounded checks passed. The driver required
matching Computer Use tool output as well as a completed turn; no tool call
failed or approval was declined in these runs.

| Command | Observed result | Elapsed |
| --- | --- | ---: |
| Foreground Finder | Visible `Applications` window | 16.6 s |
| Open Safari | Visible `Start Page` window | 18.2 s |
| Calculator `9 × 7 =` | Displayed `63` | 14.7 s |
| New unsaved TextEdit document | The requested test phrase was visible; document not saved | 16.4 s |
| Run a harmless command in Voice Computer POC | Diagnostic Log visibly showed `command_started` and `command_finished` | App turn: 3.8 s |
| Run Calculator `4 + 5 =` through Voice Computer POC | App result and Computer Use showed `9`; in-app Calculator session approval and tool events appeared in Diagnostic Log | App turn: 19.3 s |

For the last command, the app's saved JSONL file linked `command_started`,
`approval_requested`, `approval_decided`, two completed tool calls,
`turn_completed`, and `command_finished` with one command ID. It recorded the
elapsed time and had `0600` file permissions. The verification field is
`model_report_only` for Calculator arithmetic because the app has no separate
macOS signal for the displayed value; the smoke driver checked Computer Use
output for `9`. Private smoke receipts are under
`~/Library/Application Support/VoiceComputerPOC/SmokeLogs/` on the Air.

## MacBook Air Space tests, September 28, 2026

The Air has two desktop Spaces on its main display. The current Space was ID 3,
with ID 4 adjacent to its right, and the macOS left/right Space shortcuts were
enabled. The bounded app-server smoke driver attempted to move right twice
through Computer Use. A traced run confirmed `finder.pressKey("ctrl+Right")`
was sent. Neither run changed the current Space ID (it remained 3); the running
app also logged no `space_changed` event. The first agent response incorrectly
treated a disappearing Finder window as proof of a switch. The second response
correctly reported that the desktop had not changed. Both runs failed the
independent Space-ID check. The leftward case was skipped because ID 3 was the
first Space, so it had no left neighbor after the rightward attempt failed.

The Computer Use API exposes key presses, clicks, drags, and scrolling for app
targets; it does not expose a dedicated desktop Space switch or trackpad swipe.
For reliable back-and-forth Space control, the next experiment should use a
narrow native macOS action with explicit permissions and confirm each move with
`NSWorkspace.activeSpaceDidChangeNotification` and the resulting Space ID.

## Native Space action, September 28, 2026

The first native implementation recognized three exact Space phrases and posted
Control-Arrow events rather than asking Computer Use to send the shortcut. It checked the
main display's adjacent Space before posting and requires both the
`NSWorkspace.activeSpaceDidChangeNotification` event and the expected current
Space ID afterward. The right-then-left phrase verifies each step separately.
The app writes the source, target, resulting ID, event count, and verification
status to its in-window and private JSONL diagnostics.

The first rightward run on the Air reached the native route but macOS denied
permission to post keyboard events. After Accessibility permission was granted
and the app restarted, the permission check passed. We tested direct event
posting, Control modifier `flagsChanged` events, and a delayed Control release.
All three runs posted the shortcut, but Space ID 3 remained current, ID 4 was
not reached, and the app observed zero active-Space-change notifications. The
round-trip command stopped after its first, unverified rightward step. Its
diagnostic log reported `native_space_finished` with `status: unverified`,
`space_after_id: 3`, and `space_change_events: 0`. The user confirmed that
physical Control-Right and Control-Left switch Spaces on this Air. We then
tried posting through the session event tap while Voice Computer POC was
frontmost; the result was still ID 3 and zero change notifications. A separate
System Events command stalled without a result and was stopped. These results
isolate the problem to software control on this machine, not the configured
keyboard shortcut.

Two bounded Computer Use Mission Control probes also failed. Targeting the
Mission Control app timed out twice without exposing a window. Targeting Finder
and sending F3 did not show Mission Control; `fn+F3` was rejected as an
unsupported key. Neither probe clicked a Space, and both independently read
ID 3 afterward. The private receipts are in the Air's `SmokeLogs` directory.

## Mission Control Accessibility result, September 28, 2026

The app now opens Mission Control and inspects Dock's Accessibility tree. On
the Air, it found `Desktop 1` and `Desktop 2` buttons, each with an `AXPress`
action. The app selects only the adjacent desktop when the complete button
set matches the ordered Spaces. It performs `AXPress`, then requires both a
Space-change notification and the expected live Space ID before proceeding.

The original preference-based current ID stayed at 3 after an AX press moved
the Air to Space 4. A read-only live WindowServer query reported ID 4. The
prototype now uses that private SkyLight query for verification and keeps the
ordered IDs from `com.apple.spaces`; this is a distribution limitation.

On the Air, the app verified a one-way left move from ID 4 to ID 3 and three
right-then-left round trips from ID 3 to 4 to 3. Each step logged an AX press,
one `NSWorkspace.activeSpaceDidChangeNotification`, and the expected live ID.
The last round trip also passed the full app-server smoke case 10 with no tool
errors after targeting the app by bundle ID. Its private receipt is
`~/Library/Application Support/VoiceComputerPOC/SmokeLogs/mission-ax-roundtrip-bundle-1790619851.jsonl`.

## Local voice-input experiment, September 30, 2026

The Mac app now has Record and Stop Recording controls. It captures a temporary
mono WAV file, posts it to the local OpenAI-compatible transcription endpoint
used by Foil's advanced external local-server setup at `127.0.0.1:8080`, and
places the recognized text in the editable command field. The user must click
Run separately. A failed or empty transcription leaves the command untouched.

On the development Mac, Foil's running `whisper-server` returned HTTP 200 and
the expected transcript for Foil's test WAV. Two live app recordings completed
through the same endpoint. The app's JSONL log contains permission, recording,
request, and completion events with duration, audio size, and transcript length;
it contains no raw audio or transcript from either capture. The temporary WAV
files were removed, and neither capture produced a `command_started` event.
The second capture did not match the target command, so it was cleared without
execution. A full spoken-command-to-computer-action test remains to be done
with a deliberate utterance.

## Final acceptance matrix, October 1, 2026

| Criterion | Current evidence | Status |
| --- | --- | --- |
| 1. Agent MCP call | Local protocol and app-server discovery tests exist. An acting `switch_space` item on the unlocked Air remains to be captured. | Pending Air |
| 2. Native verification | Automated result contract requires expected live ID and Space notification. Three independently observed right-left round trips through the agent MCP path remain pending. | Pending Air |
| 3. Failure truth | Local negative tests cover direction, boundary, permission, stale state, timeout, interruption, and failed first step. Air boundary and permission results remain pending. | Local pass; Air pending |
| 4. Router behavior | The 51-phrase corpus ran three independent model turns per phrase: 153/153 correct, zero permitted wrong-direction or clarification actions. Production parser and coordinator regression tests and isolation probes passed in T015. | Local pass |
| 5. Computer Use | Routed Calculator selection and focus checks have local tests. Visible approval and independent foreground observation on the Air remain pending. | Pending Air |
| 6. Voice handoff | Editable transcript enters the validated router only after Run; a test covers command ID continuity and no actor before Run. Deliberate voice-to-action Air receipt remains pending. | Local pass; Air pending |
| 7. Diagnostics and CI | Command ID links voice metadata, route, MCP or Computer Use, approval, native observations, result, and elapsed time. Normal logs contain no raw audio or screenshots. Xcode tests, Swift package tests, formatting, file length, SwiftLint, Periphery, smoke-driver syntax, and generated-project consistency passed locally for this slice. Final branch CodeQL remains pending. | Local pass; CodeQL pending |

At the final audit, the Air Screen Sharing display was black. Do not issue
desktop actions while it cannot be observed. Once the owner wakes and unlocks it, first confirm the
screen is visible. Then capture the routed Space MCP call and three right-left
round trips with before/after IDs and notifications; test boundary and
permission failures; run routed Open Calculator with visible approval and
independent foreground observation; finally record one deliberate Foil command,
stop, review or correct the field, confirm no action yet, click Run, and inspect
one command ID across the in-window and JSONL events. Stop hardware work after
two unverified actions. Record exact IDs, tool outcomes, observations, errors,
and elapsed times in the Air receipt.

## T036 Air acceptance preflight, October 1, 2026

**Blocked before the first Space action.** Screen Sharing initially showed an
unlocked Air desktop with Finder and Voice Computer POC. Its Control Screen
toolbar was on, but the visible app was stale: the Air checkout was
`4d59ca413b8eb084edcac1cf905972bc4e312220`, and its running Debug app was
built September 28. The required PR #10 head is
`d32350156e1bf4c3f23873f25efeac81ed0c2732`.

Over the existing `mm0` SSH connection, the PR branch was fetched and verified
at that exact head. A clean detached Air worktree was created at
`~/Desktop/voice-computer-air-acceptance`; its Debug Xcode build passed. The
old app was stopped, and PID 60385 launched from that worktree's Debug app.
This deployment changed no source files.

The Screen Sharing frame then remained at its earlier 2:07 PM view despite the
new app launch. Reopening the connection produced a user name and password
dialog for the Air. No password was entered. The updated app window, its
Accessibility trust, live Space ID, and adjacent Space could not be visibly
confirmed. No approval was shown or selected, no Space or Calculator action was
issued, and no Foil recording was made. There are therefore no T036 command
IDs, MCP items, native notifications, or round-trip results. Resume the
walkthrough only after the owner reconnects Screen Sharing and the updated app
and Space preflight can be observed live.

### T036 resumed preflight

Screen Sharing reconnected with a fresh 2:14 PM view of the exact-head app.
Its window showed Record and live Space ID 3. A read-only Mission Control
inspection (command `4282811F-4B93-4B86-AAB8-A27B21889D86`) logged
`trusted=true`, `dock_found=true`, and `AXPress` controls for Desktop 1 and
Desktop 2. A macOS Accessibility prompt appeared, but no permission control
was changed. The probe completed in 953 ms and did not switch Spaces.

The Air's current `com.apple.spaces` preference has nine monitor records:
`Main` has ordered Space IDs `[3, 4]`; the other eight records have empty Space
lists. In the exact PR head, `SpaceNavigator.snapshot()` requires
`monitors.count == 1` at `VoiceComputerPOC/SpaceNavigator.swift:81`, so the app
cannot construct an adjacent snapshot on this Air despite the visible right
neighbor. The required repair is outside T036's documentation-only file scope.
No acting MCP Space action, approval, Calculator route, or Foil recording was
started. The hardware walkthrough remains blocked pending a corrective source
task and a fresh exact-head build.

## T038 parser repair verification, October 1, 2026

`SpaceNavigator.snapshot()` now delegates to a pure monitor parser. It accepts
one nonempty Main monitor and only distinct, well-formed empty stale monitor
records, preserving the ordered positive integer Space IDs. It rejects a
missing or duplicate Main, nonempty secondary display, malformed or duplicate
IDs, and a live ID absent from Main. Focused parser tests passed locally, as
did Swift package tests, swift-format, file length, and SwiftLint.

The prescribed full Debug Xcode test gate did not complete. Two runs stalled
in the unrelated `CommandRouteTests.testRouterLaunchDisablesDesktopTools` while
the test app tried to open `evals/router-cli-args.json` through
`RouterAgent.isolatedArguments`; process samples showed the main thread in
`__open`. The runs were interrupted after 408.096 and 154.651 seconds, both
with exit 75. The remaining Release and Periphery gates were not run. The
corrected source was not deployed to the Air, and no acting MCP Space action or
macOS permission change occurred. A separate test-runner recovery is required
before the Air single-step retest.

## T040 bundled router resources, October 1, 2026

The app now packages the three canonical `evals/router-*` files and loads them
only from its bundle. A standalone read of the old 277-byte source config
took 0.015 ms, while T038's test app had stalled opening that checkout path.
The new Debug bundle copies all three resources byte for byte. Router tests
reject missing, malformed, or unsafe isolation arguments and schema; the
isolation probe completed without desktop-tool or Computer Use tool items.
Focused router and Space parser tests, Swift package tests, swift-format, file
length, and SwiftLint passed using derived data under `/tmp`.

The full Debug Xcode suite passed 58 tests and failed three existing bridge
security tests: cold preflight returned no executable, and two helper calls
exceeded their ten-second completion waits. A standalone Swift helper build
then passed, but a focused rerun of those bridge tests failed identically.
The needed bridge preflight/test repair is outside T040's allowed files. Release
tests and Periphery were not run, and no corrected Air build, acting MCP call,
Space action, or permission change occurred.

## T042 bridge subprocess diagnosis, October 1, 2026

**Blocked at the focused bridge gate; no production or test harness change was
retained.** The cold preflight focused test failed twice at about 95 seconds
(the test's 90-second wait races the preflight's own 90-second timeout). The
first SwiftPM child remained live in `getcwd -> open` while its working
directory was the Desktop checkout's `DesktopToolServer` package. Explicitly
setting the child process's initial directory to `/tmp` did not change this:
SwiftPM switched to the package directory and blocked at the same open. The
test recorded no ready path or completed callback before its wait expired, so
an `Outcome.failed` value and build exit status were not observed. Its main
queue responsiveness expectation was fulfilled.

An APFS clone of the package under `/tmp` moved SwiftPM past that first open,
but its dependency Git child then remained in `open` for the rest of the same
90-second bound. A shell build of that clone exited with a module-cache path
mismatch because the copied `.build` cache names the original Desktop path.
This scratch copy was diagnostic only and is not a deployable build strategy.

The original Desktop-path helper's wrong-parent focused test failed in about
15 seconds at its ten-second MCP response wait. A process sample showed the
helper blocked in dyld's executable-file `open`, before its Swift entry point,
first `mcp_stage` marker, initialize response ID 1, tools/call response ID 2,
or bridge callback; it had not exited when sampled. Changing only the test's
helper path to the byte-identical `/tmp` clone made the wrong-parent test pass
in 1.344 seconds, retaining its exact-path and callback-rejection assertions.
The temporary path overrides and initial-directory experiment were reverted.

The evidence identifies a test-host subprocess file-open problem for the
Desktop build and executable paths, with an additional copied-cache problem.
There is no supported narrow in-scope correction proven for cold SwiftPM
preflight. Focused and full Debug/Release gates therefore remain unverified;
no Air deployment, permission change, native Space action, or hardware probe
occurred.

## T044 packaged helper and local gates, October 1, 2026

The Xcode build now compiles the pinned DesktopToolServer package into a
configuration-specific derived-data scratch directory and copies the compiled
executable to `VoiceComputerPOC.app/Contents/Helpers/DesktopToolServer`. The
build script runs on every app build, fails on compile/copy/hash errors, and
writes a SHA-256 manifest. Runtime preflight reads only this exact canonical
regular executable and manifest. It rejects missing, non-executable,
symlinked, escaped, and digest-mismatched paths, and has finite cancellation
and timeout outcomes. The native bridge still pins the live Unix peer to the
exact helper path, direct app-server parent, unique PID/start identity, the
observed MCP item, and visible approval. There is no runtime SwiftPM build or
source-checkout helper fallback.

The Debug and Release bundle helpers were both executable, non-symlink files
and byte-identical to their just-built configuration products. Their SHA-256
manifests matched. Regenerating the Xcode project produced identical bytes.
Focused bridge/preflight tests passed, including the MCP initialize and tool
call exchange, typed no-action, wrong-parent rejection, path/start negatives,
and invalid-bundle preflight cases. Full Debug passed 62/62 tests and Release
passed 55/55 (the Debug-only hooks are excluded from Release). Swift package
tests passed 4/4; router isolation, swift-format, 300-line limit, SwiftLint,
Periphery, and `git diff --check` passed in the Desktop checkout with derived
data under `/tmp`. No fresh checkout was needed.

The current source edits are not yet a pushed PR head. CI and CodeQL on the
new head, Air deployment/read-only preflight, and any acting MCP Space move
remain pending. No Air action or permission change occurred during T044 local
verification.

## What to test next

1. Replace the private live Space ID query with a supported verification method
   before distribution. Test the Accessibility path across macOS versions,
   multi-display layouts, non-English desktop labels, and full-screen Spaces.
2. Decide how Codex should select the native action beyond the three explicit
   prototype phrases while keeping its scope narrow and verifiable.
3. Replace the machine-specific Computer Use dependency with a documented
   control layer if this will be distributed to other Macs.
4. Test a deliberate spoken phrase through transcription, review, Run, and an
   independently verified computer action on the Air. Make the transcription
   endpoint configurable if the Air uses a different local Foil setup.
