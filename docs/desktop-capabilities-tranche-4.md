# Desktop capabilities, tranche 4

Status: in progress October 6, 2026. PR #15 merged at
`2fdddc1eab3a56e20c72485000a2b5fdfb13a2a7`; PR #16 merged at
`010bf4471e28dfea3fdf83b18775c39737c917d7`. The new-document Save/Cancel
extension is under test. Two focused new-document Save runs and one focused
canceled Save run have passed with independent Mac observations. Speech input,
Foil integration, and Codex host-task
status remain deferred.

## Goal and baseline

Make the unlocked-Mac suite usable as a trusted PR check, close the two known
Computer Use failure-path gaps, and add one file-editing workflow in TextEdit.
Preserve the current division of work: Computer Use operates visible app UI;
Voice Computer validates a narrow request and verifies its result; MCP exposes
typed desktop Space control and read-only state. Add no general shell,
keystroke, browser, or file-editing MCP action.

PR #14 passed hosted CI and CodeQL on exact source SHA
`52b8e7edc9993089883bd5da9aa6f2e2dce13a5b`. Three full Mac suites on
that SHA passed cases `20,17,18,21,22,19,15,16,20`, each restoring the
starting Space and Safari/Finder window inventories. Focused Safari and Finder
positives, decoys, route rejections, and Browser Stop passed. PR #15 closed
the original trigger and CUA failure-path gaps: its exact head passed the full
suite, the owner-attested trigger posted success, and a wrong-SHA dispatch was
rejected before running. The `Protect main` ruleset currently requires CI and
CodeQL; the Mac status is optional until a second PR SHA and blocked/allowed
rule behavior are observed.

## Work package 0: freeze and diagnose the baseline

1. Record the merged SHA, clean checkout, existing suite case IDs, private
   receipt locations, current GitHub check names, and whether the Mac is
   unlocked. Do not rerun the expensive suite merely to reproduce already
   captured evidence.
2. Confirm that the debug app, helper, and local CLI still have the required
   identity and Accessibility access before an acting run. Preserve the
   runner's exact-source, single-process, Space, and window preflights.
3. Separate failures into routing, inner CUA invocation, app verification,
   outer observation, fixture cleanup, and infrastructure. Never turn an
   unexplained failure into a pass by automatically retrying an acting command.

**Gate:** a clean baseline and a reproducible focused command can be run from
`scripts/smoke_app_server.py`; no pre-existing user window is adopted as a
fixture.

## Work package 1: close Safari and Finder failure paths

Extend focused cases 21 and 22 with a deterministic, debug-only fault seam at
the app-server CUA event boundary. The injected event must enter the same
failure classification and cleanup code used for a real failed
`mcp__cua_repl.js` call. Bind injection to one run ID, command ID, app target,
and single tool item; reject it in Release. Record whether each run uses a
synthetic event or an actual nested CUA error. Do not claim a synthetic event
proves the remote CUA service itself failed.

For both apps, check that a started CUA item with a failed or missing
completion cannot produce `verified`, does not start a later step, and leaves
the Main Space unchanged. The outer runner independently observes the
test-owned Safari sentinel tab or Finder window and selection, records any
run-owned residue, and cleans up only identified fixtures. Add a naturally
occurring inner CUA error receipt if one can be induced safely and
repeatably; keep it distinct from the deterministic test.

Test the receipt parser with mismatched command IDs, a success after injected
failure, missing completion, uncertain window identity, and cleanup failure.
Keep current positive, decoy, route-rejection, and Stop checks intact.

**Gate:** focused case 21 and 22 fault runs produce typed non-success, exact
command and tool correlation, no unrelated UI changes, and an honest private
receipt. The normal full suite still passes on the same exact build.

**Initial focused evidence:** The Debug test seam changed one completed inner
CUA item into a synthetic failed event at the app's event ingress. Focused
case 21 and 22 both passed on the unlocked Mac: the app recorded the matching
item, `tool_failed` verification, and one `synthetic_debug_event`; independent
Safari/Finder observations confirmed sentinel preservation, known window
identity, restored window inventory, and unchanged Space 5. These runs do not
prove a failure in the remote CUA service itself. PR #15 subsequently passed
the exact clean-SHA full suite and merged.

