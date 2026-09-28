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

## MacBook Air smoke run, September 27, 2026

The next explicit commands were queued on the MacBook Air through a bounded
app-server smoke driver: open Safari; calculate `9 × 7 =` in Calculator; create
an unsaved TextEdit document with a known phrase; and foreground Finder. None
could be verified in this run. Computer Use returned `cgWindowNotFound` for
Safari, Calculator, TextEdit, and Finder. The first driver revision also
declined Finder access during recovery, which was a test-driver restriction
rather than a Computer Use result.

The Air's console reported `CGSSessionScreenIsLocked=Yes`. The existing Screen
Sharing view was stale and reconnecting required the user's password. The smoke
driver now checks the console lock before sending any command and records a
clear blocked result. Rerun these commands after the Air is unlocked; do not
count the locked-session tool failures as evidence that the commands fail on an
unlocked desktop. Private receipts are under
`~/Library/Application Support/VoiceComputerPOC/SmokeLogs/` on the Air.

## What to test next

1. Add a narrow native macOS action layer for app activation and Space switching
   if those actions are required. Current Computer Use reliably inspects and
   interacts with Calculator, TextEdit, and the resolved Chrome instance, but
   did not produce an observed app activation or Space change in these tests.
   Keep Codex app-server as the command planner and use independent macOS
   signals to verify each action.
2. Replace the machine-specific Computer Use dependency with a documented
   control layer if this will be distributed to other Macs.
3. Add Foil or another local transcription source only after text commands are
   reliable. A transcript should enter the same command path as typed text.