## Work package 2: owner-attested Mac PR trigger

Replace the impossible independent-review prerequisite in
`scripts/run_reviewed_desktop_suite.py` with an explicit local owner dispatch.
The caller supplies the PR number, full head SHA, and a separate
`--attest-sha` value matching that SHA. The trigger checks the authenticated
`gh` account is the repository owner, the PR is open, ready, same-repository,
and targets `main`; its head equals the clean local checkout; and the exact
head has successful `CI / Build and test` and `CodeQL / Analyze Swift` runs.
The attestation is authorization to run this particular PR head on the
Accessibility-enabled Mac, not a substitute for code review. Document that
the owner must inspect the diff before invoking it.

Keep the trusted trigger entry point on the owner-controlled Mac. Do not
download and execute a trigger script from a PR artifact. Continue to run
the exact checked-out source through the existing static and machine gates.
Post `pending` before execution and `success` or `failure` on the exact SHA;
publish only a redacted case count, restoration result, and status. A failed
preflight before `pending` posts no green result. Any error after `pending`
posts failure if GitHub is reachable and leaves the private receipt for
diagnosis. Recheck PR head and required checks immediately before posting
success so a changed PR cannot borrow an older run.

Unit-test wrong account, absent or stale attestation, changed head, fork,
draft/closed PR, duplicate or failing check, dirty checkout, runner failure,
receipt mismatch, and status-posting failure. Then dispatch once against an
owner-attested real PR on the unlocked Mac. Verify the GitHub commit status is
on the tested SHA and its private receipt has all ordered cases and restored
Space/windows. Also run one safe negative dispatch that stops before any
desktop actor and cannot post success.

**Gate:** one live positive status and one rejected dispatch, with exact SHA
and local receipt correlation. A passing status must never outlive a changed
head, failed case, or incomplete cleanup.

## Work package 3: make the Mac result part of merging

First run the owner-attested trigger on at least two distinct exact PR SHAs
(two reviewed revisions of PR A are sufficient) without manual repair of its
result or cleanup. Confirm the Mac can be kept unlocked and available for
those runs. Then add `Voice Computer / desktop suite` as a
required status for `main` using repository rules. Verify a pending or failed
status blocks a test PR and an exact-head success permits merging after CI and
CodeQL. Record the configured rule and the recovery procedure for a locked or
unavailable Mac; recovery reruns the same SHA after fixing infrastructure and
does not waive the check silently. Keep unrelated PRs from inheriting an old
SHA's result.

**Gate:** the repository rule is active and its blocked/allowed behavior has
been observed. Inspect all three exact-head checks before merging desktop
changes.

**Observed:** The active `Protect main` ruleset (ID 24084858) requires
`Build and test`, `Analyze Swift`, and `Voice Computer / desktop suite`, with
strict exact-head checks. PR #16 was blocked while its Mac status was pending
and became mergeable after the same head passed. One real inner CUA
`noWindowsAvailable` failure produced `tool_failed` and a failed Mac status;
the same SHA was rerun after recovery and passed all ten ordered cases before
merge. Recovery reruns the same SHA and never waives the check.

**PR #17 recovery:** Its first reviewed head failed at Safari case 21 with
`scan_limit` after an unrelated Hacker News page made the Safari Accessibility
tree exceed 400 nodes. The browser verifier now skips descendants of web
areas whose URL differs from the exact fixture URL; it still checks all
matching web areas for duplicates. The outer case uses Safari's `super+n`
new-window shortcut after the visible File menu led to screenshot and offscreen
click errors. A focused case 21 passed with the unrelated window present and
restored its window inventory and Space. The updated head still needs the full
required-gate run.
An exact-source rerun passed Safari case 21 and then encountered Finder case
22 with no Finder window. CUA cannot bind headless Finder on this Mac
(`cgWindowNotFound`). The case 22 harness now prepares one run-owned Finder
window only when its baseline inventory is empty; the agent must observe and
reuse that same window, and the native observer requires its removal afterward.

## Work package 4: bounded TextEdit document workflow

**Implementation status:** PR #16 replaces one exact run-owned existing draft
and reopens it through TextEdit. That path has no Save dialog. The separate
new-document route now exercises TextEdit's Save sheet and has passed two
focused normal runs and a focused canceled Save. The canceled Save showed a
real sheet, produced no note file, returned `unverified`, and restored the
starting windows and Space. Three normal focused saves on an earlier PR #16
revision, wrong-file/wrong-text rejections, synthetic CUA failure, and Stop
at pending CUA approval have
passed. One prepared-window run, one two-window decoy run, and a Debug-only
read-only verifier failure passed with independent TextEdit window transition
evidence, exact file bytes, and restored Space. Several preceding attempts
returned genuine inner CUA `timeoutReached` or `noWindowsAvailable` errors;
those failed receipts remain in the private Mac run directory.

Build this after the trigger is working so its PR exercises the new check.
Start from existing smoke case 3, which types into an unsaved TextEdit document
but does not test Voice Computer routing, saving, or persistence. Add one
route for a run-owned UTF-8 `.txt` file under
`~/Library/Application Support/VoiceComputerPOC/TestFixtures/<run-id>/`.
Accept one exact create/edit/save request with a short run-specific text body.
Reject arbitrary paths, symlinks, existing user files, multiple destinations,
destructive verbs, and ambiguous wording before an acting turn. Keep the
nested agent restricted to TextEdit UI, with no shell or filesystem tool.

The runner prepares a unique fixture directory and records open TextEdit
windows. Computer Use creates or opens the test document, enters the exact
text, saves through the visible UI, closes the test-owned document, and
reopens it. Voice Computer's read-only verifier requires the canonical file
URL, exact UTF-8 bytes, and matching TextEdit document/window state before
reporting `verified`. The outer runner independently checks file bytes,
visible reopened text, window identity, command/tool IDs, frontmost app, and
unchanged Space. If native TextEdit Accessibility cannot establish a stable
document identity, report `unverified` and investigate that narrow gap; do
not infer success from a plausible agent sentence or the file alone.

Focused cases cover three normal unattended runs including TextEdit in the
background; an already-open test-owned document; two test-owned windows with
a decoy; Stop before save; failed CUA; wrong file or text; canceled save;
and a read-only verifier failure. In negatives, assert no unexpected file
write or later actor. Cleanup closes only run-owned windows and removes only
the fixture directory after evidence capture. Preserve unrelated TextEdit
documents. Add parser, route-safety, verifier, and receipt tests tied to the
failure boundaries.

**Gate:** three positive focused runs, all negative variants producing the
expected non-success or no-action result, one full exact-head Mac suite with
the new case, and unchanged starting Space and unrelated window inventory.
If repeated runs reveal a specific focus or document-identity limitation,
measure it first; propose a single typed MCP or app-native action only with
independent verification and a reversible effect.

## Review and release order

1. PR A: deterministic CUA failure-path evidence and the owner-attested
   trigger, with static tests and focused Mac results. A local exact-head suite
   and a live positive trigger dispatch are required before merge.
2. Enable the required Mac check only after it succeeds on two distinct PR
   heads and its failure behavior is observed. This repository setting is a
   separate, visible release gate.
3. PR B: the TextEdit route, verifier, fixture, and tests. Require the exact
   head's green CI, CodeQL, and Mac status before merge once the rule is
   active.
4. Update `docs/tool-capability-inventory.md` after each measured result.
   Keep planned behavior separate from passed hardware evidence.

Keep Codex host-task status disabled until a supported host-aware interface
can report an exact task ID and live state. Do not expand to regular browser
profiles, private documents, speech input, or Foil in this tranche.
